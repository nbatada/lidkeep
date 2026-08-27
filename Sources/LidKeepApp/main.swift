import AppKit
import Darwin
import Foundation
import LidKeepCore

private let monitorStatusPath = "/var/run/lidkeep/monitor.status"

private struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

private enum ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 2
    ) -> ProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }

        let timedOut = finished.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 0.5)
        }

        return ProcessResult(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

private struct SystemSnapshot {
    let state: PowerState
    let batteryPercent: Int?
}

private enum SystemReader {
    static func snapshot() -> SystemSnapshot {
        let stateResult = ProcessRunner.run("/usr/bin/pmset", arguments: ["-g"])
        let state: PowerState
        if stateResult.timedOut {
            state = .unknown("pmset -g timed out")
        } else if stateResult.status != 0 {
            state = .unknown("pmset -g exited \(stateResult.status)")
        } else {
            state = PMSetParser.powerState(from: stateResult.stdout)
        }

        let batteryResult = ProcessRunner.run("/usr/bin/pmset", arguments: ["-g", "batt"])
        let battery = batteryResult.status == 0 && !batteryResult.timedOut
            ? PMSetParser.batteryPercent(from: batteryResult.stdout)
            : nil
        return SystemSnapshot(state: state, batteryPercent: battery)
    }
}

private enum AdminResult {
    case success(String)
    case cancelled
    case failed(String)
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusLine: NSMenuItem!
    private var batteryLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var autoOffLine: NSMenuItem!
    private var monitorLine: NSMenuItem!
    private var heatWarningLine: NSMenuItem!
    private var quitItem: NSMenuItem!
    private var timer: Timer?

    private let workQueue = DispatchQueue(label: "io.github.lidkeep.system-reader")
    private var refreshInFlight = false
    private var busy = false
    private var latestSnapshot = SystemSnapshot(state: .unknown("Checking"), batteryPercent: nil)
    private var ownedMonitorToken: String?
    private var recoveryAttemptedToken: String?
    private var quitAfterRecovery = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        requestRefresh()

        let timer = Timer(timeInterval: 2, target: self, selector: #selector(refreshTimer), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        requestRefresh()
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "… CHECKING"
        statusItem.button?.toolTip = "LidKeep is reading the current macOS sleep state"

        menu = NSMenu()
        menu.delegate = self

        statusLine = disabledItem("Reading lid-close sleep state…")
        batteryLine = disabledItem("Battery: —")
        menu.addItem(statusLine)
        menu.addItem(batteryLine)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "KEEP AWAKE — OFF", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        autoOffLine = disabledItem("Auto-off at 10% battery")
        monitorLine = disabledItem("Safety monitor: —")
        heatWarningLine = disabledItem("⚠️ Do not put an awake Mac in a bag")
        heatWarningLine.isHidden = true
        menu.addItem(autoOffLine)
        menu.addItem(monitorLine)
        menu.addItem(heatWarningLine)
        menu.addItem(.separator())

        quitItem = NSMenuItem(title: "Quit LidKeep", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func refreshTimer() {
        requestRefresh()
    }

    private func requestRefresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        workQueue.async {
            let snapshot = SystemReader.snapshot()
            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.latestSnapshot = snapshot
                if snapshot.state == .sleep {
                    self.ownedMonitorToken = nil
                    self.recoveryAttemptedToken = nil
                }
                self.render(snapshot)
                if snapshot.state == .sleep, self.quitAfterRecovery {
                    NSApp.terminate(nil)
                    return
                }
                self.recoverOwnedSessionIfNeeded(snapshot)
            }
        }
    }

    private func render(_ snapshot: SystemSnapshot) {
        let monitor = ownedMonitorStatus()
        statusItem.button?.image = nil

        switch snapshot.state {
        case .awake:
            statusItem.button?.title = "🟢 AWAKE"
            statusItem.button?.toolTip = "KEEP AWAKE is ON; macOS reports SleepDisabled 1"
            statusItem.button?.setAccessibilityLabel("LidKeep: awake")
            statusLine.title = "Lid close: STAY AWAKE"
            toggleItem.title = "KEEP AWAKE — ON"
            toggleItem.state = .on
            heatWarningLine.isHidden = false

            if let monitor {
                switch monitor.state {
                case "restore_retry":
                    monitorLine.title = "⚠️ Restoring normal sleep; retrying"
                case "starting":
                    monitorLine.title = "Safety monitor: starting"
                default:
                    monitorLine.title = "Safety monitor: active"
                }
                quitItem.title = "Quit LidKeep (restores sleep)"
            } else if ownedMonitorToken != nil {
                monitorLine.title = "⚠️ Safety monitor lost — restore sleep now"
                quitItem.title = "Quit LidKeep (restore required)"
            } else {
                monitorLine.title = "⚠️ No LidKeep safety monitor for this external state"
                quitItem.title = "Quit LidKeep"
            }
        case .sleep:
            statusItem.button?.title = "💤 SLEEP"
            statusItem.button?.toolTip = "KEEP AWAKE is OFF; normal lid-close sleep"
            statusItem.button?.setAccessibilityLabel("LidKeep: normal sleep")
            statusLine.title = "Lid close: SLEEP"
            toggleItem.title = "KEEP AWAKE — OFF"
            toggleItem.state = .off
            monitorLine.title = "Safety monitor: not needed"
            heatWarningLine.isHidden = true
            quitItem.title = "Quit LidKeep"
        case .unknown(let reason):
            statusItem.button?.title = "⚠️ UNKNOWN"
            statusItem.button?.toolTip = "LidKeep could not verify the macOS sleep state"
            statusItem.button?.setAccessibilityLabel("LidKeep: sleep state unknown")
            statusLine.title = "Lid close: UNKNOWN — \(reason)"
            toggleItem.title = "KEEP AWAKE — UNAVAILABLE"
            toggleItem.state = .off
            if monitor?.state == "restore_retry" {
                monitorLine.title = "⚠️ Restoring normal sleep; retrying"
            } else if ownedMonitorToken != nil, monitor == nil {
                monitorLine.title = "⚠️ Safety monitor lost — restore sleep now"
            } else {
                monitorLine.title = "Safety monitor: state unavailable"
            }
            heatWarningLine.isHidden = true
            quitItem.title = ownedMonitorToken != nil && monitor == nil
                ? "Quit LidKeep (restore required)"
                : "Quit LidKeep"
        }

        batteryLine.title = snapshot.batteryPercent.map { "Battery: \($0)%" } ?? "Battery: unavailable"
        toggleItem.isEnabled = !busy && {
            if case .unknown = snapshot.state { return false }
            return true
        }()
    }

    @objc private func toggle() {
        guard !busy else { return }
        busy = true
        render(latestSnapshot)

        workQueue.async {
            let freshSnapshot = SystemReader.snapshot()
            DispatchQueue.main.async {
                self.performToggle(from: freshSnapshot)
            }
        }
    }

    private func performToggle(from snapshot: SystemSnapshot) {
        latestSnapshot = snapshot
        let turnOn: Bool
        switch snapshot.state {
        case .awake:
            turnOn = false
        case .sleep:
            turnOn = true
        case .unknown(let reason):
            busy = false
            render(snapshot)
            showAlert(
                message: "Sleep state is unknown.",
                detail: "LidKeep did not change anything. \(reason)"
            )
            return
        }

        if turnOn {
            switch BatteryPolicy.enableDecision(batteryPercent: snapshot.batteryPercent) {
            case .allowed:
                break
            case .deniedLowBattery(let percent):
                busy = false
                render(snapshot)
                showAlert(
                    message: "KEEP AWAKE is unavailable at \(percent)% battery.",
                    detail: "Charge above 10% before enabling it."
                )
                return
            case .deniedBatteryUnavailable:
                busy = false
                render(snapshot)
                showAlert(
                    message: "Battery state is unavailable.",
                    detail: "For safety, LidKeep did not enable KEEP AWAKE."
                )
                return
            }
        }

        guard ensureHelperInstalled() else {
            busy = false
            render(snapshot)
            return
        }

        let command = PrivilegedBoundary.actionCommand(turnOn: turnOn, clientPID: getpid())
        let result = runAsAdministrator(command)
        switch result {
        case .success(let output):
            if turnOn {
                ownedMonitorToken = parseToken(from: output)
                recoveryAttemptedToken = nil
            }
            verifyChange(expectedAwake: turnOn)
        case .cancelled:
            busy = false
            render(snapshot)
            showAlert(
                message: "KEEP AWAKE was not changed.",
                detail: "Administrator authorization was cancelled."
            )
        case .failed(let detail):
            busy = false
            render(snapshot)
            showAlert(message: "Could not change KEEP AWAKE.", detail: detail)
        }
    }

    private func verifyChange(expectedAwake: Bool) {
        workQueue.async {
            let actual = SystemReader.snapshot()
            DispatchQueue.main.async {
                self.busy = false
                self.latestSnapshot = actual
                if actual.state == .sleep {
                    self.ownedMonitorToken = nil
                    self.recoveryAttemptedToken = nil
                }
                self.render(actual)

                let matched = expectedAwake ? actual.state == .awake : actual.state == .sleep
                if !matched {
                    self.showAlert(
                        message: "macOS did not confirm the requested state.",
                        detail: "LidKeep is showing the state reported by pmset and will keep checking."
                    )
                }
                if actual.state == .sleep, self.quitAfterRecovery {
                    NSApp.terminate(nil)
                    return
                }
                self.recoverOwnedSessionIfNeeded(actual)
            }
        }
    }

    private func recoverOwnedSessionIfNeeded(_ snapshot: SystemSnapshot) {
        let monitorVerified = ownedMonitorStatus() != nil
        guard let token = ownedMonitorToken,
              OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
                  powerState: snapshot.state,
                  ownsSession: true,
                  monitorVerified: monitorVerified
              ),
              recoveryAttemptedToken != token,
              !busy else {
            return
        }

        recoveryAttemptedToken = token
        busy = true
        render(snapshot)

        guard ensureHelperInstalled() else {
            busy = false
            render(snapshot)
            showLostMonitorAlert(
                detail: "The power helper could not be verified. Use KEEP AWAKE to turn normal sleep back on now."
            )
            return
        }

        switch runAsAdministrator(
            PrivilegedBoundary.actionCommand(turnOn: false, clientPID: getpid())
        ) {
        case .success:
            verifyChange(expectedAwake: false)
        case .cancelled:
            busy = false
            render(snapshot)
            showLostMonitorAlert(
                detail: "Administrator authorization was cancelled. Use KEEP AWAKE to turn normal sleep back on now."
            )
        case .failed(let detail):
            busy = false
            render(snapshot)
            showLostMonitorAlert(
                detail: "LidKeep could not restore normal sleep: \(detail) Use KEEP AWAKE to try again now."
            )
        }
    }

    private func showLostMonitorAlert(detail: String) {
        showAlert(
            message: "The safety monitor was lost while KEEP AWAKE remained on.",
            detail: detail
        )
    }

    private func ensureHelperInstalled() -> Bool {
        guard let bundledURL = Bundle.main.url(forResource: "LidKeepPowerHelper", withExtension: nil) else {
            showAlert(
                message: "The power helper is missing.",
                detail: "Reinstall LidKeep from a complete release bundle."
            )
            return false
        }

        guard let expectedData = try? Data(contentsOf: bundledURL),
              let expectedSHA256 = sha256(at: bundledURL),
              expectedSHA256.count == 64 else {
            showAlert(
                message: "The bundled power helper could not be verified.",
                detail: "LidKeep did not request administrator access."
            )
            return false
        }

        if installedHelperMatches(expectedData: expectedData) { return true }

        let result = runAsAdministrator(
            PrivilegedBoundary.installCommand(
                bundledHelperPath: bundledURL.path,
                expectedSHA256: expectedSHA256,
                clientPID: getpid()
            )
        )
        switch result {
        case .success:
            guard installedHelperMatches(expectedData: expectedData) else {
                showAlert(
                    message: "The power helper could not be verified.",
                    detail: "LidKeep did not change the sleep setting."
                )
                return false
            }
            return true
        case .cancelled:
            showAlert(
                message: "KEEP AWAKE was not changed.",
                detail: "Administrator authorization was cancelled before installing the helper."
            )
            return false
        case .failed(let detail):
            showAlert(message: "Could not install the power helper.", detail: detail)
            return false
        }
    }

    private func sha256(at url: URL) -> String? {
        let result = ProcessRunner.run("/usr/bin/shasum", arguments: ["-a", "256", url.path])
        guard result.status == 0, !result.timedOut else { return nil }
        let digest = result.stdout.split(whereSeparator: \Character.isWhitespace).first.map(String.init)
        guard let digest,
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return digest.lowercased()
    }

    private func installedHelperMatches(expectedData: Data) -> Bool {
        let installedURL = URL(fileURLWithPath: PrivilegedBoundary.helperPath)
        var fileInfo = stat()
        let listing = ProcessRunner.run("/bin/ls", arguments: ["-lde", installedURL.path], timeout: 1)
        let permissionToken = listing.stdout.split(whereSeparator: \Character.isWhitespace).first

        guard lstat(installedURL.path, &fileInfo) == 0,
              fileInfo.st_uid == 0,
              fileInfo.st_gid == 0,
              fileInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              fileInfo.st_mode & 0o7777 == 0o755,
              listing.status == 0,
              !listing.timedOut,
              permissionToken?.contains("+") == false,
              FileManager.default.isExecutableFile(atPath: installedURL.path),
              let installedData = try? Data(contentsOf: installedURL) else {
            return false
        }
        return installedData == expectedData
    }

    private func runAsAdministrator(_ command: String) -> AdminResult {
        let escaped = PrivilegedBoundary.appleScriptString(command)
        guard let script = NSAppleScript(
            source: #"do shell script "\#(escaped)" with administrator privileges"#
        ) else {
            return .failed("Could not create the macOS authorization request.")
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            if number == -128 { return .cancelled }
            let message = (error[NSAppleScript.errorMessage] as? String)
                ?? "Administrator authorization failed."
            return .failed(message)
        }
        return .success(result.stringValue ?? "")
    }

    private func parseToken(from output: String) -> String? {
        output.split(whereSeparator: \Character.isWhitespace)
            .first(where: { $0.hasPrefix("token=") })
            .map { String($0.dropFirst("token=".count)) }
    }

    private func ownedMonitorStatus() -> MonitorStatus? {
        guard let ownedMonitorToken,
              let text = try? String(contentsOfFile: monitorStatusPath, encoding: .utf8),
              let status = MonitorStatus(text: text),
              status.clientPID == getpid(),
              status.token == ownedMonitorToken,
              let monitorPID = status.monitorPID,
              let heartbeat = status.heartbeatEpoch,
              Date().timeIntervalSince1970 - heartbeat <= 8,
              processExists(monitorPID) else {
            return nil
        }
        return status
    }

    private func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func showAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func quitApp() {
        if OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
            powerState: latestSnapshot.state,
            ownsSession: ownedMonitorToken != nil,
            monitorVerified: ownedMonitorStatus() != nil
        ) {
            quitAfterRecovery = true
            recoveryAttemptedToken = nil
            recoverOwnedSessionIfNeeded(latestSnapshot)
            return
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
