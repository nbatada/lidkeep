import Foundation

public enum PowerState: Equatable, Sendable {
    case awake
    case sleep
    case unknown(String)

    public var isAwake: Bool {
        if case .awake = self { return true }
        return false
    }
}

public enum EnableDecision: Equatable, Sendable {
    case allowed
    case deniedLowBattery(Int)
    case deniedBatteryUnavailable
}

public enum PMSetParser {
    public static func powerState(from output: String) -> PowerState {
        var tahoeValues: [String] = []
        var legacyValues: [String] = []

        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }

            switch fields[0] {
            case "SleepDisabled":
                tahoeValues.append(String(fields[1]))
            case "disablesleep":
                legacyValues.append(String(fields[1]))
            default:
                continue
            }
        }

        if !tahoeValues.isEmpty {
            return classify(key: "SleepDisabled", values: tahoeValues)
        }
        if !legacyValues.isEmpty {
            return classify(key: "disablesleep", values: legacyValues)
        }
        return .unknown("pmset output did not contain SleepDisabled")
    }

    public static func batteryPercent(from output: String) -> Int? {
        guard let range = output.range(
            of: #"(?<![0-9])[0-9]{1,3}%"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let token = output[range].dropLast()
        guard let value = Int(token), (0...100).contains(value) else {
            return nil
        }
        return value
    }

    private static func classify(key: String, values: [String]) -> PowerState {
        guard values.count == 1 else {
            return .unknown("pmset output contained duplicate \(key) values")
        }

        switch values[0] {
        case "1":
            return .awake
        case "0":
            return .sleep
        default:
            return .unknown("pmset reported unsupported \(key)=\(values[0])")
        }
    }
}

public enum BatteryPolicy {
    public static let cutoffPercent = 10

    public static func enableDecision(batteryPercent: Int?) -> EnableDecision {
        guard let batteryPercent else {
            return .deniedBatteryUnavailable
        }
        if batteryPercent <= cutoffPercent {
            return .deniedLowBattery(batteryPercent)
        }
        return .allowed
    }

    public static func shouldRestoreNormalSleep(batteryPercent: Int?) -> Bool {
        guard let batteryPercent else { return false }
        return batteryPercent <= cutoffPercent
    }
}

public enum SafeEnableTransaction {
    public static func finishPreparedEnable(
        setAwake: () -> Bool,
        commitMonitor: () -> Bool,
        confirmMonitoring: () -> Bool,
        restoreNormalSleepUntilVerified: () -> Void
    ) -> Bool {
        guard setAwake() else {
            restoreNormalSleepUntilVerified()
            return false
        }
        guard commitMonitor() else {
            restoreNormalSleepUntilVerified()
            return false
        }
        guard confirmMonitoring() else {
            restoreNormalSleepUntilVerified()
            return false
        }
        return true
    }
}

public enum MonitorDecision: Equatable, Sendable {
    case continueMonitoring
    case stopMonitoring
    case restoreNormalSleep(String)
}

public enum MonitorSafetyPolicy {
    public static func decision(
        clientIdentityMatches: Bool,
        powerState: PowerState,
        consecutiveStateReadFailures: Int,
        batteryCheckDue: Bool,
        batteryPercent: Int?,
        consecutiveBatteryReadFailures: Int
    ) -> MonitorDecision {
        if !clientIdentityMatches {
            return .restoreNormalSleep("controlling app exited")
        }
        if powerState == .sleep {
            return .stopMonitoring
        }
        if consecutiveStateReadFailures >= 3 {
            return .restoreNormalSleep("power state became unreadable")
        }
        if batteryCheckDue,
           let batteryPercent,
           BatteryPolicy.shouldRestoreNormalSleep(batteryPercent: batteryPercent) {
            return .restoreNormalSleep("battery reached \(batteryPercent)%")
        }
        if batteryCheckDue, batteryPercent == nil, consecutiveBatteryReadFailures >= 3 {
            return .restoreNormalSleep("battery state became unreadable")
        }
        return .continueMonitoring
    }
}

public enum OwnedSessionSafetyPolicy {
    public static func requiresRestoreBeforeExit(
        powerState: PowerState,
        ownsSession: Bool,
        monitorVerified: Bool
    ) -> Bool {
        ownsSession && !monitorVerified && powerState != .sleep
    }
}

public enum PrivilegedBoundary {
    public static let helperIdentifier = "io.github.lidkeep.LidKeepPowerHelper"
    public static let helperPath = "/Library/PrivilegedHelperTools/\(helperIdentifier)"
    public static let installedAppPath = "/Applications/LidKeep.app"

    public static func actionCommand(turnOn: Bool, clientPID: Int32) -> String {
        precondition(clientPID > 1)
        let action = turnOn ? "on \(clientPID)" : "off"
        return "\(shellQuote(helperPath)) \(action)"
    }

    public static func installCommand(
        bundledHelperPath: String,
        expectedSHA256: String,
        clientPID: Int32
    ) -> String {
        precondition(expectedSHA256.count == 64)
        precondition(expectedSHA256.allSatisfy { $0.isHexDigit })
        precondition(clientPID > 1)
        let source = shellQuote(bundledHelperPath)
        let destination = shellQuote(helperPath)
        let temporary = shellQuote("\(helperPath).install-\(clientPID)")
        let digest = shellQuote(expectedSHA256.lowercased())
        return [
            "/bin/rm -f \(temporary)",
            "/usr/bin/install -o root -g wheel -m 0755 \(source) \(temporary) || exit $?",
            "actual=$(/usr/bin/shasum -a 256 \(temporary) | /usr/bin/awk '{print $1}')",
            "if [ \"$actual\" != \(digest) ]; then /bin/rm -f \(temporary); exit 65; fi",
            "/bin/chmod -N \(temporary)",
            "/bin/mv -f \(temporary) \(destination)",
        ].joined(separator: "; ")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct MonitorStatus: Equatable, Sendable {
    public let state: String
    public let clientPID: Int32?
    public let monitorPID: Int32?
    public let token: String?
    public let heartbeatEpoch: TimeInterval?

    public init?(text: String) {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \Character.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            values[String(pair[0])] = String(pair[1])
        }
        guard let state = values["state"] else { return nil }
        self.state = state
        self.clientPID = values["client_pid"].flatMap(Int32.init)
        self.monitorPID = values["monitor_pid"].flatMap(Int32.init)
        self.token = values["token"]
        self.heartbeatEpoch = values["heartbeat_epoch"].flatMap(TimeInterval.init)
    }
}
