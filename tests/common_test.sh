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
check "${BREWAU_APPDIR}/One.app ${BREWAU_APPDIR}/Two.app ${BREWAU_APPDIR}/Link.app" \
  "$(brewau_cask_app_paths "${WORK}/casks.json" | tr '\n' ' ' | sed 's/ $//')" \
  "only existing app targets inside the app directory are returned, symlinks included"
check "one two link" "$(brewau_cask_apps "${WORK}/casks.json" | cut -f 1 | tr '\n' ' ' | sed 's/ $//')" \
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
chmod g-w "${BREWAU_APPDIR}/Safe.app/Contents"
check "ok" "$(brewau_pin_app "${BREWAU_APPDIR}/Safe.app" && echo ok)" "an app is pinned"
check "ok" "$(brewau_pin_app "${BREWAU_APPDIR}/Safe.app" && echo ok)" "pinning twice is fine"
check "group:everyone deny delete" "$(brewau_acl "${BREWAU_APPDIR}/Safe.app")" "with one entry"
check "fail" "$(mv "${BREWAU_APPDIR}/Safe.app" "${BREWAU_APPDIR}/Moved.app" 2>/dev/null && echo ok || echo fail)" \
  "which stops it from being renamed"
check "no" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Safe.app" && echo yes || echo no)" \
  "and does not count as an ACL that needs protection"
chmod +a "everyone allow add_subdirectory" "${BREWAU_APPDIR}/Safe.app"
check "yes" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Safe.app" && echo yes || echo no)" \
  "but any other entry on the app's folder does"
chmod -N "${BREWAU_APPDIR}/Safe.app"
check "yes" "$(brewau_app_needs_protection "${BREWAU_APPDIR}/Link.app" && echo yes || echo no)" \
  "a symlinked app always needs protection"

# --- brewau_lock_app ---------------------------------------------------------
BREWAU_STAGING_DIR="${WORK}/staging"
mkdir -p "${BREWAU_STAGING_DIR}"
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
INODE="$(stat -f %i "${APP}/Contents/MacOS/run")"
# Records where the app was locked; admins can rename what is in the app directory.
eval "$(declare -f brewau_lock_tree | sed '1s/brewau_lock_tree/real_lock_tree/')"
brewau_lock_tree() { echo "$1" >"${WORK}/locked-at"; real_lock_tree "$@"; }
check "ok" "$( (brewau_lock_app "${APP}") && echo ok || echo fail)" "locking it succeeds"
check "yes" "$([[ "$(cat "${WORK}/locked-at")" == "${BREWAU_STAGING_DIR}"/* ]] && echo yes || echo no)" \
  "it is locked where only root can change it, not at its path"
eval "$(declare -f real_lock_tree | sed '1s/real_lock_tree/brewau_lock_tree/')"
check "yes" "$([[ "$(stat -f %i "${APP}/Contents/MacOS/run")" != "${INODE}" && -f "${APP}/Contents/MacOS/run" ]] && echo yes || echo no)" \
  "and replaces it by a copy, so files someone held open are not the app's any more"
check "" "$(ls -A "${BREWAU_STAGING_DIR}")" "staged where only root can change it, leaving nothing behind"
check "no" "$(brewau_app_needs_protection "${APP}" && echo yes || echo no)" "and leaves nothing writable or ACL'd"
check "777 777 777" "$(stat -f '%Lp' "${OUTSIDE}" "${OUTSIDE}/deep" "${OUTSIDE}/deep/target" | tr '\n' ' ' | sed 's/ $//')" \
  "targets of symlinks inside the app are untouched"
check "fail" "$( (brewau_lock_app "${WORK}/outside") && echo ok || echo fail)" "paths outside the app directory are refused"

