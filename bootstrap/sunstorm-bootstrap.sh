#!/bin/sh
# sunstorm-bootstrap.sh — Bootstrap installer for Sunstorm on Solaris 7 SPARC
#
# This script installs the minimal set of packages required to get
# spm (Sunstorm Package Manager) running.  After bootstrap, spm can
# pull the rest of the distribution from the Sunstorm repository.
#
# Bootstrap chain (installed in order):
#   1. SSTzlib   - zlib compression library
#   2. SSTlsolc  - POSIX/C99 compatibility shim
#   3. SSTprngd  - Pseudo-random number generator daemon (entropy for SSL)
#   4. SSTossl   - OpenSSL cryptography toolkit
#   5. SSTspm    - Sunstorm Package Manager (CLI, GUI, agent)
#
# Usage:
#   ./sunstorm-bootstrap.sh                  (packages in current dir)
#   ./sunstorm-bootstrap.sh /path/to/pkgs    (packages in specified dir)
#
# The package files should be named:
#   SSTzlib-*.pkg.Z   SSTlsolc-*.pkg.Z   SSTprngd-*.pkg.Z
#   SSTossl-*.pkg.Z   SSTspm-*.pkg.Z
#
# Copyright (c) 2026 Julian Wolfe / Sunstorm Project
# SPDX-License-Identifier: MIT

set -e

VERSION="1.0.0"
PKGDIR="${1:-.}"

# ============================================================
# Preflight checks
# ============================================================

echo ""
echo "============================================"
echo "  Sunstorm Bootstrap Installer v${VERSION}"
echo "  for Solaris 7 SPARC"
echo "============================================"
echo ""

# Must be root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root." >&2
    echo "  Try: su - root -c \"sh $0 $*\"" >&2
    exit 1
fi

# Must be Solaris / SunOS
if [ "$(uname -s)" != "SunOS" ]; then
    echo "ERROR: This script only runs on Solaris." >&2
    exit 1
fi

# Must have SPARC architecture
ARCH=$(uname -p)
if [ "$ARCH" != "sparc" ]; then
    echo "ERROR: This script requires SPARC architecture (got: ${ARCH})." >&2
    exit 1
fi

# Must have pkgadd
if ! command -v pkgadd >/dev/null 2>&1; then
    echo "ERROR: pkgadd not found — is this really Solaris?" >&2
    exit 1
fi

# ============================================================
# Locate packages
# ============================================================

BOOTSTRAP_PKGS="SSTzlib SSTlsolc SSTprngd SSTossl SSTspm"
MISSING=""

for pkg in ${BOOTSTRAP_PKGS}; do
    _file=$(ls "${PKGDIR}"/${pkg}-*.pkg.Z 2>/dev/null | head -1)
    if [ -z "${_file}" ]; then
        # Also try uncompressed
        _file=$(ls "${PKGDIR}"/${pkg}-*.pkg 2>/dev/null | head -1)
    fi
    if [ -z "${_file}" ]; then
        MISSING="${MISSING} ${pkg}"
    fi
done

if [ -n "${MISSING}" ]; then
    echo "ERROR: Missing bootstrap packages in ${PKGDIR}:" >&2
    for pkg in ${MISSING}; do
        echo "  - ${pkg}-*.pkg.Z" >&2
    done
    echo "" >&2
    echo "Download the sunstorm-bootstrap bundle from:" >&2
    echo "  https://github.com/firefly128/sunstorm/releases" >&2
    exit 1
fi

echo "Package directory: ${PKGDIR}"
echo ""

# ============================================================
# Create non-interactive pkgadd admin file
# ============================================================

ADMFILE=/tmp/sst-bootstrap-admin.$$
cat > "${ADMFILE}" << 'ADMEOF'
mail=
instance=overwrite
partial=nocheck
runlevel=nocheck
idepend=nocheck
rdepend=nocheck
space=nocheck
setuid=nocheck
conflict=nocheck
action=nocheck
basedir=default
ADMEOF

