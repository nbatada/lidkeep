import Darwin
import Foundation
import LidKeepCore

private let helperVersion = "1.0.0"
private let stateDirectory = "/var/run/lidkeep"
private let monitorLockPath = "\(stateDirectory)/monitor.lock"
private let actionLockPath = "\(stateDirectory)/action.lock"
private let statusPath = "\(stateDirectory)/monitor.status"

private enum HelperFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message): return message
        }
    }
}

private struct CommandOutput {
    let status: Int32
    let stdout: String
    let stderr: String
}

private func runCommand(
    _ executable: String,
    arguments: [String],
    timeout: TimeInterval = 2
) throws -> CommandOutput {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    let finished = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = stdout
    process.standardError = stderr
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 0.5)
        }
    }

    return CommandOutput(
        status: timedOut ? -1 : process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: timedOut
            ? "\(executable) timed out"
            : String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func runPMSet(_ arguments: [String]) throws -> CommandOutput {
    try runCommand("/usr/bin/pmset", arguments: arguments)
}

private func currentPowerState() -> PowerState {
    do {
        let result = try runPMSet(["-g"])
        guard result.status == 0 else {
            return .unknown("pmset -g exited \(result.status)")
        }
        return PMSetParser.powerState(from: result.stdout)
    } catch {
        return .unknown("pmset -g failed: \(error.localizedDescription)")
    }
}

private func currentBatteryPercent() -> Int? {
    guard let result = try? runPMSet(["-g", "batt"]), result.status == 0 else {
        return nil
    }
    return PMSetParser.batteryPercent(from: result.stdout)
}

@discardableResult
private func setPowerState(awake: Bool) -> Bool {
    guard let result = try? runPMSet(["-a", "disablesleep", awake ? "1" : "0"]),
          result.status == 0 else {
        return false
    }
    let state = currentPowerState()
    return awake ? state == .awake : state == .sleep
}

private func processExists(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func processIdentity(_ pid: Int32) -> String? {
    guard processExists(pid),
          let result = try? runCommand(
            "/bin/ps",
            arguments: ["-p", String(pid), "-o", "lstart=", "-o", "comm="],
            timeout: 1
          ),
          result.status == 0 else {
        return nil
    }
    let identity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return identity.isEmpty ? nil : identity
}

private func prepareStateDirectory() throws {
    try FileManager.default.createDirectory(
        atPath: stateDirectory,
        withIntermediateDirectories: true
    )
    guard chown(stateDirectory, 0, 0) == 0, chmod(stateDirectory, 0o755) == 0 else {
        throw HelperFailure.message("Could not secure \(stateDirectory)")
    }
}

private func validToken(_ token: String) -> Bool {
    !token.isEmpty && token.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789ABCDEF-").contains($0)
    }
}

private func readyPath(token: String) -> String {
    "\(stateDirectory)/ready-\(token)"
}

private func commitPath(token: String) -> String {
    "\(stateDirectory)/commit-\(token)"
}

private func acquireActionLock() throws -> Int32 {
    try prepareStateDirectory()
    let lockFD = open(actionLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard lockFD >= 0 else {
        throw HelperFailure.message("Could not open the power action lock")
    }
    guard fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0 else {
        close(lockFD)
        throw HelperFailure.message("Could not secure the power action lock descriptor")
    }
    guard flock(lockFD, LOCK_EX) == 0 else {
        close(lockFD)
        throw HelperFailure.message("Could not lock the power action transaction")
    }
    return lockFD
}

private func releaseLock(_ lockFD: Int32) {
    _ = flock(lockFD, LOCK_UN)
    close(lockFD)
}

private func writeStatus(
    state: String,
    clientPID: Int32? = nil,
    monitorPID: Int32? = nil,
    token: String? = nil,
    detail: String? = nil
) {
    var lines = ["state=\(state)"]
    if let clientPID { lines.append("client_pid=\(clientPID)") }
    if let monitorPID { lines.append("monitor_pid=\(monitorPID)") }
    if let token { lines.append("token=\(token)") }
    lines.append("heartbeat_epoch=\(Int(Date().timeIntervalSince1970))")
    if let detail {
        let safeDetail = detail.replacingOccurrences(of: "\n", with: " ")
        lines.append("detail=\(safeDetail)")
    }
    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: statusPath, atomically: true, encoding: .utf8)
        _ = chown(statusPath, 0, 0)
        _ = chmod(statusPath, 0o644)
    } catch {
        // Power restoration remains authoritative even if status publication fails.
    }
}

private func restoreNormalSleepUntilVerified(
    clientPID: Int32,
    monitorPID: Int32,
    token: String,
    reason: String
) {
    while true {
        if setPowerState(awake: false) {
            writeStatus(state: "off", detail: reason)
            return
        }
        writeStatus(
            state: "restore_retry",
            clientPID: clientPID,
            monitorPID: monitorPID,
            token: token,
            detail: reason
        )
        sleep(5)
    }
}

