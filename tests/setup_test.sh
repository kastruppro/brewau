#!/bin/bash
# Tests for the parts of brewau-setup that run without root.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
WORK="$(cd "${WORK}" && pwd -P)"
trap 'chmod -RN "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/libexec/brewau-setup" >"${WORK}/brewau-setup"
BREWAU_SETUP_TEST=1
# shellcheck source=/dev/null
source "${WORK}/brewau-setup"
set +e

check() {
  local want="$1" got="$2" what="$3"
  if [[ "${got}" == "${want}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "${what}" "${want}" "${got}"
  fi
}

# --- return_prefix ----------------------------------------------------
HOMEBREW_PREFIX_PATH="${WORK}/prefix"
ORIGINAL_MODES_FILE="${WORK}/original-modes"
UNINSTALL_PROGRESS="${WORK}/uninstall-progress"
mkdir -p "${HOMEBREW_PREFIX_PATH}/var/with  spaces " "${WORK}/outside"
touch "${HOMEBREW_PREFIX_PATH}/file" "${WORK}/outside/target"
chmod 755 "${HOMEBREW_PREFIX_PATH}/var/with  spaces "
chmod 644 "${HOMEBREW_PREFIX_PATH}/file" "${WORK}/outside/target"
ln -s "${WORK}/outside/target" "${HOMEBREW_PREFIX_PATH}/link"
ln -s "${WORK}/outside" "${HOMEBREW_PREFIX_PATH}/linked-dir"
cat >"${ORIGINAL_MODES_FILE}" <<MODES
775 ${HOMEBREW_PREFIX_PATH}/var/with  spaces 
664 ${HOMEBREW_PREFIX_PATH}/file
777 ${HOMEBREW_PREFIX_PATH}/link
777 ${HOMEBREW_PREFIX_PATH}/linked-dir/target
777 ${WORK}/outside/target
777 ${HOMEBREW_PREFIX_PATH}/../outside/target
700 ${HOMEBREW_PREFIX_PATH}/..
700 ${HOMEBREW_PREFIX_PATH}/var/.
MODES
chmod 755 "${WORK}"
BREWAU_USER="$(id -un)"
return_prefix "$(id -u)" "$(id -g)"
check "775" "$(stat -f '%Lp' "${HOMEBREW_PREFIX_PATH}/var/with  spaces ")" "a path with spaces gets its mode back"
check "664" "$(stat -f '%Lp' "${HOMEBREW_PREFIX_PATH}/file")" "a file gets its mode back"
check "644" "$(stat -f '%Lp' "${WORK}/outside/target")" "symlinks and paths outside the prefix are left alone"
check "755 755" "$(stat -f '%Lp' "${WORK}" "${HOMEBREW_PREFIX_PATH}/var" | tr '\n' ' ' | sed 's/ $//')" \
  "paths ending in /. or /.. are refused"

rm -f "${UNINSTALL_PROGRESS}"
chmod 755 "${HOMEBREW_PREFIX_PATH}/var/with  spaces "
ln "${WORK}/outside/target" "${HOMEBREW_PREFIX_PATH}/shared"
printf '666 %s\n' "${HOMEBREW_PREFIX_PATH}/shared" >>"${ORIGINAL_MODES_FILE}"
got="$(return_prefix "$(id -u)" "$(id -g)" 2>&1)"
check "1" "$?" "uninstall refuses to restore modes through a hard link"
check "yes" "$([[ "${got}" == *"multiply linked entry: ${HOMEBREW_PREFIX_PATH}/shared"* ]] && echo yes || echo "${got}")" \
  "uninstall identifies the shared inode"
check "644 755" "$(stat -f '%Lp' "${WORK}/outside/target" "${HOMEBREW_PREFIX_PATH}/var/with  spaces " | tr '\n' ' ' | sed 's/ $//')" \
  "hard-link preflight leaves file modes unchanged"

# --- trust-app ---------------------------------------------------------------
require_root() { :; }
BREWAU_USER="$(id -un)"
BREWAU_APPDIR="${WORK}/Applications"
BREWAU_APP_STATE_DIR="${WORK}/state/apps"
BREWAU_STAGING_DIR="${WORK}"
mkdir -p "${BREWAU_APPDIR}/Odd.app/Contents"
chmod 777 "${BREWAU_APPDIR}/Odd.app/Contents"
STATE="$(brewau_app_state "${BREWAU_APPDIR}/Odd.app")"
brewau_write_state "${STATE}.untrusted" "${BREWAU_APPDIR}/Odd.app"
cmd_trust_app "${BREWAU_APPDIR}/Odd.app" >/dev/null
check "no -" "$([[ -e "${STATE}.untrusted" ]] && echo yes || echo no) $(cut -f 2 "${STATE}.team")" \
  "trusting an app clears the mark and records it afresh"
check "755" "$(stat -f '%Lp' "${BREWAU_APPDIR}/Odd.app/Contents")" "and locks it"
check "group:everyone deny delete" "$(brewau_acl "${BREWAU_APPDIR}/Odd.app")" "and pins it in place"
check "fail" "$( (cmd_trust_app "${WORK}/elsewhere.app") 2>/dev/null && echo ok || echo fail)" "apps outside the app directory are refused"

# --- prefix ownership: repair only mismatched entries ------------------------
mkdir -p "${WORK}/tools" "${WORK}/protected-prefix/Cellar/tart/Tart.app/Contents" "${WORK}/external"
PROTECTED="${WORK}/protected-prefix/Cellar/tart/Tart.app"
touch "${PROTECTED}/Contents/CodeResources" "${WORK}/external/marker"
ln -s "${WORK}/external" "${WORK}/protected-prefix/link"
cat >"${WORK}/tools/chown" <<'CHOWN'
#!/bin/bash
printf '%s\n' "$@" >>"${0%/*}/chown.calls"
for path in "$@"; do
  case "$path" in
    */CodeResources)
      if [[ "$(stat -f %Lp "${path%/*}")" != 755 ]] || /usr/bin/find -P "${path%/*}" -maxdepth 0 -acl -print | grep -q .; then
        echo "chown reached a file before its parent was secured" >&2
        exit 1
      fi
      echo "chown: $path: Operation not permitted" >&2
      exit 1
      ;;
  esac
done
CHOWN
chmod +x "${WORK}/tools/chown"
prefix_repair() (
  PATH="${WORK}/tools:${PATH}"
  HOMEBREW_PREFIX_PATH="${WORK}/protected-prefix"
  BREWAU_USER="$(id -un)"
  ORIGINAL_MODES_FILE="${WORK}/prefix-modes"
  # Use the test user's group as the expected group, or wheel to simulate a mismatch.
  find() {
    local expected_group="${group}" arg args=()
    [[ " $* " == *" -links 1 "* ]] || expected_group="$(id -gn)"
    for arg in "$@"; do
      [[ "${arg}" != admin ]] || arg="${expected_group}"
      args+=("${arg}")
    done
    /usr/bin/find "${args[@]}"
  }
  install() { :; }
  chown() { :; }
  local group="$1"
  take_over_prefix
)
got="$(prefix_repair "$(id -gn)" 2>&1)"
check "0" "$?" "repair succeeds when already-correct app files would reject a chown"
check "yes" "$([[ ! -e "${WORK}/tools/chown.calls" ]] && echo yes || echo no)" "chown never sees the correctly owned protected bundle"
chmod g+w "${PROTECTED}/Contents"
chmod +a "everyone allow add_file" "${PROTECTED}/Contents"
got="$(prefix_repair wheel 2>&1)"
check "1" "$?" "repair stops when a required group change is denied"
check "yes" "$([[ "${got}" == *"${PROTECTED}/Contents/CodeResources"*"Operation not permitted"*"macOS App Management"* ]] && echo yes || echo "${got}")" \
  "repair identifies the protected file and possible App Management denial"
check "yes" "$(grep -qxF -- '-h' "${WORK}/tools/chown.calls" && ! grep -qF 'link/marker' "${WORK}/tools/chown.calls" && echo yes)" \
  "ownership changes never follow the prefix symlink"

ln "${WORK}/external/marker" "${WORK}/protected-prefix/shared"
chmod g+w "${WORK}/external/marker"
got="$(prefix_repair "$(id -gn)" 2>&1)"
check "1" "$?" "takeover refuses to remove write bits from a shared inode"
check "yes" "$([[ "${got}" == *"multiply linked entry: ${WORK}/protected-prefix/shared"* ]] && echo yes || echo "${got}")" \
  "takeover identifies the shared inode"
check "664" "$(stat -f %Lp "${WORK}/external/marker")" "takeover leaves the external inode alone"

# --- uninstall validates the original owner before making any changes -----
got="$( (
  HOMEBREW_PREFIX_PATH="${WORK}/guard-prefix"
  mkdir -p "${HOMEBREW_PREFIX_PATH}"
  ORIGINAL_OWNER_FILE="${WORK}/handoff-owner"
  printf '%s\n' original-user >"${ORIGINAL_OWNER_FILE}"
  brewau_managed() { return 1; }
  id() {
    if [[ "$*" == "-u -- original-user" ]]; then echo 501
    elif [[ "$*" == "-G -- original-user" ]]; then echo "20 998"
    elif [[ "$*" == "-Gn -- original-user" ]]; then echo "staff admin"
    else return 1
    fi
  }
  launchctl() { echo "unexpected launchctl"; return 1; }
  rm() { echo "unexpected rm"; return 1; }
  cmd_uninstall
  ) 2>&1
)"
check "1" "$?" "uninstall refuses to return the prefix to a non-admin"
check "brewau: original Homebrew owner original-user is not a member of the local admin group (GID 80). Uninstall made no changes" \
  "${got}" "uninstall rejects the owner before touching any services or files"

# --- stable original owner identity ----------------------------------------
recorded_owner() (
  ORIGINAL_OWNER_FILE="${WORK}/identity-owner"
  local fixture_guid=A1234567-1234-ABCD-1234-123456789012
  printf 'former-name\n502\n%s\n' "${fixture_guid}" >"${ORIGINAL_OWNER_FILE}"
  dscl() {
    case "$2:$3:$4" in
      -list:/Users:GeneratedUID)
        [[ "$1" == . ]] || return 1
        if [[ "${deleted:-no}" == no ]]; then printf 'renamed-user\t%s\n' "${fixture_guid}"
        else printf 'former-name\t00000000-0000-0000-0000-000000000000\n'
        fi
        ;;
      -read:/Users/renamed-user:GeneratedUID) printf 'GeneratedUID: %s\n' "${fixture_guid}" ;;
      *) return 1 ;;
    esac
  }
  id() {
    if [[ "$*" == "-u -- renamed-user" || "$*" == "-u -- former-name" ]]; then echo 502
    elif [[ "$*" == "-G -- former-name" ]]; then echo "20 80"
    else return 1
    fi
  }
  case "$1" in
    renamed) original_owner ;;
    replaced)
      HOMEBREW_PREFIX_PATH="${WORK}/guard-prefix"
      brewau_managed() { return 1; }
      launchctl() { echo "unexpected launchctl"; return 1; }
      deleted=yes
      cmd_uninstall
      ;;
    legacy) printf 'former-name\n' >"${ORIGINAL_OWNER_FILE}"; original_owner ;;
  esac
)
check $'renamed-user\t502' "$(recorded_owner renamed)" "the recorded UUID resolves a renamed local owner"
got="$(recorded_owner replaced 2>&1)"
check "1" "$?" "uninstall refuses a deleted original account even when the short name was recorded"
check "brewau: the recorded original Homebrew account no longer exists or could not be verified. Uninstall made no changes" \
  "${got}" "uninstall stops before changes if the recorded identity cannot be verified"
check $'former-name\t' "$(recorded_owner legacy)" "name-only records still fall back to the recorded name"

# --- one setup lock for install, reload and uninstall -----------------------
SETUP_LOCK="${WORK}/setup.lock"
/usr/bin/perl -MFcntl=:flock -e '
  open my $lock, ">>", $ARGV[0] or die $!;
  flock($lock, LOCK_EX) or die $!;
  open my $ready, ">", $ARGV[1] or die $!;
  close $ready;
  sleep 10;
' "${SETUP_LOCK}" "${WORK}/setup-lock-ready" &
lock_pid=$!
for ((i=0; i<50; i++)); do
  [[ -e "${WORK}/setup-lock-ready" ]] && break
  sleep 0.02
done
got="$(with_setup_lock 0 /usr/bin/touch "${WORK}/setup-ran" 2>&1)"
check "yes" "$([[ "${got}" == *"setup is busy"* && ! -e "${WORK}/setup-ran" ]] && echo yes || echo "${got}")" \
  "another lifecycle operation holds the lock until it exits"
with_setup_lock 1 /usr/bin/touch "${WORK}/setup-ran" >"${WORK}/setup-wait.log" 2>&1
check "yes" "$(grep -Fq 'setup is busy' "${WORK}/setup-wait.log" && [[ ! -e "${WORK}/setup-ran" ]] && echo yes)" \
  "a deferred setup worker times out if the active operation still holds the lock"
with_setup_lock 5 /usr/bin/touch "${WORK}/setup-ran" &
wait_pid=$!
kill "${lock_pid}" 2>/dev/null
wait "${lock_pid}" 2>/dev/null
wait "${wait_pid}"
check "yes" "$([[ -e "${WORK}/setup-ran" ]] && echo yes)" "deferred setup runs after the lock is released"
rm -f "${WORK}/setup-ran"
with_setup_lock 0 /usr/bin/perl -MFcntl=:flock -e '
  open my $lock, "+<", $ARGV[0] or die $!;
  exit(flock($lock, LOCK_EX | LOCK_NB) ? 1 : 7)
' "${SETUP_LOCK}"
check "7" "$?" "the flock stays held through the worker and its status is returned"
rm -f "${SETUP_LOCK}"
ln -s "${WORK}/setup-target" "${SETUP_LOCK}"
got="$(with_setup_lock 0 /usr/bin/touch "${WORK}/setup-ran" 2>&1)"
check "yes" "$([[ "${got}" == *"could not open the setup lock"* && ! -e "${WORK}/setup-target" && ! -e "${WORK}/setup-ran" ]] && echo yes || echo "${got}")" \
  "a symlink lock is rejected before the setup worker starts"

# --- resume after an App Management refusal -------------------------------
HOMEBREW_PREFIX_PATH="${WORK}/retry-prefix"
ORIGINAL_MODES_FILE="${WORK}/retry-modes"
UNINSTALL_PROGRESS="${WORK}/retry-progress"
mkdir -p "${HOMEBREW_PREFIX_PATH}/already-returned" "${HOMEBREW_PREFIX_PATH}/tart.app"
touch "${HOMEBREW_PREFIX_PATH}/already-returned/file"
chmod 644 "${HOMEBREW_PREFIX_PATH}/already-returned/file"
printf '775 %s\n' "${HOMEBREW_PREFIX_PATH}/already-returned" "${HOMEBREW_PREFIX_PATH}/tart.app" >"${ORIGINAL_MODES_FILE}"
printf '664 %s\n' "${HOMEBREW_PREFIX_PATH}/already-returned/file" >>"${ORIGINAL_MODES_FILE}"
cat >"${WORK}/tools/uninstall-chown" <<'CHOWN'
#!/bin/bash
if [[ "$3" == */tart.app && ! -e "${0%/*}/app-management-granted" ]]; then
  echo "chown: $3: Operation not permitted" >&2
  exit 1
fi
[[ "$1" == -hn && "$2" =~ ^[0-9]+:[0-9]+$ ]] || exit 1
printf '%s\n' "$3" >>"${0%/*}/uninstall-chown.calls"
CHOWN
chmod +x "${WORK}/tools/uninstall-chown"
fixture_handoff() (
  local group=0
  [[ "$(id -g)" == 0 ]] && group=20
  eval "$(declare -f return_prefix | sed "s#/usr/sbin/chown#${WORK}/tools/uninstall-chown#g")"
  return_prefix "$(id -u)" "${group}"
)
got="$(fixture_handoff 2>&1)"
check "1" "$?" "uninstall stops when macOS refuses a required owner change"
check "yes" "$([[ "${got}" == *"${HOMEBREW_PREFIX_PATH}/tart.app"*"Terminal"*"App Management"*"Privacy & Security"*"continue where it stopped"* ]] && echo yes || echo "${got}")" \
  "uninstall identifies the denied path and tells the user how to resume"
check "775 775" "$(stat -f %Lp "${HOMEBREW_PREFIX_PATH}/already-returned" "${HOMEBREW_PREFIX_PATH}/tart.app" | paste -sd ' ' -)" \
  "the first directory was handed back and the pending directory mode changed before chown failed"
# A completed record must match the current inode, even within the same prefix.
mv "${HOMEBREW_PREFIX_PATH}/already-returned" "${WORK}/saved-returned"
mkdir "${HOMEBREW_PREFIX_PATH}/already-returned"
got="$(fixture_handoff 2>&1)"
check "yes" "$([[ "${got}" == *"completed directory has changed: ${HOMEBREW_PREFIX_PATH}/already-returned"* ]] && echo yes || echo "${got}")" \
  "replacement directory cannot be skipped by a completed record"
rmdir "${HOMEBREW_PREFIX_PATH}/already-returned"
mv "${WORK}/saved-returned" "${HOMEBREW_PREFIX_PATH}/already-returned"

# A short append must leave the preceding ready checkpoint usable.
printf 'done\tincomplete' >>"${UNINSTALL_PROGRESS}"
# Check that a retry neither descends into completed directories nor resets their files.
chmod 644 "${HOMEBREW_PREFIX_PATH}/already-returned/file"
touch "${WORK}/tools/app-management-granted"
: >"${WORK}/tools/uninstall-chown.calls"
got="$(fixture_handoff 2>&1)"
check "0" "$?" "uninstall discards the torn append and resumes after the user grants access"
check "644 775" "$(stat -f %Lp "${HOMEBREW_PREFIX_PATH}/already-returned/file" "${HOMEBREW_PREFIX_PATH}/tart.app" | paste -sd ' ' -)" \
  "the retry skips the completed subtree and finishes the refused handoff"
check "yes" "$(grep -Fxq "${HOMEBREW_PREFIX_PATH}/tart.app" "${WORK}/tools/uninstall-chown.calls" &&
  ! grep -Fq "${HOMEBREW_PREFIX_PATH}/already-returned" "${WORK}/tools/uninstall-chown.calls" && echo yes)" \
  "the retry only changes the refused directory and its unfinished ancestors"

mv "${HOMEBREW_PREFIX_PATH}" "${WORK}/previous-prefix"
mkdir -p "${HOMEBREW_PREFIX_PATH}/tart.app" "${HOMEBREW_PREFIX_PATH}/already-returned"
got="$(fixture_handoff 2>&1)"
check "0" "$?" "progress for a replaced prefix is discarded"
check "775 775" "$(stat -f %Lp "${HOMEBREW_PREFIX_PATH}/already-returned" "${HOMEBREW_PREFIX_PATH}/tart.app" | paste -sd ' ' -)" \
  "both directories in the replacement prefix are handed back"

# --- sudoers: only fixed agent verbs for members ------------------------------
sudoers="$(
  visudo() { return 0; }
  install() { cat "${@: -2:1}"; }
  BREWAU_SUDOERS="${WORK}/sudoers"
  write_sudoers
)"
check "%${BREWAU_USERS_GROUP} ALL=(root) NOPASSWD: ${BREWAU_LIBEXEC}/brewau-agent configure, ${BREWAU_LIBEXEC}/brewau-agent completions, ${BREWAU_LIBEXEC}/brewau-agent clear-blocked, ${BREWAU_LIBEXEC}/brewau-agent protect" \
  "$(grep -F "${BREWAU_LIBEXEC}/brewau-agent protect" <<<"${sudoers}")" "sudoers adds only the fixed protect verb"

