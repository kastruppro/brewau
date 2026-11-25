#!/bin/bash
# Account and sudoers diagnostics use read-only stubs, never the host's records.
set -u
HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0 FAIL=0
sed -e "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" -e '/^case "${1:-}" in/,$d' \
  "${PAYLOAD}/bin/brewau" >"${WORK}/brewau"
# shellcheck source=/dev/null
source "${WORK}/brewau"
check() {
  if eval "$1"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $2"; fi
}
dscl() {
  [[ "$*" == ". -read /Users/${BREWAU_USER}" ]] || return 1
  printf '%s\n' "${RECORD}"
  return "${DSCL_RC:-0}"
}
record() { printf 'UserShell: %s\ndsAttrTypeNative:IsHidden: %s\nPassword: %s\n' "$1" "$2" "$3"; }
account() { FAILED=0; OUTPUT="$(doctor_account; echo "FAILED=${FAILED}")"; }
RECORD="$(record /usr/bin/false 1 '*')"
account
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "disabled hidden account is healthy"
RECORD="$(record /usr/bin/false 1 '*')"
RECORD="${RECORD/dsAttrTypeNative:IsHidden:/IsHidden:}"
account
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "plain hidden attribute is accepted"
RECORD="$(record /usr/bin/false 1 '*')"
RECORD="${RECORD/Password:/dsAttrTypeNative:Password:}"
account
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "native password attribute is accepted"
for attribute in AuthenticationAuthority ShadowHashData; do
  for prefix in '' dsAttrTypeNative:; do
    RECORD="$(record /usr/bin/false 1 '*')"$'\n'"${prefix}${attribute}: ;ShadowHash;"
    account
    check '[[ "${OUTPUT}" == *FAILED=1 ]]' "${prefix}${attribute} warns"
  done
done
RECORD="$(record /sbin/nologin 1 '*')"
account
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "nologin is accepted"
RECORD="$(record /bin/zsh 1 '*')"
account
check '[[ "${OUTPUT}" == *"has login shell /bin/zsh"* && "${OUTPUT}" == *FAILED=1 ]]' "login shell warns"
RECORD="$(record /usr/bin/false 0 '*')"
account
check '[[ "${OUTPUT}" == *"is not hidden"* && "${OUTPUT}" == *FAILED=1 ]]' "visible account warns"
RECORD="$(record /usr/bin/false 1 '********')"
account
check '[[ "${OUTPUT}" == *"password/authentication attributes"* && "${OUTPUT}" == *FAILED=1 ]]' "password warns"
RECORD="$(record /usr/bin/false 1 '*')"$'\nAuthenticationAuthority: ;ShadowHash;'
account
check '[[ "${OUTPUT}" == *FAILED=1 ]]' "authentication authority warns"
DSCL_RC=1
account
check '[[ "${OUTPUT}" == *"cannot read"* && "${OUTPUT}" == *FAILED=1 ]]' "unreadable account warns"
unset DSCL_RC

BREWAU_STATE_DIR="${WORK}/state"
BREWAU_LOG_DIR="${WORK}/logs"
mkdir -p "${BREWAU_STATE_DIR}" "${BREWAU_LOG_DIR}"
echo 'could not protect Docker.app' >"${BREWAU_LOG_DIR}/upgrade.log"
protection() { FAILED=0; OUTPUT="$(doctor_app_protection; echo "FAILED=${FAILED}")"; }
protection
check '[[ "${OUTPUT}" == *Docker.app* && "${OUTPUT}" == *FAILED=1 ]]' "legacy log fallback names app"
printf '%s' '{"status":"ok","blocked":[],"errors":[]}' >"${BREWAU_STATE_DIR}/last-result.json"
protection
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "clean result overrides old protection log"
printf '%s' '{"blocked":[{"name":"docker","reason":"app-management"}]}' >"${BREWAU_STATE_DIR}/blocked-casks.json"
protection
check '[[ "${OUTPUT}" == *"Blocked cask: docker"* && "${OUTPUT}" == *FAILED=0 ]]' "persistent blocks remain visible after clean result"
check '[[ "${OUTPUT}" == *"sudo brewau clear-blocked"* ]]' "doctor shows how to retry a Homebrew block"
printf '%s' '{"items":[{"token":"paseo","version":"0.17.4","app":"/Applications/Paseo.app","operation":"pin"}]}' >"${BREWAU_STATE_DIR}/pending-protection.json"
protection
check '[[ "${OUTPUT}" == *"Paseo 0.17.4: afventer beskyttelse"*"åbn brewau-appen"*"sudo /opt/brewau/libexec/brewau-agent protect"* &&
  "${OUTPUT}" == *FAILED=0 ]]' "pending protection is visible with app and command guidance"
