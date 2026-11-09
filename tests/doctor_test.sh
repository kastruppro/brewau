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
record() { printf 'UserShell: %s\nIsHidden: %s\nPassword: %s\n' "$1" "$2" "$3"; }
account() { FAILED=0; OUTPUT="$(doctor_account; echo "FAILED=${FAILED}")"; }
RECORD="$(record /usr/bin/false 1 '*')"
account
check '[[ "${OUTPUT}" == *FAILED=0 ]]' "disabled hidden account is healthy"
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