# --- LaunchDaemons: fixed entry points, validation, and safe reload -----------
BREWAU_PLIST="${WORK}/launch/com.kastruppro.brewau.upgrade.plist"
mkdir -p "${WORK}/launch" "${WORK}/loaded"
chown() { :; }
launchctl() {
  local label="${2##*/}"
  label="${label%.plist}"
  case "$1" in
    print)
      [[ -f "${WORK}/loaded/${label}" ]] || return 1
      echo "state = ${MOCK_JOB_STATE:-waiting}"
      ;;
    bootstrap) touch "${WORK}/loaded/$(basename "$3" .plist)"; echo bootstrap >>"${WORK}/launch-calls" ;;
    bootout) rm -f "${WORK}/loaded/${label}"; echo bootout >>"${WORK}/launch-calls" ;;
    *) return 1 ;;
  esac
}
write_launchdaemon
check "60" "$(plutil -extract StartInterval raw -o - "${WORK}/launch/com.kastruppro.brewau.scheduler.plist")" "scheduler checks once a minute"
check "scheduled" "$(plutil -extract ProgramArguments.1 raw -o - "${WORK}/launch/com.kastruppro.brewau.scheduler.plist")" "scheduler has a fixed entry point"
check "scan" "$(plutil -extract ProgramArguments.1 raw -o - "${WORK}/launch/com.kastruppro.brewau.scan.plist")" "manual scan has a fixed entry point"
check "upgrade" "$(plutil -extract ProgramArguments.1 raw -o - "${BREWAU_PLIST}")" "manual upgrade remains available"
cp "${WORK}/launch-calls" "${WORK}/launch-before"
write_launchdaemon
check "yes" "$(cmp -s "${WORK}/launch-before" "${WORK}/launch-calls" && echo yes)" "unchanged jobs are not reloaded"
printf '\n' >>"${BREWAU_PLIST}"
MOCK_JOB_STATE=running
check "fail" "$( (write_launchdaemon) >/dev/null 2>&1 && echo ok || echo fail)" "a running worker is never killed for reload"

