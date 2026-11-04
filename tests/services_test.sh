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
# Everything the script writes for the user derives from HOME.
HOME="${WORK}/home"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
# shellcheck source=/dev/null
source "${WORK}/brewau-services"
BREWAU_CONF="${WORK}/brewau.conf"
CALLS="${WORK}/calls"
UID_DOMAIN="gui/$(id -u)"

# Mocks: record what would run instead of running Homebrew or launchd.
user_brew() {
  echo "user $*" >>"${CALLS}"
  [[ "$*" == *--json* ]] && echo "${MOCK_USER_JSON:-[]}"
  return "${MOCK_USER_RC:-0}"
}
system_services() {
  echo "system $*" >>"${CALLS}"
  [[ "$*" == *--json* ]] && echo "${MOCK_SYSTEM_JSON:-[]}"
  return 0
}
requires_root() { [[ "$1" == "dnsmasq" ]]; }
# launchd keeps MOCK_LOADED, the loaded service targets.
launchctl() {
  echo "launchctl $*" >>"${CALLS}"
  case "$1" in
    print) brewau_in_words "$2" "${MOCK_LOADED}" ;;
    bootout) MOCK_LOADED=" ${MOCK_LOADED} " && MOCK_LOADED="${MOCK_LOADED// $2 / }" ;;
    bootstrap) MOCK_LOADED="${MOCK_LOADED} $2/$(plutil -extract Label raw -o - "$3")" ;;
  esac
}

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
  rm -rf "${LAUNCH_AGENTS}" "${HOME}/Library/Application Support" "${HOME}/Library/brewau"
  mkdir -p "${LAUNCH_AGENTS}"
  MOCK_LOADED=""
  unset MOCK_USER_JSON MOCK_SYSTEM_JSON MOCK_USER_RC
}
# write_agent <formula> <data path>: a LaunchAgent as Homebrew generates it.
write_agent() {
  cat >"${LAUNCH_AGENTS}/homebrew.mxcl.$1.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>homebrew.mxcl.$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/opt/$1/bin/$1</string>
    <string>-D</string>
    <string>$2</string>
    <string>--log=${PREFIX_VAR}/log/$1-extra.log</string>
    ${3:+<string>$3</string>}
  </array>
  <key>StandardErrorPath</key>
  <string>${PREFIX_VAR}/log/$1.log</string>
  <key>WorkingDirectory</key>
  <string>/opt/homebrew</string>
</dict>
</plist>
EOF
}

scenario "allowed service goes to the system" "tailscale"
main services start tailscale >/dev/null 2>&1
check 'called "system start tailscale"' "start runs as a system service"
check '! grep -q "^user services start" "${CALLS}"' "and not as the user"

scenario "Homebrew's aliases" "tailscale"
main services s tailscale >/dev/null 2>&1
check 'called "system s tailscale"' "s starts a system service"

scenario "-v is handled like brew.sh does" "tailscale"
main -v services restart tailscale >/dev/null 2>&1
check 'called "system restart tailscale -v"' "a leading -v moves to the end"

scenario "options before the action" "tailscale"
main services -v start tailscale >/dev/null 2>&1
check 'called "system -v start tailscale"' "the first word is still the action"

scenario "other services run as the user" "tailscale"
main services start redis >/dev/null 2>&1
check 'called "user services start redis"' "start runs as the user"

scenario "root-only service that is not allowed" ""
RC=0
OUT="$(main services start dnsmasq 2>&1 >/dev/null)" || RC=$?
check '[[ ${RC} -ne 0 ]]' "is refused"
check '[[ "${OUT}" == *"allow it with: sudo brewau config add ALLOWED_SERVICES dnsmasq" ]]' "with a command that allows it"
check '! grep -q "services start" "${CALLS}"' "and never started"

scenario "run is refused" "tailscale"
RC=0
main services run redis >/dev/null 2>&1 || RC=$?
main services run tailscale >/dev/null 2>&1 || RC=$?
check '[[ ${RC} -ne 0 && ! -s "${CALLS}" ]]' "for user and system services alike"

