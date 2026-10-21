#!/bin/bash
# Unit tests for brew-policy's allow/deny decisions. Runs without installing.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
BREWAU_POLICY_TEST=1
# shellcheck source=../payload/opt/brewau/libexec/brew-policy
source "${HERE}/../payload/opt/brewau/libexec/brew-policy"

ALLOWED_TAPS="acme/tools"
PASS=0
FAIL=0

expect() {
  local want="$1"
  shift
  local got
  DENY_REASON=""
  if check_command "$@"; then got=allow; else got=deny; fi
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: expected %s, got %s: brew %s %s\n' "${want}" "${got}" "$*" "${DENY_REASON:+(${DENY_REASON})}"
  fi
}

# Everyday usage.
expect allow
expect allow --version
expect allow list
expect allow info wget
expect allow install wget
expect allow install --cask firefox google-chrome
expect allow install node@22
expect allow install libxml++3
expect allow upgrade
expect allow upgrade --greedy --cask
expect allow uninstall --zap --cask firefox
expect allow cleanup --prune=all
expect allow search "/^py.*/"
expect allow outdated --json=v2
expect allow tap
expect allow tap homebrew/cask-fonts
expect allow tap acme/tools
expect allow install acme/tools/thing
expect allow install homebrew/cask/firefox
expect allow analytics off
expect allow doctor

# Every allowlist entry passes, including the last word on each line.
expect allow --config
expect allow missing
expect allow update-reset
expect allow update-reset -q
# Its arguments are repository paths, relative to where brew runs.
expect deny update-reset tmp
expect deny update-reset Library/Taps/acme/homebrew-tools
expect allow install --help wget
expect allow install -s wget
expect allow list --pinned
expect allow deps --include-test wget
expect allow upgrade --greedy-auto-updates
expect allow install --skip-cask-deps --cask firefox
expect allow completions --bash
EXTRA_ALLOWED_OPTIONS="--no-binaries
  --ignore-pinned"
expect allow install --no-binaries wget
expect allow upgrade --ignore-pinned
EXTRA_ALLOWED_OPTIONS=""
expect deny install "--force --zap" wget

# Arbitrary code execution as _brewau.
expect deny sh
expect deny ruby -e 'puts 1'
expect deny irb
expect deny edit wget
expect deny extract wget acme/tools
expect deny bundle
expect deny services start postgresql
expect deny tap-new evil/tap
expect deny developer on
expect deny command ls
expect deny install ./evil.rb
expect deny install /tmp/evil.rb
expect deny install https://example.com/evil.rb
expect deny install file:///tmp/evil.rb
expect deny info ../evil
expect deny install wget --cc=/tmp/evil
expect deny install --interactive wget
expect deny install -i wget
expect deny install --debug wget
expect deny install --appdir=/Library/LaunchDaemons --cask firefox
expect deny install -- wget
expect deny install --no-quarantine --cask firefox
# --adopt registers an app the user owns, whose code cask steps then run.
expect deny install --adopt --cask orbstack

# brew.sh moves a leading -v to the end, so the policy must see the real command.
expect allow -v
expect allow -v install wget
expect allow -v -v
expect deny -v sh
expect deny -v ruby
expect deny -v irb
expect deny -v edit wget
expect deny -v developer on
expect deny -v services start postgresql
expect deny -v x wget

# brew services runs as root, so only ALLOWED_SERVICES and safe actions pass.
ALLOWED_SERVICES="tailscale"
expect allow services
expect allow services list
expect allow services list --json
expect allow services start tailscale
expect allow services restart tailscale
expect allow services stop tailscale
expect allow services info tailscale --json
expect allow -v services start tailscale
expect deny services start redis
expect deny services start tailscale redis
expect deny services start
expect deny services list tailscale
expect deny services start tailscale --file=/tmp/evil.plist
expect deny services start --file=/tmp/evil.plist tailscale
expect deny services start tailscale --sudo-service-user=root
expect deny services start tailscale --json
expect deny services cleanup
expect deny services start ../tailscale
expect deny services start acme/tools/tailscale
expect allow -v services
expect allow services --json
expect allow services --json list
expect allow services -v start tailscale
expect deny services start --json tailscale
expect deny services run tailscale
expect deny services tailscale
# Homebrew's aliases mean the same actions.
expect allow services s tailscale
expect allow services relaunch tailscale
expect allow services ls
expect deny services rm
expect deny services cl tailscale
ALLOWED_SERVICES=""

