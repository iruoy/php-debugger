#!/bin/sh
# Builds php_debugger.so for one PHP version and thread-safety mode, for the
# Linux release assets (the plain .so downloads and the PIE
# pre-packaged-binary zips).
#
# Runs inside one of the build images in .github/builders/, which decide the
# oldest libc the binary runs on; see the comments there.
#
# PHP is built from source with everything disabled, only to get the headers,
# phpize and php-config for exactly this version and thread-safety mode, plus
# a CLI binary to check that the extension loads and can debug.
#
# If MAX_GLIBC is set (the glibc image sets it), the build fails when the
# binary needs a newer glibc than that.
#
# Usage: build-linux-binary.sh <php tarball url> <sha256> <nts|ts> <extension source dir> <output dir>
# (the tarball as resolved by resolve-php-sources.py)
set -eu

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
EXT_SRC="$4"
OUT_DIR="$5"

sh "$EXT_SRC/.github/scripts/fetch-php-source.sh" "$PHP_URL" "$PHP_SHA256" /tmp/php-src
cd /tmp/php-src
ZTS_FLAG=""
[ "$TS" = "ts" ] && ZTS_FLAG="--enable-zts"
./configure --quiet --prefix=/opt/php --disable-all --disable-cgi --disable-phpdbg $ZTS_FLAG
make -s -j"$(nproc)" >/dev/null
make -s install >/dev/null

# Build out of a copy, so the bind-mounted source tree stays clean
cp -r "$EXT_SRC" /tmp/ext
cd /tmp/ext
/opt/php/bin/phpize >/dev/null
./configure --quiet --with-php-config=/opt/php/bin/php-config --enable-php-debugger
make -s -j"$(nproc)" >/dev/null

EXT="$PWD/modules/php_debugger.so"
file "$EXT"

# The newest glibc symbol version the binary needs (none for musl)
REQUIRED_GLIBC=$(grep -ao 'GLIBC_[0-9][0-9.]*' "$EXT" | sed 's/^GLIBC_//' | sort -uV | tail -1)
echo "Requires glibc: ${REQUIRED_GLIBC:-none}"
if [ -n "${MAX_GLIBC:-}" ]; then
    if [ -z "$REQUIRED_GLIBC" ]; then
        echo "error: no glibc symbol versions found in a glibc build" >&2
        exit 1
    fi
    NEWEST=$(printf '%s\n%s\n' "$REQUIRED_GLIBC" "$MAX_GLIBC" | sort -V | tail -1)
    if [ "$NEWEST" != "$MAX_GLIBC" ]; then
        echo "error: the binary needs glibc ${REQUIRED_GLIBC}, newer than the supported ${MAX_GLIBC}" >&2
        exit 1
    fi
fi

/opt/php/bin/php -n -d zend_extension="$EXT" -v
/opt/php/bin/php -n -d zend_extension="$EXT" -r '
    if (!function_exists("xdebug_info") || !function_exists("php_debugger_info")) { fwrite(STDERR, "functions missing\n"); exit(1); }
    if ((bool) PHP_ZTS !== ($argv[1] === "ts")) { fwrite(STDERR, "thread safety mismatch\n"); exit(1); }
' "$TS"

# DBGp smoke test: a debug client actually attaches and drives a script
TEST_PHP_EXECUTABLE=/opt/php/bin/php TEST_PHP_ARGS="-n -d zend_extension=$EXT" \
    /opt/php/bin/php -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt

mkdir -p "$OUT_DIR"
cp "$EXT" "$OUT_DIR/php_debugger.so"
