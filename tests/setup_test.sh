#!/bin/bash
# Tests for the parts of brewau-setup that run without root.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
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

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
