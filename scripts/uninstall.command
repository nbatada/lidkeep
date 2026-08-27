#!/bin/bash
set -euo pipefail

APP="/Applications/LidKeep.app"
HELPER="/Library/PrivilegedHelperTools/io.github.lidkeep.LidKeepPowerHelper"
STATE_DIR="/var/run/lidkeep"

if [[ -e "${APP}" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "${installed_id}" != "io.github.lidkeep.LidKeep" ]]; then
    echo "ERROR: ${APP} is not a verified LidKeep application."
    echo "Nothing was changed."
    exit 1
  fi
fi

echo "Restoring normal lid-close sleep before removal…"
/usr/bin/osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges'

sleep_disabled="$('/usr/bin/pmset' -g | /usr/bin/awk '
  $1 == "SleepDisabled" { print $2; found=1; exit }
  $1 == "disablesleep" { legacy=$2 }
  END { if (!found && legacy != "") print legacy }
')"

if [[ "${sleep_disabled}" != "0" ]]; then
  echo "ERROR: macOS did not confirm SleepDisabled 0."
  echo "Nothing was removed. Restore normal sleep before retrying."
  exit 1
fi

/usr/bin/pkill -x LidKeep 2>/dev/null || true

admin_command="/bin/rm -rf '${APP}'; /bin/rm -f '${HELPER}'; /bin/rm -rf '${STATE_DIR}'"
/usr/bin/osascript -e "do shell script \"${admin_command}\" with administrator privileges"

if [[ -e "${APP}" || -e "${HELPER}" || -e "${STATE_DIR}" ]]; then
  echo "ERROR: removal was incomplete. Normal sleep is restored, but LidKeep files remain."
  exit 1
fi

echo "Removed LidKeep and its power helper."
echo "Verified: normal lid-close sleep is enabled."
