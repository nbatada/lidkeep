import Darwin
import Foundation
import LidKeepCore

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func isUnknown(_ state: PowerState) -> Bool {
    if case .unknown = state { return true }
    return false
}

expect(
    PMSetParser.powerState(from: "System-wide power settings:\n SleepDisabled\t\t1\n") == .awake,
    "Tahoe SleepDisabled=1 must parse as awake"
)
expect(
    PMSetParser.powerState(from: "System-wide power settings:\n SleepDisabled 0\n") == .sleep,
    "Tahoe SleepDisabled=0 must parse as sleep"
)
expect(
    PMSetParser.powerState(from: "SleepDisabled 0\ndisablesleep 1\n") == .sleep,
    "Tahoe key must take precedence over the legacy key"
)
expect(
    PMSetParser.powerState(from: " disablesleep 1\n") == .awake,
    "legacy disablesleep must remain supported"
)
expect(isUnknown(PMSetParser.powerState(from: "sleep 1\n")), "missing state must be unknown")
expect(
    isUnknown(PMSetParser.powerState(from: "SleepDisabled 1\nSleepDisabled 1\n")),
    "duplicate state must be unknown"
)
expect(
    isUnknown(PMSetParser.powerState(from: "SleepDisabled 2\n")),
    "unsupported state must be unknown"
)

expect(
    PMSetParser.batteryPercent(from: "-InternalBattery-0\t72%; discharging; present: true") == 72,
    "battery percentage must parse from pmset output"
)
expect(PMSetParser.batteryPercent(from: "10%; charged") == 10, "10% boundary must parse")
expect(PMSetParser.batteryPercent(from: "Battery unavailable") == nil, "missing battery must be nil")
expect(PMSetParser.batteryPercent(from: "101%; invalid") == nil, "invalid battery must be nil")

expect(BatteryPolicy.enableDecision(batteryPercent: 11) == .allowed, "11% must permit ON")
expect(
    BatteryPolicy.enableDecision(batteryPercent: 10) == .deniedLowBattery(10),
    "10% must reject ON"
)
expect(
    BatteryPolicy.enableDecision(batteryPercent: 9) == .deniedLowBattery(9),
    "9% must reject ON"
)
expect(
    BatteryPolicy.enableDecision(batteryPercent: nil) == .deniedBatteryUnavailable,
    "unknown battery must fail closed"
)
expect(!BatteryPolicy.shouldRestoreNormalSleep(batteryPercent: 11), "11% must not cut off")
expect(BatteryPolicy.shouldRestoreNormalSleep(batteryPercent: 10), "10% must cut off")

var restored = false
let failedEnable = SafeEnableTransaction.finishPreparedEnable(
    setAwake: { false },
    commitMonitor: { true },
    confirmMonitoring: { true },
    restoreNormalSleepUntilVerified: { restored = true }
)
expect(!failedEnable && restored, "ambiguous ON must run verified rollback")

restored = false
let failedCommit = SafeEnableTransaction.finishPreparedEnable(
    setAwake: { true },
    commitMonitor: { false },
    confirmMonitoring: { true },
    restoreNormalSleepUntilVerified: { restored = true }
)
expect(!failedCommit && restored, "failed monitor commit must run verified rollback")

restored = false
let failedMonitoring = SafeEnableTransaction.finishPreparedEnable(
    setAwake: { true },
    commitMonitor: { true },
    confirmMonitoring: { false },
    restoreNormalSleepUntilVerified: { restored = true }
)
expect(!failedMonitoring && restored, "failed monitoring confirmation must run verified rollback")

restored = false
let successfulEnable = SafeEnableTransaction.finishPreparedEnable(
    setAwake: { true },
    commitMonitor: { true },
    confirmMonitoring: { true },
    restoreNormalSleepUntilVerified: { restored = true }
)
expect(successfulEnable && !restored, "confirmed monitoring must not roll back")

