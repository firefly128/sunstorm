#!/bin/sh
# make-bootstrap.sh — Build the Sunstorm bootstrap bundle
#
# Collects the 5 bootstrap packages (SSTzlib, SSTlsolc, SSTprngd,
# SSTossl, SSTspm) and the bootstrap installer script into a single
# self-contained tarball for distribution.
#
# Usage:
#   ./make-bootstrap.sh [package_dir] [output_dir]
#
# The resulting tarball can be transferred to a fresh Solaris 7 system
# and extracted + run:
#   uncompress sunstorm-bootstrap-1.0.0.tar.Z
#   tar xf sunstorm-bootstrap-1.0.0.tar
#   cd sunstorm-bootstrap-1.0.0
#   sh sunstorm-bootstrap.sh

set -e

VERSION="1.0.0"
BASEDIR="$(cd "$(dirname "$0")" && pwd)"

PKGDIR="${1:-${BASEDIR}/../output}"
OUTDIR="${2:-${BASEDIR}/../output}"

BUNDLENAME="sunstorm-bootstrap-${VERSION}"
STAGING="/tmp/${BUNDLENAME}-$$"

echo "============================================"
echo "  Sunstorm Bootstrap Bundle Builder"
echo "  Version: ${VERSION}"
echo "============================================"
echo ""

# ============================================================
# Locate required packages
# ============================================================

BOOTSTRAP_PKGS="SSTzlib SSTlsolc SSTprngd SSTossl SSTspm"
FOUND=0
MISSING=""

for pkg in ${BOOTSTRAP_PKGS}; do
    _file=$(ls "${PKGDIR}"/${pkg}-*.pkg.Z 2>/dev/null | head -1)
    if [ -n "${_file}" ]; then
        FOUND=$((FOUND + 1))
        echo "  Found: $(basename "${_file}")"
    else
        MISSING="${MISSING} ${pkg}"
    fi
done
echo ""

if [ -n "${MISSING}" ]; then
    echo "WARNING: Missing packages:${MISSING}"
    echo "The bootstrap bundle will be incomplete."
    echo "Build the missing packages first, then re-run."
    echo ""
fi

if [ ${FOUND} -eq 0 ]; then
    echo "ERROR: No bootstrap packages found in ${PKGDIR}"
    echo "Build packages first with make-packages.sh or package-installed.sh"
    exit 1
fi

# ============================================================
# Build the bundle
# ============================================================

rm -rf "${STAGING}"
mkdir -p "${STAGING}"

# Copy bootstrap installer script
cp "${BASEDIR}/sunstorm-bootstrap.sh" "${STAGING}/"
chmod 755 "${STAGING}/sunstorm-bootstrap.sh"

# Copy available packages
for pkg in ${BOOTSTRAP_PKGS}; do
    _file=$(ls "${PKGDIR}"/${pkg}-*.pkg.Z 2>/dev/null | head -1)
    if [ -n "${_file}" ]; then
        cp "${_file}" "${STAGING}/"
    fi
done

# Create a README
cat > "${STAGING}/README" << 'EOF'
Sunstorm Bootstrap Bundle
==========================

This bundle contains the minimal packages needed to bootstrap
the Sunstorm distribution on a fresh Solaris 7 SPARC system.

Quick Start:
  1. As root, run:   sh sunstorm-bootstrap.sh
  2. Then:           PATH=/opt/sst/bin:$PATH; export PATH
  3. Then:           spm update && spm install bash gcc curl

What's Inside:
  SSTzlib   - zlib compression library
  SSTlsolc  - POSIX/C99 compatibility shim
  SSTprngd  - Pseudo-random number generator daemon
  SSTossl   - OpenSSL cryptography toolkit
  SSTspm    - Sunstorm Package Manager

After these 5 packages are installed, spm can fetch and install
any of the 60+ packages in the Sunstorm distribution via HTTPS.

More info: https://github.com/firefly128/sunstorm
EOF

# Create tarball (use compress for Solaris compatibility)
mkdir -p "${OUTDIR}"

echo "Creating bootstrap bundle..."
TARFILE="${OUTDIR}/${BUNDLENAME}.tar"

# Create tar — cd to parent so the archive extracts to a directory
(cd /tmp && tar cf "${TARFILE}" "${BUNDLENAME}-$$")
# Rename the top-level dir in the tar to the proper name
# Actually, easier to just use the proper directory name
rm -rf "/tmp/${BUNDLENAME}"
mv "${STAGING}" "/tmp/${BUNDLENAME}"
(cd /tmp && tar cf "${TARFILE}" "${BUNDLENAME}")
rm -rf "/tmp/${BUNDLENAME}"

# Compress with compress for Solaris 7 compatibility
if command -v compress >/dev/null 2>&1; then
    compress -f "${TARFILE}" 2>/dev/null && TARFILE="${TARFILE}.Z"
elif command -v gzip >/dev/null 2>&1; then
    gzip -9 "${TARFILE}" && TARFILE="${TARFILE}.gz"
fi

_size=$(ls -lh "${TARFILE}" 2>/dev/null | awk '{print $5}')
echo ""
echo "Bootstrap bundle created:"
echo "  ${TARFILE} (${_size})"
echo ""
echo "Transfer to Solaris 7 and run:"
if echo "${TARFILE}" | grep -q '\.Z$'; then
    echo "  uncompress $(basename "${TARFILE}")"
    echo "  tar xf ${BUNDLENAME}.tar"
elif echo "${TARFILE}" | grep -q '\.gz$'; then
    echo "  gzip -d $(basename "${TARFILE}")"
    echo "  tar xf ${BUNDLENAME}.tar"
else
    echo "  tar xf $(basename "${TARFILE}")"
fi
echo "  cd ${BUNDLENAME}"
echo "  sh sunstorm-bootstrap.sh"
echo ""
