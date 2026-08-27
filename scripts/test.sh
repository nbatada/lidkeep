#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWIFT_SCRATCH="${REPO_ROOT}/build/swift-test"
CACHE_ROOT="${TMPDIR:-/tmp}/lidkeep-build-cache"

cd "${REPO_ROOT}"
mkdir -p "${CACHE_ROOT}/clang" "${CACHE_ROOT}/swiftpm"

export CLANG_MODULE_CACHE_PATH="${CACHE_ROOT}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${CACHE_ROOT}/swiftpm"

swift run \
  --disable-sandbox \
  --scratch-path "${SWIFT_SCRATCH}" \
  LidKeepCoreTests

swift build \
  --disable-sandbox \
  --scratch-path "${SWIFT_SCRATCH}" \
  --product LidKeep

swift build \
  --disable-sandbox \
  --scratch-path "${SWIFT_SCRATCH}" \
  --product LidKeepPowerHelper

BIN_DIR="$(swift build --disable-sandbox --scratch-path "${SWIFT_SCRATCH}" --show-bin-path)"
"${BIN_DIR}/LidKeepPowerHelper" --version

plutil -lint Resources/Info.plist

echo "PASS: tests and debug compilation"
echo "NOTE: no test changed the macOS power state"