# --- sync_tap_trust ------------------------------------------------------------
mkdir -p "${HOMEBREW_PREFIX_PATH}/Library/Homebrew/cmd"
touch "${HOMEBREW_PREFIX_PATH}/Library/Homebrew/cmd/trust.rb"
# A fake trust store: one tap still allowed, one removed, one custom remote.
printf '%s\n' acme/tools old/tap https://example.com/x.git >"${WORK}/trusted"
brew_as_service() {
  case "$1 $2" in
    "trust --tap")
      if [[ "${3:-}" == "--json=v1" ]]; then
        printf '[\n'; sed 's/.*/  "&",/' "${WORK}/trusted"; printf ']\n'
      else
        echo "$3" >>"${WORK}/trusted"
      fi
      ;;
    "untrust --tap") grep -vxF "$3" "${WORK}/trusted" >"${WORK}/t"; mv "${WORK}/t" "${WORK}/trusted" ;;
  esac
}
ALLOWED_TAPS="acme/tools openai/tools"
sync_tap_trust >/dev/null
check "acme/tools https://example.com/x.git openai/tools" "$(sort "${WORK}/trusted" | tr '\n' ' ' | sed 's/ $//')" \
  "allowed taps are trusted, removed ones untrusted, custom remotes left alone"
rm "${HOMEBREW_PREFIX_PATH}/Library/Homebrew/cmd/trust.rb"
ALLOWED_TAPS="new/tap"
sync_tap_trust >/dev/null
check "" "$(grep -x new/tap "${WORK}/trusted")" "Homebrew without brew trust is left alone"
# brewau-setup runs with errexit and pipefail; an empty store prints [].
touch "${HOMEBREW_PREFIX_PATH}/Library/Homebrew/cmd/trust.rb"
: >"${WORK}/trusted"
ALLOWED_TAPS="acme/tools"
check "ok acme/tools" "$( { (set -euo pipefail; sync_tap_trust >/dev/null; echo ok); cat "${WORK}/trusted"; } | tr '\n' ' ' | sed 's/ $//')" \
  "an empty trust store does not abort under set -euo pipefail"
