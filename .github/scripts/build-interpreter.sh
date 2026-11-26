#!/bin/sh
# Builds the standalone PHP interpreters for Linux and macOS (the
# php-php{ver}-{ts}-{linux,macos}-{arch} release assets): a PHP CLI with
# php_debugger compiled in, built with StaticPHP (static-php-cli) v3 on a GitHub
# runner. Every library (libxml2, OpenSSL, curl, ...) is linked in statically,
# so nothing needs to be installed for it to run:
# - Linux: only glibc is linked dynamically, and StaticPHP's zig toolchain
#   targets glibc MAX_GLIBC, so it runs on any distro with that glibc or newer
#   (2.34: Debian 12+, Ubuntu 22.04+, RHEL 9+).
# - macOS: only the system's own libraries and frameworks are linked, built for
#   macOS MIN_MACOS and newer.
# It can still load shared extensions, which php-debugger/installer relies on
# when it keeps a replaced PHP's extensions.
#
# The libraries are built once per architecture instead of once per PHP version
# and thread-safety mode (they depend on neither), and cached between runs:
#   libs-prepare <key file>
#       sets up StaticPHP and its zig toolchain and downloads the library
#       sources (StaticPHP picks the latest release of each), then writes what
#       decides the build into the key file: StaticPHP's commit, the target,
#       the libraries and each download's version and hash. The workflow caches
#       the built libraries under a hash of this file, so a new library release
#       means a new build.
#   libs-build <output archive>
#       (after libs-prepare, on a cache miss) builds the libraries and packs
#       them into an archive, with StaticPHP itself (set up, with its zig)
#   php <php tarball url> <sha256> <nts|ts> <extension source dir> <output file> [libs archive]
#       builds the interpreter from the tarball and its sha256 (as resolved by
#       resolve-php-sources.py); with the archive from libs-build, StaticPHP is
#       already set up and finds the libraries built, so it only builds PHP
#       (anything missing from the archive it still builds itself)
#
# Needs GITHUB_TOKEN (StaticPHP looks up its library sources through the GitHub
# API) and MAX_GLIBC (Linux) or MIN_MACOS (macOS) in the environment, PHP 8.4+
# and composer to run StaticPHP, and on Linux re2c and gettext installed.
set -eu

MODE="$1"
shift

# The extensions the interpreter is built with; php_debugger is added below
EXTENSIONS="ctype,curl,dom,fileinfo,filter,iconv,mbstring,mysqlnd,opcache,openssl,password-argon2,pdo,pdo_sqlite,phar,posix,readline,session,simplexml,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib"
# The libraries those extensions need, built by libs-build. Keep in sync: a
# library missing here is still built by every php build, just not shared.
LIBRARIES="zlib,openssl,libiconv,xz,libxml2,libsodium,ncurses,libedit,curl,libargon2,sqlite"

OS=$(uname -s)
if [ "$OS" = Linux ]; then
    # Link against glibc instead of musl, targeting the oldest version supported.
    # With a target set, StaticPHP builds with its zig toolchain. The architecture
    # is named explicitly: "native" would also mean the runner's CPU, and zig would
    # use instructions that older CPUs (and Apple Silicon VMs) do not have.
    SPC_TARGET="$(uname -m)-linux-gnu.${MAX_GLIBC}"
    export SPC_TARGET
    TARGET_DESCRIPTION="$SPC_TARGET"
else
    # StaticPHP's default macOS target (clang for the machine's architecture,
    # whose default CPU is the architecture's baseline), for this macOS and newer
    export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
    TARGET_DESCRIPTION="macos-$(uname -m)-${MIN_MACOS}"
fi

WORK="${RUNNER_TEMP:-/tmp}/staticphp"

