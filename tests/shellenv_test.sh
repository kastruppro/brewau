#!/bin/bash
# shellenv only prints code; test with a scratch HOME and no Homebrew dependency.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd -P)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
sed '/^    \/opt\/homebrew\/bin\/brew shellenv /c\
    :
' "${HERE}/../payload/opt/brewau/bin/brew" >"${WORK}/brew"
NPM="$(command -v npm || true)"
for home in 'home space' 'home\\test'; do
mkdir "${WORK}/${home}"
export HOME="${WORK}/${home}"
unset NPM_CONFIG_PREFIX npm_config_prefix NPM_CONFIG_USERCONFIG npm_config_userconfig GEM_HOME
for shell in bash zsh; do
  output="$(/bin/bash "${WORK}/brew" shellenv "${shell}")"
  BREWAU_TEST_OUTPUT="${output}" /bin/"${shell}" -ec '
    PATH=/opt/homebrew/bin:/usr/bin:/opt/brewau/bin:/opt/brewau/bin:/bin
    eval "$BREWAU_TEST_OUTPUT"
    eval "$BREWAU_TEST_OUTPUT"
    test "$NPM_CONFIG_PREFIX" = "$HOME/.npm-global"
    test "$GEM_HOME" = "$HOME/.gem"
    test "$PATH" = "/opt/brewau/bin:$HOME/.npm-global/bin:$HOME/.gem/bin:/opt/homebrew/bin:/usr/bin:/bin"
  '
  # Re-generating shellenv with defaults already exported keeps both bin dirs.
  NPM_CONFIG_PREFIX="$HOME/.npm-global" GEM_HOME="$HOME/.gem" /bin/bash "${WORK}/brew" shellenv "${shell}" >"${WORK}/repeat"
  grep -Fq '.npm-global/bin' "${WORK}/repeat"
  grep -Fq '.gem/bin' "${WORK}/repeat"
  NPM_CONFIG_PREFIX=/custom/npm GEM_HOME=/custom/gem /bin/bash "${WORK}/brew" shellenv "${shell}" >"${WORK}/custom"
  ! grep -Eq 'export (NPM_CONFIG_PREFIX|GEM_HOME)=' "${WORK}/custom"
  ! grep -Eq '\.npm-global|\.gem/bin' "${WORK}/custom"
  for key in prefix '"prefix"' "'prefix'"; do
    printf '#prefix=ignored\n  %s = /custom/npmrc\n' "${key}" >"${HOME}/.npmrc"
    /bin/bash "${WORK}/brew" shellenv "${shell}" >"${WORK}/npmrc"
    ! grep -q NPM_CONFIG_PREFIX "${WORK}/npmrc"
    ! grep -q '.npm-global' "${WORK}/npmrc"
    BREWAU_TEST_OUTPUT="$(cat "${WORK}/npmrc")" BREWAU_TEST_NPM="${NPM}" /bin/"${shell}" -ec '
      eval "$BREWAU_TEST_OUTPUT"
      test "${NPM_CONFIG_PREFIX+x}" = ""
      if test -n "$BREWAU_TEST_NPM"; then
        test "$("$BREWAU_TEST_NPM" config get prefix)" = /custom/npmrc
      fi
    '
  done
  rm "${HOME}/.npmrc"
  NPM_CONFIG_PREFIX='' GEM_HOME='' /bin/bash "${WORK}/brew" shellenv "${shell}" >"${WORK}/empty"
  ! grep -Eq 'export (NPM_CONFIG_PREFIX|GEM_HOME)=' "${WORK}/empty"
done
for shell in tcsh fish; do
  /bin/bash "${WORK}/brew" shellenv "${shell}" >"${WORK}/env.${shell}"
  if command -v "${shell}" >/dev/null; then
    if [[ "${shell}" == tcsh ]]; then
      { echo 'setenv PATH /opt/homebrew/bin:/usr/bin:/opt/brewau/bin:/bin'; cat "${WORK}/env.tcsh" "${WORK}/env.tcsh"; echo '/usr/bin/printenv NPM_CONFIG_PREFIX; /usr/bin/printenv GEM_HOME; /usr/bin/printenv PATH'; } >"${WORK}/check.tcsh"
      tcsh -f "${WORK}/check.tcsh" >"${WORK}/result"
    else
      { echo 'set -gx PATH /opt/homebrew/bin /usr/bin /opt/brewau/bin /bin'; cat "${WORK}/env.fish" "${WORK}/env.fish"; echo '/usr/bin/printenv NPM_CONFIG_PREFIX; /usr/bin/printenv GEM_HOME; /usr/bin/printenv PATH'; } >"${WORK}/check.fish"
      fish --no-config "${WORK}/check.fish" >"${WORK}/result"
    fi
    grep -Fxq "$HOME/.npm-global" "${WORK}/result"
    grep -Fxq "$HOME/.gem" "${WORK}/result"
    grep -Fq "/opt/brewau/bin:$HOME/.npm-global/bin:$HOME/.gem/bin:/opt/homebrew/bin" "${WORK}/result"
  else
    echo "shellenv: ${shell} unavailable; output syntax only"
    grep -q 'NPM_CONFIG_PREFIX "$HOME/.npm-global"' "${WORK}/env.${shell}"
  fi
done
[[ "$(ls -A "${HOME}")" == '' ]]
done
echo "shellenv tests passed (defaults, overrides, npmrc, repeated evaluation, no files created)"