private func restoreFromMonitorAndExit(
    clientPID: Int32,
    monitorPID: Int32,
    token: String,
    reason: String
) -> Never {
    let actionLock = try? acquireActionLock()
    restoreNormalSleepUntilVerified(
        clientPID: clientPID,
        monitorPID: monitorPID,
        token: token,
        reason: reason
    )
    if let actionLock { releaseLock(actionLock) }
    exit(EXIT_SUCCESS)
}

private func runMonitor(clientPID: Int32, clientIdentity: String, token: String) throws -> Never {
    guard geteuid() == 0 else {
        throw HelperFailure.message("The monitor must run as root")
    }
    guard processIdentity(clientPID) == clientIdentity, validToken(token) else {
        throw HelperFailure.message("Invalid monitor identity")
    }

    try prepareStateDirectory()
    let lockFD = open(monitorLockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
    guard lockFD >= 0 else {
        throw HelperFailure.message("Could not open the monitor lock")
    }
    guard fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0 else {
        close(lockFD)
        throw HelperFailure.message("Could not secure the monitor lock descriptor")
    }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
        close(lockFD)
        throw HelperFailure.message("Another LidKeep safety monitor is active")
    }

    _ = signal(SIGHUP, SIG_IGN)
    let monitorPID = getpid()
    let ready = readyPath(token: token)
    let commit = commitPath(token: token)
    defer {
        _ = unlink(ready)
        _ = unlink(commit)
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
    }

    FileManager.default.createFile(atPath: ready, contents: Data())
    _ = chown(ready, 0, 0)
    _ = chmod(ready, 0o644)
    writeStatus(
        state: "starting",
        clientPID: clientPID,
        monitorPID: monitorPID,
        token: token
    )

    let commitDeadline = Date().addingTimeInterval(10)
    while Date() < commitDeadline, !FileManager.default.fileExists(atPath: commit) {
        if processIdentity(clientPID) != clientIdentity {
            restoreFromMonitorAndExit(
                clientPID: clientPID,
                monitorPID: monitorPID,
                token: token,
                reason: "controlling app exited during startup"
            )
        }
        usleep(50_000)
    }

    guard FileManager.default.fileExists(atPath: commit) else {
        restoreFromMonitorAndExit(
            clientPID: clientPID,
            monitorPID: monitorPID,
            token: token,
            reason: "monitor startup was not committed"
        )
    }

    guard currentPowerState() == .awake else {
        restoreFromMonitorAndExit(
            clientPID: clientPID,
            monitorPID: monitorPID,
            token: token,
            reason: "KEEP AWAKE was not confirmed at monitor commit"
        )
    }

    _ = unlink(ready)
    _ = unlink(commit)
    writeStatus(
        state: "monitoring",
        clientPID: clientPID,
        monitorPID: monitorPID,
        token: token
    )

    var stateReadFailures = 0
    var batteryReadFailures = 0
    var batteryTick = 0

    while true {
        let identityMatches = processIdentity(clientPID) == clientIdentity
        let powerState = currentPowerState()
        switch powerState {
        case .awake, .sleep:
            stateReadFailures = 0
        case .unknown:
            stateReadFailures += 1
        }

        let batteryCheckDue = batteryTick == 0
        let battery = batteryCheckDue ? currentBatteryPercent() : nil
        if batteryCheckDue {
            if battery != nil {
                batteryReadFailures = 0
            } else {
                batteryReadFailures += 1
            }
        }

        switch MonitorSafetyPolicy.decision(
            clientIdentityMatches: identityMatches,
            powerState: powerState,
            consecutiveStateReadFailures: stateReadFailures,
            batteryCheckDue: batteryCheckDue,
            batteryPercent: battery,
            consecutiveBatteryReadFailures: batteryReadFailures
        ) {
        case .continueMonitoring:
            break
        case .stopMonitoring:
            writeStatus(state: "off", detail: "normal sleep restored externally")
            exit(EXIT_SUCCESS)
        case .restoreNormalSleep(let reason):
            restoreFromMonitorAndExit(
                clientPID: clientPID,
                monitorPID: monitorPID,
                token: token,
                reason: reason
            )
        }

        writeStatus(
            state: "monitoring",
            clientPID: clientPID,
            monitorPID: monitorPID,
            token: token
        )
        batteryTick = (batteryTick + 1) % 15
        sleep(2)
    }
}

