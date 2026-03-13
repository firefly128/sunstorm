#!/bin/ksh
# package-all.sh — Create SVR4 .pkg.Z for ALL sunstorm userland packages
# Runs on Solaris 7. Scans /opt/sst and creates individual packages.
#
# Usage: /bin/ksh package-all.sh [output_dir]

set -e

SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
PKGMETA="${SCRIPTDIR}/packages"
OUTPUT="${1:-/tmp/sunstorm-output}"
PREFIX="/opt/sst"
TMPDIR=/tmp/sst-pkgall-$$
SPOOLDIR="${TMPDIR}/spool"
LISTS="${TMPDIR}/lists"

mkdir -p "${OUTPUT}" "${TMPDIR}" "${LISTS}"

echo "============================================"
echo "  Sunstorm Full SVR4 Packager"
echo "  Install root : ${PREFIX}"
echo "  Output       : ${OUTPUT}"
echo "============================================"
echo ""

# --- Preflight ---
if [ "$(uname -s)" != "SunOS" ]; then
    echo "ERROR: Must run on Solaris." >&2; exit 1
fi

# ============================================================
# make_pkg — generic SVR4 package builder
# ============================================================
make_pkg() {
    _code="$1"; _filelist="$2"; _metadir="$3"

    if [ ! -f "${_metadir}/pkginfo" ]; then
        echo "  ERROR: No pkginfo in ${_metadir}" >&2
        return 1
    fi

    # Deduplicate file list (ksh88 + find can produce dupes)
    sort -u "${_filelist}" > "${_filelist}.tmp" && mv "${_filelist}.tmp" "${_filelist}"

    # Count real files
    _count=0
    while IFS= read -r _line; do
        case "$_line" in \#*|"") continue ;; esac
        [ -e "${PREFIX}/${_line}" -o -L "${PREFIX}/${_line}" ] && _count=$((_count + 1))
    done < "${_filelist}"

    _name=$(grep '^NAME=' "${_metadir}/pkginfo" | sed 's/NAME="\{0,1\}\([^"]*\)"\{0,1\}/\1/')
    _ver=$(grep '^VERSION=' "${_metadir}/pkginfo" | sed 's/VERSION="\{0,1\}\([^,"]*\).*/\1/')

    if [ ${_count} -eq 0 ]; then
        echo "--- ${_code}: ${_name} v${_ver} --- SKIPPED (no files)"
        return 0
    fi

    echo "--- ${_code}: ${_name} v${_ver} (${_count} files) ---"

    _stagedir="${TMPDIR}/${_code}"
    rm -rf "${_stagedir}"
    mkdir -p "${_stagedir}"

    # pkginfo with timestamp
    sed "s/^PSTAMP=.*/PSTAMP=$(hostname)$(date '+%Y%m%d%H%M%S')/" \
        "${_metadir}/pkginfo" > "${_stagedir}/pkginfo"
    # Add PSTAMP if not present
    grep -s 'PSTAMP=' "${_stagedir}/pkginfo" > /dev/null 2>&1 || \
        echo "PSTAMP=$(hostname)$(date '+%Y%m%d%H%M%S')" >> "${_stagedir}/pkginfo"

    # Copy packaging scripts
    for _script in depend postinstall preinstall postremove preremove; do
        [ -f "${_metadir}/${_script}" ] && cp "${_metadir}/${_script}" "${_stagedir}/${_script}"
    done

    # Generate prototype
    {
        echo "i pkginfo"
        for _script in depend postinstall preinstall postremove preremove; do
            [ -f "${_stagedir}/${_script}" ] && echo "i ${_script}"
        done
        while IFS= read -r _line; do
            case "$_line" in \#*|"") continue ;; esac
            _fullpath="${PREFIX}/${_line}"
            if [ -L "$_fullpath" ]; then
                _target=$(ls -l "$_fullpath" | sed 's/.*-> //')
                echo "s none ${_line}=${_target}"
            elif [ -d "$_fullpath" ]; then
                echo "d none ${_line} 0755 root bin"
            elif [ -x "$_fullpath" ]; then
                echo "f none ${_line} 0755 root bin"
            elif [ -f "$_fullpath" ]; then
                echo "f none ${_line} 0644 root bin"
            fi
        done < "${_filelist}"
    } > "${_stagedir}/prototype"

    # pkgmk + pkgtrans
    rm -rf "${SPOOLDIR}"
    mkdir -p "${SPOOLDIR}"
    if ! pkgmk -o -d "${SPOOLDIR}" -r "${PREFIX}" -f "${_stagedir}/prototype" 2>&1; then
        echo "  ERROR: pkgmk failed" >&2
        return 1
    fi
    _pkgfile="${OUTPUT}/${_code}-${_ver}-sparc.pkg"
    rm -f "${_pkgfile}" "${_pkgfile}.Z"
    if ! pkgtrans -s "${SPOOLDIR}" "${_pkgfile}" "${_code}" 2>&1; then
        echo "  ERROR: pkgtrans failed" >&2
        return 1
    fi
    compress "${_pkgfile}"
    _size=$(ls -l "${_pkgfile}.Z" | awk '{print $5}')
    echo "  -> $(basename ${_pkgfile}.Z) (${_size} bytes)"
}

