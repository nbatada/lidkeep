# LidKeep

Keep your MacBook running with its lid closed while computations, downloads,
builds, or other long tasks finish. LidKeep lives in the menu bar and shows
`🟢 AWAKE` or `💤 SLEEP` from the actual macOS setting.

**Public release: v1.0.0 · Apple silicon · macOS 13 or later.**
No Xcode, Python, or other runtime installation is required.

**This app is ad-hoc signed, not Developer-ID signed or notarized.**
If macOS blocks it, follow the first-launch instructions below.

## Install from Terminal

Paste the following block into Terminal. It downloads the released app, checks
its SHA-256 checksum and signature, and installs it in your user's Applications
folder. It stops rather than overwriting an existing copy there.

```bash
(
  set -eu
  [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
    echo "LidKeep requires an Apple silicon Mac."; exit 1;
  }
  [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || {
    echo "LidKeep requires macOS 13 or later."; exit 1;
  }
  destination="$HOME/Applications/LidKeep.app"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    echo "LidKeep already exists at $destination. Quit it and move that copy to Trash before reinstalling."
    exit 1
  fi
  download_dir=$(mktemp -d "${TMPDIR:-/tmp}/lidkeep-install.XXXXXX")
  cd "$download_dir"
  base="https://github.com/nbatada/lidkeep/releases/download/v1.0.0"
  curl --fail --location --proto '=https' --proto-redir '=https' -O "$base/LidKeep-v1.0.0-macOS.zip"
  curl --fail --location --proto '=https' --proto-redir '=https' -O "$base/LidKeep-v1.0.0-macOS.zip.sha256"
  shasum -a 256 -c LidKeep-v1.0.0-macOS.zip.sha256
  ditto -x -k LidKeep-v1.0.0-macOS.zip .
  codesign --verify --deep --strict LidKeep.app
  mkdir -p "$HOME/Applications"
  ditto LidKeep.app "$destination"
  open "$destination"
)
```

Or download the [app ZIP](https://github.com/nbatada/lidkeep/releases/download/v1.0.0/LidKeep-v1.0.0-macOS.zip)
and [checksum](https://github.com/nbatada/lidkeep/releases/download/v1.0.0/LidKeep-v1.0.0-macOS.zip.sha256)
from the [public release](https://github.com/nbatada/lidkeep/releases/tag/v1.0.0).

## First launch and use

If macOS blocks opening the app, try opening it once, then go to
**System Settings → Privacy & Security → Open Anyway**. Do this only for the
verified download you trust. These commands do not disable Gatekeeper.

Select **KEEP AWAKE** in the menu to enable or disable lid-close sleep.
In v1.0.0, macOS asks for administrator authorization to install the helper and
change the power setting. The app restores normal sleep at 10% battery or lower,
when it exits, or when its safety checks fail. A lost monitor heartbeat can
also request authorization to restore sleep.

**Never put an awake MacBook in a bag or enclosed space.**

LidKeep has no telemetry, account, or cloud service. Its helper is limited to
enabling and disabling the macOS sleep setting.

## Release status

The public v1.0.0 provides the keep-awake function and battery safety cutoff.
The newer v1.1.0 remains a draft pending release checks. Memory tracking,
large-file tools, and later authorization fixes are not included in this download.

This branch contains installation information only. Older source remains in
Git history. Report security issues privately through the repository's
**Security → Advisories → Report a vulnerability** form.

## License

[MIT](LICENSE).
