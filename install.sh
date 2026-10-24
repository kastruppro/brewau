#!/bin/bash
# brewau installer.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kastruppro/brewau/main/install.sh)"
#       downloads the latest signed, notarized .pkg and installs it.
#
#   sudo ./install.sh --from build/root
#       installs a staged checkout (make install), for development.

set -euo pipefail
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

BREWAU_REPO="${BREWAU_REPO:-kastruppro/brewau}"
# Apple Developer team that signs official releases. Forks set their own.
BREWAU_TEAM_ID="${BREWAU_TEAM_ID:-5W98EXLE44}"
PKG_ID="com.kastruppro.brewau"

die() {
  echo "install.sh: $*" >&2
  exit 1
}

install_from_root() {
  local root="$1" tmp version source_dir
  [[ "$(id -u)" -eq 0 ]] || die "--from must run as root"
  [[ -x "${root}/opt/brewau/libexec/brewau-setup" ]] || die "${root} is not a staged brewau root (run: make stage)"
  source_dir="$(cd "$(dirname "$0")" && pwd -P)"
  root="$(cd "${root}" && pwd -P)"
  version="$(cat "${root}/opt/brewau/share/VERSION")"
  tmp="$(mktemp -d /private/tmp/brewau-install.XXXXXX)"
  # Use Installer's bundle replacement, rather than following an app path in /Applications.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  /usr/bin/pkgbuild --root "${root}" --scripts "${source_dir}/scripts" \
    --component-plist "${source_dir}/app/components.plist" --identifier "${PKG_ID}" \
    --version "${version}" --install-location / --ownership recommended "${tmp}/brewau.pkg"
  /usr/sbin/installer -pkg "${tmp}/brewau.pkg" -target /
}

install_release() {
  local tmp pkg url team
  tmp="$(mktemp -d)"
  # Expand now: the EXIT trap runs after this function, when ${tmp} is gone.
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  pkg="${tmp}/brewau.pkg"
  url="https://github.com/${BREWAU_REPO}/releases/latest/download/brewau.pkg"

  echo "Downloading ${url}"
  curl -fsSL -o "${pkg}" "${url}" || die "download failed"

  # Refuse anything Gatekeeper would not accept as a notarized Developer ID installer.
  spctl --assess --type install "${pkg}" 2>/dev/null || die "package is not signed and notarized; refusing to install"
  # Any notarized Developer ID package passes spctl, so also require ours.
  team="$(pkgutil --check-signature "${pkg}" | sed -n 's/.*Developer ID Installer: .*(\(.*\)).*/\1/p' | head -1)"
  [[ "${team}" == "${BREWAU_TEAM_ID}" ]] ||
    die "package is signed by team ${team:-unknown}, expected ${BREWAU_TEAM_ID}; refusing to install"
  echo "Package signed by Developer ID team ${team}"

  echo "Installing (you will be asked for your password once)"
  sudo /usr/sbin/installer -pkg "${pkg}" -target /
  pkgutil --pkg-info "${PKG_ID}" >/dev/null || die "installation did not register ${PKG_ID}"
}

case "${1:-}" in
  --from) install_from_root "${2:?--from requires a directory}" ;;
  "") install_release ;;
  *) die "usage: install.sh [--from <staged-root>]" ;;
esac

cat <<'EOF'

brewau is installed.
  1. Run:  /opt/brewau/bin/brewau setup-shell
  2. Open a new terminal and run:  brewau doctor
EOF
