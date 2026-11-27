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
# (the tarball and its sha256 as resolved by resolve-php-sources.py)
set -eu

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
TARGET="$4"
EXT_SRC=$(cd "$5" && pwd)
# Absolute, since the script changes directories
mkdir -p "$6"
OUT_DIR=$(cd "$6" && pwd)

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

# Only the C library (and libm) may be linked dynamically, and for a glibc
# target, no newer glibc than the target's
MAX_GLIBC=""
case "$TARGET" in *-gnu.*) MAX_GLIBC="${TARGET##*-gnu.}" ;; esac
sh "$EXT_SRC/.github/scripts/check-linux-elf.sh" "$EXT" "$MAX_GLIBC" 'libc.so' 'libc.so.*' 'libm.so.*'

if [ -n "$MAX_GLIBC" ]; then
    PHP="$WORK/php/bin/php"
    "$PHP" -n -d zend_extension="$EXT" -v
    "$PHP" -n -d zend_extension="$EXT" -r '
        if (!function_exists("xdebug_info") || !function_exists("php_debugger_info")) { fwrite(STDERR, "functions missing\n"); exit(1); }
        if ((bool) PHP_ZTS !== ($argv[1] === "ts")) { fwrite(STDERR, "thread safety mismatch\n"); exit(1); }
    ' "$TS"
    sh "$EXT_SRC/.github/scripts/smoke-test.sh" "$PHP" "$EXT_SRC" -d zend_extension="$EXT"
fi

cp "$EXT" "$OUT_DIR/php_debugger.so"
