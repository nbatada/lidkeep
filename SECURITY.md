# Security

LidKeep changes a privileged macOS power setting. Its design keeps that
boundary narrow, visible, and reversible.

## Privileged operations

The app requests the standard macOS administrator dialog. It does not install a
sudoers rule or setuid binary.

On first use or helper update, the authorized command copies the bundled native
helper to:

```text
/Library/PrivilegedHelperTools/io.github.lidkeep.LidKeepPowerHelper
```

The copy is bound to a SHA-256 digest captured before the authorization prompt,
installed through a root-owned temporary file, stripped of ACLs, moved into
place, and then checked as a regular root:wheel `0755` file whose bytes match
the pre-prompt source.

For normal operation the app authorizes only:

```text
LidKeepPowerHelper on <numeric-client-pid>
LidKeepPowerHelper off
```

The compiled helper invokes only fixed `/usr/bin/pmset` arguments for state,
battery, and these two changes:

```bash
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

## Safety monitor

ON uses a serialized two-phase transaction. One transient root monitor acquires
a lock and reports READY; the helper enables and verifies ON; the helper commits
the monitor; and success is returned only after a fresh MONITORING heartbeat.
Any ambiguous or partial ON retries OFF until `pmset` confirms normal sleep.

The monitor is tied to the exact client process identity, not only a reusable
PID. It restores and verifies OFF when the client exits, battery reaches 10%,
or state/battery reads fail repeatedly. All `pmset` and process-identity calls
have bounded timeouts. ON/OFF transactions use a separate serialized lock.
If the app owns an awake session but loses the monitor heartbeat, it requests
OFF recovery and refuses to quit until normal sleep is confirmed.

There is no permanent background daemon. The transient root monitor exists only
for a LidKeep-owned ON session.

## Distribution boundary

The local v1.0.0 artifact is ad-hoc signed and not notarized. Ad-hoc signing
does not establish publisher identity. Obtain the artifact from the project
release, verify its SHA-256 checksum, and do not override Gatekeeper for an
artifact you do not trust.

A future Developer ID release should move helper installation to Apple's
ServiceManagement flow. That change requires an Apple Developer identity and is
outside the unsigned v1.0 scope.

## Privacy

LidKeep has no telemetry, analytics, account, cloud service, update framework,
or application network request.

## Reporting

Do not open a public issue for a suspected vulnerability. Use the repository's
**Security → Advisories → Report a vulnerability** form so the report remains
private while maintainers assess it.
