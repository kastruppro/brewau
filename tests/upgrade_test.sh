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

# Mocked brew: answers from MOCK_* variables and records every call.
brew_run() {
  echo "$*" >>"${CALLS}"
  case "$*" in
    "list --formula -1") printf '%s\n' ${MOCK_INSTALLED:-}; return "${MOCK_LIST_RC:-0}" ;;
    "list --pinned") printf '%s\n' ${MOCK_PINNED:-}; return "${MOCK_PINNED_RC:-0}" ;;
    "outdated --formula --quiet") printf '%s\n' ${MOCK_OUTDATED_FORMULAE:-}; return "${MOCK_OUTDATED_FORMULAE_RC:-0}" ;;
    "outdated --cask --quiet"*) printf '%s\n' ${MOCK_OUTDATED_CASKS:-}; return "${MOCK_OUTDATED_CASKS_RC:-0}" ;;
  esac
  return 0
}
protect_apps() { :; }
clean_tmp() { :; }
# Mocked root brew and launchd: tailscale's system daemon is loaded.
brewau_exec_brew_as_root() { echo "root $*" >>"${CALLS}"; }
launchctl() { [[ "$*" == "print system/homebrew.mxcl.tailscale" ]]; }

# scenario <name>: resets state; set MOCK_* and config before calling run.
scenario() {
  NAME="$1"
  rm -rf "${BREWAU_STATE_DIR}" "${CALLS}"
  mkdir -p "${BREWAU_STATE_DIR}"
  touch "${CALLS}"
  unset MOCK_INSTALLED MOCK_PINNED MOCK_LIST_RC MOCK_PINNED_RC MOCK_OUTDATED_FORMULAE \
    MOCK_OUTDATED_FORMULAE_RC MOCK_OUTDATED_CASKS MOCK_OUTDATED_CASKS_RC
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

scenario "outdated formulae fails"
MOCK_OUTDATED_FORMULAE_RC=1
run
check '[[ ${RC} -ne 0 ]]' "job exits non-zero"
check '[[ "${STATUS}" == "outdated-failed" ]]' "status is outdated-failed (got ${STATUS})"
check '[[ "${OUTPUT}" != *"everything is up to date"* ]]' "does not claim everything is up to date"

scenario "outdated casks fails"
MOCK_OUTDATED_CASKS_RC=1
run
check '[[ "${STATUS}" == "outdated-failed" ]]' "status is outdated-failed (got ${STATUS})"

scenario "all good"
MOCK_OUTDATED_FORMULAE="wget"
MOCK_OUTDATED_CASKS="firefox"
run
check '[[ ${RC} -eq 0 && "${STATUS}" == "ok" ]]' "status ok"
check 'called "upgrade --formula wget"' "upgrades outdated formulae"
check 'called "upgrade --cask firefox"' "upgrades outdated casks"

scenario "upgraded system services are restarted"
ALLOWED_SERVICES="tailscale redis"
MOCK_OUTDATED_FORMULAE="tailscale redis wget"
run
check 'called "root services restart tailscale"' "restarts a loaded system service after its upgrade"
check '! called "root services restart redis"' "leaves allowed services that are not loaded alone"
check '! grep -q "root services restart wget" "${CALLS}"' "never touches services outside ALLOWED_SERVICES"
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

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
