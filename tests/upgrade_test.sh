#!/bin/bash
# Tests for the scheduled upgrade job with a mocked brew.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/libexec/brewau-upgrade" >"${WORK}/brewau-upgrade"
BREWAU_UPGRADE_TEST=1
# shellcheck source=/dev/null
source "${WORK}/brewau-upgrade"

BREWAU_STATE_DIR="${WORK}/state"
LAST_RUN="${BREWAU_STATE_DIR}/last-run"
EXCLUDE_PINS="${BREWAU_STATE_DIR}/exclude-pins"
SELF_UPDATE_DUE="${BREWAU_STATE_DIR}/self-update-due"
CALLS="${WORK}/calls"

# Prints `brew outdated --json=v2` entries for names $2...; names in
# MOCK_OUTDATED_PINNED are pinned.
json_entries() {
  local kind="$1" name sep=""
  shift
  printf '"%s": [' "${kind}"
  for name in "$@"; do
    printf '%s{"name": "%s", "installed_versions": ["1"], "current_version": "2", "pinned": %s, "pinned_version": null}' \
      "${sep}" "${name}" "$(brewau_in_words "${name}" "${MOCK_OUTDATED_PINNED:-}" && echo true || echo false)"
    sep=", "
  done
  printf ']'
}

# Mocked brew: answers from MOCK_* variables and records every call.
brew_run() {
  echo "$*" >>"${CALLS}"
  case "$*" in
    "list --formula -1") printf '%s\n' ${MOCK_INSTALLED:-}; return "${MOCK_LIST_RC:-0}" ;;
    "list --pinned --formula") printf '%s\n' ${MOCK_PINNED:-}; return "${MOCK_PINNED_RC:-0}" ;;
    "outdated --json=v2"*)
      [[ "${MOCK_OUTDATED_RC:-0}" -eq 0 ]] || return "${MOCK_OUTDATED_RC}"
      printf '{%s, %s}\n' "$(json_entries formulae ${MOCK_OUTDATED_FORMULAE:-})" "$(json_entries casks ${MOCK_OUTDATED_CASKS:-})"
      ;;
    "info --json=v2 --installed --cask") echo '{"casks": []}' ;;
    "upgrade --cask"*)
      if [[ "$*" == *"${MOCK_CASK_FAIL:-never}" ]]; then echo "${MOCK_CASK_ERROR:-failure}"; return 1; fi
      ;;
    "upgrade --formula"*) return "${MOCK_UPGRADE_RC:-0}" ;;
  esac
  return 0
}
brewau_protect_installed_apps() {
  echo "protect" >>"${CALLS}"
  [[ -n "${MOCK_UNPROTECTED:-}" ]] && echo "${MOCK_UNPROTECTED}"
  return "${MOCK_PROTECT_RC:-0}"
}
# Exercise the production network classification without network access.
eval "$(declare -f clean_tmp | sed 's/clean_tmp/real_clean_tmp/')"
eval "$(declare -f network_available | sed 's/network_available/real_network_available/; s#/usr/bin/curl#mock_curl#')"
mock_curl() { return "${MOCK_CURL_RC}"; }
clean_tmp() { :; }
network_available() { [[ "${MOCK_OFFLINE:-0}" == 0 ]]; }
# Mocked root brew and launchd: tailscale's and db's system daemons are loaded.
brewau_exec_brew_as_root() { echo "root $*" >>"${CALLS}"; [[ "$*" != *"${MOCK_RESTART_FAILS:-none}"* ]]; }
brewau_release_service_keg() { echo "release $1" >>"${CALLS}"; }
launchctl() { [[ "$*" == "print system/homebrew.mxcl.tailscale" || "$*" == "print system/homebrew.mxcl.db" ]]; }

