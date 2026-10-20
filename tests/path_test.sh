#!/bin/bash
# The privileged scripts must not run programs from the caller's PATH: sudo
# passes PATH through, so a planted `dirname` would run as _brewau.

set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PAYLOAD="${HERE}/../payload/opt/brewau"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS=0
FAIL=0

# Fake versions of every tool the scripts call before or while sourcing.
mkdir -p "${WORK}/evil"
for tool in dirname basename id cat date tr printenv sed grep awk find stat; do
  printf '#!/bin/sh\necho %s >>"%s/ran"\nexit 1\n' "${tool}" "${WORK}" >"${WORK}/evil/${tool}"
  chmod 755 "${WORK}/evil/${tool}"
done

run_with_evil_path() {
  rm -f "${WORK}/ran"
  PATH="${WORK}/evil:/usr/bin:/bin" "$@" >/dev/null 2>&1
  if [[ -f "${WORK}/ran" ]]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: $* ran planted $(tr '\n' ' ' <"${WORK}/ran")from PATH"
  else
    PASS=$((PASS + 1))
  fi
}

point_at_checkout() {
  sed "s#^BREWAU_LIBEXEC=.*#BREWAU_LIBEXEC=\"${PAYLOAD}/libexec\"#" "$1" >"$2"
}

run_with_evil_path env BREWAU_POLICY_TEST=1 /bin/bash "${PAYLOAD}/libexec/brew-policy" install wget
point_at_checkout "${PAYLOAD}/libexec/brewau-upgrade" "${WORK}/brewau-upgrade"
run_with_evil_path env BREWAU_UPGRADE_TEST=1 /bin/bash "${WORK}/brewau-upgrade"
point_at_checkout "${PAYLOAD}/bin/brewau" "${WORK}/brewau"
run_with_evil_path /bin/bash "${WORK}/brewau" version
point_at_checkout "${PAYLOAD}/libexec/brewau-setup" "${WORK}/brewau-setup"
run_with_evil_path /bin/bash "${WORK}/brewau-setup"

# And statically: PATH is pinned before anything else runs.
for script in libexec/brew-policy libexec/brewau-upgrade libexec/brewau-setup libexec/brewau-services bin/brewau; do
  first_cmd="$(grep -nE '\$\(|^source |^[a-z_]+ ' "${PAYLOAD}/${script}" | grep -vE '^[0-9]+:(set |#)' | head -1 | cut -d: -f1)"
  path_line="$(grep -n '^PATH="/usr/bin:/bin:/usr/sbin:/sbin"$' "${PAYLOAD}/${script}" | head -1 | cut -d: -f1)"
  if [[ -n "${path_line}" && "${path_line}" -lt "${first_cmd:-0}" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: ${script} does not pin PATH before line ${first_cmd}"
  fi
done

echo "${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]]