# The absolute path of a file that may not exist yet (the script changes directories)
abspath() {
    echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

setup_staticphp() {
    rm -rf "$WORK"
    mkdir -p "$WORK/bin"
    cd "$WORK"
    # StaticPHP v3 has no release yet, and its only prebuilt binary is an
    # unversioned nightly, so it runs from source at a pinned commit of its v3
    # branch (the first version with PHP 8.6 support), with its dependencies from
    # its composer.lock. Bump the commit by hand; switch to a release once v3 has one.
    STATICPHP_COMMIT=4193678111e6841b434348d76c94feadf7086542
    curl -fsSL --retry 3 "https://github.com/crazywhalecc/static-php-cli/archive/${STATICPHP_COMMIT}.tar.gz" | tar -xz -C "$WORK"
    mv "$WORK/static-php-cli-${STATICPHP_COMMIT}" "$WORK/staticphp-src"
    # The runner's PHP (8.4+ needed) has Xdebug enabled, which only slows
    # StaticPHP down. XDEBUG_MODE is set for these commands only: php_debugger
    # reads it too, so exporting it would also switch the debugger off in the
    # smoke test below.
    XDEBUG_MODE=off composer install --working-dir="$WORK/staticphp-src" --no-dev --no-interaction --no-progress --prefer-dist --quiet
    printf '#!/bin/sh\nXDEBUG_MODE=off exec php "%s/staticphp-src/bin/spc" "$@"\n' "$WORK" > "$WORK/bin/spc"
    chmod +x "$WORK/bin/spc"
    export PATH="$WORK/bin:$PATH"
    spc --version
}

if [ "$MODE" = libs-prepare ]; then
    KEY_FILE=$(abspath "$1")
    setup_staticphp
    spc doctor --auto-fix
    spc download --for-packages="$LIBRARIES"
    {
        echo "staticphp $STATICPHP_COMMIT"
        echo "target $TARGET_DESCRIPTION"
        echo "libraries $LIBRARIES"
        python3 -c '
import json, sys

# Every download StaticPHP recorded: an object with a "hash", at any depth
def downloads(path, node):
    if isinstance(node, dict):
        if "hash" in node:
            yield "/".join(path), node.get("version"), node.get("hash")
        for key in sorted(node):
            yield from downloads(path + [str(key)], node[key])
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from downloads(path + [str(i)], item)

for entry in downloads([], json.load(open(sys.argv[1]))):
    print(*entry)
' "$WORK/downloads/.cache.json"
    } > "$KEY_FILE"
    cat "$KEY_FILE"
    exit 0
fi

if [ "$MODE" = libs-build ]; then
    OUT=$(abspath "$1")
    cd "$WORK"
    export PATH="$WORK/bin:$PATH"
    spc build:libs "$LIBRARIES" || { tail -n 60 "$WORK/log/spc.shell.log" >&2; exit 1; }
    tar -czf "$OUT" -C "$WORK" staticphp-src bin buildroot pkgroot downloads
    ls -la "$OUT"
    exit 0
fi

[ "$MODE" = php ] || { echo "usage: $0 libs-prepare <key file> | libs-build <archive> | php <url> <sha256> <nts|ts> <extension source dir> <output file> [libs archive]" >&2; exit 2; }

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
EXT_SRC=$(cd "$4" && pwd)
OUT=$(abspath "$5")

# Before doctor: the archive holds StaticPHP's zig, which doctor would otherwise
# download and install again (minutes)
if [ $# -ge 6 ]; then
    LIBS_ARCHIVE=$(abspath "$6")
    rm -rf "$WORK"
    mkdir -p "$WORK"
    tar -xzf "$LIBS_ARCHIVE" -C "$WORK"
    export PATH="$WORK/bin:$PATH"
else
    setup_staticphp
fi
cd "$WORK"
spc doctor --auto-fix

# PHP source: the php.net tarball, with the debugger added as a bundled extension.
# It goes where StaticPHP keeps the PHP source (source/php-src): for a local
# source it skips extraction and builds from that directory.
PHP_SRC="$WORK/source/php-src"
sh "$EXT_SRC/.github/scripts/fetch-php-source.sh" "$PHP_URL" "$PHP_SHA256" "$PHP_SRC"
cp -r "$EXT_SRC" "$PHP_SRC/ext/php_debugger"
rm -rf "$PHP_SRC/ext/php_debugger/.git"
mkdir -p "$PHP_SRC/m4"
cp "$EXT_SRC"/m4/*.m4 "$PHP_SRC/m4/"

# Registers the PHP source; the build downloads whatever else it still needs
spc download php-src --custom-local="php-src:$PHP_SRC"

# StaticPHP's default configure command (config/env.ini, [linux], at
# STATICPHP_COMMIT: compare it when bumping the commit) plus the debugger and
# the mhash functions, which StaticPHP has no option for. zig ships
# the newest glibc headers and only limits the symbols that link; PHP 8.6
# enables epoll_pwait2 (glibc 2.35+) whenever the headers declare it, so rule
# it out (an optional fast path for PHP). PHP 8.6 bundles Libtool 2.5, which
# rejects --with-pic in favour of --enable-pic; 8.2-8.5 bundle Libtool 1.5,
# which only knows --with-pic.
PHP_MINOR=$(grep -o 'PHP_VERSION "[0-9]*\.[0-9]*' "$PHP_SRC/main/php_version.h" | cut -d'"' -f2)
PHP_FULL=$(grep -o 'PHP_VERSION "[0-9.]*' "$PHP_SRC/main/php_version.h" | cut -d'"' -f2)
case "$PHP_MINOR" in
    8.[2-5]) PIC_FLAG=--with-pic ;;
    *) PIC_FLAG=--enable-pic ;;
esac
ZTS_ARG=""
[ "$TS" = "ts" ] && ZTS_ARG="--enable-zts"
# Where PHP looks for its configuration and, from the prefix, its extensions
# (php-debugger/installer copies a replaced PHP's extensions there): PHP's
# default /usr/local on Linux, and Homebrew's layout on macOS
if [ "$OS" = Linux ]; then
    PATHS="--prefix=/usr/local"
    CONFIG_DIR=/usr/local/etc/php
    SYSCONFDIR_ARG=""
else
    PATHS="--prefix=/opt/homebrew/Cellar/php@${PHP_MINOR}/${PHP_FULL} --localstatedir=/opt/homebrew/var"
    CONFIG_DIR="/opt/homebrew/etc/php/${PHP_MINOR}"
    SYSCONFDIR_ARG="--with-sysconfdir=$CONFIG_DIR"
fi
# Shared extensions must keep loading (the installer keeps a replaced PHP's):
# - no --enable-rtld-now (StaticPHP's default): like the distributions' and
#   Homebrew's PHP, symbols an extension never calls need not resolve when it
#   loads (e.g. pcre2_* in extensions built against an external PCRE2)
# - macOS: no -dead_strip (StaticPHP's default linker flag), which removes the
#   PHP API functions PHP itself does not call, so extensions fail to load
# - PCRE2 under both names: extensions built against a PHP with bundled PCRE2
#   (the official Docker images, PECL builds) call php_pcre2_*, those of the
#   distributions' and Homebrew's PHP (system PCRE2) call pcre2_*_8, and on
#   Linux bind them when they load. Every bundled function is also exported
#   under its standard name, see pcre2-aliases.h. The aliases are added to
#   ext/pcre/php_pcre.c, so they are compiled into PHP itself (zig's linker
#   has no --defsym).
if [ "$OS" = Darwin ]; then
    export SPC_DEFAULT_LDFLAGS=""
fi
# Only functions get a stub: php_compat.h also renames a typedef
# (pcre2_jit_callback), recognisable as not being declared as "name(" in pcre2.h.
PCRE2_NAMES=$(sed -n 's/^#define[[:space:]]*\(pcre2_[a-z0-9_]*_8\)[[:space:]]*\(php_pcre2_[a-z0-9_]*\)[[:space:]]*$/\2 \1/p' "$PHP_SRC/main/php_compat.h" \
    | while read -r bundled standard; do
        grep -q "\b${standard%_8}(" "$PHP_SRC/ext/pcre/pcre2lib/pcre2.h" && echo "$bundled $standard"
    done)
[ -n "$PCRE2_NAMES" ] || { echo "error: no PCRE2 names found in main/php_compat.h" >&2; exit 1; }
cp "$EXT_SRC/.github/scripts/pcre2-aliases.h" "$PHP_SRC/ext/pcre/php_debugger_pcre2_aliases.h"
{
    printf '\n#ifdef HAVE_BUNDLED_PCRE\n#include "php_debugger_pcre2_aliases.h"\n'
    echo "$PCRE2_NAMES" | while read -r bundled standard; do
        echo "PHP_DEBUGGER_PCRE2_ALIAS(\"$standard\", \"$bundled\")"
    done
    echo "#endif"
} >> "$PHP_SRC/ext/pcre/php_pcre.c"
echo "PCRE2 standard names: $(echo "$PCRE2_NAMES" | wc -l | tr -d ' ')"
# --no-smoke-test: the checks below cover the same (the binary runs, the
# extensions load) plus the debugger itself
SPC_CMD_PREFIX_PHP_CONFIGURE="./configure $PATHS --with-valgrind=no --disable-shared --enable-static --disable-all --disable-phpdbg --enable-re2c-cgoto --disable-rpath $PIC_FLAG --with-mhash --enable-php-debugger ac_cv_have_decl_epoll_pwait2=no" \
    spc build:php-cli "$EXTENSIONS" $ZTS_ARG \
        --no-smoke-test \
        --disable-opcache-jit $SYSCONFDIR_ARG \
        --with-config-file-path="$CONFIG_DIR" \
        --with-config-file-scan-dir="$CONFIG_DIR/conf.d" \
    || { tail -n 60 "$WORK/log/spc.shell.log" >&2; exit 1; }

PHP="$WORK/buildroot/bin/php"
file "$PHP"

if [ "$OS" = Linux ]; then
    # Only glibc's own libraries may be linked dynamically, from MAX_GLIBC on
    sh "$EXT_SRC/.github/scripts/check-linux-elf.sh" "$PHP" "$MAX_GLIBC" \
        'libc.so.*' 'libm.so.*' 'libdl.so.*' 'libpthread.so.*' 'librt.so.*' 'libresolv.so.*' 'ld-linux*'
else
    # Only the system's own libraries and frameworks may be linked, not e.g. Homebrew's
    LINKED=$(otool -L "$PHP" | tail -n +2 | awk '{print $1}')
    echo "Linked libraries:" $LINKED
    for lib in $LINKED; do
        case "$lib" in
            /usr/lib/*|/System/Library/Frameworks/*) ;;
            *) echo "error: the interpreter links $lib" >&2; exit 1 ;;
        esac
    done

    MINOS=$(otool -l "$PHP" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')
    echo "Requires macOS: $MINOS"
    if [ -z "$MINOS" ] || [ "$(printf '%s\n%s\n' "$MINOS" "$MIN_MACOS" | sort -V | tail -1)" != "$MIN_MACOS" ]; then
        echo "error: the interpreter needs macOS '${MINOS}', not at most ${MIN_MACOS}" >&2
        exit 1
    fi
fi

# PHP API functions that only extensions use must still be exported, or shared
# extensions do not load
if [ "$OS" = Linux ]; then
    EXPORTED=$(nm -D --defined-only "$PHP" | awk '{print $3}')
else
    EXPORTED=$(nm -gU "$PHP" | awk '{print $3}' | sed 's/^_//')
fi
for symbol in zend_parse_parameters zend_declare_property add_next_index_bool _emalloc_3072 php_pcre2_match pcre2_match_8; do
    # Not grep -q: it stops reading early, and the writer then fails on the closed pipe
    printf '%s\n' "$EXPORTED" | grep -x "$symbol" >/dev/null || { echo "error: the interpreter does not export $symbol, shared extensions will not load" >&2; exit 1; }
done
echo "Exports the PHP API: $(echo "$EXPORTED" | grep -c '^zend_\|^php_\|^add_\|^_e') symbols"

"$PHP" -n -v
"$PHP" -n -r '
    $missing = [];
    foreach (array_merge(explode(",", $argv[1]), ["php_debugger"]) as $ext) {
        $loaded = match ($ext) {
            "opcache" => extension_loaded("Zend OPcache"),
            "password-argon2" => defined("PASSWORD_ARGON2ID"),
            default => extension_loaded($ext),
        };
        if (!$loaded) { $missing[] = $ext; }
    }
    if ($missing) { fwrite(STDERR, "missing extensions: " . implode(", ", $missing) . "\n"); exit(1); }
    if ((bool) PHP_ZTS !== ($argv[2] === "ts")) { fwrite(STDERR, "thread safety mismatch\n"); exit(1); }
' "$EXTENSIONS" "$TS"

sh "$EXT_SRC/.github/scripts/smoke-test.sh" "$PHP" "$EXT_SRC"

cp "$PHP" "$OUT"