# scenario <name>: resets state; set MOCK_* and config before calling run.
scenario() {
  NAME="$1"
  rm -rf "${BREWAU_STATE_DIR}" "${CALLS}"
  mkdir -p "${BREWAU_STATE_DIR}"
  touch "${CALLS}"
  unset MOCK_INSTALLED MOCK_PINNED MOCK_LIST_RC MOCK_PINNED_RC MOCK_OUTDATED_FORMULAE \
    MOCK_OUTDATED_CASKS MOCK_OUTDATED_RC MOCK_OUTDATED_PINNED MOCK_UPGRADE_RC MOCK_RESTART_FAILS \
    MOCK_UNPROTECTED MOCK_PROTECT_RC MOCK_OFFLINE MOCK_CASK_ERROR MOCK_CASK_FAIL
  UPGRADE_EXCLUDE=""
  UPGRADE_GREEDY="0"
}
run() {
  OUTPUT="$(run_upgrade 2>&1)"
  RC=$?
  STATUS="$(sed -n 's/^status=//p' "${LAST_RUN}" 2>/dev/null)"
}
check() {
  if eval "$1"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [${NAME}]: $2"
  fi
}
called() { grep -qx "$1" "${CALLS}"; }

scenario "outdated fails"
MOCK_OUTDATED_RC=1
run
check '[[ ${RC} -ne 0 ]]' "job exits non-zero"
check '[[ "${STATUS}" == "outdated-failed" ]]' "status is outdated-failed (got ${STATUS})"
check '[[ "${OUTPUT}" != *"everything is up to date"* ]]' "does not claim everything is up to date"
check '! grep -q "^upgrade" "${CALLS}"' "upgrades nothing"

scenario "all good"
MOCK_OUTDATED_FORMULAE="wget"
MOCK_OUTDATED_CASKS="firefox"
run
check '[[ ${RC} -eq 0 && "${STATUS}" == "ok" ]]' "status ok"
check 'called "upgrade --formula wget"' "upgrades outdated formulae"
check 'called "upgrade --cask firefox"' "upgrades outdated casks"
check '[[ "$(grep -c "^protect$" "${CALLS}")" -eq 2 ]]' "protects apps before and after the cask upgrade"

scenario "apps are protected even when no cask is outdated"
run
check '[[ "$(grep -c "^protect$" "${CALLS}")" -eq 1 ]]' "protects apps every run"

scenario "a cask whose app could not be protected"
MOCK_OUTDATED_CASKS="firefox slack"
MOCK_UNPROTECTED="slack"
MOCK_PROTECT_RC=1
run
check 'called "upgrade --cask firefox"' "the others are upgraded"
check '[[ ${RC} -ne 0 && "${STATUS}" == "protect-failed" ]]' "status is protect-failed (got ${STATUS})"

scenario "casks cannot be listed for protection"
MOCK_OUTDATED_FORMULAE="wget"
MOCK_OUTDATED_CASKS="firefox"
MOCK_PROTECT_RC=2
run
check '! grep -q "^upgrade --cask" "${CALLS}"' "no cask is upgraded"
check 'called "upgrade --formula wget"' "formulae still are"

scenario "pinned packages are left to Homebrew"
MOCK_OUTDATED_FORMULAE="wget acme/tools/thing"
MOCK_OUTDATED_CASKS="firefox slack"
MOCK_OUTDATED_PINNED="acme/tools/thing slack"
run
check 'called "upgrade --formula wget"' "upgrades unpinned formulae only"
check 'called "upgrade --cask firefox"' "upgrades unpinned casks only"
check '[[ ${RC} -eq 0 && "${STATUS}" == "ok" ]]' "a pin does not fail the run (got ${STATUS})"

scenario "tap formulae match UPGRADE_EXCLUDE by name"
UPGRADE_EXCLUDE="thing acme/tools/other"
MOCK_INSTALLED="thing other wget"
MOCK_OUTDATED_FORMULAE="acme/tools/thing acme/tools/other wget"
run
check 'called "pin thing" && called "pin other"' "pins both, with or without the tap"
check 'called "upgrade --formula wget"' "upgrades only the rest"
check '[[ "$(cat "${EXCLUDE_PINS}")" == "thing other" ]]' "owns the pins by plain name"

