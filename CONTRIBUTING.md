# Contributing

LidKeep intentionally has one purpose: keep a MacBook running with the lid
closed while making the real macOS state obvious. Keep proposed changes within
that boundary.

Priorities:

1. authoritative state;
2. battery and cleanup safety;
3. narrow privilege;
4. obvious menu-bar status;
5. small native implementation.

Run before submitting a change:

```bash
./scripts/test.sh
./scripts/build.sh
./scripts/check_release.sh
```

Automated tests must never change the live macOS power setting. Any manual test
that invokes `pmset -a disablesleep` must begin from confirmed normal sleep and
use EXIT, INT, TERM, and HUP cleanup traps that restore and verify
`SleepDisabled 0`.

Changes to privilege handling, parsing, monitor lifecycle, battery policy,
signing, or release packaging require focused tests and updated documentation.
Do not add dependencies, telemetry, broad power modes, or unrelated settings.