# Cleanup on exit
trap "rm -f ${ADMFILE}; exit" 0 1 2 15

# ============================================================
# Install packages in dependency order
# ============================================================

install_pkg() {
    _code="$1"
    _pkgfile=$(ls "${PKGDIR}"/${_code}-*.pkg.Z 2>/dev/null | head -1)
    _compressed=1

    if [ -z "${_pkgfile}" ]; then
        _pkgfile=$(ls "${PKGDIR}"/${_code}-*.pkg 2>/dev/null | head -1)
        _compressed=0
    fi

    if [ -z "${_pkgfile}" ]; then
        echo "  ERROR: ${_code} package not found!" >&2
        return 1
    fi

    _basename=$(basename "${_pkgfile}")
    echo "  Installing ${_basename}..."

    if [ ${_compressed} -eq 1 ]; then
        # Decompress .pkg.Z to a temporary file
        _tmpfile="/tmp/sst-bootstrap-${_code}.$$"
        uncompress -c "${_pkgfile}" > "${_tmpfile}" 2>/dev/null
        pkgadd -n -a "${ADMFILE}" -d "${_tmpfile}" all 2>&1 | sed 's/^/    /'
        rm -f "${_tmpfile}"
    else
        pkgadd -n -a "${ADMFILE}" -d "${_pkgfile}" all 2>&1 | sed 's/^/    /'
    fi

    # Verify installation
    if pkginfo -q "${_code}" 2>/dev/null; then
        echo "  OK: ${_code} installed."
    else
        echo "  WARNING: ${_code} may not have installed correctly." >&2
    fi
    echo ""
}

echo "--- Step 1/5: Installing SSTzlib (compression library) ---"
install_pkg SSTzlib

echo "--- Step 2/5: Installing SSTlsolc (POSIX/C99 compatibility) ---"
install_pkg SSTlsolc

echo "--- Step 3/5: Installing SSTprngd (entropy daemon) ---"
install_pkg SSTprngd

# Start prngd if not already running — OpenSSL needs it
if [ -x /opt/sst/sbin/prngd ]; then
    if ! pgrep -x prngd >/dev/null 2>&1; then
        echo "  Starting prngd entropy daemon..."
        /opt/sst/sbin/prngd /var/run/egd-pool 2>/dev/null &
        sleep 2
    fi
fi

echo "--- Step 4/5: Installing SSTossl (OpenSSL) ---"
install_pkg SSTossl

echo "--- Step 5/5: Installing SSTspm (Sunstorm Package Manager) ---"
install_pkg SSTspm

# ============================================================
# Post-bootstrap setup
# ============================================================

echo "============================================"
echo "  Bootstrap complete!"
echo "============================================"
echo ""

# Verify all packages
echo "Installed packages:"
for pkg in ${BOOTSTRAP_PKGS}; do
    _info=$(pkginfo "${pkg}" 2>/dev/null | awk '{$1=""; $2=""; print}' | sed 's/^  //')
    if [ -n "${_info}" ]; then
        printf "  %-10s %s\n" "${pkg}" "${_info}"
    else
        printf "  %-10s NOT INSTALLED\n" "${pkg}"
    fi
done
echo ""

echo "Next steps:"
echo ""
echo "  1. Add spm to your PATH:"
echo "     PATH=/opt/sst/bin:\$PATH; export PATH"
echo ""
echo "  2. Update the package index:"
echo "     spm update"
echo ""
echo "  3. Install the rest of the distribution:"
echo "     spm install bash coreutils gcc openssh"
echo ""
echo "  4. Or launch the GUI:"
echo "     spm-gui"
echo ""
echo "  For the full Sunstorm experience:"
echo "     spm install bash coreutils grep sed gawk findutils \\"
echo "       diffutils make gcc curl wget git vim less screen"
echo ""
