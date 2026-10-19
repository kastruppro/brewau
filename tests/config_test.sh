#!/bin/bash
# Tests for parsing and validating brewau.conf.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../payload/opt/brewau/libexec/common.sh
source "${HERE}/../payload/opt/brewau/libexec/common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

# expect valid|invalid <config lines...>
expect() {
  local want="$1" got
  shift
  printf '%s\n' "$@" >"${WORK}/brewau.conf"
  if (brewau_load_config "${WORK}/brewau.conf") 2>/dev/null; then got=valid; else got=invalid; fi
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: expected %s, got %s: %s\n' "${want}" "${got}" "$*"
  fi
}

expect valid "$(cat "${HERE}/../payload/opt/brewau/share/brewau.conf.default")"
expect valid 'ALLOWED_TAPS="acme/tools other/tap"' 'UPGRADE_HOUR="08"' 'UPGRADE_MINUTE="59"'
expect valid 'UPGRADE_EXCLUDE="node@22 libxml++3"'
expect invalid 'ALLOWED_TAPS="acme/tools" # trailing comment'
expect invalid 'ALLOWED_TAPS="$(id)"'
expect invalid 'UPGRADE_HOUR="24"'
expect invalid 'UPGRADE_HOUR="4am"'
expect invalid 'UPGRADE_MINUTE="60"'
expect invalid 'AUTO_UPGRADE="yes"'
expect invalid 'UPGRADE_GREEDY="2"'

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
