#!/bin/bash
# Tests for tap blocking and app protection helpers in common.sh.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../payload/opt/brewau/libexec/common.sh
source "${HERE}/../payload/opt/brewau/libexec/common.sh"
WORK="$(mktemp -d)"
trap 'chmod -RN "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
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

# --- brewau_forbidden_taps ---------------------------------------------------
HOMEBREW_PREFIX_PATH="${WORK}/prefix"
make_tap() {
  local dir="${HOMEBREW_PREFIX_PATH}/Library/Taps/$1/homebrew-$2"
  mkdir -p "${dir}/.git"
  [[ -n "${3:-}" ]] && printf '[remote "origin"]\n\turl = %s\n' "$3" >"${dir}/.git/config"
  return 0
}
make_tap homebrew core https://github.com/Homebrew/homebrew-core
make_tap acme tools https://github.com/acme/homebrew-tools
make_tap evil default https://github.com/Evil/homebrew-Default.git
make_tap evil custom https://gitlab.example.com/evil/custom.git
make_tap evil noremote

ALLOWED_TAPS="acme/tools"
check "evil/custom evil/default evil/noremote" \
  "$(brewau_forbidden_taps | tr ' ' '\n' | sed 's#https://gitlab.example.com/evil/custom.git#evil/custom#' | sort | tr '\n' ' ' | sed 's/ $//')" \
  "every installed tap outside ALLOWED_TAPS is blocked"
check "1" "$(brewau_forbidden_taps | tr ' ' '\n' | grep -cx 'https://gitlab.example.com/evil/custom.git')" \
  "a tap with a custom remote is blocked by its remote URL"
check "1" "$(brewau_forbidden_taps | tr ' ' '\n' | grep -cx 'evil/default')" \
  "a tap with the default remote is blocked by name (case-insensitive URL match)"
ALLOWED_TAPS="acme/tools evil/custom evil/default evil/noremote"
check "" "$(brewau_forbidden_taps)" "allowed taps are not blocked"
make_tap evil weird 'https://example.com/a b'
ALLOWED_TAPS="acme/tools"
check "fail" "$( (brewau_forbidden_taps >/dev/null 2>&1) && echo ok || echo fail)" \
  "a remote that cannot be passed safely fails closed"

# --- brewau_cask_app_paths ---------------------------------------------------
BREWAU_APPDIR="${WORK}/Applications"
mkdir -p "${BREWAU_APPDIR}/One.app" "${BREWAU_APPDIR}/Two.app"
ln -s One.app "${BREWAU_APPDIR}/Link.app"
cat >"${WORK}/casks.json" <<EOF
{"casks": [
  {"token": "one", "artifacts": [{"uninstall": [{"quit": "x"}]}, {"app": ["One.app"], "target": "${BREWAU_APPDIR}/One.app"}]},
  {"token": "cli", "artifacts": [{"binary": ["cli"], "target": "/opt/homebrew/bin/cli"}]},
  {"token": "two", "artifacts": [{"app": ["Src.app", {"target": "Two.app"}], "target": "${BREWAU_APPDIR}/Two.app"}]},
  {"token": "link", "artifacts": [{"app": ["Link.app"], "target": "${BREWAU_APPDIR}/Link.app"}]},
  {"token": "gone", "artifacts": [{"app": ["Gone.app"], "target": "${BREWAU_APPDIR}/Gone.app"}]},
  {"token": "escape", "artifacts": [{"app": ["E.app"], "target": "${BREWAU_APPDIR}/../E.app"}]},
  {"token": "elsewhere", "artifacts": [{"app": ["X.app"], "target": "/tmp/X.app"}]}
]}
EOF
check "${BREWAU_APPDIR}/One.app ${BREWAU_APPDIR}/Two.app" \
  "$(brewau_cask_app_paths "${WORK}/casks.json" | tr '\n' ' ' | sed 's/ $//')" \
  "only existing, non-symlinked app targets inside the app directory are returned"

# --- brewau_app_needs_protection ---------------------------------------------
# Treat the test user as the service account so ownership alone passes.
BREWAU_USER="$(id -un)"
mkdir -p "${BREWAU_APPDIR}/Safe.app/Contents"
touch "${BREWAU_APPDIR}/Safe.app/Contents/run.sh"
chmod -R go-w "${BREWAU_APPDIR}/Safe.app"
check "no" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Safe.app" && echo yes || echo no)" \
  "an app owned by the service account without write bits is safe"
chmod +a "everyone allow write" "${BREWAU_APPDIR}/Safe.app/Contents/run.sh"
check "yes" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Safe.app" && echo yes || echo no)" \
  "a write ACL inside the app is detected"
chmod -N "${BREWAU_APPDIR}/Safe.app/Contents/run.sh"
chmod g+w "${BREWAU_APPDIR}/Safe.app/Contents"
check "yes" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Safe.app" && echo yes || echo no)" \
  "a group-writable directory inside the app is detected"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