# Another run (or an admin) puts something at the app's path while it is staged.
APP="${BREWAU_APPDIR}/Raced.app"
mkdir -p "${APP}/Contents"
chmod 777 "${APP}/Contents"
ditto() { /usr/bin/ditto "$@" && mkdir -p "${APP}/Contents"; }
check "fail" "$( (brewau_lock_app "${APP}") 2>/dev/null && echo ok || echo fail)" "the copy is not put over it"
check "Contents" "$(ls "${APP}")" "and not moved into it either"
unset -f ditto
rm -rf "${APP}" "${BREWAU_STAGING_DIR:?}"/*

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
check "fail" "$( (brewau_lock_app "${APP}") 2>/dev/null && echo ok || echo fail)" "locking reports a directory it cannot lock"
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

# --- code signatures ---------------------------------------------------------
BREWAU_APP_STATE_DIR="${WORK}/state/apps"
APP="${BREWAU_APPDIR}/Signed.app"
mkdir -p "${APP}/Contents/MacOS"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.signed</string><key>CFBundleExecutable</key><string>run</string></dict></plist>\n' \
  >"${APP}/Contents/Info.plist"
cp /usr/bin/true "${APP}/Contents/MacOS/run"
codesign -s - --force "${APP}" 2>/dev/null
check "fail" "$(brewau_app_team "${APP}" || echo fail)" "an ad-hoc signature has no Team ID"
check "ok" "$(brewau_record_app "${APP}" && echo ok)" "an app is recorded"
check "-" "$(cut -f 2 "$(brewau_app_state "${APP}").team")" "as unsigned"
STATE="$(brewau_app_state "${APP}")"

# With a signed app (codesign mocked).
brewau_app_team() { [[ -n "${MOCK_TEAM}" && ( -z "${2:-}" || "$2" == "${MOCK_TEAM}" ) ]] && echo "${MOCK_TEAM}"; }
rm -f "${STATE}.team"
MOCK_TEAM="TEAM1"
check "yes" "$(brewau_app_trusted "${APP}" && echo yes || echo no)" "without a record, an intact signature is trusted"
check "TEAM1" "$(cut -f 2 "${STATE}.team")" "and becomes the record"
check "yes" "$(brewau_app_trusted "${APP}" && echo yes || echo no)" "the same Team ID stays trusted"
MOCK_TEAM="OTHER"
check "no" "$(brewau_app_trusted "${APP}" && echo yes || echo no)" "another Team ID is not"
check "yes" "$(brewau_app_untrusted "${APP}" && echo yes || echo no)" "and the app is marked untrusted"
MOCK_TEAM="TEAM1"
check "yes" "$(brewau_app_untrusted "${APP}" && echo yes || echo no)" "until an administrator trusts it again"
cat >"${WORK}/signed.json" <<EOF
{"casks": [{"token": "signed", "artifacts": [{"app": ["Signed.app"], "target": "${APP}"}]}]}
EOF
check "signed" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "an untrusted app's cask is reported though the app is locked"
rm -f "${STATE}.untrusted"
check "" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "a trusted, locked app is not"
check "group:everyone deny delete" "$(brewau_acl "${APP}")" "and is pinned in place"
printf '{"casks": [{"token": "link", "artifacts": [{"app": ["Link.app"], "target": "%s"}]}]}\n' \
  "${BREWAU_APPDIR}/Link.app" >"${WORK}/link.json"
check "link" "$(brewau_protect_apps "${WORK}/link.json" 2>/dev/null)" "a symlinked app's cask is reported"
# Locked, but the fresh copy failed: files someone held open may still be its.
# Root, which locks apps, is not bound by the pin; this test user is.
chmod -N "${APP}"
chmod g+w "${APP}/Contents"
ditto() { return 1; }
check "signed" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "an app that was locked but could not be copied is reported"
unset -f ditto
check "signed" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "and stays reported"
check "no" "$(brewau_app_needs_protection "${APP}" && echo yes || echo no)" "though it is locked"
rm -f "${STATE}.untrusted"
MOCK_TEAM=""
chmod -N "${APP}"
chmod g+w "${APP}/Contents"
check "signed" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "a writable app whose signature broke is reported"
check "yes" "$(brewau_app_untrusted "${APP}" && echo yes || echo no)" "and marked untrusted"
rm -f "${STATE}.untrusted" "${STATE}.team"
chmod -N "${APP}"
chmod g+w "${APP}/Contents"
BREWAU_APPS_BASELINE=1
check "" "$(brewau_protect_apps "${WORK}/signed.json" 2>/dev/null)" "on first install, apps are taken as they are"
brewau_record_apps "${WORK}/signed.json"
check "no -" "$(brewau_app_untrusted "${APP}" && echo yes || echo no) $(cut -f 2 "${STATE}.team")" "and recorded"
BREWAU_APPS_BASELINE=0
unset -f brewau_app_team

# --- git repositories ---------------------------------------------------------
REPO="${WORK}/repo"
mkdir -p "${REPO}/.git/hooks"
printf '[core]\n\tfsmonitor = false\n[remote "origin"]\n\turl = https://github.com/acme/brew\n' >"${REPO}/.git/config"
touch "${REPO}/.git/hooks/pre-commit.sample"
check "" "$(brewau_repo_problems "${REPO}")" "a plain repository has no problems"
HOMEBREW_PREFIX_PATH="${REPO}"
check "${REPO}: git config sets remote.origin.url" "$(brewau_repo_problems "${REPO}")" "Homebrew's own repository must use the official remote"
printf '[filter "x"]\n\tclean = evil\n[core]\n\tfsmonitor = /tmp/evil\n' >>"${REPO}/.git/config"
touch "${REPO}/.git/hooks/post-checkout"
check "4" "$(brewau_repo_problems "${REPO}" | wc -l | tr -d ' ')" "config that runs commands and hooks are flagged"
HOMEBREW_PREFIX_PATH="${WORK}/prefix"
REPO="${WORK}/repo2"
mkdir -p "${REPO}/.git"
printf '[core]\n\trepositoryformatversion = 0\n\tautocrlf = false\n[branch "main"]\n\tremote = origin\n\tmerge = refs/heads/main\n[homebrew]\n\tforceautoupdate = true\n' >"${REPO}/.git/config"
check "" "$(brewau_repo_problems "${REPO}")" "plain settings git and Homebrew write pass"
printf '[http]\n\tproxy = http://evil\n' >"${REPO}/.git/config.worktree"
check "${REPO}: git config sets http.proxy" "$(brewau_repo_problems "${REPO}")" "anything else is flagged, in config.worktree too"
rm -f "${REPO}/.git/config.worktree"
ln -s "${WORK}/elsewhere" "${REPO}/.git/hooks"
check "${REPO}: .git contains symlinks" "$(brewau_repo_problems "${REPO}")" "symlinks inside .git are flagged"
rm -rf "${REPO}/.git"
echo "gitdir: /tmp/elsewhere" >"${REPO}/.git"
check "${REPO}: .git is not a plain repository directory" "$(brewau_repo_problems "${REPO}")" "a .git file is flagged"
HOMEBREW_PREFIX_PATH="${WORK}/brewprefix"
mkdir -p "${HOMEBREW_PREFIX_PATH}/Library/Taps/acme/homebrew-file"
echo "gitdir: /tmp/elsewhere" >"${HOMEBREW_PREFIX_PATH}/Library/Taps/acme/homebrew-file/.git"
check "yes" "$(brewau_repos | grep -qx "${HOMEBREW_PREFIX_PATH}/Library/Taps/acme/homebrew-file" && echo yes || echo no)" \
  "a tap whose .git is a file is checked too"
HOMEBREW_PREFIX_PATH="${WORK}/prefix"

# --- service names and data directories ---------------------------------------
check "sh.brew.redis homebrew.mxcl.redis" "$(brewau_service_labels redis | tr '\n' ' ' | sed 's/ $//')" "both of Homebrew's names"
check "redis postgresql@17" "$(brewau_service_formula /x/sh.brew.redis.plist) $(brewau_service_formula /x/homebrew.mxcl.postgresql@17.plist)" \
  "the formula comes from either name"
check "fail" "$(brewau_service_formula /x/com.example.plist || echo fail)" "other plists are not Homebrew's"
mkdir -p "${WORK}/prefix/opt/redis" "${WORK}/prefix/etc"
VAR="${WORK}/prefix/var"
printf 'dir %s/db/redis/\nlogfile "%s/log/redis.log"\n' "${VAR}" "${VAR}" >"${WORK}/prefix/etc/redis.conf"
cat >"${WORK}/prefix/opt/redis/sh.brew.redis.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>sh.brew.redis</string>
  <key>ProgramArguments</key><array>
    <string>${WORK}/prefix/opt/redis/bin/redis-server</string>
    <string>${WORK}/prefix/etc/redis.conf</string>
    <string>--dir=${VAR}/redis-extra</string>
    <string>${VAR}/../escape</string>
  </array>
  <key>StandardErrorPath</key><string>${VAR}/log/redis.log</string>
  <key>WorkingDirectory</key><string>${VAR}</string>
</dict></plist>
EOF
check "/db/redis /redis-extra" "$(brewau_service_var_dirs redis | tr '\n' ' ' | sed 's/ $//')" \
  "data directories come from the keg's plist and config, without the var directory, logs or escapes"
check "fail" "$(brewau_service_var_dirs nothere || echo fail)" "a formula without a keg plist has none"
# The last string a config without var paths in it, under pipefail.
mkdir -p "${WORK}/prefix/opt/svc"
echo "# dir ${VAR}/commented" >"${WORK}/prefix/etc/svc.conf"
cat >"${WORK}/prefix/opt/svc/sh.brew.svc.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>sh.brew.svc</string>
  <key>ProgramArguments</key><array>
    <string>${VAR}/svc-data</string>
    <string>${WORK}/prefix/etc/svc.conf</string>
  </array>
</dict></plist>
EOF
check "/svc-data ok" "$( (set -o pipefail; brewau_service_var_dirs svc | tr '\n' ' '; echo ok))" \
  "succeeds, and skips commented-out config"

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
