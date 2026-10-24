#!/bin/bash
# Tests for the parts of brewau-setup that run without root.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'chmod -RN "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/libexec/brewau-setup" >"${WORK}/brewau-setup"
BREWAU_SETUP_TEST=1
# shellcheck source=/dev/null
source "${WORK}/brewau-setup"
set +e

check() {
  local want="$1" got="$2" what="$3"
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${want}" "${got}"
  fi
}

# --- restore_prefix_modes ----------------------------------------------------
HOMEBREW_PREFIX_PATH="${WORK}/prefix"
ORIGINAL_MODES_FILE="${WORK}/original-modes"
mkdir -p "${HOMEBREW_PREFIX_PATH}/var/with  spaces " "${WORK}/outside"
touch "${HOMEBREW_PREFIX_PATH}/file" "${WORK}/outside/target"
chmod 755 "${HOMEBREW_PREFIX_PATH}/var/with  spaces "
chmod 644 "${HOMEBREW_PREFIX_PATH}/file" "${WORK}/outside/target"
ln -s "${WORK}/outside/target" "${HOMEBREW_PREFIX_PATH}/link"
cat >"${ORIGINAL_MODES_FILE}" <<MODES
775 ${HOMEBREW_PREFIX_PATH}/var/with  spaces 
664 ${HOMEBREW_PREFIX_PATH}/file
777 ${HOMEBREW_PREFIX_PATH}/link
777 ${WORK}/outside/target
777 ${HOMEBREW_PREFIX_PATH}/../outside/target
700 ${HOMEBREW_PREFIX_PATH}/..
700 ${HOMEBREW_PREFIX_PATH}/var/.
MODES
chmod 755 "${WORK}"
restore_prefix_modes
check "775" "$(stat -f '%Lp' "${HOMEBREW_PREFIX_PATH}/var/with  spaces ")" "a path with spaces gets its mode back"
check "664" "$(stat -f '%Lp' "${HOMEBREW_PREFIX_PATH}/file")" "a file gets its mode back"
check "644" "$(stat -f '%Lp' "${WORK}/outside/target")" "symlinks and paths outside the prefix are left alone"
check "755 755" "$(stat -f '%Lp' "${WORK}" "${HOMEBREW_PREFIX_PATH}/var" | tr '\n' ' ' | sed 's/ $//')" \
  "paths ending in /. or /.. are refused"

# --- trust-app ---------------------------------------------------------------
require_root() { :; }
BREWAU_USER="$(id -un)"
BREWAU_APPDIR="${WORK}/Applications"
BREWAU_APP_STATE_DIR="${WORK}/state/apps"
BREWAU_STAGING_DIR="${WORK}"
mkdir -p "${BREWAU_APPDIR}/Odd.app/Contents"
chmod 777 "${BREWAU_APPDIR}/Odd.app/Contents"
STATE="$(brewau_app_state "${BREWAU_APPDIR}/Odd.app")"
brewau_write_state "${STATE}.untrusted" "${BREWAU_APPDIR}/Odd.app"
cmd_trust_app "${BREWAU_APPDIR}/Odd.app" >/dev/null
check "no -" "$([[ -e "${STATE}.untrusted" ]] && echo yes || echo no) $(cut -f 2 "${STATE}.team")" \
  "trusting an app clears the mark and records it afresh"
check "755" "$(stat -f '%Lp' "${BREWAU_APPDIR}/Odd.app/Contents")" "and locks it"
check "group:everyone deny delete" "$(brewau_acl "${BREWAU_APPDIR}/Odd.app")" "and pins it in place"
check "fail" "$( (cmd_trust_app "${WORK}/elsewhere.app") 2>/dev/null && echo ok || echo fail)" "apps outside the app directory are refused"

# --- LaunchDaemons: fixed entry points, validation, and safe reload -----------
BREWAU_PLIST="${WORK}/launch/com.kastruppro.brewau.upgrade.plist"
mkdir -p "${WORK}/launch" "${WORK}/loaded"
chown() { :; }
launchctl() {
  local label="${2##*/}"
  label="${label%.plist}"
  case "$1" in
    print)
      [[ -f "${WORK}/loaded/${label}" ]] || return 1
      echo "state = ${MOCK_JOB_STATE:-waiting}"
      ;;
    bootstrap) touch "${WORK}/loaded/$(basename "$3" .plist)"; echo bootstrap >>"${WORK}/launch-calls" ;;
    bootout) rm -f "${WORK}/loaded/${label}"; echo bootout >>"${WORK}/launch-calls" ;;
    *) return 1 ;;
  esac
}
write_launchdaemon
check "60" "$(plutil -extract StartInterval raw -o - "${WORK}/launch/com.kastruppro.brewau.scheduler.plist")" "scheduler checks once a minute"
check "scheduled" "$(plutil -extract ProgramArguments.1 raw -o - "${WORK}/launch/com.kastruppro.brewau.scheduler.plist")" "scheduler has a fixed entry point"
check "scan" "$(plutil -extract ProgramArguments.1 raw -o - "${WORK}/launch/com.kastruppro.brewau.scan.plist")" "manual scan has a fixed entry point"
check "upgrade" "$(plutil -extract ProgramArguments.1 raw -o - "${BREWAU_PLIST}")" "manual upgrade remains available"
cp "${WORK}/launch-calls" "${WORK}/launch-before"
write_launchdaemon
check "yes" "$(cmp -s "${WORK}/launch-before" "${WORK}/launch-calls" && echo yes)" "unchanged jobs are not reloaded"
printf '\n' >>"${BREWAU_PLIST}"
MOCK_JOB_STATE=running
check "fail" "$( (write_launchdaemon) >/dev/null 2>&1 && echo ok || echo fail)" "a running worker is never killed for reload"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
