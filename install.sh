#!/bin/bash
# brewau installer.
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kastruppro/brewau/main/install.sh)"
#       downloads the latest signed, notarized .pkg and installs it.
#
#   sudo ./install.sh --from build/root
#       installs a staged checkout (make install), for development.

set -euo pipefail

BREWAU_REPO="${BREWAU_REPO:-kastruppro/brewau}"
PKG_ID="com.kastruppro.brewau"

die() {
  echo "install.sh: $*" >&2
  exit 1
}

install_from_root() {
  local root="$1"
  [[ "$(id -u)" -eq 0 ]] || die "--from must run as root"
  [[ -x "${root}/opt/brewau/libexec/brewau-setup" ]] || die "${root} is not a staged brewau root (run: make stage)"
  /bin/bash "$(dirname "$0")/scripts/preinstall"
  ditto "${root}/opt/brewau" /opt/brewau
  chown -R root:wheel /opt/brewau/bin /opt/brewau/libexec /opt/brewau/share
  /opt/brewau/libexec/brewau-setup install
}

install_release() {
  local tmp pkg url team
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  pkg="${tmp}/brewau.pkg"
  url="https://github.com/${BREWAU_REPO}/releases/latest/download/brewau.pkg"

  echo "Downloading ${url}"
  curl -fsSL -o "${pkg}" "${url}" || die "download failed"

  # Refuse anything Gatekeeper would not accept as a notarized Developer ID installer.
  spctl --assess --type install "${pkg}" 2>/dev/null || die "package is not signed and notarized; refusing to install"
  team="$(pkgutil --check-signature "${pkg}" | sed -n 's/.*Developer ID Installer: .*(\(.*\)).*/\1/p' | head -1)"
  echo "Package signed by Developer ID team ${team:-unknown}"

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
