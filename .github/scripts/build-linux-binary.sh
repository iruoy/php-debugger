#!/bin/sh
# Builds php_debugger.so for one PHP version and thread-safety mode, for the
# Linux release assets (the plain .so downloads and the PIE
# pre-packaged-binary zips).
#
# Runs inside one of the build images in .github/builders/: glibc (AlmaLinux
# 9) or musl (Alpine). The image decides the oldest libc the binary runs on;
# see the comments there. This matters because a binary built on a GitHub
# Ubuntu runner needs the glibc of that runner (2.38 for the 0.6.2 release
# binaries) and will not load on Debian 12 or Ubuntu 22.04, something PIE
# cannot detect before installing it.
#
# PHP is built from source with everything disabled, only to get the headers,
# phpize and php-config for exactly this version and thread-safety mode, plus
# a CLI binary to check that the extension loads and can debug.
#
# If MAX_GLIBC is set (the glibc image sets it), the build fails when the
# binary needs a newer glibc than that.
#
# Usage: build-linux-binary.sh <php-src tag or branch> <nts|ts> <extension source dir> <output dir>
set -eu

PHP_TAG="$1"
TS="$2"
EXT_SRC="$3"
OUT_DIR="$4"

git clone --quiet --depth=1 --branch="${PHP_TAG}" https://github.com/php/php-src.git /tmp/php-src
cd /tmp/php-src
./buildconf --force >/dev/null
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
TS="$TS" /opt/php/bin/php -n -d zend_extension="$EXT" -r '
    if (!function_exists("xdebug_info") || !function_exists("php_debugger_info")) { fwrite(STDERR, "functions missing\n"); exit(1); }
    if ((bool) PHP_ZTS !== (getenv("TS") === "ts")) { fwrite(STDERR, "thread safety mismatch\n"); exit(1); }
'

# DBGp smoke test: a debug client actually attaches and drives a script
TEST_PHP_EXECUTABLE=/opt/php/bin/php TEST_PHP_ARGS="-n -d zend_extension=$EXT" \
    /opt/php/bin/php -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt

mkdir -p "$OUT_DIR"
cp "$EXT" "$OUT_DIR/php_debugger.so"