scenario "upgraded system services are restarted"
ALLOWED_SERVICES="tailscale redis"
MOCK_OUTDATED_FORMULAE="tailscale redis wget"
run
check 'called "root services restart tailscale"' "restarts a loaded system service after its upgrade"
check '! called "root services restart redis"' "leaves allowed services that are not loaded alone"
check '! grep -q "root services restart wget" "${CALLS}"' "never touches services outside ALLOWED_SERVICES"
check 'called "release tailscale"' "hands the keg back to _brewau"
check '[[ "${STATUS}" == "ok" ]]' "status ok (got ${STATUS})"

scenario "a tap formula's system service is restarted"
ALLOWED_SERVICES="db"
MOCK_OUTDATED_FORMULAE="acme/tools/db"
run
check 'called "root services restart db"' "restarts it by its plain name"

scenario "a failed restart fails the run"
ALLOWED_SERVICES="tailscale"
MOCK_OUTDATED_FORMULAE="tailscale"
MOCK_RESTART_FAILS="tailscale"
run
check '[[ ${RC} -ne 0 && "${STATUS}" == "restart-failed" ]]' "status is restart-failed (got ${STATUS})"
ALLOWED_SERVICES=""

scenario "lost pin is restored"
UPGRADE_EXCLUDE="node"
MOCK_INSTALLED="node wget"
echo "node" >"${EXCLUDE_PINS}"
run
check 'called "pin node"' "re-pins a formula whose pin disappeared"
check '[[ "$(cat "${EXCLUDE_PINS}")" == "node" ]]' "keeps owning the pin"

scenario "excluded formula is pinned and skipped"
UPGRADE_EXCLUDE="node"
MOCK_INSTALLED="node wget"
MOCK_OUTDATED_FORMULAE="node wget"
run
check 'called "pin node"' "pins the excluded formula"
check 'called "upgrade --formula wget"' "upgrades the rest"
check '! grep -q "upgrade --formula.*node" "${CALLS}"' "does not upgrade the excluded formula"

scenario "own pin is removed when no longer excluded"
MOCK_INSTALLED="node"
MOCK_PINNED="node"
echo "node" >"${EXCLUDE_PINS}"
run
check 'called "unpin node"' "unpins its own pin"
check '[[ -z "$(cat "${EXCLUDE_PINS}")" ]]' "forgets the pin"

scenario "a user's pin is left alone"
UPGRADE_EXCLUDE="python"
MOCK_INSTALLED="python"
MOCK_PINNED="python"
run
check '! called "pin python" && ! called "unpin python"' "neither pins nor unpins"
check '[[ -z "$(cat "${EXCLUDE_PINS}")" ]]' "does not take over the pin"
UPGRADE_EXCLUDE=""
run
check '! called "unpin python"' "does not unpin it after removal from UPGRADE_EXCLUDE"

scenario "pins cannot be verified"
UPGRADE_EXCLUDE="node"
MOCK_INSTALLED="node"
MOCK_PINNED_RC=1
MOCK_OUTDATED_FORMULAE="node"
run
check '[[ "${STATUS}" == "pin-failed" ]]' "status is pin-failed (got ${STATUS})"
check '! grep -q "^upgrade --formula" "${CALLS}"' "skips formula upgrades rather than risk excluded ones"
check '[[ "$(sed -n "s/^upgraded=//p" "${LAST_RUN}")" == "" ]]' "records nothing as upgraded"

scenario "scan does not install"
MOCK_OUTDATED_CASKS="postman"
UPDATE_HOMEBREW=1
SCAN_OUTPUT="$(run_scan 2>&1)"
check '[[ $? -eq 0 ]]' "scan succeeds"
check '[[ "${SCAN_OUTPUT}" == *"[scan] done (status=0)"* ]]' "scan records its job and result"
check 'called "update"' "refreshes Homebrew"
check '! grep -q "^upgrade" "${CALLS}"' "installs nothing"
check '[[ -s "${BREWAU_STATE_DIR}/updates.json" && -s "${BREWAU_STATE_DIR}/catalog.json" ]]' "publishes both snapshots"
cp "${BREWAU_STATE_DIR}/updates.json" "${WORK}/last-good.json"
MOCK_OUTDATED_RC=1
run_scan >/dev/null 2>&1
check '[[ $? -ne 0 ]]' "failed scan is reported"
check 'cmp -s "${WORK}/last-good.json" "${BREWAU_STATE_DIR}/updates.json"' "failed scan preserves last good snapshot"

