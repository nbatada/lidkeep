#!/bin/bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PLIST="${REPO_ROOT}/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
ZIP_NAME="LidKeep-v${VERSION}-macOS.zip"
ZIP_PATH="${REPO_ROOT}/dist/${ZIP_NAME}"
CHECKSUM_PATH="${ZIP_PATH}.sha256"
VERIFY_DIR="${REPO_ROOT}/build/release-verify"

cd "${REPO_ROOT}"

./scripts/build.sh
./scripts/check_release.sh "${REPO_ROOT}/build/LidKeep.app"

mkdir -p dist
rm -f "${ZIP_PATH}" "${CHECKSUM_PATH}"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc --noextattr \
  build/LidKeep.app "${ZIP_PATH}"
unzip -t "${ZIP_PATH}" >/dev/null

if unzip -Z1 "${ZIP_PATH}" | grep -Ev '^LidKeep\.app(/|$)' | grep -q .; then
  echo "ERROR: release ZIP contains files outside LidKeep.app" >&2
  exit 1
fi

rm -rf "${VERIFY_DIR}"
mkdir -p "${VERIFY_DIR}"
ditto -x -k "${ZIP_PATH}" "${VERIFY_DIR}"
./scripts/check_release.sh "${VERIFY_DIR}/LidKeep.app"

cd dist
shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256"
shasum -a 256 -c "${ZIP_NAME}.sha256"

echo "Created: ${ZIP_PATH}"
echo "Created: ${CHECKSUM_PATH}"
echo "NOTICE: this build is ad-hoc signed and is not notarized."
