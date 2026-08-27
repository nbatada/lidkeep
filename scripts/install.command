#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${REPO_ROOT}/build/LidKeep.app"
INSTALL_APP="/Applications/LidKeep.app"

sleep_disabled="$('/usr/bin/pmset' -g | /usr/bin/awk '
  $1 == "SleepDisabled" { print $2; found=1; exit }
  $1 == "disablesleep" { legacy=$2 }
  END { if (!found && legacy != "") print legacy }
')"

if [[ "${sleep_disabled}" != "0" ]]; then
  echo "ERROR: normal lid-close sleep is not currently confirmed."
  echo "Turn KEEP AWAKE off, verify SleepDisabled 0, then run this installer again."
  exit 1
fi

cd "${REPO_ROOT}"
./scripts/build.sh
./scripts/check_release.sh "${SOURCE_APP}"

if [[ -e "${INSTALL_APP}" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INSTALL_APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${installed_id}" != "io.github.lidkeep.LidKeep" ]]; then
    echo "ERROR: ${INSTALL_APP} is not an existing LidKeep installation."
    echo "It was not replaced."
    exit 1
  fi
fi

shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

admin_command="/bin/rm -rf $(shell_quote "${INSTALL_APP}"); /usr/bin/ditto $(shell_quote "${SOURCE_APP}") $(shell_quote "${INSTALL_APP}"); /usr/sbin/chown -R root:wheel $(shell_quote "${INSTALL_APP}")"
apple_command="${admin_command//\\/\\\\}"
apple_command="${apple_command//\"/\\\"}"

/usr/bin/osascript -e "do shell script \"${apple_command}\" with administrator privileges"
installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INSTALL_APP}/Contents/Info.plist")"
[[ "${installed_id}" == "io.github.lidkeep.LidKeep" ]] || {
  echo "ERROR: installed application identity could not be verified."
  exit 1
}
codesign --verify --deep --strict --verbose=2 "${INSTALL_APP}"
/usr/bin/open "${INSTALL_APP}"

echo "Installed: ${INSTALL_APP}"
echo "The first KEEP AWAKE change may request authorization to install the fixed power helper."