brew_as_service() { return 1; }
check "ok" "$( (set -euo pipefail; sync_tap_trust >/dev/null 2>&1; echo ok) )" "a failing brew only warns"

# --- own tap in the configuration -------------------------------------------------
BREWAU_CONF="${WORK}/etc/brewau.conf"
OWN_TAP_MARKER="${WORK}/etc/own-tap-added"
mkdir -p "${WORK}/etc"
printf 'ALLOWED_TAPS="acme/tools"\n' >"${BREWAU_CONF}"
ALLOWED_TAPS="acme/tools"
add_own_tap_once >/dev/null
check 'ALLOWED_TAPS="acme/tools kastruppro/tap"' "$(grep ALLOWED_TAPS "${BREWAU_CONF}")" "an existing config gets the own tap"
printf 'ALLOWED_TAPS="acme/tools"\n' >"${BREWAU_CONF}"
ALLOWED_TAPS="acme/tools"
add_own_tap_once >/dev/null
check 'ALLOWED_TAPS="acme/tools"' "$(grep ALLOWED_TAPS "${BREWAU_CONF}")" "only once: removing it again sticks"

# --- LaunchDaemons: the root self-update job ---------------------------------------
launchctl() {
  local label="${2##*/}"
  label="${label%.plist}"
  case "$1" in
    print)
      [[ -f "${WORK}/loaded/${label}" ]] || return 1
      [[ " ${MOCK_RUNNING:-} " == *" ${label} "* ]] && echo "state = running" || echo "state = waiting"
      ;;
    bootstrap) touch "${WORK}/loaded/$(basename "$3" .plist)" ;;
    bootout) rm -f "${WORK}/loaded/${label}"; echo "bootout ${label}" >>"${WORK}/launch-calls" ;;
    *) return 1 ;;
  esac
}
SELF="${WORK}/launch/com.kastruppro.brewau.selfupdate.plist"
MOCK_RUNNING=""
write_launchdaemon >/dev/null
check "self-update 300" "$(plutil -extract ProgramArguments.1 raw -o - "${SELF}") $(plutil -extract StartInterval raw -o - "${SELF}")" \
  "the self-update job has a fixed entry point and checks every 5 minutes"