scenario "list shows both" "tailscale"
main services list >/dev/null 2>&1
check 'called "user services list" && called "system list"' "lists user and system services"

scenario "bare -v services lists both" "tailscale"
main -v services >/dev/null 2>&1
check 'called "user services -v" && called "system -v"' "lists user and system services"

scenario "list without system services" ""
main services >/dev/null 2>&1
check 'called "user services" && ! grep -q "^system" "${CALLS}"' "passes the bare command to Homebrew and lists only user services"

scenario "list --json is one JSON array" "tailscale"
MOCK_USER_JSON='[{"name": "redis", "user": "me"}, {"name": "tailscale", "user": null}]'
MOCK_SYSTEM_JSON='[{"name": "redis", "user": null}, {"name": "tailscale", "user": "root"}]'
OUTPUT="$(main services list --json 2>/dev/null)"
check '[[ "$(plutil -extract 0.user raw -o - - <<<"${OUTPUT}")" == "me" ]]' "has the user's own services"
check '[[ "$(plutil -extract 1.user raw -o - - <<<"${OUTPUT}")" == "root" ]]' "has allowed services as the system sees them"
check '! plutil -extract 2 raw -o - - <<<"${OUTPUT}" >/dev/null 2>&1' "lists each service once"

scenario "own agent for an allowed service" "tailscale"
write_agent tailscale "${PREFIX_VAR}/tailscale"
RC=0
main services start tailscale >/dev/null 2>&1 || RC=$?
check '[[ ${RC} -ne 0 ]] && ! grep -q "^system" "${CALLS}"' "start refuses to start a second, system instance"
: >"${CALLS}"
MOCK_LOADED="system/homebrew.mxcl.tailscale"
main services stop tailscale >/dev/null 2>&1
check 'called "user services stop tailscale" && called "system stop tailscale"' "stop stops both"

# --- relocation of a generated LaunchAgent -----------------------------------
scenario "relocation" ""
write_agent postgresql@17 "${PREFIX_VAR}/postgresql@17"
write_agent redis "${PREFIX_VAR}/redis"
PLIST="${LAUNCH_AGENTS}/homebrew.mxcl.postgresql@17.plist"
cp "${LAUNCH_AGENTS}/homebrew.mxcl.redis.plist" "${WORK}/redis.plist"
OUTPUT="$(main services start postgresql@17 2>&1)"
check 'called "user services start postgresql@17"' "Homebrew starts the service as the user"
check '! grep -q "/opt/homebrew/var" "${PLIST}"' "no path into the prefix var directory is left"
check '[[ "$(plutil -extract ProgramArguments.2 raw -o - "${PLIST}")" == "${BREWAU_USER_VAR}/postgresql@17" ]]' "data directory points at the user var"
check '[[ "$(plutil -extract StandardErrorPath raw -o - "${PLIST}")" == "${BREWAU_USER_VAR}/log/postgresql@17.log" ]]' "log points at the user var"
check '[[ "$(plutil -extract WorkingDirectory raw -o - "${PLIST}")" == "/opt/homebrew" ]]' "other prefix paths are kept"
check '[[ -d "${BREWAU_USER_VAR}/log" ]]' "the log directory is created"
check '[[ ! -e "${BREWAU_USER_VAR}/postgresql@17" ]]' "data directories are not invented"
check '[[ "${OUTPUT}" == *"${BREWAU_USER_VAR}/postgresql@17"* ]]' "the missing data directory is named"
check 'called "launchctl bootstrap ${UID_DOMAIN} ${PLIST}"' "the agent is reloaded"
check 'plutil -lint -s "${PLIST}"' "the plist stays valid"
check 'cmp -s "${WORK}/redis.plist" "${LAUNCH_AGENTS}/homebrew.mxcl.redis.plist"' "another service's agent is left alone"

