# shellcheck shell=bash
# Shared definitions for brewau. Sourced by brew-policy, brewau-upgrade and
# the installer scripts. Must stay compatible with /bin/bash 3.2.

BREWAU_ROOT="/opt/brewau"
BREWAU_USER="_brewau"
BREWAU_GROUP="_brewau"
BREWAU_USERS_GROUP="brewau_users"
BREWAU_LABEL="com.kastruppro.brewau.upgrade"
BREWAU_PLIST="/Library/LaunchDaemons/${BREWAU_LABEL}.plist"
BREWAU_SUDOERS="/etc/sudoers.d/brewau"
BREWAU_PATHS_D="/etc/paths.d/10-brewau"
BREWAU_CONF="${BREWAU_ROOT}/etc/brewau.conf"
BREWAU_VAR="${BREWAU_ROOT}/var"
BREWAU_HOME="${BREWAU_VAR}/home"
BREWAU_LOG_DIR="${BREWAU_VAR}/log"
BREWAU_STATE_DIR="${BREWAU_VAR}/state"
BREWAU_AUDIT_LOG="${BREWAU_LOG_DIR}/audit.log"

HOMEBREW_PREFIX_PATH="/opt/homebrew"
HOMEBREW_BIN="${HOMEBREW_PREFIX_PATH}/bin/brew"

# Taps that are always trusted. Everything else must be listed in
# ALLOWED_TAPS in brewau.conf.
BREWAU_OFFICIAL_TAP_RE='^homebrew/[a-z0-9][a-z0-9._-]*$'

# Config defaults; overridden by brewau_load_config.
ALLOWED_TAPS=""
FORBIDDEN_FORMULAE=""
FORBIDDEN_CASKS=""
EXTRA_ALLOWED_OPTIONS=""
AUTO_UPGRADE="1"
UPGRADE_GREEDY="1"
UPGRADE_EXCLUDE=""
UPGRADE_HOUR="4"
UPGRADE_MINUTE="0"

brewau_die() {
  echo "brewau: $*" >&2
  exit 1
}

brewau_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Parse brewau.conf as KEY="value" lines. The file is never sourced, so a
# tampered config cannot execute code; only known keys are accepted.
brewau_load_config() {
  local file="${1:-${BREWAU_CONF}}" line key value
  [[ -r "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    value="${value#\"}"
    [[ "${value}" =~ ^[A-Za-z0-9@/._+=[:space:]-]*$ ]] || brewau_die "invalid value for ${key} in ${file}"
    case "${key}" in
      ALLOWED_TAPS | FORBIDDEN_FORMULAE | FORBIDDEN_CASKS | EXTRA_ALLOWED_OPTIONS | \
        AUTO_UPGRADE | UPGRADE_GREEDY | UPGRADE_EXCLUDE | UPGRADE_HOUR | UPGRADE_MINUTE)
        printf -v "${key}" '%s' "${value}"
        ;;
      *) echo "brewau: ignoring unknown config key ${key}" >&2 ;;
    esac
  done <"${file}"
  ALLOWED_TAPS="$(brewau_lower "${ALLOWED_TAPS}")"
}

brewau_tap_allowed() {
  local tap word
  tap="$(brewau_lower "$1")"
  [[ "${tap}" =~ ${BREWAU_OFFICIAL_TAP_RE} ]] && return 0
  for word in ${ALLOWED_TAPS}; do
    [[ "${word}" == "${tap}" ]] && return 0
  done
  return 1
}

# Run brew as the current (_brewau) user with a fully reset environment.
# Extra NAME=value pairs passed via BREWAU_PASSTHROUGH_ENV are appended.
brewau_exec_brew() {
  cd / || exit 1
  # shellcheck disable=SC2086
  exec /usr/bin/env -i \
    HOME="${BREWAU_HOME}" \
    USER="${BREWAU_USER}" \
    LOGNAME="${BREWAU_USER}" \
    SHELL=/bin/bash \
    PATH="${HOMEBREW_PREFIX_PATH}/bin:${HOMEBREW_PREFIX_PATH}/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR=/private/tmp \
    HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_FORBID_PACKAGES_FROM_PATHS=1 \
    HOMEBREW_FORBIDDEN_FORMULAE="${FORBIDDEN_FORMULAE}" \
    HOMEBREW_FORBIDDEN_CASKS="${FORBIDDEN_CASKS}" \
    ${BREWAU_PASSTHROUGH_ENV} \
    "${HOMEBREW_BIN}" "$@"
}
