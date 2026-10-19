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

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