# ============================================================
# File lists — map each package to its files under /opt/sst
# ============================================================

# Helper: find libs by pattern (no -maxdepth on Solaris)
find_libs() {
    _pat="$1"
    ls -d ${PREFIX}/lib/${_pat} 2>/dev/null | while read _f; do
        [ -f "$_f" -o -L "$_f" ] && echo "$_f" | sed "s|^${PREFIX}/||"
    done | sort
}

# --- SSTlsolc: libsolcompat ---
{
    find_libs 'libsolcompat.*'
    [ -d "${PREFIX}/include/solcompat" ] && \
        find "${PREFIX}/include/solcompat" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/include/override" ] && \
        find "${PREFIX}/include/override" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/libsolcompat"

# --- SSTzlib: zlib ---
{
    find_libs 'libz.*'
    for f in include/zlib.h include/zconf.h; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libz.a'
    [ -f "${PREFIX}/lib/pkgconfig/zlib.pc" ] && echo "lib/pkgconfig/zlib.pc"
} > "${LISTS}/zlib"

# --- SSTbz2: bzip2 ---
{
    for f in bin/bzip2 bin/bunzip2 bin/bzcat bin/bzip2recover; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libbz2.*'
    [ -f "${PREFIX}/include/bzlib.h" ] && echo "include/bzlib.h"
} > "${LISTS}/bzip2"

# --- SSTxz: xz ---
{
    for f in bin/xz bin/unxz bin/xzcat bin/lzma bin/unlzma bin/lzcat \
             bin/xzdec bin/lzmadec bin/xzcmp bin/xzdiff bin/xzegrep \
             bin/xzfgrep bin/xzgrep bin/xzless bin/xzmore \
             bin/lzcmp bin/lzdiff bin/lzegrep bin/lzfgrep bin/lzgrep \
             bin/lzless bin/lzmore bin/lzmainfo; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'liblzma.*'
    [ -f "${PREFIX}/include/lzma.h" ] && echo "include/lzma.h"
    [ -d "${PREFIX}/include/lzma" ] && \
        find "${PREFIX}/include/lzma" -type f | sed "s|^${PREFIX}/||"
    [ -f "${PREFIX}/lib/pkgconfig/liblzma.pc" ] && echo "lib/pkgconfig/liblzma.pc"
} > "${LISTS}/xz"

# --- SSTncurs: ncurses ---
{
    for f in bin/clear bin/infocmp bin/tic bin/toe bin/tput bin/tset \
             bin/reset bin/tabs bin/captoinfo bin/infotocap bin/ncursesw6-config; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    for pat in 'libncurses*' 'libform*' 'libmenu*' 'libpanel*' 'libtinfo*' \
               'libncursesw*' 'libformw*' 'libmenuw*' 'libpanelw*' 'libtinfow*'; do
        find_libs "$pat"
    done
    [ -d "${PREFIX}/include/ncursesw" ] && \
        find "${PREFIX}/include/ncursesw" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/terminfo" ] && \
        find "${PREFIX}/share/terminfo" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/tabset" ] && \
        find "${PREFIX}/share/tabset" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    for f in lib/pkgconfig/ncursesw.pc lib/pkgconfig/formw.pc \
             lib/pkgconfig/menuw.pc lib/pkgconfig/panelw.pc; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/ncurses"

# --- SSTrdln: readline ---
{
    find_libs 'libreadline.*'
    find_libs 'libhistory.*'
    [ -d "${PREFIX}/include/readline" ] && \
        find "${PREFIX}/include/readline" -type f | sed "s|^${PREFIX}/||"
} > "${LISTS}/readline"

# --- SSTpcre2: pcre2 ---
{
    for f in bin/pcre2grep bin/pcre2test bin/pcre2-config; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libpcre2*'
    for f in include/pcre2.h include/pcre2posix.h; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -f "${PREFIX}/lib/pkgconfig/libpcre2-8.pc" ] && echo "lib/pkgconfig/libpcre2-8.pc"
} > "${LISTS}/pcre2"