# check_services records what main() acts on.
ALLOWED_SERVICES="tailscale"
check_command -v services restart tailscale
if [[ "${SERVICE_ACTION} ${SERVICE_NAME}" == "restart tailscale" ]]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: check_services recorded '${SERVICE_ACTION} ${SERVICE_NAME}'"
fi
ALLOWED_SERVICES=""

# Commands after which cask apps are locked.
cask_lock() {
  local want="$1"
  shift
  local got=no
  installs_casks "$@" && got=yes
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: installs_casks $* is ${got}, expected ${want}"
  fi
}
cask_lock yes install install --cask firefox
cask_lock yes install install wget
cask_lock yes upgrade upgrade
cask_lock yes reinstall reinstall firefox
cask_lock yes upgrade -v upgrade
cask_lock no install install --formula wget
cask_lock no upgrade upgrade --formulae
cask_lock no uninstall uninstall --cask firefox
cask_lock no list list --cask

# Commands that can run code from cask apps, and the refusal when an app
# could not be protected.
code_from_apps() {
  local want="$1"
  shift
  local got=no
  runs_cask_uninstall "$@" && got=yes
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: runs_cask_uninstall $* is ${got}, expected ${want}"
  fi
}
code_from_apps yes uninstall --cask firefox
code_from_apps yes upgrade
code_from_apps yes reinstall firefox
code_from_apps yes install --force firefox
code_from_apps no install firefox
code_from_apps no uninstall --formula wget
code_from_apps no list

protect_cask_apps() { [[ -z "${MOCK_UNPROTECTED}" ]] || { echo "${MOCK_UNPROTECTED}"; return 1; }; }
protected() {
  local want="$1"
  shift
  local got=deny
  DENY_REASON=""
  cask_apps_protected "$@" && got=allow
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: with ${MOCK_UNPROTECTED:-no} unprotected, $* was ${got}, expected ${want}"
  fi
}
MOCK_UNPROTECTED=""
protected allow --cask firefox
MOCK_UNPROTECTED="slack"
protected allow --cask firefox
protected deny --cask slack
protected deny homebrew/cask/slack
protected deny --greedy

# Taps outside the allowlist.
expect deny tap evil/tap
expect deny tap acme/tools https://evil.example/tools.git
expect deny tap --custom-remote acme/tools
expect deny install evil/tap/thing
expect deny upgrade evil/tap/thing
expect deny analytics on extra

# Option injection disguised as names.
expect deny install '-'
expect deny install 'wget;id'
expect deny install 'wget$(id)'
expect deny install $'wget\nid'

# Drift checks against the installed Homebrew, whose brew.sh rewrites argv
# before dispatch. The policy must agree with every rewrite.
BREW_SH="/opt/homebrew/Library/Homebrew/brew.sh"
if [[ -r "${BREW_SH}" ]]; then
  # Only the known `-v` rotation may reorder arguments.
  if [[ "$(grep -c 'set -- "\$@"' "${BREW_SH}")" -eq 1 ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${BREW_SH} reorders argv in a new way; review check_command"
  fi
  # An allowed alias must map to an allowed command.
  while read -r alias target; do
    DENY_REASON=""
    check_command "${alias}" || continue
    if check_command "${target}"; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "FAIL: allowed alias '${alias}' maps to denied command '${target}'"
    fi
  done < <(sed -n 's/^ *\([^ )]*\)) HOMEBREW_COMMAND="\([^"]*\)" ;;.*/\1 \2/p' "${BREW_SH}")
else
  echo "skipping Homebrew drift checks: ${BREW_SH} not found"
fi

# The audit log quotes arguments so free text cannot forge entries.
BREWAU_LOG_DIR="$(mktemp -d)"
BREWAU_AUDIT_LOG="${BREWAU_LOG_DIR}/audit.log"
SUDO_USER=tester
audit allow search $'x\n2026-01-01T00:00:00Z user=root decision=allow argv=sh'
audit allow
if [[ "$(wc -l <"${BREWAU_AUDIT_LOG}" | tr -d ' ')" -eq 2 ]] &&
  grep -q "user=tester decision=allow argv=search \\$'x\\\\n" "${BREWAU_AUDIT_LOG}"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: audit log entries are not one quoted line each:"
  cat "${BREWAU_AUDIT_LOG}"
fi
rm -rf "${BREWAU_LOG_DIR}"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