check "no" "$(plutil -extract UserName raw -o - "${SELF}" >/dev/null 2>&1 && echo yes || echo no)" "and runs as root"
: >"${WORK}/launch-calls"
printf '\n' >>"${SELF}"
MOCK_RUNNING="com.kastruppro.brewau.selfupdate"
check "ok" "$( (write_launchdaemon) >/dev/null 2>&1 && echo ok || echo fail)" "a running self-update job does not stop a reload"
check "" "$(grep selfupdate "${WORK}/launch-calls")" "and is never stopped, since it may be the installer"
printf '\n' >>"${WORK}/launch/com.kastruppro.brewau.scheduler.plist"
MOCK_RUNNING="com.kastruppro.brewau.scheduler"
brewau_self_update_running() { return 0; }
check "ok" "$( (write_launchdaemon) >/dev/null 2>&1 && echo ok || echo fail)" \
  "during a self-update (which holds the lock) a running scheduler may be reloaded"
brewau_self_update_running() { return 1; }
printf '\n' >>"${WORK}/launch/com.kastruppro.brewau.scheduler.plist"
check "fail" "$( (write_launchdaemon) >/dev/null 2>&1 && echo ok || echo fail)" "otherwise it may not"
MOCK_RUNNING=""

# --- self-update -------------------------------------------------------------------
BREWAU_ROOT="${WORK}/root"
BREWAU_STATE_DIR="${WORK}/state"
mkdir -p "${BREWAU_ROOT}/share" "${BREWAU_STATE_DIR}" "${HOMEBREW_PREFIX_PATH}/Library/Taps/kastruppro/homebrew-tap"
echo "0.6.1" >"${BREWAU_ROOT}/share/VERSION"
brewau_load_config() { :; }
sync_tap_trust() { :; }
UPGRADE_EXCLUDE=""
brew_as_service() {
  echo "$*" >>"${WORK}/brew-calls"
  case "$1" in
    info) printf '{"casks":[{"version":"%s"%s}]}\n' "${MOCK_AVAILABLE}" "${MOCK_REGISTERED:+,\"installed\":\"${MOCK_REGISTERED}\"}" ;;
  esac
}
self_update() { : >"${WORK}/brew-calls"; (cmd_self_update "$@") >/dev/null 2>&1; grep -E '^(install|upgrade)' "${WORK}/brew-calls"; }
MOCK_AVAILABLE="0.7.0"
MOCK_REGISTERED=""
ALLOWED_TAPS="kastruppro/tap"
check "" "$(self_update)" "nothing happens unless a scheduled upgrade asked for it"
touch "${BREWAU_STATE_DIR}/self-update-due"
check "install --cask kastruppro/tap/brewau" "$(self_update)" "a package install is registered as the cask"
check "no" "$([[ -e "${BREWAU_STATE_DIR}/self-update-due" ]] && echo yes || echo no)" "the request is used up"
MOCK_REGISTERED="0.6.1"
check "upgrade --cask kastruppro/tap/brewau" "$(self_update --now)" "a registered cask is upgraded"
MOCK_AVAILABLE="0.6.1"
check "" "$(self_update --now)" "an up-to-date brewau is left alone"
MOCK_AVAILABLE="0.7.0"
UPGRADE_EXCLUDE="kastruppro/tap/brewau"
check "" "$(self_update --now)" "UPGRADE_EXCLUDE turns self-update off"
UPGRADE_EXCLUDE=""
ALLOWED_TAPS="acme/tools"
check "" "$(self_update --now)" "and so does removing the own tap from ALLOWED_TAPS"

