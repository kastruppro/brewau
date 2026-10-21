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
    "upgrade --formula"*) return "${MOCK_UPGRADE_RC:-0}" ;;
  esac
  return 0
}
protect_apps() {
  echo "protect" >>"${CALLS}"
  [[ -n "${MOCK_UNPROTECTED:-}" ]] && echo "${MOCK_UNPROTECTED}"
  return "${MOCK_PROTECT_RC:-0}"
}
clean_tmp() { :; }
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
    MOCK_UNPROTECTED MOCK_PROTECT_RC
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

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