cp "${PLIST}" "${WORK}/once.plist"
: >"${CALLS}"
main services restart postgresql@17 >/dev/null 2>&1
check 'cmp -s "${WORK}/once.plist" "${PLIST}"' "relocating again changes nothing"
check '! grep -q "^launchctl bootout" "${CALLS}"' "and does not reload an already relocated agent"

scenario "relocation fails" ""
write_agent redis "${PREFIX_VAR}/redis"
plutil() { [[ "$1" == "-lint" ]] && return 1; command plutil "$@"; }
RC=0
main services start redis >/dev/null 2>&1 || RC=$?
unset -f plutil
check '[[ ${RC} -ne 0 ]]' "start fails when the agent could not be relocated"

scenario "Homebrew fails after writing the agent" ""
write_agent redis "${PREFIX_VAR}/redis"
MOCK_USER_RC=1
RC=0
main services start redis >/dev/null 2>&1 || RC=$?
check '[[ ${RC} -eq 0 ]]' "succeeds once the relocated agent is loaded"
: >"${CALLS}"
RC=0
main services start redis >/dev/null 2>&1 || RC=$?
check '[[ ${RC} -ne 0 ]]' "but a failure with nothing to relocate stays a failure"

# Data and config from before brewau, in a prefix the test controls.
scenario "existing data and config" ""
PREFIX_VAR="${WORK}/prefix/var"
mkdir -p "${PREFIX_VAR}/redis" "${WORK}/prefix/etc"
HOMEBREW_PREFIX_PATH="${WORK}/prefix"
echo "dir ${PREFIX_VAR}/redis" >"${WORK}/prefix/etc/redis.conf"
write_agent redis "${PREFIX_VAR}/redis" "${WORK}/prefix/etc/redis.conf"
OUTPUT="$(main services start redis 2>&1)"
PLIST="${LAUNCH_AGENTS}/homebrew.mxcl.redis.plist"
COPY="${BREWAU_USER_DIR}/etc/redis.conf"
check '[[ "${OUTPUT}" == *"sudo brewau move-service-data $(id -un) redis"* ]]' "says how to copy the data over"
check '[[ "$(plutil -extract ProgramArguments.4 raw -o - "${PLIST}")" == "${COPY}" ]]' "the service reads a copy of its config"
check '[[ "$(cat "${COPY}")" == "dir ${BREWAU_USER_VAR_LINK}/redis" ]]' "which uses the user var by a path without spaces"
check '[[ "$(cd -P "${BREWAU_USER_VAR_LINK}" && pwd -P)" == "$(cd -P "${BREWAU_USER_VAR}" && pwd -P)" ]]' "that leads to the user var"
check '[[ "$(cat "${WORK}/prefix/etc/redis.conf")" == "dir ${PREFIX_VAR}/redis" ]]' "the original is untouched"
echo "dir /edited" >"${COPY}"
write_agent redis "${PREFIX_VAR}/redis" "${WORK}/prefix/etc/redis.conf"
main services restart redis >/dev/null 2>&1
check '[[ "$(cat "${COPY}")" == "dir /edited" ]]' "a copy the user edited is kept"

