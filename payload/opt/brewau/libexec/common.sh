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
# Where root stages copies of apps: only root can change anything there, unlike
# /Applications, where admins can rename what root is working on.
BREWAU_STAGING_DIR="${BREWAU_VAR}"
BREWAU_LOG_DIR="${BREWAU_VAR}/log"
BREWAU_STATE_DIR="${BREWAU_VAR}/state"
# What brewau knows about each cask app's code signature (see brewau_app_trusted).
BREWAU_APP_STATE_DIR="${BREWAU_STATE_DIR}/apps"
BREWAU_AUDIT_LOG="${BREWAU_LOG_DIR}/audit.log"

# Homebrew's system-wide environment file and the block brewau manages in it.
BREWAU_BREW_ENV="/etc/homebrew/brew.env"
BREWAU_BREW_ENV_BEGIN="# BEGIN brewau (managed; regenerate with: sudo brewau reload)"
BREWAU_BREW_ENV_END="# END brewau"

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

# 1 makes every problem in brewau.conf fatal (`brewau config` sets it while an
# administrator edits). Otherwise problems that cannot weaken the policy only
# warn, so a stale value never locks everyone out of brew.
BREWAU_CONFIG_STRICT=0

# 1 while brewau first takes over: apps as they are then become the record,
# since whoever owned them before is trusted (see brewau_protect_apps).
BREWAU_APPS_BASELINE=0

# Set once by brewau_cache_forbidden_taps for jobs that run brew many times.
BREWAU_FORBIDDEN_TAPS_CACHE=""
BREWAU_FORBIDDEN_TAPS_CACHED=0

brewau_die() {
  echo "brewau: $*" >&2
  exit 1
}

brewau_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# True if $1 is one of the whitespace-separated words in $2.
brewau_in_words() {
  [[ -n "$1" && "$1" != *[[:space:]]* ]] || return 1
  case " ${2//[[:space:]]/ } " in *" $1 "*) return 0 ;; esac
  return 1
}

brewau_daemon_loaded() {
  launchctl print "system/${BREWAU_LABEL}" >/dev/null 2>&1
}

# Reports a problem in brewau.conf that cannot weaken the policy: fatal with
# BREWAU_CONFIG_STRICT=1, otherwise a warning. $2 says what happens instead.
brewau_config_problem() {
  [[ "${BREWAU_CONFIG_STRICT}" == "1" ]] && brewau_die "$1"
  echo "brewau: warning: $1${2:+; $2}" >&2
}

# Parse brewau.conf as KEY="value" lines. The file is never sourced, so a
# tampered config cannot execute code; only known keys are accepted. A line
# that does not parse and an unknown key are always fatal: either could be a
# misspelt restriction (no key has ever been retired).
brewau_load_config() {
  local file="${1:-${BREWAU_CONF}}" line key value n=0
  [[ -r "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "${line}" =~ ^[[:space:]]*([A-Z_]+)=(.*)$ ]] ||
      brewau_die "${file} line ${n}: expected KEY=\"value\" (upper-case key, no spaces around =)"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    value="${value#\"}"
    [[ "${value}" =~ ^[A-Za-z0-9@/._+=[:space:]-]*$ ]] || brewau_die "${file} line ${n}: invalid value for ${key}"
    case "${key}" in
      ALLOWED_TAPS | FORBIDDEN_FORMULAE | FORBIDDEN_CASKS | EXTRA_ALLOWED_OPTIONS | \
        AUTO_UPGRADE | UPGRADE_GREEDY | UPGRADE_EXCLUDE | UPGRADE_HOUR | UPGRADE_MINUTE | ALLOWED_SERVICES)
        printf -v "${key}" '%s' "${value}"
        ;;
      *) brewau_die "${file} line ${n}: unknown key ${key}" ;;
    esac
  done <"${file}"
  ALLOWED_TAPS="$(brewau_lower "${ALLOWED_TAPS}")"
  brewau_check_config "${file}"
}

