#!/bin/sh
# Builds the standalone Linux PHP interpreter (the php-php{ver}-{ts}-linux-{arch}
# release assets): a PHP CLI with php_debugger compiled in, built with StaticPHP
# (static-php-cli) v3. Every library is linked in statically except glibc, so the
# binary runs on any distro with glibc >= MAX_GLIBC (see .github/builders/interpreter)
# without needing libxml2, OpenSSL, curl and so on installed, and it can still load
# shared extensions, which php-debugger/installer relies on when it keeps a
# replaced PHP's extensions.
#
# Runs inside the .github/builders/interpreter image. GITHUB_TOKEN should be set:
# StaticPHP looks up its library sources through the GitHub API.
#
# Usage: build-linux-interpreter.sh <php tarball url> <sha256> <nts|ts> <extension source dir> <output file>
# (the tarball as resolved by resolve-php-sources.py)
set -eu

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
EXT_SRC="$4"
OUT="$5"

# The extensions the interpreter is built with; php_debugger is added below
EXTENSIONS="ctype,curl,dom,fileinfo,filter,iconv,mbstring,mysqlnd,opcache,openssl,password-argon2,pdo,pdo_sqlite,phar,posix,readline,session,simplexml,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib"

# StaticPHP v3 is not released yet; its nightly is the only build with PHP 8.6 support
curl -fsSL --retry 3 -o /usr/local/bin/spc "https://dl.static-php.dev/v3/spc-bin/nightly/spc-linux-$(uname -m)"
chmod +x /usr/local/bin/spc
spc --version

WORK=/tmp/staticphp
mkdir -p "$WORK"
cd "$WORK"

# PHP source: the php.net tarball, with the debugger added as a bundled extension
sh "$EXT_SRC/.github/scripts/fetch-php-source.sh" "$PHP_URL" "$PHP_SHA256" "$WORK/php-src"
cp -r "$EXT_SRC" "$WORK/php-src/ext/php_debugger"
rm -rf "$WORK/php-src/ext/php_debugger/.git"
mkdir -p "$WORK/php-src/m4"
cp "$EXT_SRC"/m4/*.m4 "$WORK/php-src/m4/"

# Link against glibc instead of musl, targeting the oldest version supported.
# With a target set, StaticPHP builds with its zig toolchain.
export SPC_TARGET="native-native-gnu.${MAX_GLIBC}"

spc doctor --auto-fix
# Registers the PHP source; the build downloads the libraries and toolchain it needs
spc download php-src --custom-local="php-src:$WORK/php-src"

# StaticPHP's default configure command (config/env.ini, [linux]) plus the
# debugger and the mhash functions, which StaticPHP has no option for. PHP 8.6 bundles Libtool 2.5, which rejects --with-pic in favour of
# --enable-pic; 8.2-8.5 bundle Libtool 1.5, which only knows --with-pic.
case "$(grep -o 'PHP_VERSION "[0-9]*\.[0-9]*' "$WORK/php-src/main/php_version.h" | cut -d'"' -f2)" in
    8.[2-5]) PIC_FLAG=--with-pic ;;
    *) PIC_FLAG=--enable-pic ;;
esac
ZTS_ARG=""
[ "$TS" = "ts" ] && ZTS_ARG="--enable-zts"
SPC_CMD_PREFIX_PHP_CONFIGURE="./configure --prefix= --with-valgrind=no --disable-shared --enable-static --disable-all --disable-phpdbg --enable-rtld-now --enable-re2c-cgoto --disable-rpath $PIC_FLAG --with-mhash --enable-php-debugger" \
    spc build:php-cli "$EXTENSIONS" $ZTS_ARG \
        --disable-opcache-jit \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d

PHP="$WORK/buildroot/bin/php"
file "$PHP"

# Only glibc's own libraries may be linked dynamically
NEEDED=$(readelf -d "$PHP" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
echo "Linked libraries:" $NEEDED
for lib in $NEEDED; do
    case "$lib" in
        libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|ld-linux*) ;;
        *) echo "error: the interpreter links $lib dynamically" >&2; exit 1 ;;
    esac
done

REQUIRED_GLIBC=$(grep -ao 'GLIBC_[0-9][0-9.]*' "$PHP" | sed 's/^GLIBC_//' | sort -uV | tail -1)
echo "Requires glibc: $REQUIRED_GLIBC"
if [ "$(printf '%s\n%s\n' "$REQUIRED_GLIBC" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
    echo "error: the interpreter needs glibc ${REQUIRED_GLIBC}, newer than the supported ${MAX_GLIBC}" >&2
    exit 1
fi

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

# DBGp smoke test: a debug client actually attaches and drives a script. Run
# from a copy, since the test runner writes files next to the tests.
cp -r "$EXT_SRC" "$WORK/tests-src"
cd "$WORK/tests-src"
TEST_PHP_EXECUTABLE="$PHP" TEST_PHP_ARGS="-n" "$PHP" -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt

cp "$PHP" "$OUT"