# --- starting from the keg's plist -------------------------------------------
scenario "start from the keg" ""
mkdir -p "${WORK}/prefix/opt/memcached"
write_agent memcached "${PREFIX_VAR}/memcached"
mv "${LAUNCH_AGENTS}/homebrew.mxcl.memcached.plist" "${WORK}/prefix/opt/memcached/"
PLIST="${LAUNCH_AGENTS}/homebrew.mxcl.memcached.plist"
# Not in a subshell: launchd's mock state has to persist.
RC=0
main services start memcached >"${WORK}/output" 2>&1 || RC=$?
OUTPUT="$(cat "${WORK}/output")"
check '[[ ${RC} -eq 0 ]] && ! grep -q "^user services start" "${CALLS}"' "starts it without Homebrew"
check '! grep -q "${PREFIX_VAR}" "${PLIST}"' "from a relocated copy"
check '[[ "$(grep -c "^launchctl bootstrap" "${CALLS}")" -eq 1 ]]' "that was never loaded with prefix paths"
check 'called "launchctl enable ${UID_DOMAIN}/homebrew.mxcl.memcached" && called "launchctl bootstrap ${UID_DOMAIN} ${PLIST}"' "enabled and loaded like Homebrew does"
check '[[ -d "${BREWAU_USER_VAR}/log" ]]' "its log directory exists"
check '[[ "${OUTPUT}" == *"Successfully started"* ]]' "and says so"
: >"${CALLS}"
main services start memcached >/dev/null 2>&1
check '! grep -q "^launchctl bootstrap" "${CALLS}"' "starting it again leaves it running"
: >"${CALLS}"
main services restart memcached >/dev/null 2>&1
check 'called "launchctl bootout ${UID_DOMAIN}/homebrew.mxcl.memcached" && called "launchctl bootstrap ${UID_DOMAIN} ${PLIST}"' "restart reloads it"
: >"${CALLS}"
main services start --file=/tmp/x.plist memcached >/dev/null 2>&1
check 'called "user services start --file=/tmp/x.plist memcached"' "a plist of the user's own is left to Homebrew"

scenario "current Homebrew names jobs sh.brew" ""
mkdir -p "${WORK}/prefix/opt/valkey"
write_agent valkey "${PREFIX_VAR}/valkey"
sed 's/homebrew.mxcl.valkey/sh.brew.valkey/' "${LAUNCH_AGENTS}/homebrew.mxcl.valkey.plist" >"${WORK}/prefix/opt/valkey/sh.brew.valkey.plist"
# An agent from an older Homebrew, still loaded under the old name.
MOCK_LOADED="${UID_DOMAIN}/homebrew.mxcl.valkey"
main services restart valkey >/dev/null 2>&1
check 'called "launchctl bootout ${UID_DOMAIN}/homebrew.mxcl.valkey"' "the old job is stopped"
check '[[ ! -e "${LAUNCH_AGENTS}/homebrew.mxcl.valkey.plist" && -f "${LAUNCH_AGENTS}/sh.brew.valkey.plist" ]]' "and replaced under the new name"
check 'called "launchctl bootstrap ${UID_DOMAIN} ${LAUNCH_AGENTS}/sh.brew.valkey.plist"' "which is loaded"
check '! grep -q "${PREFIX_VAR}" "${LAUNCH_AGENTS}/sh.brew.valkey.plist"' "relocated"

scenario "Homebrew writes the agent when the user overrides its environment" ""
mkdir -p "${HOME}/.homebrew/services"
touch "${HOME}/.homebrew/services/memcached.env"
main services start memcached >/dev/null 2>&1
check 'called "user services start memcached"' "Homebrew starts it"
rm -rf "${HOME}/.homebrew"

scenario "an sh.brew agent written by Homebrew is relocated" ""
write_agent memcached "${PREFIX_VAR}/memcached"
mv "${LAUNCH_AGENTS}/homebrew.mxcl.memcached.plist" "${LAUNCH_AGENTS}/sh.brew.memcached.plist"
mkdir -p "${HOME}/.homebrew/services"
touch "${HOME}/.homebrew/services/memcached.env"
main services start memcached >/dev/null 2>&1
check '! grep -q "${PREFIX_VAR}" "${LAUNCH_AGENTS}/sh.brew.memcached.plist"' "after Homebrew started it"
rm -rf "${HOME}/.homebrew"

scenario "the space-free link is the user's" ""
mkdir -p "${BREWAU_USER_VAR_LINK}"
echo "dir ${PREFIX_VAR}/redis" >"${WORK}/prefix/etc/redis.conf"
write_agent redis "${PREFIX_VAR}/redis" "${WORK}/prefix/etc/redis.conf"
OUTPUT="$(main services start redis 2>&1)"
check '[[ "${OUTPUT}" == *"still use"*"redis.conf"* && ! -e "${BREWAU_USER_VAR_LINK}/var" ]]' "something else there is left alone, and the config named"
rmdir "${BREWAU_USER_VAR_LINK}"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
