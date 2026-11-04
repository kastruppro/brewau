#!/bin/bash
# Tests for `brewau config add|remove|set` on a copy of brewau.conf.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

# The checkout's CLI against the checkout's libexec, without running a command.
sed -e "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" -e '/^case "${1:-}" in/,$d' \
  "${PAYLOAD}/bin/brewau" >"${WORK}/brewau"
# shellcheck source=/dev/null
source "${WORK}/brewau"

check() {
  local want="$1" got="$2" what="$3"
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${want}" "${got}"
  fi
}

CONF="${WORK}/brewau.conf"
reset() { cp "${PAYLOAD}/share/brewau.conf.default" "${CONF}"; }
# change <args...>: runs config_change on the copy; prints ok or failed.
change() { (config_change "$1" "${CONF}" "${@:2}") >/dev/null 2>&1 && echo ok || echo failed; }
line() { grep -E "^$1=" "${CONF}"; }

reset
check ok "$(change add ALLOWED_TAPS openai/tools)" "add a tap"
check 'ALLOWED_TAPS="openai/tools"' "$(line ALLOWED_TAPS)" "the tap is written"
check ok "$(change add allowed_taps Acme/Tools openai/tools)" "add another tap, key in lower case"
check 'ALLOWED_TAPS="openai/tools acme/tools"' "$(line ALLOWED_TAPS)" "taps are lowered and not repeated"
check ok "$(change remove ALLOWED_TAPS OpenAI/Tools)" "remove a tap"
check 'ALLOWED_TAPS="acme/tools"' "$(line ALLOWED_TAPS)" "only that tap is removed"
check ok "$(change add EXTRA_ALLOWED_OPTIONS "--no-binaries,--foo")" "commas separate entries in add"
check 'EXTRA_ALLOWED_OPTIONS="--no-binaries --foo"' "$(line EXTRA_ALLOWED_OPTIONS)" "and are written as spaces"
check ok "$(change set UPGRADE_MODE weekly)" "set a value"
check 'UPGRADE_MODE="weekly"' "$(line UPGRADE_MODE)" "the value is replaced"
check 1 "$(grep -c '^UPGRADE_MODE=' "${CONF}")" "the key stays on one line"
check ok "$(change set FORBIDDEN_CASKS)" "set a list to empty"
check 'FORBIDDEN_CASKS=""' "$(line FORBIDDEN_CASKS)" "the list is empty"

printf 'UPGRADE_MODE="daily"\n' >"${CONF}"
check ok "$(change add ALLOWED_SERVICES tailscale)" "add a key the file does not have yet"
check 'ALLOWED_SERVICES="tailscale"' "$(line ALLOWED_SERVICES)" "the key is appended"

reset
check failed "$(change add UPGRADE_MODE daily)" "add refuses a setting that is not a list"
check failed "$(change set FORBIDDEN_CASKS 'a,b')" "set refuses commas"
check failed "$(change set FORBIDDEN_CASKS "$(printf 'a"\nALLOWED_TAPS="evil/tap')")" "set refuses quotes and newlines"
check failed "$(change set 'X=1 #' 1)" "set refuses an invalid key"
check failed "$(change add ALLOWED_TAPS)" "add needs a value"
check "" "$(grep -E '^ALLOWED_TAPS="evil' "${CONF}")" "no line was injected"

echo "cli config tests: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