# --- uninstall on a computer the MDM manages ------------------------------------------
BREWAU_MANAGED_PREFS="${WORK}/managed.plist"
BREWAU_MANAGED_OWNER="$(id -u)"
plutil -create xml1 "${BREWAU_MANAGED_PREFS}"
plutil -insert PreventUninstall -bool YES "${BREWAU_MANAGED_PREFS}"
chmod 644 "${BREWAU_MANAGED_PREFS}"
BREWAU_SUDOERS="${WORK}/sudoers"
touch "${BREWAU_SUDOERS}"
: >"${WORK}/launch-calls"
# Should the guard fail, nothing real may be touched.
got="$( (
  for f in dscl dseditgroup pkgutil dscacheutil stop_service_processes restore_users return_cask_apps \
    return_prefix remove_brew_env rm; do eval "${f}() { echo '${f}' >>\"\${WORK}/launch-calls\"; }"; done
  cmd_uninstall
) 2>&1)"
check "yes" "$([[ "${got}" == *"blocked by your organisation's MDM profile"* ]] && echo yes || echo "${got}")" \
  "uninstall is refused while the MDM profile sets PreventUninstall"
check "yes " "$([[ -e "${BREWAU_SUDOERS}" ]] && echo yes) $(cat "${WORK}/launch-calls")" "before it changes anything"