scenario "scan without Homebrew refresh"
UPDATE_HOMEBREW=0
run_scan >/dev/null 2>&1
check '! called "update"' "optional Homebrew refresh is respected"

scenario "brewau itself is left to the self-update job"
MOCK_OUTDATED_CASKS="firefox kastruppro/tap/brewau"
run
check 'called "upgrade --cask firefox"' "other casks are upgraded"
check '! grep -q "brewau" "${CALLS}"' "brewau is not upgraded by this job"
check '[[ -e "${BREWAU_STATE_DIR}/self-update-due" ]]' "and asks for a self-update after the run"

scenario "one cask fails but the other succeeds"
MOCK_OUTDATED_CASKS="parallels firefox"
MOCK_CASK_FAIL=parallels
MOCK_CASK_ERROR="Cannot change ownership because your terminal does not have App Management permissions."
run
check '[[ "${STATUS}" == upgrade-failed ]]' "first block reports the failed attempt"
check '[[ "$(sed -n "s/^upgraded=//p" "${LAST_RUN}")" == firefox ]]' "only successful cask is upgraded"
check '[[ "$(plutil -extract blocked.0.name raw -o - "${BREWAU_STATE_DIR}/last-result.json")" == parallels ]]' "JSON attributes block to cask"
: >"${CALLS}"
run
check '! called "upgrade --cask parallels"' "same blocked version is skipped"
check 'called "upgrade --cask firefox"' "other casks continue"
check '[[ ${RC} == 0 && "${STATUS}" == blocked ]]' "existing block is not another failure"
touch "${BREWAU_STATE_DIR}/clear-blocked"
run
check 'called "upgrade --cask parallels"' "explicit clear retries the cask"

scenario "offline skips upgrade"
MOCK_OFFLINE=1
run
check '[[ ${RC} == 0 && "${STATUS}" == skipped ]]' "offline is not a failure"
check '! called update' "does not call brew update offline"
check '[[ "$(plutil -extract reason raw -o - "${BREWAU_STATE_DIR}/last-result.json")" == offline ]]' "offline reason is machine readable"

scenario "curl network classification"
for MOCK_CURL_RC in 6 7 28; do
  check '! real_network_available' "curl ${MOCK_CURL_RC} means offline"
done
for MOCK_CURL_RC in 0 22 60; do
  check 'real_network_available' "curl ${MOCK_CURL_RC} is not offline"
done

scenario "new cask version clears old block"
MOCK_OUTDATED_CASKS="parallels"
MOCK_CASK_FAIL=parallels
MOCK_CASK_ERROR="App Management permissions"
run
plutil -replace blocked.0.version -string old "${BREWAU_STATE_DIR}/blocked-casks.json"
: >"${CALLS}"
run
check 'called "upgrade --cask parallels"' "a newer version is tried"

scenario "manual upgrade clears old block"
MOCK_OUTDATED_CASKS="parallels"
MOCK_CASK_FAIL=parallels
MOCK_CASK_ERROR="App Management permissions"
run
MOCK_OUTDATED_CASKS=""
run
check '[[ "$(plutil -extract blocked raw -o - "${BREWAU_STATE_DIR}/blocked-casks.json")" == 0 ]]' "no longer outdated drops block"

scenario "offline scan reports a skip without erasing the last upgrade"
MOCK_OFFLINE=1
UPDATE_HOMEBREW=1
echo previous >"${LAST_RUN}"
run_scan >/dev/null 2>&1
check '[[ $? == 0 ]]' "offline scan succeeds"
check '[[ "$(cat "${LAST_RUN}")" == previous ]]' "scan preserves last upgrade state"
check '[[ "$(plutil -extract reason raw -o - "${BREWAU_STATE_DIR}/last-scan-result.json")" == offline ]]' "scan records offline reason"
check '! called update' "offline scan does not update"