private func enable(clientPID: Int32) throws {
    guard geteuid() == 0 else {
        throw HelperFailure.message("Administrator authorization is required")
    }
    guard let clientIdentity = processIdentity(clientPID) else {
        throw HelperFailure.message("The LidKeep client process is not running")
    }

    let actionLock = try acquireActionLock()
    defer { releaseLock(actionLock) }

    guard currentPowerState() == .sleep else {
        throw HelperFailure.message("Normal sleep must be confirmed before enabling KEEP AWAKE")
    }

    switch BatteryPolicy.enableDecision(batteryPercent: currentBatteryPercent()) {
    case .allowed:
        break
    case .deniedLowBattery(let percent):
        throw HelperFailure.message("KEEP AWAKE is unavailable at \(percent)% battery")
    case .deniedBatteryUnavailable:
        throw HelperFailure.message("Battery state is unavailable; KEEP AWAKE was not enabled")
    }

    try prepareStateDirectory()
    let token = UUID().uuidString
    let ready = readyPath(token: token)
    let commit = commitPath(token: token)
    _ = unlink(ready)
    _ = unlink(commit)

    let monitor = Process()
    monitor.executableURL = URL(fileURLWithPath: PrivilegedBoundary.helperPath)
    monitor.arguments = ["monitor", String(clientPID), clientIdentity, token]
    monitor.standardInput = FileHandle.nullDevice
    monitor.standardOutput = FileHandle.nullDevice
    monitor.standardError = FileHandle.nullDevice
    try monitor.run()

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !FileManager.default.fileExists(atPath: ready) {
        if !monitor.isRunning { break }
        usleep(50_000)
    }

    guard monitor.isRunning, FileManager.default.fileExists(atPath: ready) else {
        if monitor.isRunning { monitor.terminate() }
        throw HelperFailure.message("The battery safety monitor did not become ready")
    }

    let enabled = SafeEnableTransaction.finishPreparedEnable(
        setAwake: {
            setPowerState(awake: true)
        },
        commitMonitor: {
            do {
                try Data().write(to: URL(fileURLWithPath: commit), options: .atomic)
                _ = chown(commit, 0, 0)
                _ = chmod(commit, 0o644)
                return true
            } catch {
                return false
            }
        },
        confirmMonitoring: {
            let monitoringDeadline = Date().addingTimeInterval(3)
            while Date() < monitoringDeadline, monitor.isRunning {
                if let text = try? String(contentsOfFile: statusPath, encoding: .utf8),
                   let status = MonitorStatus(text: text),
                   status.state == "monitoring",
                   status.clientPID == clientPID,
                   status.monitorPID == monitor.processIdentifier,
                   status.token == token,
                   let heartbeat = status.heartbeatEpoch,
                   Date().timeIntervalSince1970 - heartbeat <= 3 {
                    return true
                }
                usleep(50_000)
            }
            return false
        },
        restoreNormalSleepUntilVerified: {
            restoreNormalSleepUntilVerified(
                clientPID: clientPID,
                monitorPID: monitor.processIdentifier,
                token: token,
                reason: "prepared enable transaction did not complete"
            )
        }
    )

    guard enabled else {
        if monitor.isRunning { monitor.terminate() }
        throw HelperFailure.message("KEEP AWAKE was not safely established; normal sleep was restored")
    }

    guard monitor.isRunning else {
        restoreNormalSleepUntilVerified(
            clientPID: clientPID,
            monitorPID: monitor.processIdentifier,
            token: token,
            reason: "monitor exited after startup confirmation"
        )
        throw HelperFailure.message("Safety monitor exited; normal sleep was restored")
    }

    print("OK ON token=\(token) monitor_pid=\(monitor.processIdentifier)")
}

private func disable() throws {
    guard geteuid() == 0 else {
        throw HelperFailure.message("Administrator authorization is required")
    }

    let actionLock = try acquireActionLock()
    defer { releaseLock(actionLock) }

    if !setPowerState(awake: false) {
        restoreNormalSleepUntilVerified(
            clientPID: 0,
            monitorPID: 0,
            token: "",
            reason: "user requested normal sleep"
        )
    }
    writeStatus(state: "off", detail: "normal sleep restored by user")
    print("OK OFF")
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--version"] {
        print("LidKeepPowerHelper \(helperVersion)")
        return
    }

    switch arguments.first {
    case "on" where arguments.count == 2:
        guard let clientPID = Int32(arguments[1]), clientPID > 1 else {
            throw HelperFailure.message("Usage: LidKeepPowerHelper on <client-pid>")
        }
        try enable(clientPID: clientPID)
    case "off" where arguments.count == 1:
        try disable()
    case "monitor" where arguments.count == 4:
        guard let clientPID = Int32(arguments[1]), clientPID > 1 else {
            throw HelperFailure.message("Invalid monitor client PID")
        }
        try runMonitor(clientPID: clientPID, clientIdentity: arguments[2], token: arguments[3])
    default:
        throw HelperFailure.message("Usage: LidKeepPowerHelper {on <client-pid>|off|--version}")
    }
}

do {
    try run()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}