# --- first install started by Homebrew ------------------------------------------------
HOMEBREW_PREFIX_PATH="${WORK}/brewprefix"
BREWAU_USER="_brewau"
mkdir -p "${HOMEBREW_PREFIX_PATH}"
check "no" "$(homebrew_installing_brewau && echo yes || echo no)" "no Homebrew running, nothing to wait for"
/bin/bash -c 'sleep 30; :' "${HOMEBREW_PREFIX_PATH}/Library/Homebrew/brew.rb" &
FAKE_BREW=$!
sleep 0.3
check "yes" "$(homebrew_installing_brewau && echo yes || echo no)" "Homebrew of the prefix owner is still busy"
kill "${FAKE_BREW}" 2>/dev/null
wait "${FAKE_BREW}" 2>/dev/null

# --- restarting the brewau app after an upgrade ------------------------------------------
: >"${WORK}/app-calls"
ps() { printf '%s\n' "101 501 /Applications/brewau.app/Contents/MacOS/brewau" "102 502 /usr/bin/other" \
  "103 777 /Applications/brewau.app/Contents/MacOS/brewau"; }
id() { case "$2" in 501) echo alice ;; *) return 1 ;; esac; }
kill() { [[ "$1" == "-0" ]] && return 1; echo "kill $*" >>"${WORK}/app-calls"; }
launchctl() { echo "launchctl $*" >>"${WORK}/app-calls"; }
check "kill -TERM 101|launchctl asuser 501 sudo -u alice /usr/bin/open -g /Applications/brewau.app" \
  "$( (set -euo pipefail; restart_brewau_app >/dev/null); paste -sd '|' "${WORK}/app-calls")" \
  "a running brewau app is stopped and opened again in its user's session, other processes are left alone"
launchctl() { return 1; }
check "ok" "$( (set -euo pipefail; restart_brewau_app >/dev/null 2>&1; echo ok) )" "a failed relaunch never fails the install"
unset -f ps id kill launchctl

# --- failure report -------------------------------------------------------------
# A command that fails under errexit is named, so install.log shows the cause.
got="$( (set -euo pipefail; inner() { grep -q nothing /dev/null; }; cmd_reload() { inner; echo after; }; main reload) 2>&1)"
check "yes" "$([[ "${got}" == "brewau-setup: reload failed (exit 1) at line "*": grep -q nothing /dev/null" ]] && echo yes || echo "${got}")" \
  "a failing command inside a function is reported and stops the script"
got="$( (set -euo pipefail; cmd_reload() { x="$(false)" || x=""; false || true; brewau_die "explained"; }; main reload) 2>&1)"
check "brewau: explained" "${got}" "handled failures are not reported, brewau_die speaks for itself"
check "" "$( (set -euo pipefail; cmd_reload() { :; }; main reload) 2>&1)" "success prints nothing"

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
