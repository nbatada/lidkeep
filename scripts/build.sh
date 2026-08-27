#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWIFT_SCRATCH="${REPO_ROOT}/build/swift-release"
APP_DIR="${REPO_ROOT}/build/LidKeep.app"
ICON_WORK="${REPO_ROOT}/build/icon"
CACHE_ROOT="${TMPDIR:-/tmp}/lidkeep-build-cache"

cd "${REPO_ROOT}"
mkdir -p "${CACHE_ROOT}/clang" "${CACHE_ROOT}/swiftpm"

export CLANG_MODULE_CACHE_PATH="${CACHE_ROOT}/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${CACHE_ROOT}/swiftpm"

rm -rf "${SWIFT_SCRATCH}" "${APP_DIR}" "${ICON_WORK}"

swift build \
  --configuration release \
  --disable-sandbox \
  --scratch-path "${SWIFT_SCRATCH}" \
  -Xswiftc -gnone \
  --product LidKeep

swift build \
  --configuration release \
  --disable-sandbox \
  --scratch-path "${SWIFT_SCRATCH}" \
  -Xswiftc -gnone \
  --product LidKeepPowerHelper

BIN_DIR="$(swift build --configuration release --disable-sandbox --scratch-path "${SWIFT_SCRATCH}" --show-bin-path)"

mkdir -p \
  "${APP_DIR}/Contents/MacOS" \
  "${APP_DIR}/Contents/Resources" \
  "${ICON_WORK}/AppIcon.iconset"

cp "${BIN_DIR}/LidKeep" "${APP_DIR}/Contents/MacOS/LidKeep"
cp "${BIN_DIR}/LidKeepPowerHelper" "${APP_DIR}/Contents/Resources/LidKeepPowerHelper"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

swiftc -framework AppKit scripts/make_icon.swift -o "${ICON_WORK}/make_icon"
"${ICON_WORK}/make_icon" "${ICON_WORK}/AppIcon-1024.png"

for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  pixels="${spec%% *}"
  filename="${spec#* }"
  sips -z "${pixels}" "${pixels}" \
    "${ICON_WORK}/AppIcon-1024.png" \
    --out "${ICON_WORK}/AppIcon.iconset/${filename}" >/dev/null
done

swiftc scripts/make_icns.swift -o "${ICON_WORK}/make_icns"
"${ICON_WORK}/make_icns" \
  "${ICON_WORK}/AppIcon.iconset" \
  "${APP_DIR}/Contents/Resources/AppIcon.icns"

chmod 755 \
  "${APP_DIR}/Contents/MacOS/LidKeep" \
  "${APP_DIR}/Contents/Resources/LidKeepPowerHelper"

plutil -lint "${APP_DIR}/Contents/Info.plist"
codesign --force --sign - "${APP_DIR}/Contents/Resources/LidKeepPowerHelper"
codesign --force --sign - "${APP_DIR}"

echo "Built: ${APP_DIR}"
echo "Signing: ad hoc (not Developer ID signed or notarized)"