# --- SSTbash: bash ---
{
    for f in bin/bash bin/sh; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/bash"

# --- SSTcorut: coreutils ---
{
    for f in \[ b2sum base32 base64 basename basenc cat chcon chgrp chmod chown \
             chroot cksum comm coreutils cp csplit cut date dd df dir dircolors \
             dirname du echo env expand expr factor false fmt fold groups head \
             hostid id install join kill link ln logname ls md5sum mkdir mkfifo \
             mknod mktemp mv nice nl nohup nproc numfmt od paste pathchk pinky \
             pr printenv printf ptx pwd readlink realpath rm rmdir runcon seq \
             sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf sleep sort \
             split stat stdbuf stty sum sync tac tail tee test timeout touch tr \
             true truncate tsort tty uname unexpand uniq unlink uptime users vdir \
             wc who whoami yes; do
        [ -f "${PREFIX}/bin/$f" -o -L "${PREFIX}/bin/$f" ] && echo "bin/$f"
    done
    [ -d "${PREFIX}/libexec/coreutils" ] && \
        find "${PREFIX}/libexec/coreutils" -type f | sed "s|^${PREFIX}/||"
} > "${LISTS}/coreutils"

# --- SSTgawk: gawk ---
{
    for f in bin/gawk bin/awk bin/gawk-5.3.0 bin/gawkbug; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/lib/gawk" ] && \
        find "${PREFIX}/lib/gawk" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/awk" ] && \
        find "${PREFIX}/share/awk" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/libexec/awk" ] && \
        find "${PREFIX}/libexec/awk" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/gawk"

# --- SSTgrep: grep ---
{
    for f in bin/grep bin/egrep bin/fgrep; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/grep"

# --- SSTsed: sed ---
{ [ -f "${PREFIX}/bin/sed" ] && echo "bin/sed"; } > "${LISTS}/sed"

# --- SSTtar: tar ---
{ [ -f "${PREFIX}/bin/tar" ] && echo "bin/tar"; } > "${LISTS}/tar"

# -- SSTgzip: gzip ---
{
    for f in bin/gzip bin/gunzip bin/gzexe bin/uncompress bin/zcat \
             bin/zcmp bin/zdiff bin/zegrep bin/zfgrep bin/zforce \
             bin/zgrep bin/zless bin/zmore bin/znew; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/gzip"

# --- SSTless: less ---
{
    for f in bin/less bin/lessecho bin/lesskey; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/less"

# --- SSTpatch: patch ---
{ [ -f "${PREFIX}/bin/patch" ] && echo "bin/patch"; } > "${LISTS}/patch"

# --- SSTdiffu: diffutils ---
{
    for f in bin/diff bin/diff3 bin/sdiff bin/cmp; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/diffutils"

# --- SSTfindu: findutils ---
{
    for f in bin/find bin/xargs bin/locate bin/updatedb; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/libexec/frcode" ] && echo "libexec/frcode"
} > "${LISTS}/findutils"

# --- SSTmake: make ---
{ [ -f "${PREFIX}/bin/make" ] && echo "bin/make"; } > "${LISTS}/make"

# --- SSTm4: m4 ---
{ [ -f "${PREFIX}/bin/m4" ] && echo "bin/m4"; } > "${LISTS}/m4"

# --- SSTaconf: autoconf ---
{
    for f in bin/autoconf bin/autoheader bin/autom4te bin/autoreconf \
             bin/autoscan bin/autoupdate bin/ifnames; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/autoconf" ] && \
        find "${PREFIX}/share/autoconf" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/autoconf"

# --- SSTamake: automake ---
{
    for f in bin/automake bin/aclocal bin/automake-1.16 bin/aclocal-1.16; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/automake-1.16" ] && \
        find "${PREFIX}/share/automake-1.16" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/aclocal-1.16" ] && \
        find "${PREFIX}/share/aclocal-1.16" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/aclocal" ] && \
        find "${PREFIX}/share/aclocal" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/automake"

# --- SSTltool: libtool ---
{
    for f in bin/libtool bin/libtoolize; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libltdl.*'
    [ -f "${PREFIX}/include/ltdl.h" ] && echo "include/ltdl.h"
    [ -d "${PREFIX}/include/libltdl" ] && \
        find "${PREFIX}/include/libltdl" -type f | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/libtool" ] && \
        find "${PREFIX}/share/libtool" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/libtool"

# --- SSTpkgcf: pkgconf ---
{
    for f in bin/pkgconf bin/pkg-config; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libpkgconf.*'
    [ -d "${PREFIX}/include/pkgconf" ] && \
        find "${PREFIX}/include/pkgconf" -type f | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/pkgconfig" ] && \
        find "${PREFIX}/share/pkgconfig" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/pkgconf"

# --- SSTossl: openssl ---
{
    [ -f "${PREFIX}/bin/openssl" ] && echo "bin/openssl"
    find_libs 'libssl.*'
    find_libs 'libcrypto.*'
    [ -d "${PREFIX}/lib/engines-3" ] && \
        find "${PREFIX}/lib/engines-3" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/include/openssl" ] && \
        find "${PREFIX}/include/openssl" -type f | sed "s|^${PREFIX}/||"
    for f in lib/pkgconfig/openssl.pc lib/pkgconfig/libssl.pc lib/pkgconfig/libcrypto.pc; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/etc/ssl" ] && \
        find "${PREFIX}/etc/ssl" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/openssl"

# --- SSTcurl: curl ---
{
    for f in bin/curl bin/curl-config; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libcurl.*'
    [ -d "${PREFIX}/include/curl" ] && \
        find "${PREFIX}/include/curl" -type f | sed "s|^${PREFIX}/||"
    [ -f "${PREFIX}/lib/pkgconfig/libcurl.pc" ] && echo "lib/pkgconfig/libcurl.pc"
} > "${LISTS}/curl"

# --- SSTwget: wget ---
{ [ -f "${PREFIX}/bin/wget" ] && echo "bin/wget"; } > "${LISTS}/wget"

# --- SSTossh: openssh ---
{
    for f in bin/ssh bin/scp bin/sftp bin/ssh-add bin/ssh-agent \
             bin/ssh-keygen bin/ssh-keyscan; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    for f in sbin/sshd; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/libexec" ] && \
        find "${PREFIX}/libexec" -name 'ssh*' -type f 2>/dev/null | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/etc/ssh" ] && \
        find "${PREFIX}/etc/ssh" -type f 2>/dev/null | sed "s|^${PREFIX}/||"
} > "${LISTS}/openssh"

# --- SSTprngd: prngd ---
{
    for f in sbin/prngd; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    for f in etc/prngd.conf etc/prngd-seed; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/prngd"

# --- SSTexpat: expat ---
{
    [ -f "${PREFIX}/bin/xmlwf" ] && echo "bin/xmlwf"
    find_libs 'libexpat.*'
    [ -f "${PREFIX}/include/expat.h" ] && echo "include/expat.h"
    [ -f "${PREFIX}/include/expat_external.h" ] && echo "include/expat_external.h"
    [ -f "${PREFIX}/lib/pkgconfig/expat.pc" ] && echo "lib/pkgconfig/expat.pc"
} > "${LISTS}/expat"

# --- SSTliconv: libiconv ---
{
    [ -f "${PREFIX}/bin/iconv" ] && echo "bin/iconv"
    find_libs 'libiconv.*'
    find_libs 'libcharset.*'
    [ -f "${PREFIX}/include/iconv.h" ] && echo "include/iconv.h"
    [ -f "${PREFIX}/include/libcharset.h" ] && echo "include/libcharset.h"
    [ -f "${PREFIX}/include/localcharset.h" ] && echo "include/localcharset.h"
    [ -f "${PREFIX}/lib/charset.alias" ] && echo "lib/charset.alias"
} > "${LISTS}/libiconv"

# --- SSTbison: bison ---
{
    for f in bin/bison bin/yacc; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/bison" ] && \
        find "${PREFIX}/share/bison" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    find_libs 'liby.*'
} > "${LISTS}/bison"

# --- SSTflex: flex ---
{
    for f in bin/flex bin/lex bin/flex++; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libfl.*'
    [ -f "${PREFIX}/include/FlexLexer.h" ] && echo "include/FlexLexer.h"
} > "${LISTS}/flex"

# --- SSTgtxt: gettext ---
{
    for f in bin/gettext bin/ngettext bin/msgfmt bin/msgmerge bin/msgunfmt \
             bin/msgcat bin/msgconv bin/msggrep bin/msginit bin/msgattrib \
             bin/msgcmp bin/msgcomm bin/msgen bin/msgexec bin/msgfilter \
             bin/msguniq bin/xgettext bin/gettextize bin/autopoint \
             bin/envsubst bin/gettext.sh bin/recode-sr-latin; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libintl.*'
    find_libs 'libgettextlib*'
    find_libs 'libgettextsrc*'
    find_libs 'libasprintf*'
    find_libs 'libtextstyle*'
    [ -d "${PREFIX}/lib/gettext" ] && \
        find "${PREFIX}/lib/gettext" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -f "${PREFIX}/include/gettext-po.h" ] && echo "include/gettext-po.h"
    [ -f "${PREFIX}/include/autosprintf.h" ] && echo "include/autosprintf.h"
    [ -f "${PREFIX}/include/libintl.h" ] && echo "include/libintl.h"
    [ -f "${PREFIX}/include/textstyle.h" ] && echo "include/textstyle.h"
    [ -d "${PREFIX}/include/textstyle" ] && \
        find "${PREFIX}/include/textstyle" -type f | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/gettext" ] && \
        find "${PREFIX}/share/gettext" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/gettext"

# --- SSTperl: perl ---
{
    for f in bin/perl bin/perl5.36.3 bin/cpan bin/corelist bin/encguess \
             bin/enc2xs bin/h2ph bin/h2xs bin/instmodsh bin/json_pp \
             bin/libnetcfg bin/perldoc bin/perlbug bin/perlivp bin/perlthanks \
             bin/piconv bin/pl2pm bin/pod2html bin/pod2man bin/pod2text \
             bin/pod2usage bin/podchecker bin/prove bin/ptar bin/ptardiff \
             bin/ptargrep bin/shasum bin/splain bin/streamzip bin/xsubpp \
             bin/zipdetails; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/lib/perl5" ] && \
        find "${PREFIX}/lib/perl5" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/perl"

# --- SSTtxinf: texinfo ---
{
    for f in bin/makeinfo bin/texi2any bin/texi2dvi bin/texi2pdf \
             bin/texindex bin/pdftexi2dvi bin/pod2texi bin/install-info; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/texinfo" ] && \
        find "${PREFIX}/share/texinfo" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/texinfo"

# --- SSTgit: git ---
{
    for f in bin/git bin/git-receive-pack bin/git-upload-pack \
             bin/git-upload-archive bin/git-shell bin/git-cvsserver; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/libexec/git-core" ] && \
        find "${PREFIX}/libexec/git-core" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/git-core" ] && \
        find "${PREFIX}/share/git-core" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -d "${PREFIX}/share/gitweb" ] && \
        find "${PREFIX}/share/gitweb" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/git"

# --- SSTvim: vim ---
{
    for f in bin/vim bin/vi bin/view bin/ex bin/rview bin/rvim \
             bin/vimdiff bin/vimtutor bin/xxd; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/vim" ] && \
        find "${PREFIX}/share/vim" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/vim"

# --- SSTscrn: screen ---
{
    for f in bin/screen bin/screen-4.9.1; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/screen" ] && \
        find "${PREFIX}/share/screen" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
    [ -f "${PREFIX}/etc/screenrc" ] && echo "etc/screenrc"
} > "${LISTS}/screen"

# --- SSTlpng: libpng ---
{
    for f in bin/libpng-config bin/libpng16-config bin/png-fix-itxt bin/pngfix; do
        [ -f "${PREFIX}/$f" -o -L "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libpng*'
    for f in include/png.h include/pngconf.h include/pnglibconf.h; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/include/libpng16" ] && \
        find "${PREFIX}/include/libpng16" -type f | sed "s|^${PREFIX}/||"
    [ -f "${PREFIX}/lib/pkgconfig/libpng.pc" ] && echo "lib/pkgconfig/libpng.pc"
    [ -f "${PREFIX}/lib/pkgconfig/libpng16.pc" ] && echo "lib/pkgconfig/libpng16.pc"
} > "${LISTS}/libpng"

# --- SSTjpeg: libjpeg ---
{
    for f in bin/cjpeg bin/djpeg bin/jpegtran bin/rdjpgcom bin/wrjpgcom; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    find_libs 'libjpeg.*'
    for f in include/jpeglib.h include/jconfig.h include/jerror.h include/jmorecfg.h; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
} > "${LISTS}/libjpeg"

# --- SSTutf8p: libutf8proc ---
{
    find_libs 'libutf8proc.*'
    [ -f "${PREFIX}/include/utf8proc.h" ] && echo "include/utf8proc.h"
} > "${LISTS}/libutf8proc"

# --- SSTnsurf: netsurf (skip framebuffer, only monkey or actual binary) ---
{
    for f in bin/netsurf bin/netsurf-fb bin/netsurf-monkey; do
        [ -f "${PREFIX}/$f" ] && echo "$f"
    done
    [ -d "${PREFIX}/share/netsurf" ] && \
        find "${PREFIX}/share/netsurf" \( -type f -o -type l \) | sed "s|^${PREFIX}/||"
} > "${LISTS}/netsurf"

# --- SSTgmp: gmp ---
{
    find_libs 'libgmp.*'
    find_libs 'libgmpxx.*'
    [ -f "${PREFIX}/include/gmp.h" ] && echo "include/gmp.h"
    [ -f "${PREFIX}/include/gmpxx.h" ] && echo "include/gmpxx.h"
} > "${LISTS}/gmp"

# --- SSTmpfr: mpfr ---
{
    find_libs 'libmpfr.*'
    [ -f "${PREFIX}/include/mpfr.h" ] && echo "include/mpfr.h"
    [ -f "${PREFIX}/include/mpf2mpfr.h" ] && echo "include/mpf2mpfr.h"
} > "${LISTS}/mpfr"

# --- SSTmpc: mpc ---
{
    find_libs 'libmpc.*'
    [ -f "${PREFIX}/include/mpc.h" ] && echo "include/mpc.h"
} > "${LISTS}/mpc"

# --- SSTbinut: binutils (already built by package-installed.sh, skip) ---
# --- SSTlgcc: libgcc (already built by package-installed.sh, skip) ---
# --- SSTgcc: gcc 11 (already built by package-gcc11.sh, skip) ---

# ============================================================
# Build all packages
# ============================================================
echo ""
echo "Building SVR4 packages..."
echo ""

# Mapping: list-name -> pkg-code -> metadata-dir
for entry in \
    "libsolcompat|SSTlsolc|libsolcompat" \
    "zlib|SSTzlib|zlib" \
    "bzip2|SSTbz2|bzip2" \
    "xz|SSTxz|xz" \
    "ncurses|SSTncurs|ncurses" \
    "readline|SSTrdln|readline" \
    "pcre2|SSTpcre2|pcre2" \
    "bash|SSTbash|bash" \
    "coreutils|SSTcorut|coreutils" \
    "gawk|SSTgawk|gawk" \
    "grep|SSTgrep|grep" \
    "sed|SSTsed|sed" \
    "tar|SSTtar|tar" \
    "gzip|SSTgzip|gzip" \
    "less|SSTless|less" \
    "patch|SSTpatch|patch" \
    "diffutils|SSTdiffu|diffutils" \
    "findutils|SSTfindu|findutils" \
    "make|SSTmake|make" \
    "m4|SSTm4|m4" \
    "autoconf|SSTaconf|autoconf" \
    "automake|SSTamake|automake" \
    "libtool|SSTltool|libtool" \
    "pkgconf|SSTpkgcf|pkgconf" \
    "openssl|SSTossl|openssl" \
    "curl|SSTcurl|curl" \
    "wget|SSTwget|wget" \
    "openssh|SSTossh|openssh" \
    "prngd|SSTprngd|prngd" \
    "expat|SSTexpat|expat" \
    "libiconv|SSTliconv|libiconv" \
    "bison|SSTbison|bison" \
    "flex|SSTflex|flex" \
    "gettext|SSTgtxt|gettext" \
    "perl|SSTperl|perl" \
    "texinfo|SSTtxinf|texinfo" \
    "git|SSTgit|git" \
    "vim|SSTvim|vim" \
    "screen|SSTscrn|screen" \
    "libpng|SSTlpng|libpng" \
    "libjpeg|SSTjpeg|libjpeg" \
    "libutf8proc|SSTutf8p|libutf8proc" \
    "netsurf|SSTnsurf|netsurf" \
    "gmp|SSTgmp|gmp" \
    "mpfr|SSTmpfr|mpfr" \
    "mpc|SSTmpc|mpc" \
; do
    _listname=$(echo "$entry" | cut -d'|' -f1)
    _pkgcode=$(echo "$entry" | cut -d'|' -f2)
    _metaname=$(echo "$entry" | cut -d'|' -f3)
    make_pkg "$_pkgcode" "${LISTS}/${_listname}" "${PKGMETA}/${_metaname}"
done

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  Package build complete"
echo "============================================"
echo ""

_total=0
for f in "${OUTPUT}"/*.pkg.Z; do
    [ -f "$f" ] || continue
    _total=$((_total + 1))
    _size=$(ls -l "$f" | awk '{print $5}')
    printf "  %-45s %s\n" "$(basename "$f")" "${_size}"
done

echo ""
echo "  Total: ${_total} packages in ${OUTPUT}/"
echo ""

# Cleanup
rm -rf "${TMPDIR}"