expect(
    MonitorSafetyPolicy.decision(
        clientIdentityMatches: false,
        powerState: .awake,
        consecutiveStateReadFailures: 0,
        batteryCheckDue: false,
        batteryPercent: 72,
        consecutiveBatteryReadFailures: 0
    ) == .restoreNormalSleep("controlling app exited"),
    "client crash must restore normal sleep"
)
expect(
    MonitorSafetyPolicy.decision(
        clientIdentityMatches: true,
        powerState: .awake,
        consecutiveStateReadFailures: 0,
        batteryCheckDue: true,
        batteryPercent: 10,
        consecutiveBatteryReadFailures: 0
    ) == .restoreNormalSleep("battery reached 10%"),
    "10% monitor sample must restore normal sleep"
)
expect(
    MonitorSafetyPolicy.decision(
        clientIdentityMatches: true,
        powerState: .unknown("timeout"),
        consecutiveStateReadFailures: 3,
        batteryCheckDue: false,
        batteryPercent: nil,
        consecutiveBatteryReadFailures: 0
    ) == .restoreNormalSleep("power state became unreadable"),
    "three unreadable state samples must fail safe"
)
expect(
    MonitorSafetyPolicy.decision(
        clientIdentityMatches: true,
        powerState: .awake,
        consecutiveStateReadFailures: 0,
        batteryCheckDue: true,
        batteryPercent: nil,
        consecutiveBatteryReadFailures: 3
    ) == .restoreNormalSleep("battery state became unreadable"),
    "three unreadable battery samples must fail safe"
)

expect(
    OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
        powerState: .awake,
        ownsSession: true,
        monitorVerified: false
    ),
    "owned awake session without a monitor must restore before exit"
)
expect(
    OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
        powerState: .unknown("timeout"),
        ownsSession: true,
        monitorVerified: false
    ),
    "owned unknown session without a monitor must fail safe before exit"
)
expect(
    !OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
        powerState: .sleep,
        ownsSession: true,
        monitorVerified: false
    ),
    "confirmed normal sleep does not require another restore"
)
expect(
    !OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
        powerState: .awake,
        ownsSession: true,
        monitorVerified: true
    ),
    "a verified monitor owns restoration when the app exits"
)
expect(
    !OwnedSessionSafetyPolicy.requiresRestoreBeforeExit(
        powerState: .awake,
        ownsSession: false,
        monitorVerified: false
    ),
    "an external awake state is not claimed as an owned session"
)

expect(
    PrivilegedBoundary.actionCommand(turnOn: true, clientPID: 123)
        == "'/Library/PrivilegedHelperTools/io.github.lidkeep.LidKeepPowerHelper' on 123",
    "ON command must use only the fixed helper path and numeric PID"
)
expect(
    PrivilegedBoundary.actionCommand(turnOn: false, clientPID: 123)
        == "'/Library/PrivilegedHelperTools/io.github.lidkeep.LidKeepPowerHelper' off",
    "OFF command must use only the fixed helper path"
)
expect(
    PrivilegedBoundary.installCommand(
        bundledHelperPath: "/tmp/LidKeep's Helper",
        expectedSHA256: String(repeating: "a", count: 64),
        clientPID: 123
    ).contains(
        "/usr/bin/install -o root -g wheel -m 0755 '/tmp/LidKeep'\\''s Helper' '/Library/PrivilegedHelperTools/io.github.lidkeep.LidKeepPowerHelper.install-123'"
    ),
    "helper install source and temporary path must be shell quoted"
)
expect(
    PrivilegedBoundary.installCommand(
        bundledHelperPath: "/tmp/helper",
        expectedSHA256: String(repeating: "b", count: 64),
        clientPID: 123
    ).contains("if [ \"$actual\" != 'bbbb"),
    "helper install must bind the privileged copy to the pre-prompt digest"
)

let status = MonitorStatus(
    text: "state=monitoring\nclient_pid=123\nmonitor_pid=456\ntoken=ABC\nheartbeat_epoch=123456\n"
)
expect(status?.state == "monitoring", "monitor state must parse")
expect(status?.clientPID == 123, "monitor client PID must parse")
expect(status?.monitorPID == 456, "monitor PID must parse")
expect(status?.token == "ABC", "monitor token must parse")
expect(status?.heartbeatEpoch == 123456, "monitor heartbeat must parse")
expect(MonitorStatus(text: "client_pid=123\n") == nil, "status without state must fail")

if failures > 0 {
    fputs("\(failures) LidKeep core test(s) failed.\n", stderr)
    exit(EXIT_FAILURE)
}

print("PASS: LidKeep core tests")