rm "${BREWAU_STATE_DIR}/pending-protection.json"
rm "${BREWAU_STATE_DIR}/blocked-casks.json"
printf '%s' '{"blocked":[{"name":"parallels","reason":"app-management"}],"failed":[{"name":"docker","reason":"protect-failed"}],"errors":[{"stage":"protect","reason":"protect-failed"}]}' >"${BREWAU_STATE_DIR}/last-result.json"
protection
check '[[ "${OUTPUT}" == *"Blocked cask: parallels"* && "${OUTPUT}" == *"docker is unprotected"* && "${OUTPUT}" == *FAILED=1 ]]' "current protection failures name affected casks"
printf '%s' '{"blocked":[{"name":"paseo","reason":"app-management"}],"errors":[{"stage":"protect","reason":"protect-failed"}]}' >"${BREWAU_STATE_DIR}/last-result.json"
protection
check '[[ "${OUTPUT}" == *"Blocked cask: paseo"* && "${OUTPUT}" == *"latest run could not protect"* && "${OUTPUT}" == *FAILED=1 ]]' "block guidance does not hide unrelated protection error"
printf '%s' '{"errors":[{"stage":"protect","reason":"protect-failed"}]}' >"${BREWAU_STATE_DIR}/last-result.json"
protection
check '[[ "${OUTPUT}" == *"latest run could not protect"* && "${OUTPUT}" == *FAILED=1 ]]' "unnamed protection error is reported"
echo "{broken" >"${BREWAU_STATE_DIR}/last-result.json"
protection
check '[[ "${OUTPUT}" == *"cannot read app protection state"* && "${OUTPUT}" != *Docker.app* ]]' "invalid state warns without historical log fallback"

USER_PATH="${PATH}"
HOMEBREW_PREFIX_PATH="${WORK}/homebrew"
mkdir -p "${HOMEBREW_PREFIX_PATH}/lib/node_modules/npm" "${HOMEBREW_PREFIX_PATH}/lib/node_modules/@microsoft/learn-cli" "${HOMEBREW_PREFIX_PATH}/lib/node_modules/plain"
PREFIX="${WORK}/per user/new"
npm() { [[ "$*" == 'config get prefix' ]] && printf '%s\n' "${PREFIX}"; }
gem() { [[ "$*" == 'environment home' ]] && printf '%s\n' "${PREFIX}"; }
id() { if [[ "$1" == -u ]]; then echo 501; else echo tester; fi; }
languages() { FAILED=0; OUTPUT="$(doctor_language_prefixes; echo "FAILED=${FAILED}")"; }
languages
check '[[ "${OUTPUT}" == *FAILED=0 && "${OUTPUT}" == *"npm installs are writable"* && "${OUTPUT}" == *"gem installs are writable"* ]]' "missing user prefixes can be created without side effects"
check '[[ ! -e "${PREFIX}" ]]' "doctor does not create prefixes"
check '[[ "${OUTPUT}" == *"npm install -g @microsoft/learn-cli"* && "${OUTPUT}" == *"npm install -g plain"* && "${OUTPUT}" != *"shared npm global npm;"* ]]' "leftover globals include scoped packages and omit npm"
PREFIX="relative"
languages
check '[[ "${OUTPUT}" == *FAILED=1 && "${OUTPUT}" == *"not writable"* ]]' "invalid effective prefix warns"
PREFIX="${WORK}/not-a-directory"
touch "${PREFIX}"
languages
check '[[ "${OUTPUT}" == *FAILED=1 ]]' "non-directory prefix warns"
PREFIX=''
languages
check '[[ "${OUTPUT}" == *unknown* && "${OUTPUT}" == *FAILED=1 ]]' "unknown effective prefixes cannot pass"
unset -f npm gem
USER_PATH="${WORK}/missing-tools"
languages
check '[[ "${OUTPUT}" != *"installs are writable"* && "${OUTPUT}" != *"install directory is not writable"* ]]' "absent tools skip prefix checks"
id() { echo 0; }
languages
check '[[ "${OUTPUT}" == *"as your normal user"* && "${OUTPUT}" == *FAILED=0 ]]' "root does not execute user tools"
unset -f id
USER_PATH="${PATH}"

