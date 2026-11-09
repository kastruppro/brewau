#!/bin/bash
# Evaluate shellenv repeatedly with an existing wrapper and Homebrew ahead of it.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sed '/^    \/opt\/homebrew\/bin\/brew shellenv /c\
    :
' "${HERE}/../payload/opt/brewau/bin/brew" >"${WORK}/brew"
for shell in bash zsh; do
  output="$(/bin/bash "${WORK}/brew" shellenv "${shell}")"
  BREWAU_TEST_OUTPUT="${output}" /bin/"${shell}" -c '
    PATH=/opt/homebrew/bin:/usr/bin:/opt/brewau/bin:/opt/brewau/bin:/bin
    eval "$BREWAU_TEST_OUTPUT"
    eval "$BREWAU_TEST_OUTPUT"
    if test -n "${ZSH_VERSION:-}"; then export PATH="/opt/brewau/bin:${PATH}"; fi
    test "${PATH%%:*}" = /opt/brewau/bin
    test "$(printf "%s" "$PATH" | /usr/bin/tr : "\n" | /usr/bin/grep -cx /opt/brewau/bin)" = 1
  '
done
echo "shellenv tests: 2 passed, 0 failed"