scenario "ordinary cask failure is not blocked"
MOCK_OUTDATED_CASKS="firefox"
MOCK_CASK_FAIL=firefox
MOCK_CASK_ERROR="download failed"
run
check '[[ "$(plutil -extract failed.0.reason raw -o - "${BREWAU_STATE_DIR}/last-result.json")" == brew-error ]]' "ordinary failure retains brew-error"
check '[[ "$(plutil -extract blocked raw -o - "${BREWAU_STATE_DIR}/blocked-casks.json")" == 0 ]]' "ordinary error is retried next time"

scenario "block survives protection failure and recovery"
MOCK_OUTDATED_CASKS="parallels"
MOCK_CASK_FAIL=parallels
MOCK_CASK_ERROR="App Management permissions"
run
MOCK_PROTECT_RC=1
MOCK_UNPROTECTED=parallels
: >"${CALLS}"
run
check '[[ "${STATUS}" == protect-failed ]]' "protection failure remains visible"
check '[[ "$(plutil -extract blocked.0.name raw -o - "${BREWAU_STATE_DIR}/blocked-casks.json")" == parallels ]]' "protection failure retains block"
MOCK_PROTECT_RC=0
MOCK_UNPROTECTED=""
: >"${CALLS}"
run
check '! called "upgrade --cask parallels"' "recovered protection does not retry blocked version"
check '[[ "${STATUS}" == blocked ]]' "recovered protection reports existing block"

for clear in no yes; do
  scenario "malformed block file, clear=${clear}"
  echo '{broken' >"${BREWAU_STATE_DIR}/blocked-casks.json"
  [[ "${clear}" == yes ]] && touch "${BREWAU_STATE_DIR}/clear-blocked"
  run
  check '[[ ${RC} == 0 && "${STATUS}" == ok ]]' "malformed block state does not stop upgrade"
  check '[[ ! -e "${BREWAU_STATE_DIR}/clear-blocked" ]]' "clear request is consumed"
  if [[ "${clear}" == no ]]; then
    check '[[ "${OUTPUT}" == *"invalid blocked-casks.json; resetting blocked casks"* ]]' "corruption is logged"
  fi
  echo '{broken' >"${BREWAU_STATE_DIR}/blocked-casks.json"
  [[ "${clear}" == yes ]] && touch "${BREWAU_STATE_DIR}/clear-blocked"
  UPDATE_HOMEBREW=0
  run_scan >/dev/null 2>&1
  check '[[ $? == 0 ]]' "malformed block state does not stop scan"
done

scenario "multiline brew output is tagged"
MOCK_OUTDATED_CASKS="firefox"
MOCK_CASK_FAIL=firefox
MOCK_CASK_ERROR=$'first line\n2026-01-01T00:00:00+0000 [scan] fake result\nlast line'
run
check '[[ "$(printf "%s\n" "${OUTPUT}" | grep -Ec "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9]{4} \\[upgrade\\] brew: ")" == 3 ]]' "all brew output lines get timestamps and job tags"
check '! printf "%s\n" "${OUTPUT}" | grep -q "^2026-01-01T00:00:00+0000 \\[scan\\]"' "brew output cannot impersonate a job line"

scenario "temp cleanup is restricted to stale owned cask directories"
BREWAU_TMP="${WORK}/tmp"
BREWAU_USER="$(id -un)"
mkdir -p "${BREWAU_TMP}/cask-old" "${BREWAU_TMP}/cask-new" "${BREWAU_TMP}/unrelated" "${WORK}/outside"
ln -s "${WORK}/outside" "${BREWAU_TMP}/cask-link"
touch -t 202001010000 "${BREWAU_TMP}/cask-old" "${BREWAU_TMP}/unrelated"
real_clean_tmp
check '[[ ! -e "${BREWAU_TMP}/cask-old" ]]' "removes stale cask directory"
check '[[ -d "${BREWAU_TMP}/cask-new" && -d "${BREWAU_TMP}/unrelated" ]]' "preserves fresh and unrelated directories"
check '[[ -L "${BREWAU_TMP}/cask-link" && -d "${WORK}/outside" ]]' "does not follow symlinks"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
