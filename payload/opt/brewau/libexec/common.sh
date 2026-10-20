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
BREWAU_TMP="${BREWAU_VAR}/tmp"
BREWAU_LOG_DIR="${BREWAU_VAR}/log"
BREWAU_STATE_DIR="${BREWAU_VAR}/state"
BREWAU_AUDIT_LOG="${BREWAU_LOG_DIR}/audit.log"

HOMEBREW_PREFIX_PATH="/opt/homebrew"
# Where casks put apps. Overridden only by tests.
BREWAU_APPDIR="${BREWAU_APPDIR:-/Applications}"
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
ALLOWED_SERVICES=""
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
        AUTO_UPGRADE | UPGRADE_GREEDY | UPGRADE_EXCLUDE | UPGRADE_HOUR | UPGRADE_MINUTE | ALLOWED_SERVICES)
        printf -v "${key}" '%s' "${value}"
        ;;
      *) echo "brewau: ignoring unknown config key ${key}" >&2 ;;
    esac
  done <"${file}"
  ALLOWED_TAPS="$(brewau_lower "${ALLOWED_TAPS}")"
  brewau_check_config "${file}"
}

# Rejects values that would break the policy or the LaunchDaemon.
brewau_check_config() {
  local file="$1"
  [[ "${AUTO_UPGRADE}" == "0" || "${AUTO_UPGRADE}" == "1" ]] || brewau_die "AUTO_UPGRADE must be 0 or 1 in ${file}"
  [[ "${UPGRADE_GREEDY}" == "0" || "${UPGRADE_GREEDY}" == "1" ]] || brewau_die "UPGRADE_GREEDY must be 0 or 1 in ${file}"
  [[ "${UPGRADE_HOUR}" =~ ^[0-9]{1,2}$ ]] && ((10#${UPGRADE_HOUR} <= 23)) || brewau_die "UPGRADE_HOUR must be 0-23 in ${file}"
  [[ "${UPGRADE_MINUTE}" =~ ^[0-9]{1,2}$ ]] && ((10#${UPGRADE_MINUTE} <= 59)) || brewau_die "UPGRADE_MINUTE must be 0-59 in ${file}"
  local name
  for name in ${ALLOWED_SERVICES}; do
    [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]] || brewau_die "ALLOWED_SERVICES entries must be formula names in ${file}"
  done
  return 0
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

# True if formula $1 may run its service as a root system daemon.
brewau_service_allowed() {
  local word
  for word in ${ALLOWED_SERVICES}; do
    [[ "${word}" == "$1" ]] && return 0
  done
  return 1
}

# Taps that are installed but not allowed. Unqualified names and dependencies
# can resolve to any installed tap, so these are passed to Homebrew as
# HOMEBREW_FORBIDDEN_TAPS and enforced by brew itself. Homebrew matches a
# user/repo entry only against taps with the default GitHub remote, so taps
# with a custom remote are listed by their remote URL.
brewau_forbidden_taps() {
  local dir user repo tap remote ref out=""
  for dir in "${HOMEBREW_PREFIX_PATH}"/Library/Taps/*/homebrew-*; do
    [[ -d "${dir}" ]] || continue
    user="$(basename "$(dirname "${dir}")")"
    repo="$(basename "${dir}")"
    repo="${repo#homebrew-}"
    tap="${user}/${repo}"
    brewau_tap_allowed "${tap}" && continue
    ref="${tap}"
    # Read the config file directly: `git -C` refuses repositories owned by
    # someone else, and this also runs as the user in `brewau doctor`.
    remote="$(git config --file "${dir}/.git/config" --get remote.origin.url 2>/dev/null || true)"
    remote="${remote%/}"
    case "$(brewau_lower "${remote%.git}")" in
      "" | "https://github.com/$(brewau_lower "${user}/homebrew-${repo}")") ;;
      *) ref="${remote}" ;;
    esac
    # A reference Homebrew could misparse would leave the tap unblocked, so
    # refuse to run at all rather than pass it on.
    [[ "${ref}" =~ ^[A-Za-z0-9@:/._+~%=-]+$ ]] || brewau_die "cannot block tap ${tap}: unexpected remote ${remote}"
    out="${out:+${out} }${ref}"
  done
  echo "${out}"
}

# Prints the installed path of every app artifact in the output of
# `brew info --json=v2 --installed --cask`, read from the file $1.
brewau_cask_app_paths() {
  local json="$1" casks artifacts i j target
  casks="$(plutil -extract casks raw -o - "${json}" 2>/dev/null)" || return 0
  [[ "${casks}" =~ ^[0-9]+$ ]] || return 0
  for ((i = 0; i < casks; i++)); do
    artifacts="$(plutil -extract "casks.${i}.artifacts" raw -o - "${json}" 2>/dev/null)" || continue
    [[ "${artifacts}" =~ ^[0-9]+$ ]] || continue
    for ((j = 0; j < artifacts; j++)); do
      plutil -extract "casks.${i}.artifacts.${j}.app" raw -o - "${json}" >/dev/null 2>&1 || continue
      target="$(plutil -extract "casks.${i}.artifacts.${j}.target" raw -o - "${json}" 2>/dev/null)" || continue
      [[ "${target}" == "${BREWAU_APPDIR}"/*.app && "${target}" != *..* ]] || continue
      [[ -d "${target}" && ! -L "${target}" ]] && echo "${target}"
    done
  done
}

# Makes cask-installed apps unwritable by users. Cask upgrade and uninstall
# steps can run code from inside the app (e.g. `uninstall script:`) as
# _brewau, and so as root; an app its user can write to would let them plant
# that code. Apps that update themselves as the user lose that ability.
# $1 is the JSON file; the rest is an optional command prefix (e.g. sudo -n).
brewau_protect_apps() {
  local json="$1" app
  shift
  while IFS= read -r app; do
    brewau_app_needs_protection "${app}" || continue
    echo "brewau: protecting ${app}"
    "$@" /usr/bin/find "${app}" ! -user root ! -user "${BREWAU_USER}" -exec /usr/sbin/chown -h "${BREWAU_USER}:admin" {} + </dev/null ||
      echo "brewau: WARNING: could not take ownership of ${app} (App Management permission?)" >&2
    "$@" /usr/bin/find "${app}" ! -type l \( -perm -g+w -o -perm -o+w \) -exec /bin/chmod go-w {} + </dev/null || true
    # chmod go-w leaves ACL entries alone, and an ACL can grant write too.
    "$@" /usr/bin/find "${app}" ! -type l -acl -exec /bin/chmod -N {} + </dev/null || true
  done < <(brewau_cask_app_paths "${json}")
}

# True if anything in the app is owned by someone other than root/_brewau, is
# group/world-writable, or carries an ACL (which can grant write access).
brewau_app_needs_protection() {
  [[ -n "$(find "$1" ! -type l \( ! -user root ! -user "${BREWAU_USER}" -o -perm -g+w -o -perm -o+w -o -acl \) -print 2>/dev/null | head -1)" ]]
}

# Runs a filter command over a file and writes the result back in place, so
# symlinked files (stow, chezmoi, ...) stay symlinks and keep their owner.
brewau_rewrite_file() {
  local file="$1" tmp
  shift
  tmp="$(mktemp "${TMPDIR:-/tmp}/brewau-rewrite.XXXXXX")" || return 1
  if "$@" <"${file}" >"${tmp}"; then
    cmp -s "${tmp}" "${file}" || cat "${tmp}" >"${file}"
  fi
  rm -f "${tmp}"
}

# Filter for brewau_rewrite_file: replaces every occurrence of $1 with $2,
# literally (no regex or sed escaping involved).
brewau_replace_literal() {
  awk -v from="$1" -v to="$2" '{
    out = ""
    while ((i = index($0, from)) > 0) {
      out = out substr($0, 1, i - 1) to
      $0 = substr($0, i + length(from))
    }
    print out $0
  }'
}

# Run brew as the current (_brewau) user with a fully reset environment.
# Extra NAME=value pairs passed via BREWAU_PASSTHROUGH_ENV are appended.
brewau_exec_brew() {
  _brewau_exec_brew "${BREWAU_USER}" "$@"
}

# Run brew as root, for `brew services` on ALLOWED_SERVICES (system daemons).
# Homebrew permits root only for `brew services`. Root gets its own HOME and
# temp directory so it never leaves root-owned files where _brewau works.
brewau_exec_brew_as_root() {
  _brewau_exec_brew root "$@"
}

_brewau_exec_brew() {
  local as="$1" home="${BREWAU_HOME}" tmp="${BREWAU_TMP}" forbidden_taps
  local sudo=()
  shift
  cd / || exit 1
  # sudo already never lowers the umask below 022; do not rely on its config.
  umask 022
  forbidden_taps="$(brewau_forbidden_taps)" || exit 1
  if [[ "${as}" == "root" ]]; then
    home="/var/root"
    tmp="/private/tmp"
    sudo=(/usr/bin/sudo -n)
  fi
  # shellcheck disable=SC2086
  exec ${sudo[@]+"${sudo[@]}"} /usr/bin/env -i \
    HOME="${home}" \
    USER="${as}" \
    LOGNAME="${as}" \
    SHELL=/bin/bash \
    PATH="${HOMEBREW_PREFIX_PATH}/bin:${HOMEBREW_PREFIX_PATH}/sbin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="${tmp}" \
    HOMEBREW_TEMP="${tmp}" \
    HOMEBREW_NO_ENV_HINTS=1 \
    HOMEBREW_FORBID_PACKAGES_FROM_PATHS=1 \
    HOMEBREW_FORBIDDEN_FORMULAE="${FORBIDDEN_FORMULAE}" \
    HOMEBREW_FORBIDDEN_CASKS="${FORBIDDEN_CASKS}" \
    HOMEBREW_FORBIDDEN_TAPS="${forbidden_taps}" \
    ${BREWAU_PASSTHROUGH_ENV} \
    "${HOMEBREW_BIN}" "$@"
}
