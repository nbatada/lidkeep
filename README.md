# LidKeep

Keep a MacBook running with the lid closed, and see the current state at a
glance.

<p align="center">
  <img src="docs/assets/lidkeep-awake.png" width="220" alt="LidKeep showing AWAKE in the macOS menu bar">
  &nbsp;&nbsp;
  <img src="docs/assets/lidkeep-sleep.png" width="220" alt="LidKeep showing SLEEP in the macOS menu bar">
</p>

LidKeep is a small native macOS menu-bar app. It has one control,
`KEEP AWAKE`, and reads the current state directly from macOS instead of
trusting cached application state.

**Current release:** v1.0.0 · Apple silicon · macOS 13 or later

## Download

Download these two files from the
[latest GitHub release](https://github.com/nbatada/lidkeep/releases/latest):

- [LidKeep-v1.0.0-macOS.zip](https://github.com/nbatada/lidkeep/releases/download/v1.0.0/LidKeep-v1.0.0-macOS.zip)
- [LidKeep-v1.0.0-macOS.zip.sha256](https://github.com/nbatada/lidkeep/releases/download/v1.0.0/LidKeep-v1.0.0-macOS.zip.sha256)

Verify the download in Terminal:

```bash
cd ~/Downloads
shasum -a 256 -c LidKeep-v1.0.0-macOS.zip.sha256
```

You should see:

```text
LidKeep-v1.0.0-macOS.zip: OK
```

Unzip the archive, move `LidKeep.app` to `/Applications`, and open it.

### First launch

LidKeep v1.0.0 is ad-hoc signed and is **not notarized**. If macOS blocks the
first launch:

1. Try to open LidKeep once.
2. Open **System Settings → Privacy & Security**.
3. Select **Open Anyway** only if you downloaded LidKeep from this repository
   and verified the checksum.

This is Apple's documented process for
[opening an app from an unidentified developer](https://support.apple.com/102445).
LidKeep never disables Gatekeeper or removes quarantine attributes.

## Use

The menu-bar label always reflects the state reported by macOS:

- `🟢 AWAKE` — closing the lid will not trigger normal sleep.
- `💤 SLEEP` — normal lid-close sleep is enabled.
- `⚠️ UNKNOWN` — LidKeep could not verify the setting, so the control is
  disabled.

Open the menu and select `KEEP AWAKE` to change the state. macOS requests
administrator authorization for the first helper installation and for each
ON/OFF change.

## Safety

When LidKeep turns KEEP AWAKE on, a temporary safety monitor:

- refuses to start at 10% battery or lower;
- restores normal sleep when the battery reaches 10%;
- restores normal sleep if LidKeep quits or crashes;
- restores normal sleep after repeated unreadable power or battery state;
- requests recovery if its monitor heartbeat is lost.

An AWAKE state created outside LidKeep remains visible, but the app does not
claim that its safety monitor owns that state.

**Do not place an awake MacBook in a bag or other enclosed space.**

## Permissions and privacy

LidKeep installs one fixed, root-owned helper for these operations:

```bash
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset -a disablesleep 0
```

It does not install a permanent daemon, sudoers rule, account, analytics,
telemetry, update framework, or network service. See [SECURITY.md](SECURITY.md)
for the privilege and threat model.

## Build from source

Requirements: Apple silicon Mac, macOS 13 or later, and Apple Command Line
Tools with Swift.

```bash
git clone https://github.com/nbatada/lidkeep.git
cd lidkeep
./scripts/test.sh
./scripts/build.sh
./scripts/check_release.sh
```

The app is created at `build/LidKeep.app`.

To install the local build:

```bash
./scripts/install.command
```

## Uninstall

From a source checkout, run:

```bash
./scripts/uninstall.command
```

The uninstaller restores and verifies normal lid-close sleep before removing
the app, helper, or transient state directory. It stops without deleting the
app if `SleepDisabled 0` cannot be confirmed.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Keep changes focused on the core
lid-close workflow, state truthfulness, and safety.

## License

[MIT](LICENSE)
