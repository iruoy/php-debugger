#!/bin/sh
# Builds php_debugger.so for one PHP version, thread-safety mode and libc
# target, for the Linux release assets (the plain .so downloads and the PIE
# pre-packaged-binary zips). Runs on a GitHub runner.
#
# The build uses zig (setup-zig.sh) for the target, so the binary needs only
# the libc the target names: e.g. x86_64-linux-gnu.2.34 works on any distro
# with glibc 2.34+ (Debian 12+, Ubuntu 22.04+, RHEL 9+), whatever glibc the
# runner has; x86_64-linux-musl works on Alpine. A binary built against the
# runner's own glibc would need that glibc and not load on older distros,
# something PIE cannot detect before installing it.
#
# PHP is built from the php.net tarball with everything disabled, only to get
# the headers, phpize and php-config for exactly this version and
# thread-safety mode. For glibc targets it also runs here, to check that the
# extension loads and can debug; musl builds are tested in an Alpine image by
# the workflow.
#
# Usage: build-linux-binary.sh <php tarball url> <sha256> <nts|ts> <zig target> <extension source dir> <output dir>
# (the tarball as resolved by resolve-php-sources.py)
set -eu

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
TARGET="$4"
EXT_SRC=$(cd "$5" && pwd)
OUT_DIR="$6"

WORK="${RUNNER_TEMP:-/tmp}/php-debugger-build"
rm -rf "$WORK"
mkdir -p "$WORK"

sh "$EXT_SRC/.github/scripts/setup-zig.sh" "$TARGET" "$WORK/zig"
export PATH="$WORK/zig/bin:$PATH" CC=zcc CXX=zcxx AR=zar RANLIB=zranlib

sh "$EXT_SRC/.github/scripts/fetch-php-source.sh" "$PHP_URL" "$PHP_SHA256" "$WORK/php-src"
cd "$WORK/php-src"
ZTS_FLAG=""
[ "$TS" = "ts" ] && ZTS_FLAG="--enable-zts"
# zig ships the newest libc headers for every target and only limits the symbols
# that link. PHP 8.6 enables epoll_pwait2 (glibc 2.35+) whenever the headers
# declare it, even when it does not link, so rule it out explicitly; PHP treats
# it as an optional fast path.
./configure --quiet --prefix="$WORK/php" --disable-all --disable-cgi --disable-phpdbg --disable-opcache-jit $ZTS_FLAG \
    ac_cv_have_decl_epoll_pwait2=no
make -s -j"$(nproc)" >/dev/null
make -s install >/dev/null

# Build out of a copy, so the source tree stays clean
cp -r "$EXT_SRC" "$WORK/ext"
cd "$WORK/ext"
"$WORK/php/bin/phpize" >/dev/null
./configure --quiet --with-php-config="$WORK/php/bin/php-config" --enable-php-debugger
make -s -j"$(nproc)" >/dev/null

EXT="$WORK/ext/modules/php_debugger.so"
file "$EXT"

# Only the C library (and libm) may be linked dynamically
NEEDED=$(readelf -d "$EXT" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
echo "Linked libraries:" $NEEDED
for lib in $NEEDED; do
    case "$lib" in
        libc.so|libc.so.*|libm.so.*) ;;
        *) echo "error: the extension links $lib" >&2; exit 1 ;;
    esac
done

case "$TARGET" in
    *-gnu.*)
        # The newest glibc symbol version the binary needs must not exceed the target's
        MAX_GLIBC="${TARGET##*-gnu.}"
        REQUIRED_GLIBC=$(grep -ao 'GLIBC_[0-9][0-9.]*' "$EXT" | sed 's/^GLIBC_//' | sort -uV | tail -1)
        echo "Requires glibc: ${REQUIRED_GLIBC} (target ${MAX_GLIBC})"
        if [ -z "$REQUIRED_GLIBC" ] || [ "$(printf '%s\n%s\n' "$REQUIRED_GLIBC" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
            echo "error: the extension needs glibc '${REQUIRED_GLIBC}', not at most ${MAX_GLIBC}" >&2
            exit 1
        fi

        PHP="$WORK/php/bin/php"
        "$PHP" -n -d zend_extension="$EXT" -v
        "$PHP" -n -d zend_extension="$EXT" -r '
            if (!function_exists("xdebug_info") || !function_exists("php_debugger_info")) { fwrite(STDERR, "functions missing\n"); exit(1); }
            if ((bool) PHP_ZTS !== ($argv[1] === "ts")) { fwrite(STDERR, "thread safety mismatch\n"); exit(1); }
        ' "$TS"
        # DBGp smoke test: a debug client actually attaches and drives a script
        TEST_PHP_EXECUTABLE="$PHP" TEST_PHP_ARGS="-n -d zend_extension=$EXT" \
            "$PHP" -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt
        ;;
esac

mkdir -p "$OUT_DIR"
cp "$EXT" "$OUT_DIR/php_debugger.so"
