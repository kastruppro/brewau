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
make_tap evil slash https://git.example.com/evil/slash/
ALLOWED_TAPS="acme/tools evil/custom evil/default evil/noremote"
check "https://git.example.com/evil/slash/" "$(brewau_forbidden_taps)" \
  "a custom remote is passed on as Homebrew sees it, trailing slash included"
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
check "one two" "$(brewau_cask_apps "${WORK}/casks.json" | cut -f 1 | tr '\n' ' ' | sed 's/ $//')" \
  "each app comes with its cask"

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

# --- brewau_lock_app ---------------------------------------------------------
APP="${BREWAU_APPDIR}/Open.app"
OUTSIDE="${WORK}/outside"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${OUTSIDE}/deep"
touch "${APP}/Contents/MacOS/run" "${APP}/Contents/Resources/data" "${OUTSIDE}/deep/target"
chmod 777 "${APP}/Contents" "${APP}/Contents/MacOS/run" "${OUTSIDE}" "${OUTSIDE}/deep" "${OUTSIDE}/deep/target"
chmod +a "everyone allow write" "${APP}/Contents/Resources/data"
chmod +a "everyone allow add_file" "${APP}/Contents/Resources"
# A user's symlinks out of the app must never be followed.
ln -s "${OUTSIDE}" "${APP}/Contents/Link"
ln -s "${OUTSIDE}/deep/target" "${APP}/Contents/MacOS/linked"
check "yes" "$(brewau_app_needs_protection "${APP}" && echo yes || echo no)" "an open app needs protection"
check "ok" "$( (brewau_lock_app "${APP}") && echo ok || echo fail)" "locking it succeeds"
check "no" "$(brewau_app_needs_protection "${APP}" && echo yes || echo no)" "and leaves nothing writable or ACL'd"
check "777 777 777" "$(stat -f '%Lp' "${OUTSIDE}" "${OUTSIDE}/deep" "${OUTSIDE}/deep/target" | tr '\n' ' ' | sed 's/ $//')" \
  "targets of symlinks inside the app are untouched"
check "fail" "$( (brewau_lock_app "${WORK}/outside") && echo ok || echo fail)" "paths outside the app directory are refused"

# A directory name ending in a newline must not stop the locking.
APP="${BREWAU_APPDIR}/Newline.app"
mkdir -p "${APP}/Contents/x"$'\n'
touch "${APP}/Contents/x"$'\n'"/run"
chmod 777 "${APP}/Contents/x"$'\n' "${APP}/Contents/x"$'\n'"/run"
check "ok" "$( (brewau_lock_app "${APP}") && echo ok || echo fail)" "an app with a newline in a directory name is locked"
check "no" "$(brewau_app_needs_protection "${APP}" && echo yes || echo no)" "completely"

# What cannot be locked does not stop the rest, and nothing below it is touched.
APP="${BREWAU_APPDIR}/Stuck.app"
mkdir -p "${APP}/Contents/Stuck" "${APP}/Contents/Open"
touch "${APP}/Contents/Stuck/run" "${APP}/Contents/Open/run"
chmod 777 "${APP}/Contents/Stuck" "${APP}/Contents/Stuck/run" "${APP}/Contents/Open" "${APP}/Contents/Open/run"
chflags uchg "${APP}/Contents/Stuck"
check "fail" "$( (brewau_lock_app "${APP}") && echo ok || echo fail)" "locking reports a directory it cannot lock"
check "755 755" "$(stat -f '%Lp' "${APP}/Contents/Open" "${APP}/Contents/Open/run" | tr '\n' ' ' | sed 's/ $//')" \
  "but still locks the rest"
check "777" "$(stat -f '%Lp' "${APP}/Contents/Stuck/run")" "and leaves files in the unlocked directory alone"
chflags nouchg "${APP}/Contents/Stuck"

# A hard-linked file is replaced by a copy, so the other file is unaffected.
mkdir -p "${BREWAU_APPDIR}/Linked.app/Contents"
echo data >"${OUTSIDE}/shared"
ln "${OUTSIDE}/shared" "${BREWAU_APPDIR}/Linked.app/Contents/shared"
check "ok" "$(brewau_unlink_copy "${BREWAU_APPDIR}/Linked.app/Contents/shared" && echo ok || echo fail)" "a hard link is replaced"
check "1 1 data" "$(stat -f '%l' "${OUTSIDE}/shared" "${BREWAU_APPDIR}/Linked.app/Contents/shared" | tr '\n' ' ')$(cat "${BREWAU_APPDIR}/Linked.app/Contents/shared")" \
  "by a copy with the same content"
ln "${OUTSIDE}/shared" "${BREWAU_APPDIR}/Linked.app/Contents/flagged"
chflags uchg "${OUTSIDE}/shared"
check "fail" "$(brewau_unlink_copy "${BREWAU_APPDIR}/Linked.app/Contents/flagged" && echo ok || echo fail)" \
  "a hard link with user flags is left alone"
chflags nouchg "${OUTSIDE}/shared"
check "fail" "$( (brewau_lock_app "${BREWAU_APPDIR}/Link.app") && echo ok || echo fail)" "a symlinked app is refused"

# --- brewau_rewrite_file -----------------------------------------------------
echo "keep" >"${WORK}/file"
check "fail" "$(brewau_rewrite_file "${WORK}/file" false && echo ok || echo fail)" "a failing filter is reported"
check "keep" "$(cat "${WORK}/file")" "and leaves the file alone"
check "ok" "$(brewau_rewrite_file "${WORK}/file" sed 's/keep/new/' && echo ok || echo fail)" "a working filter succeeds"
check "new" "$(cat "${WORK}/file")" "and rewrites the file"

# --- brew.env block ----------------------------------------------------------
BREWAU_BREW_ENV="${WORK}/brew.env"
FORBIDDEN_FORMULAE="wget"
FORBIDDEN_CASKS=""
{ echo "HOMEBREW_NO_ANALYTICS=1"; brewau_brew_env_block; } >"${BREWAU_BREW_ENV}"
check "yes" "$([[ "$(brewau_brew_env_current)" == "$(brewau_brew_env_block)" ]] && echo yes || echo no)" \
  "the block written from the config is recognised as current"
FORBIDDEN_CASKS="firefox"
check "no" "$([[ "$(brewau_brew_env_current)" == "$(brewau_brew_env_block)" ]] && echo yes || echo no)" \
  "a block from an older config is not"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
