#!/bin/bash
# Round-trip test for `brewau setup-shell` and `brewau restore-shell`.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

check() {
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $*"
  fi
}

# Run the checkout's CLI against the checkout's libexec.
sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/bin/brewau" >"${WORK}/brewau"
mkdir -p "${WORK}/home/dotfiles"
brewau() { HOME="${WORK}/home" /bin/bash "${WORK}/brewau" "$@" >/dev/null; }

printf 'export FOO=1\n\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >"${WORK}/home/dotfiles/zprofile"
ln -s dotfiles/zprofile "${WORK}/home/.zprofile"
printf 'alias ll=ls\neval $(brew shellenv)\n' >"${WORK}/home/.zshrc"
cp "${WORK}/home/dotfiles/zprofile" "${WORK}/zprofile.orig"

brewau setup-shell
check grep -qF '/opt/brewau/bin/brew shellenv' "${WORK}/home/.zprofile"
check grep -qF 'eval $(/opt/brewau/bin/brew shellenv)' "${WORK}/home/.zshrc"
check test -L "${WORK}/home/.zprofile"
check grep -qF 'fpath=(/opt/brewau/share/zsh/site-functions ${fpath:#/opt/homebrew/*})' "${WORK}/home/.zshrc"
check grep -qF '# BEGIN brewau completions' "${WORK}/home/.zprofile"

# Running it twice must not change anything.
cp "${WORK}/home/.zshrc" "${WORK}/zshrc.once"
brewau setup-shell
check cmp -s "${WORK}/zshrc.once" "${WORK}/home/.zshrc"

brewau restore-shell
check cmp -s "${WORK}/zprofile.orig" "${WORK}/home/.zprofile"
check test -L "${WORK}/home/.zprofile"
check cmp -s <(printf 'alias ll=ls\neval $(/opt/homebrew/bin/brew shellenv)\n') "${WORK}/home/.zshrc"
check test "$(grep -c 'brewau completions' "${WORK}/home/.zshrc")" -eq 0

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