BREWAU_SUDOERS="${WORK}/managed"
OTHER="${WORK}/other"
printf '%s ALL=(root) NOPASSWD: ALL\n' "${BREWAU_USER}" >"${BREWAU_SUDOERS}"
echo 'root ALL=(ALL) ALL' >"${OTHER}"
sudo() {
  shift
  case "$1" in
    /usr/sbin/visudo)
      [[ "${SUDO_RC:-0}" == 0 ]] || return 1
      [[ "${SUDO_EMPTY:-0}" == 0 ]] || return 0
      printf '%s: parsed OK\n' "${BREWAU_SUDOERS}" "${OTHER}"
      ;;
    /usr/bin/awk) shift; /usr/bin/awk "$@" ;;
    *) return 1 ;;
  esac
}
audit() { FAILED=0; OUTPUT="$(doctor_sudoers; echo "FAILED=${FAILED}")"; }
audit
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "managed root rule is accepted"
printf '%s ALL=(root) NOPASSWD: ALL\n' "${BREWAU_USER}" >"${OTHER}"
audit
check '[[ "${OUTPUT}" == *"additional sudoers references"* && "${OUTPUT}" == *FAILED=1 ]]' "external account grant warns"
printf '%%%s ALL=(%s) NOPASSWD: /bin/sh\n' "${BREWAU_USERS_GROUP}" "${BREWAU_USER}" >"${OTHER}"
audit
check '[[ "${OUTPUT}" == *FAILED=1 ]]' "group bypass of policy warns"
printf 'Runas_Alias BREW = %s\n' "${BREWAU_USER}" >"${OTHER}"
audit
check '[[ "${OUTPUT}" == *FAILED=1 ]]' "alias references warn"
printf '# %s ALL=(root) ALL\nDefaults:%s log_allowed\n' "${BREWAU_USER}" "${BREWAU_USER}" >"${OTHER}"
audit
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "comments and logging defaults do not grant access"
SUDO_RC=1
audit
check '[[ "${OUTPUT}" == *"cannot inspect all sudoers"* && "${OUTPUT}" == *FAILED=1 ]]' "unavailable privileged inspection warns"
unset SUDO_RC
SUDO_EMPTY=1
audit
check '[[ "${OUTPUT}" == *"could not enumerate"* && "${OUTPUT}" == *FAILED=1 ]]' "empty enumeration cannot pass the audit"
unset SUDO_EMPTY
echo 'ALL ALL=(ALL) NOPASSWD: ALL' >"${OTHER}"
audit
check '[[ "${OUTPUT}" == *FAILED=1 ]]' "universal grant warns"

# Exercise the actual generated sudoers through the installed parser without installing it.
sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "${PAYLOAD}/libexec/brewau-setup" >"${WORK}/setup"
BREWAU_SETUP_TEST=1
# shellcheck source=/dev/null
source "${WORK}/setup"
set +e
BREWAU_SUDOERS="${WORK}/generated"
install() { /bin/cp "$7" "$8"; }
write_sudoers >"${WORK}/validation" 2>&1
check '[[ $? == 0 ]]' "installed visudo accepts generated sudoers"
check 'grep -qx "Defaults:${BREWAU_USER} log_allowed" "${BREWAU_SUDOERS}"' "allowed root commands are logged"
check 'grep -qx "${BREWAU_USER} ALL=(root) NOPASSWD: ALL" "${BREWAU_SUDOERS}"' "required root rule remains"

# Existing accounts are repaired without changing passwords or their identity.
dscl() { printf '%s\n' "$*" >>"${WORK}/dscl"; return 0; }
ensure_service_account
ensure_service_account
check '[[ "$(grep -c "UserShell /usr/bin/false$" "${WORK}/dscl")" == 2 ]]' "existing account shell is enforced idempotently"
check '[[ "$(grep -c "IsHidden 1$" "${WORK}/dscl")" == 2 ]]' "existing account stays hidden"
check '! grep -q "Password\|UniqueID" "${WORK}/dscl"' "existing credentials and identity are preserved"
echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} == 0 ]]
