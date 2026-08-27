#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
APP_PATH="${1:-${REPO_ROOT}/build/LidKeep.app}"
PLIST="${APP_PATH}/Contents/Info.plist"
APP_BINARY="${APP_PATH}/Contents/MacOS/LidKeep"
HELPER_BINARY="${APP_PATH}/Contents/Resources/LidKeepPowerHelper"
ICON="${APP_PATH}/Contents/Resources/AppIcon.icns"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -d "${APP_PATH}" ]] || fail "Missing app bundle: ${APP_PATH}"
[[ -f "${PLIST}" ]] || fail "Missing Info.plist"
[[ -x "${APP_BINARY}" ]] || fail "Missing executable LidKeep binary"
[[ -x "${HELPER_BINARY}" ]] || fail "Missing executable power helper"
[[ -f "${ICON}" ]] || fail "Missing AppIcon.icns"

plutil -lint "${PLIST}" >/dev/null

bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${PLIST}")"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${PLIST}")"

[[ "${bundle_name}" == "LidKeep" ]] || fail "Unexpected bundle name: ${bundle_name}"
[[ "${bundle_id}" == "io.github.lidkeep.LidKeep" ]] || fail "Unexpected bundle identifier: ${bundle_id}"
[[ "${bundle_version}" == "1.0.0" ]] || fail "Unexpected version: ${bundle_version}"
[[ "${minimum_system}" == "13.0" ]] || fail "Unexpected minimum macOS: ${minimum_system}"

helper_version="$(${HELPER_BINARY} --version)"
[[ "${helper_version}" == "LidKeepPowerHelper ${bundle_version}" ]] \
  || fail "Helper/app version mismatch: ${helper_version}"

[[ "$(stat -f '%Lp' "${APP_BINARY}")" == "755" ]] || fail "App binary mode is not 755"
[[ "$(stat -f '%Lp' "${HELPER_BINARY}")" == "755" ]] || fail "Helper mode is not 755"

for binary in "${APP_BINARY}" "${HELPER_BINARY}"
do
  /usr/bin/lipo -archs "${binary}" | tr ' ' '\n' | grep -qx arm64 \
    || fail "Binary does not contain arm64: ${binary}"
  binary_minos="$(/usr/bin/vtool -show-build "${binary}" | /usr/bin/awk '$1 == "minos" { print $2; exit }')"
  [[ "${binary_minos}" == "13.0" ]] || fail "Unexpected binary minimum macOS ${binary_minos}: ${binary}"
done

codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
sips -g format -g pixelWidth -g pixelHeight "${ICON}" \
  | grep -q 'format: icns' || fail "App icon is not a valid ICNS file"
sips -g pixelWidth "${ICON}" | grep -q 'pixelWidth: 1024' \
  || fail "App icon does not contain a 1024px representation"

if otool -L "${APP_BINARY}" "${HELPER_BINARY}" \
  | grep -E '^[[:space:]]+(/usr/local/|/opt/homebrew/|/Users/)'
then
  fail "Bundle links a non-system runtime"
fi

if find "${APP_PATH}" -type l -print | grep -q .; then
  fail "Bundle contains symbolic links"
fi

if find "${APP_PATH}" -type f \( -name '*.sh' -o -name '*.command' \) -print | grep -q .; then
  fail "Bundle contains a shell helper"
fi

if /usr/bin/grep -a -n -E -r \
  -e '/Users/[A-Za-z0-9_-]+/' \
  "${APP_PATH}"
then
  fail "Bundle contains an absolute user path"
fi

echo "PASS: release bundle ${APP_PATH}"
echo "Version: ${bundle_version}"
echo "Signing: ad hoc verification passed; Developer ID/notarization not present"
