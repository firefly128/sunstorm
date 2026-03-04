#!/bin/sh
# build-all.sh — Build all Sunstorm packages from cross-build staging
#
# This is the top-level build orchestrator. It:
# 1. Runs the cross-build to produce the staging directory
# 2. Splits staging into individual package trees
# 3. Creates SVR4 packages (or tarballs if not on Solaris)
#
# Usage: ./build-all.sh
#        ./build-all.sh --split-only    (skip cross-build, just split)
#        ./build-all.sh --pkg-only      (create .pkg from existing split)

set -e

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
STAGING="/opt/staging"
OUTPUT="/opt/cross-build/output/packages"

. "${BASEDIR}/lib/sst-common.sh"

echo "============================================"
echo "  Sunstorm ${SST_VERSION} — Full Build"
echo "  Target: ${SST_TARGET}"
echo "============================================"
echo ""

case "$1" in
    --split-only)
        echo "Skipping cross-build, splitting existing staging..."
        ;;
    --pkg-only)
        echo "Creating packages from existing split..."
        exec "${BASEDIR}/make-packages.sh" "${OUTPUT}"
        ;;
    *)
        echo "Phase 1: Cross-build"
        echo "  (Use sparc-build-host cross-build infrastructure)"
        echo "  Run: docker compose run --rm solaris-cross-build"
        echo ""
        echo "Phase 2: Package split"
        ;;
esac

# Split staging into individual packages
"${BASEDIR}/split-staging.sh" "${STAGING}" "${OUTPUT}"

echo ""
echo "Phase 3: Package creation"
echo ""

# Generate tarballs (or SVR4 packages on Solaris)
for _pkgdir in "${OUTPUT}"/*/; do
    [ -d "${_pkgdir}root" ] || continue
    _name=$(basename "$_pkgdir")
    _pkg=$(grep '^PKG=' "${_pkgdir}/pkginfo" | sed 's/PKG="*\([^"]*\)"*/\1/')
    _ver=$(grep '^VERSION=' "${_pkgdir}/pkginfo" | sed 's/VERSION="*\([^"]*\)"*/\1/' | cut -d, -f1)
    _tarball="${OUTPUT}/${_pkg}-${_ver}-1.sst-${SST_OS}-${SST_ARCH}.tar.gz"

    echo "  Creating: $(basename "$_tarball")"
    tar czf "$_tarball" -C "${_pkgdir}root" .
done

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "Packages in: ${OUTPUT}/"
ls -lh "${OUTPUT}"/*.tar.gz 2>/dev/null || echo "  (no packages built)"