# Normalises the boolean setting named $1 to 0 or 1; $2 is its default.
brewau_config_bool() {
  local key="$1" default="$2" file="$3"
  case "$(brewau_lower "${!key}")" in
    1 | yes | true | on) printf -v "${key}" 1 ;;
    0 | no | false | off) printf -v "${key}" 0 ;;
    *)
      brewau_config_problem "${key} must be 0 or 1 in ${file}" "using ${default}"
      printf -v "${key}" '%s' "${default}"
      ;;
  esac
}

# Keeps only the entries of list setting $1 that match regex $2.
brewau_config_list() {
  local key="$1" re="$2" what="$3" file="$4" word kept=""
  for word in ${!key}; do
    if [[ "${word}" =~ ${re} ]]; then
      kept="${kept:+${kept} }${word}"
    else
      brewau_config_problem "${key}: '${word}' is not ${what} in ${file}" "ignoring it"
    fi
  done
  printf -v "${key}" '%s' "${kept}"
}

# Checks the values that the policy, the job and the LaunchDaemon depend on.
# Invalid entries can only ever narrow what is allowed, so they are dropped
# (or reset to the default) with a warning rather than blocking brew.
brewau_check_config() {
  local file="$1"
  brewau_config_bool AUTO_UPGRADE 1 "${file}"
  brewau_config_bool UPGRADE_GREEDY 1 "${file}"
  if ! [[ "${UPGRADE_HOUR}" =~ ^[0-9]{1,2}$ ]] || ((10#${UPGRADE_HOUR} > 23)); then
    brewau_config_problem "UPGRADE_HOUR must be 0-23 in ${file}" "using 4"
    UPGRADE_HOUR=4
  fi
  if ! [[ "${UPGRADE_MINUTE}" =~ ^[0-9]{1,2}$ ]] || ((10#${UPGRADE_MINUTE} > 59)); then
    brewau_config_problem "UPGRADE_MINUTE must be 0-59 in ${file}" "using 0"
    UPGRADE_MINUTE=0
  fi
  brewau_config_list ALLOWED_TAPS '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$' "a user/repo tap" "${file}"
  brewau_config_list ALLOWED_SERVICES '^[A-Za-z0-9][A-Za-z0-9@._+-]*$' "a formula name" "${file}"
  return 0
}

brewau_tap_allowed() {
  local tap
  tap="$(brewau_lower "$1")"
  [[ "${tap}" =~ ${BREWAU_OFFICIAL_TAP_RE} ]] && return 0
  brewau_in_words "${tap}" "${ALLOWED_TAPS}"
}

# launchd job names Homebrew uses for formula $1: sh.brew.<formula>, and
# homebrew.mxcl.<formula> for services started by older versions.
brewau_service_labels() {
  echo "sh.brew.$1"
  echo "homebrew.mxcl.$1"
}

# Prints the plist in directory $1 named after one of formula $2's labels.
brewau_service_plist() {
  local label
  while IFS= read -r label; do
    [[ -f "$1/${label}.plist" ]] && { echo "$1/${label}.plist"; return 0; }
  done < <(brewau_service_labels "$2")
  return 1
}

# True if a job of formula $2 is loaded in launchd domain $1 (gui/<uid>, system).
brewau_service_loaded() {
  local label
  while IFS= read -r label; do
    launchctl print "$1/${label}" >/dev/null 2>&1 && return 0
  done < <(brewau_service_labels "$2")
  return 1
}

# Prints the formula that Homebrew service plist $1 belongs to, by its name.
brewau_service_formula() {
  local name="${1##*/}"
  name="${name%.plist}"
  case "${name}" in
    sh.brew.?*) name="${name#sh.brew.}" ;;
    homebrew.mxcl.?*) name="${name#homebrew.mxcl.}" ;;
    *) return 1 ;;
  esac
  [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]] && echo "${name}"
}

