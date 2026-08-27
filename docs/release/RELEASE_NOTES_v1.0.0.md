# LidKeep v1.0.0

LidKeep keeps an Apple silicon MacBook running with the lid closed and shows
the current state in the macOS menu bar.

## Included

- Native AppKit menu-bar app with `🟢 AWAKE`, `💤 SLEEP`, and explicit UNKNOWN
  states.
- One `KEEP AWAKE` control backed by the state reported by `pmset`.
- Detection of external `pmset` changes within the polling interval.
- 10% battery cutoff, restoration after app exit or crash, and recovery after
  monitor-heartbeat loss.
- Fixed, root-owned compiled helper with no external runtime dependency.
- Verified arm64 release ZIP and SHA-256 checksum.

## Requirements

- Apple silicon Mac
- macOS 13 or later

## Distribution note

This release is ad-hoc signed and is not notarized. Verify the SHA-256 checksum
before opening it, then follow the README's Gatekeeper instructions if macOS
blocks the first launch.
