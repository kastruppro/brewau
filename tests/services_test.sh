#!/bin/bash
# Tests for `brew services` routing and relocation of user LaunchAgents.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/libexec/brewau-services" >"${WORK}/brewau-services"
BREWAU_SERVICES_TEST=1
BREWAU_USER_VAR="${WORK}/home/Library/Application Support/brewau/var"
LAUNCH_AGENTS="${WORK}/home/Library/LaunchAgents"
# shellcheck source=/dev/null
source "${WORK}/brewau-services"
BREWAU_CONF="${WORK}/brewau.conf"
CALLS="${WORK}/calls"

# Mocks: record what would run instead of running Homebrew or launchd.
user_brew() { echo "user $*" >>"${CALLS}"; }
system_services() { echo "system $*" >>"${CALLS}"; }
requires_root() { [[ "$1" == "dnsmasq" ]]; }
launchctl() { echo "launchctl $*" >>"${CALLS}"; [[ "$1" != "print" ]]; }

check() {
  if eval "$1"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [${NAME}]: $2"
    sed 's/^/    /' "${CALLS}"
  fi
}
called() { grep -qxF "$1" "${CALLS}"; }
scenario() {
  NAME="$1"
  : >"${CALLS}"
  printf 'ALLOWED_SERVICES="%s"\n' "${2:-}" >"${BREWAU_CONF}"
}

scenario "allowed service goes to the system" "tailscale"
main services start tailscale >/dev/null 2>&1
check 'called "system start tailscale"' "start runs as a system service"
check '! grep -q "^user services start" "${CALLS}"' "and not as the user"

scenario "-v is handled like brew.sh does" "tailscale"
main -v services restart tailscale >/dev/null 2>&1
check 'called "system restart tailscale -v"' "a leading -v moves to the end"

scenario "other services run as the user" "tailscale"
main services start redis >/dev/null 2>&1
check 'called "user services start redis"' "start runs as the user"

scenario "root-only service that is not allowed" ""
RC=0
main services start dnsmasq >/dev/null 2>&1 || RC=$?
check '[[ ${RC} -ne 0 ]]' "is refused"
check '! grep -q "services start" "${CALLS}"' "and never started"

scenario "list shows both" "tailscale"
main services list >/dev/null 2>&1
check 'called "user services list" && called "system list"' "lists user and system services"

scenario "list without system services" ""
main services >/dev/null 2>&1
check 'called "user services" && ! grep -q "^system" "${CALLS}"' "passes the bare command to Homebrew and lists only user services"

# --- relocation of a generated LaunchAgent -----------------------------------
scenario "relocation" ""
mkdir -p "${LAUNCH_AGENTS}"
PLIST="${LAUNCH_AGENTS}/homebrew.mxcl.postgresql@17.plist"
cat >"${PLIST}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>homebrew.mxcl.postgresql@17</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/opt/postgresql@17/bin/postgres</string>
    <string>-D</string>
    <string>/opt/homebrew/var/postgresql@17</string>
    <string>--log=/opt/homebrew/var/log/pg-extra.log</string>
  </array>
  <key>StandardErrorPath</key>
  <string>/opt/homebrew/var/log/postgresql@17.log</string>
  <key>WorkingDirectory</key>
  <string>/opt/homebrew</string>
</dict>
</plist>
EOF
OUTPUT="$(main services start postgresql@17 2>&1)"
check 'called "user services start postgresql@17"' "Homebrew starts the service as the user"
check '! grep -q "/opt/homebrew/var" "${PLIST}"' "no path into the prefix var directory is left"
check '[[ "$(plutil -extract ProgramArguments.2 raw -o - "${PLIST}")" == "${BREWAU_USER_VAR}/postgresql@17" ]]' "data directory points at the user var"
check '[[ "$(plutil -extract StandardErrorPath raw -o - "${PLIST}")" == "${BREWAU_USER_VAR}/log/postgresql@17.log" ]]' "log points at the user var"
check '[[ "$(plutil -extract WorkingDirectory raw -o - "${PLIST}")" == "/opt/homebrew" ]]' "other prefix paths are kept"
check '[[ -d "${BREWAU_USER_VAR}/log" ]]' "the log directory is created"
check '[[ ! -e "${BREWAU_USER_VAR}/postgresql@17" ]]' "data directories are not invented"
check '[[ "${OUTPUT}" == *"${BREWAU_USER_VAR}/postgresql@17"* ]]' "the missing data directory is named"
check 'called "launchctl bootstrap gui/$(id -u) ${PLIST}"' "the agent is reloaded"
check 'plutil -lint -s "${PLIST}"' "the plist stays valid"

cp "${PLIST}" "${WORK}/once.plist"
: >"${CALLS}"
main services restart postgresql@17 >/dev/null 2>&1
check 'cmp -s "${WORK}/once.plist" "${PLIST}"' "relocating again changes nothing"
check '! grep -q "^launchctl bootout" "${CALLS}"' "and does not reload an already relocated agent"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