# Prints, relative to the prefix's var directory, the data directories that
# formula $1's service uses according to its keg, which only BREWAU_USER can
# change: paths in its plist, and in config files that plist passes it,
# except the var directory itself and its logs.
brewau_service_var_dirs() {
  local var="${HOMEBREW_PREFIX_PATH}/var" plist path rel seen=$'\n'
  plist="$(brewau_service_plist "${HOMEBREW_PREFIX_PATH}/opt/$1" "$1")" || return 1
  while IFS= read -r path; do
    path="${path#*=}"
    if [[ "${path}" == "${HOMEBREW_PREFIX_PATH}/etc/"* && -f "${path}" ]]; then
      # Not in comments; a config without any is fine (pipefail).
      sed '/^[[:space:]]*[#;]/d' "${path}" 2>/dev/null | grep -oE "${var//./\\.}/[^[:space:]\"';,]+" || true
    else
      echo "${path}"
    fi
  done < <(brewau_plist_strings "${plist}") |
    while IFS= read -r path; do
      [[ "${path}" == "${var}"/* ]] || continue
      rel="${path#"${var}"}"
      rel="${rel%/}"
      [[ -n "${rel}" && "${rel}" != /log && "${rel}" != /log/* && "${rel}/" != */./* && "${rel}/" != */../* ]] || continue
      [[ "${seen}" == *$'\n'"${rel}"$'\n'* ]] && continue
      seen="${seen}${rel}"$'\n'
      echo "${rel}"
    done
}

# Prints the `brew services` action that $1 means, resolving Homebrew's
# aliases (`s` is start, `ls` is list, ...).
brewau_service_action() {
  case "$1" in
    ls) echo list ;;
    i) echo info ;;
    launch | load | s | l) echo start ;;
    unload | terminate | term | t | u) echo stop ;;
    relaunch | reload | r) echo restart ;;
    k) echo kill ;;
    clean | cl | rm) echo cleanup ;;
    *) echo "$1" ;;
  esac
}

# True if formula $1 may run its service as a root system daemon.
brewau_service_allowed() {
  brewau_in_words "$1" "${ALLOWED_SERVICES}"
}

# Taps that are installed but not allowed. Unqualified names and dependencies
# can resolve to any installed tap, so these are passed to Homebrew as
# HOMEBREW_FORBIDDEN_TAPS and enforced by brew itself. Homebrew matches a
# user/repo entry only against taps with the default GitHub remote, so taps
# with a custom remote are listed by their remote URL.
brewau_forbidden_taps() {
  local dir user repo tap remote stripped ref out=""
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
    # Homebrew ignores a trailing slash and .git only for some hosts, so pass
    # the remote on unchanged and strip them only to spot the default remote.
    stripped="${remote%/}"
    case "$(brewau_lower "${stripped%.git}")" in
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

# Computes the forbidden taps once for the rest of this process, for jobs that
# run brew many times. Taps do not change while such a job runs.
brewau_cache_forbidden_taps() {
  BREWAU_FORBIDDEN_TAPS_CACHE="$(brewau_forbidden_taps)" || return 1
  BREWAU_FORBIDDEN_TAPS_CACHED=1
}

# Prints "token<TAB>path" for every installed app artifact in the output of
# `brew info --json=v2 --installed --cask`, read from the file $1.
brewau_cask_apps() {
  local json="$1" casks artifacts i j token target
  casks="$(plutil -extract casks raw -o - "${json}" 2>/dev/null)" || return 0
  [[ "${casks}" =~ ^[0-9]+$ ]] || return 0
  for ((i = 0; i < casks; i++)); do
    token="$(plutil -extract "casks.${i}.token" raw -o - "${json}" 2>/dev/null)" || continue
    artifacts="$(plutil -extract "casks.${i}.artifacts" raw -o - "${json}" 2>/dev/null)" || continue
    [[ "${artifacts}" =~ ^[0-9]+$ ]] || continue
    for ((j = 0; j < artifacts; j++)); do
      plutil -extract "casks.${i}.artifacts.${j}.app" raw -o - "${json}" >/dev/null 2>&1 || continue
      target="$(plutil -extract "casks.${i}.artifacts.${j}.target" raw -o - "${json}" 2>/dev/null)" || continue
      [[ "${target}" == "${BREWAU_APPDIR}"/*.app && "${target}" != *..* ]] || continue
      [[ -d "${target}" && ! -L "${target}" ]] && printf '%s\t%s\n' "${token}" "${target}"
    done
  done
}

# Prints the installed path of every app artifact (see brewau_cask_apps).
brewau_cask_app_paths() {
  brewau_cask_apps "$1" | cut -f 2-
}

# Makes cask-installed apps unwritable by users. Cask upgrade and uninstall
# steps can run code from inside the app (e.g. `uninstall script:`) as
# _brewau, and so as root; an app its user can write to would let them plant
# that code. Apps that update themselves as the user lose that ability.
# $1 is the JSON file; the rest is an optional command prefix that gives root
# (e.g. sudo -n). Prints the tokens of casks whose apps are still unprotected
# afterwards or untrusted (and then fails); progress goes to stderr.
brewau_protect_apps() {
  local json="$1" token app locked result=0
  shift
  while IFS=$'\t' read -r token app; do
    if brewau_app_untrusted "${app}"; then
      echo "brewau: WARNING: ${app} is marked untrusted; an administrator must check it, then run: sudo brewau trust-app '${app}'" >&2
      echo "${token}"
      result=1
      continue
    fi
    brewau_app_needs_protection "${app}" || continue
    echo "brewau: protecting ${app}" >&2
    locked=1
    if [[ $# -gt 0 ]]; then
      "$@" /bin/bash -p -c 'source /opt/brewau/libexec/common.sh && brewau_lock_app "$1"' brewau "${app}" </dev/null >&2 || locked=0
    else
      (brewau_lock_app "${app}") </dev/null >&2 || locked=0
    fi
    # On the first install apps are taken as they are (see BREWAU_APPS_BASELINE).
    [[ "${BREWAU_APPS_BASELINE}" == "1" ]] && { brewau_record_app "${app}" || true; }
    # Locked but not replaced by a fresh copy (see brewau_lock_app): files
    # someone held open may still be its, so keep reporting it.
    if [[ ${locked} -eq 0 ]] && ! brewau_app_needs_protection "${app}"; then
      brewau_write_state "$(brewau_app_state "${app}").untrusted" "${app}" || true
    fi
    if [[ ${locked} -eq 0 ]] || brewau_app_needs_protection "${app}"; then
      echo "brewau: WARNING: could not protect ${app} (App Management permission?)" >&2
      echo "${token}"
      result=1
    elif [[ "${BREWAU_APPS_BASELINE}" != "1" ]] && ! brewau_app_trusted "${app}"; then
      echo "brewau: WARNING: ${app} could be changed by others, and it no longer carries the signature brewau recorded." >&2
      echo "brewau: an administrator must check it, then run: sudo brewau trust-app '${app}'" >&2
      echo "${token}"
      result=1
    fi
  done < <(brewau_cask_apps "${json}")
  return "${result}"
}

# Records the signature of every cask app (see brewau_record_app), after
# brewau itself installed or upgraded casks. $1 is the JSON file.
brewau_record_apps() {
  local token app
  while IFS=$'\t' read -r token app; do
    brewau_app_needs_protection "${app}" || brewau_record_app "${app}" || true
  done < <(brewau_cask_apps "$1")
  return 0
}

# Prints the base name of the state files for app $1.
brewau_app_state() {
  echo "${BREWAU_APP_STATE_DIR}/$(md5 -qs "$1")"
}

brewau_app_untrusted() {
  [[ -e "$(brewau_app_state "$1").untrusted" ]]
}

# Prints the Team ID of app $1 if its signature is intact and by a
# certificate Apple issued (a self-made one can claim any Team ID). With $2,
# the Team ID must be that one.
brewau_app_team() {
  local requirement="anchor apple generic" team
  if [[ -n "${2:-}" ]]; then
    [[ "$2" =~ ^[A-Z0-9]+$ ]] || return 1
    requirement="${requirement} and certificate leaf[subject.OU] = \"$2\""
  fi
  codesign --verify --deep --strict -R="${requirement}" "$1" >/dev/null 2>&1 || return 1
  team="$(codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "${team}" =~ ^[A-Z0-9]+$ && ( -z "${2:-}" || "${team}" == "$2" ) ]] || return 1
  echo "${team}"
}

# Writes $2 to state file $1 atomically.
brewau_write_state() {
  local tmp
  mkdir -p "${1%/*}" 2>/dev/null
  tmp="$(mktemp "${1%/*}/.tmp.XXXXXX")" || return 1
  if printf '%s\n' "$2" >"${tmp}" && chmod 0644 "${tmp}" && mv -f "${tmp}" "$1"; then
    return 0
  fi
  rm -f "${tmp}"
  return 1
}

# Remembers who signed app $1 ("-" if nobody did) as brewau put it in place,
# so a later change can be told apart. Only re-checks an app whose bundle was
# replaced (another inode) since; never one that is marked untrusted.
brewau_record_app() {
  local app="$1" state inode team
  state="$(brewau_app_state "${app}")"
  [[ -e "${state}.untrusted" ]] && return 0
  inode="$(stat -f %i "${app}" 2>/dev/null)" || return 1
  [[ "$(cut -f 1 "${state}.team" 2>/dev/null)" == "${inode}" ]] && return 0
  team="$(brewau_app_team "${app}")" || team="-"
  brewau_write_state "${state}.team" "${inode}"$'\t'"${team}"$'\t'"${app}"
}

# True if app $1, which others could change until it was just locked, still
# carries an intact signature by the Team ID brewau recorded for it (or, with
# no record yet, by any Team ID). Otherwise anyone's code may be in it, so it
# is marked untrusted, and brew refuses to run its cask's steps, until an
# administrator runs `sudo brewau trust-app`.
brewau_app_trusted() {
  local app="$1" state team recorded
  state="$(brewau_app_state "${app}")"
  recorded="$(cut -f 2 "${state}.team" 2>/dev/null)"
  # An app recorded as unsigned can never be shown to be unchanged.
  if [[ "${recorded}" != "-" ]] && team="$(brewau_app_team "${app}" "${recorded}")"; then
    brewau_write_state "${state}.team" "$(stat -f %i "${app}")"$'\t'"${team}"$'\t'"${app}" && return 0
  fi
  brewau_write_state "${state}.untrusted" "${app}"
  return 1
}

# Locks app bundle $1 in BREWAU_APPDIR (see brewau_lock_tree), then replaces
# it by a copy of itself: whoever could change it before may still hold one of
# its files open for writing, which locking cannot take away. Runs as root.
brewau_lock_app() {
  [[ "$1" == "${BREWAU_APPDIR}"/*.app && "$1" != *..* && -d "$1" && ! -L "$1" ]] || return 1
  brewau_lock_tree "$1" && brewau_replace_with_copy "$1"
}

# Replaces locked app $1 by a fresh copy (new files nobody has open), staged
# in a directory only root can change. mv -h: if an admin turned the app's
# path into a symlink meanwhile, it is replaced rather than followed.
brewau_replace_with_copy() {
  local app="$1" tmp
  tmp="$(mktemp -d "${BREWAU_STAGING_DIR}/app-copy.XXXXXX")" || return 1
  if [[ -d "${app}" && ! -L "${app}" ]] && ditto "${app}" "${tmp}/new" && mv -h "${app}" "${tmp}/old"; then
    if mv -h "${tmp}/new" "${app}"; then
      rm -rf "${tmp}"
      return 0
    fi
    mv -h "${tmp}/old" "${app}"
  fi
  rm -rf "${tmp}"
  return 1
}

# Gives everything under directory $1 that root does not own to BREWAU_USER
# and removes group/world write and ACLs. Runs as root over a tree its users
# may still be changing, so it must never follow a symlink they plant: a
# directory is locked only after every directory above it (so no component of
# its path can be swapped any more), files only in locked directories, and
# every change uses -h. Users can also hard-link any file (root's included),
# so a file with more than one link is replaced by a copy before it is taken
# over. Locks what it can; fails if any directory stayed unlocked.
brewau_lock_tree() {
  local root dir parent phys pass locked failed=() f skip
  root="$(cd -P "$1" 2>/dev/null && pwd -P)" || return 1
  for ((pass = 0; pass < 10; pass++)); do
    locked=0
    # find lists parents before their children.
    while IFS= read -r -d '' dir; do
      skip=0
      for f in ${failed[@]+"${failed[@]}"}; do
        [[ "${dir}" == "${f}"/* ]] && skip=1
      done
      [[ ${skip} -eq 0 ]] || continue
      # Skip what became a symlink, or sits below one, before its parent was
      # locked. The x keeps $(...) from eating trailing newlines in a name.
      parent="${dir%/*}"
      phys="$(cd -P "${parent}" 2>/dev/null && pwd -P && echo x)"
      [[ "${phys%$'\n'x}" == "${parent}" && -d "${dir}" && ! -L "${dir}" ]] || continue
      if brewau_lock_path "${dir}"; then
        locked=1
      else
        failed+=("${dir}")
      fi
    done < <(find "${root}" -type d \( ! -user root ! -user "${BREWAU_USER}" -o -perm -g+w -o -perm -o+w -o -acl \) -print0 2>/dev/null)
    # Directories created before their parent was locked show up next pass.
    [[ ${locked} -eq 1 ]] || break
  done

  # Files, outside directories that are still unlocked.
  brewau_locked_files "${root}" -links +1 ! -user root ! -user "${BREWAU_USER}" -print0 |
    while IFS= read -r -d '' f; do brewau_unlink_copy "${f}"; done
  brewau_locked_files "${root}" -links 1 ! -user root ! -user "${BREWAU_USER}" -exec /usr/bin/chflags -h nouchg,nouappnd {} +
  brewau_locked_files "${root}" -links 1 ! -user root ! -user "${BREWAU_USER}" -exec /usr/sbin/chown -h "${BREWAU_USER}:admin" {} +
  brewau_locked_files "${root}" ! -type l \( -links 1 -o -user "${BREWAU_USER}" \) \( -perm -g+w -o -perm -o+w \) \
    -exec /bin/chmod -h go-w {} +
  # chmod go-w leaves ACL entries alone, and an ACL can grant write too.
  brewau_locked_files "${root}" ! -type l \( -links 1 -o -user "${BREWAU_USER}" \) -acl -exec /bin/chmod -h -N {} +
  [[ -z "$(find "${root}" -type d \( ! -user root ! -user "${BREWAU_USER}" -o -perm -g+w -o -perm -o+w -o -acl \) -print 2>/dev/null | head -1)" ]]
}

# Runs find over the non-directories under $1 that are not inside a directory
# someone other than root/BREWAU_USER could still change; the rest of the
# arguments are the test and action.
brewau_locked_files() {
  local root="$1"
  shift
  find "${root}" -type d \( ! -user root ! -user "${BREWAU_USER}" -o -perm -g+w -o -perm -o+w -o -acl \) -prune \
    -o ! -type d "$@" 2>/dev/null
}

# Replaces hard-linked file $1, in a locked directory, by a copy of its own,
# so taking it over cannot change the same file elsewhere. Leaves a file with
# user flags alone: clearing them would change the other file too.
brewau_unlink_copy() {
  local file="$1" tmp
  (($(stat -f %f "${file}" 2>/dev/null || echo 6) & 6)) && return 1
  tmp="$(mktemp "${file%/*}/.brewau-copy.XXXXXX")" || return 1
  if /bin/cp -p "${file}" "${tmp}" && /bin/mv -f "${tmp}" "${file}"; then
    return 0
  fi
  /bin/rm -f "${tmp}"
  return 1
}

# Locks one directory whose parent is already locked. Clears the user flags
# first: with uchg set, not even root can change it.
brewau_lock_path() {
  local owner
  owner="$(stat -f %Su "$1" 2>/dev/null)" || return 1
  if [[ "${owner}" != "root" && "${owner}" != "${BREWAU_USER}" ]]; then
    /usr/bin/chflags -h nouchg,nouappnd "$1" && /usr/sbin/chown -h "${BREWAU_USER}:admin" "$1" || return 1
  fi
  /bin/chmod -h go-w "$1" && /bin/chmod -h -N "$1"
}

# True if anything in the app is owned by someone other than root/_brewau, is
# group/world-writable, or carries an ACL (which can grant write access).
brewau_app_needs_protection() {
  [[ -n "$(find "$1" ! -type l \( ! -user root ! -user "${BREWAU_USER}" -o -perm -g+w -o -perm -o+w -o -acl \) -print 2>/dev/null | head -1)" ]]
}

# Prints every string value in plist $1 (ProgramArguments, environment
# variables, paths), one per line; - reads the plist from stdin.
brewau_plist_strings() {
  plutil -convert xml1 -o - "$1" 2>/dev/null |
    sed -n 's#.*<string>\(.*\)</string>.*#\1#p' |
    sed 's#&amp;#\&#g; s#&lt;#<#g; s#&gt;#>#g'
}

# Runs a filter command over a file and writes the result back in place, so
# symlinked files (stow, chezmoi, ...) stay symlinks and keep their owner.
brewau_rewrite_file() {
  local file="$1" tmp result=0
  shift
  tmp="$(mktemp "${TMPDIR:-/tmp}/brewau-rewrite.XXXXXX")" || return 1
  if "$@" <"${file}" >"${tmp}"; then
    cmp -s "${tmp}" "${file}" || cat "${tmp}" >"${file}" || result=1
  else
    result=1
  fi
  rm -f "${tmp}"
  return "${result}"
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
  local as="$1" home="${BREWAU_HOME}" tmp="${BREWAU_TMP}" forbidden_taps="${BREWAU_FORBIDDEN_TAPS_CACHE}"
  local sudo=()
  shift
  cd / || exit 1
  # sudo already never lowers the umask below 022; do not rely on its config.
  umask 022
  if [[ "${BREWAU_FORBIDDEN_TAPS_CACHED}" != "1" ]]; then
    forbidden_taps="$(brewau_forbidden_taps)" || exit 1
  fi
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

# Prints what in git repository $1 (Homebrew or a tap) could make git, and so
# Homebrew as BREWAU_USER, run something other than upstream code: any repo
# config beyond the plain settings git and Homebrew write, hooks, a .git that
# is not a plain directory, or (for Homebrew) another remote. Reads the files
# only, never runs git on them.
brewau_repo_problems() {
  local dir="$1" file key value hook
  [[ -e "${dir}/.git" || -L "${dir}/.git" ]] || return 0
  if [[ ! -d "${dir}/.git" || -L "${dir}/.git" || -e "${dir}/.git/commondir" ]]; then
    echo "${dir}: .git is not a plain repository directory"
    return 0
  fi
  # git follows them, to files someone else may still control.
  if [[ -n "$(find "${dir}/.git" -type l -print 2>/dev/null | head -1)" ]]; then
    echo "${dir}: .git contains symlinks"
    return 0
  fi
  for file in "${dir}/.git/config" "${dir}/.git/config.worktree"; do
    [[ -f "${file}" ]] || continue
    while IFS= read -r key; do
      value="${key#*=}"
      key="$(brewau_lower "${key%%=*}")"
      brewau_git_setting_harmless "${dir}" "${key}" "${value}" || echo "${dir}: git config sets ${key}"
    done < <(git config --file "${file}" --list 2>/dev/null)
  done
  for hook in "${dir}"/.git/hooks/*; do
    [[ -e "${hook}" && "${hook}" != *.sample ]] && echo "${dir}: git hook ${hook##*/}"
  done
  return 0
}

# True for repository settings (key $2, value $3, in repository $1) that
# cannot make git run anything or fetch from elsewhere.
brewau_git_setting_harmless() {
  case "$2" in
    core.repositoryformatversion | core.filemode | core.bare | core.logallrefupdates | core.ignorecase | \
      core.precomposeunicode | core.autocrlf | core.symlinks | core.untrackedcache | core.checkstat | \
      core.trustctime | remote.origin.fetch | remote.origin.tagopt | remote.origin.prune | \
      remote.origin.prunetags | remote.origin.followremotehead | fetch.prune | fetch.prunetags | \
      fetch.writecommitgraph | gc.auto | gc.autodetach | branch.*.remote | branch.*.merge | branch.*.rebase | \
      pull.rebase | pull.ff | homebrew.*) return 0 ;;
    core.fsmonitor) [[ "$3" == "false" ]] ;;
    # Taps are blocked or allowed by their remote elsewhere.
    remote.origin.url)
      [[ "$1" != "${HOMEBREW_PREFIX_PATH}" ]] && return 0
      case "$(brewau_lower "${3%.git}")" in https://github.com/homebrew/brew | https://github.com/homebrew/brew/) return 0 ;; esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Homebrew's repository and its taps.
