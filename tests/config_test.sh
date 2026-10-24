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

check() {
  local want="$1" got="$2" what="$3"
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${want}" "${got}"
  fi
}

# load <strict 0|1> <config lines...>: prints valid or invalid.
load() {
  local strict="$1"
  shift
  printf '%s\n' "$@" >"${WORK}/brewau.conf"
  if (BREWAU_CONFIG_STRICT="${strict}" brewau_load_config "${WORK}/brewau.conf") 2>/dev/null; then
    echo valid
  else
    echo invalid
  fi
}

# expect <valid|invalid when edited> <valid|invalid at runtime> <config lines...>
expect() {
  local edited="$1" runtime="$2"
  shift 2
  check "${edited}" "$(load 1 "$@")" "sudo brewau config: $*"
  check "${runtime}" "$(load 0 "$@")" "runtime: $*"
}

# value <setting> <config lines...>: the setting after loading at runtime.
value() {
  local key="$1"
  shift
  printf '%s\n' "$@" >"${WORK}/brewau.conf"
  (brewau_load_config "${WORK}/brewau.conf" 2>/dev/null && echo "${!key}")
}

expect valid valid "$(cat "${HERE}/../payload/opt/brewau/share/brewau.conf.default")"
expect valid valid 'ALLOWED_TAPS="acme/tools other/tap"' 'UPGRADE_HOUR="08"' 'UPGRADE_MINUTE="59"'
expect valid valid 'UPGRADE_EXCLUDE="node@22 libxml++3 acme/tools/thing"'

# Anything that could hide or change a restriction is always fatal.
expect invalid invalid 'ALLOWED_TAPS="acme/tools" # trailing comment'
expect invalid invalid 'ALLOWED_TAPS="$(id)"'
expect invalid invalid 'ALLOWED_TAPS="https://example.com/tap.git"'
expect invalid invalid 'FORBIDDEN_CASKS = "firefox"'
expect invalid invalid 'forbidden_formulae="wget"'
expect invalid invalid 'export FORBIDDEN_CASKS="firefox"'
expect invalid invalid 'FORBIDEN_CASKS="firefox"'

# Problems that can only narrow the policy are refused when editing, but at
# runtime only warn, so a stale value never locks everyone out of brew.
expect invalid valid 'UPGRADE_HOUR="24"'
expect invalid valid 'UPGRADE_HOUR="4am"'
expect invalid valid 'UPGRADE_MINUTE="60"'
expect invalid valid 'UPGRADE_GREEDY="2"'
expect invalid valid 'ALLOWED_TAPS="my-tap"'
expect invalid valid 'ALLOWED_SERVICES="acme/tools/thing"'

check "4" "$(value UPGRADE_HOUR 'UPGRADE_HOUR="24"')" "an invalid hour falls back to the default"
check "0" "$(value UPGRADE_MINUTE 'UPGRADE_MINUTE="60"')" "an invalid minute falls back to the default"
check "1" "$(value UPGRADE_GREEDY 'UPGRADE_GREEDY="2"')" "an invalid boolean falls back to the default"
check "acme/tools" "$(value ALLOWED_TAPS 'ALLOWED_TAPS="acme/tools my-tap"')" "an invalid tap is dropped"
check "tailscale" "$(value ALLOWED_SERVICES 'ALLOWED_SERVICES="tailscale ../x"')" "an invalid service is dropped"
check "1" "$(value AUTO_UPGRADE 'AUTO_UPGRADE="yes"')" "yes means 1"
check "0" "$(value AUTO_UPGRADE 'AUTO_UPGRADE="Off"')" "off means 0"
check "valid" "$(load 1 'AUTO_UPGRADE="true"' 'UPGRADE_GREEDY="no"')" "spelled-out booleans are accepted when editing"
check "acme/tools" "$(value ALLOWED_TAPS 'ALLOWED_TAPS="Acme/Tools"')" "taps are case-insensitive"

printf 'UPGRADE_HOUR="24"\n' >"${WORK}/brewau.conf"
check "1" "$(brewau_load_config "${WORK}/brewau.conf" 2>&1 >/dev/null | grep -c 'warning: UPGRADE_HOUR')" \
  "a runtime problem is reported"
printf '# comment\n\nFORBIDDEN_CASKS = "firefox"\n' >"${WORK}/brewau.conf"
check "1" "$( (brewau_load_config "${WORK}/brewau.conf") 2>&1 | grep -c 'line 3')" \
  "a line that does not parse is reported with its number"

expect valid valid 'UPGRADE_MODE="weekly"' 'UPGRADE_WEEKDAY="2"' 'UPGRADE_TIMES="180 900"' 'SCAN_MINUTES="15"'
expect invalid valid 'UPGRADE_MODE="cron"'
expect invalid valid 'SCAN_MINUTES="1"'
expect invalid valid 'UPGRADE_TIMES="1440"'
expect invalid valid 'UPGRADE_TIMES="180 180"'
expect invalid valid 'UPGRADE_WEEKDAY="8"'
expect invalid valid 'UPGRADE_INTERVAL_HOURS="0"'
check "0" "$(value AUTO_UPGRADE 'UPGRADE_MODE="cron"')" "invalid mode disables upgrades"
check "0" "$(value AUTO_UPGRADE 'UPGRADE_TIMES="9999"')" "invalid time disables upgrades"

# --- brewau_in_words -------------------------------------------------------
LIST=" one two
  three	four "
for word in one two three four; do
  check "yes" "$(brewau_in_words "${word}" "${LIST}" && echo yes || echo no)" "'${word}' is found across lines and tabs"
done
check "no" "$(brewau_in_words "tw" "${LIST}" && echo yes || echo no)" "only whole words match"
check "no" "$(brewau_in_words "one two" "${LIST}" && echo yes || echo no)" "a word with whitespace never matches"
check "no" "$(brewau_in_words "" "${LIST}" && echo yes || echo no)" "an empty word never matches"
check "no" "$(brewau_in_words "*" "${LIST}" && echo yes || echo no)" "patterns are not expanded"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