brewau_repos() {
  local dir
  echo "${HOMEBREW_PREFIX_PATH}"
  for dir in "${HOMEBREW_PREFIX_PATH}"/Library/Taps/*/*; do
    [[ -e "${dir}/.git" || -L "${dir}/.git" ]] && echo "${dir}"
  done
  return 0
}

# `brew services start` as root makes the service's keg root-owned (and
# sticky) so users cannot edit what root runs. Here the prefix belongs to
# BREWAU_USER, which users cannot write and which has root anyway, so give the
# keg of formula $1 back; otherwise BREWAU_USER could never upgrade or remove
# it. Runs as BREWAU_USER.
brewau_release_service_keg() {
  local keg="${HOMEBREW_PREFIX_PATH}/Cellar/$1"
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ && -d "${keg}" && ! -L "${keg}" ]] || return 0
  [[ -n "$(find "${keg}" -user root -print 2>/dev/null | head -1)" ]] || return 0
  /usr/bin/sudo -n /usr/bin/find "${keg}" -user root -exec /usr/sbin/chown -h "${BREWAU_USER}:admin" {} + &&
    /usr/bin/sudo -n /usr/bin/find "${keg}" -type d -perm -1000 -exec /bin/chmod -h -t {} + &&
    echo "brewau: ${keg} stays owned by ${BREWAU_USER}, so the scheduled upgrade can keep it current"
}

# The settings brewau enforces through /etc/homebrew/brew.env. Homebrew loads
# that file over the environment the policy sets, so it is what applies.
brewau_brew_env_block() {
  cat <<EOF
${BREWAU_BREW_ENV_BEGIN}
HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY=1
HOMEBREW_FORBID_PACKAGES_FROM_PATHS=1
HOMEBREW_FORBIDDEN_FORMULAE=${FORBIDDEN_FORMULAE}
HOMEBREW_FORBIDDEN_CASKS=${FORBIDDEN_CASKS}
${BREWAU_BREW_ENV_END}
EOF
}

# Prints the brewau block currently in /etc/homebrew/brew.env.
brewau_brew_env_current() {
  [[ -r "${BREWAU_BREW_ENV}" ]] || return 0
  awk -v begin="${BREWAU_BREW_ENV_BEGIN}" -v end="${BREWAU_BREW_ENV_END}" \
    '$0 == begin { keep = 1 } keep { print } $0 == end { keep = 0 }' "${BREWAU_BREW_ENV}"
}
