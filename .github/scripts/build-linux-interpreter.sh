#!/bin/sh
# Builds the standalone Linux PHP interpreter (the php-php{ver}-{ts}-linux-{arch}
# release assets): a PHP CLI with php_debugger compiled in, built with StaticPHP
# (static-php-cli) v3 on a GitHub runner. Every library is linked in statically
# except glibc, and StaticPHP's zig toolchain targets glibc MAX_GLIBC, so the
# binary runs on any distro with that glibc or newer (2.34: Debian 12+, Ubuntu
# 22.04+, RHEL 9+) without needing libxml2, OpenSSL, curl and so on installed.
# It can still load shared extensions, which php-debugger/installer relies on
# when it keeps a replaced PHP's extensions.
#
# Needs MAX_GLIBC and GITHUB_TOKEN in the environment (StaticPHP looks up its
# library sources through the GitHub API), PHP 8.4+ and composer to run
# StaticPHP (the GitHub runners have both), and re2c and gettext installed.
#
# Usage: build-linux-interpreter.sh <php tarball url> <sha256> <nts|ts> <extension source dir> <output file>
# (the tarball as resolved by resolve-php-sources.py)
set -eu

PHP_URL="$1"
PHP_SHA256="$2"
TS="$3"
EXT_SRC=$(cd "$4" && pwd)
# Absolute, since the script changes directories
OUT="$(cd "$(dirname "$5")" && pwd)/$(basename "$5")"

# The extensions the interpreter is built with; php_debugger is added below
EXTENSIONS="ctype,curl,dom,fileinfo,filter,iconv,mbstring,mysqlnd,opcache,openssl,password-argon2,pdo,pdo_sqlite,phar,posix,readline,session,simplexml,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zlib"

WORK="${RUNNER_TEMP:-/tmp}/staticphp"
rm -rf "$WORK"
mkdir -p "$WORK/bin"
cd "$WORK"

# StaticPHP v3 has no release yet, and its only prebuilt binary is an unversioned
# nightly, so it runs from source at a pinned commit of its v3 branch (the first
# version with PHP 8.6 support), with its dependencies from its composer.lock.
# Bump the commit by hand; switch to a release once v3 has one.
STATICPHP_COMMIT=4193678111e6841b434348d76c94feadf7086542
curl -fsSL --retry 3 "https://github.com/crazywhalecc/static-php-cli/archive/${STATICPHP_COMMIT}.tar.gz" | tar -xz -C "$WORK"
mv "$WORK/static-php-cli-${STATICPHP_COMMIT}" "$WORK/staticphp-src"
# The runner's PHP (8.4+ needed) has Xdebug enabled, which only slows StaticPHP
# down. XDEBUG_MODE is set for these commands only: php_debugger reads it too,
# so exporting it would also switch the debugger off in the smoke test below.
XDEBUG_MODE=off composer install --working-dir="$WORK/staticphp-src" --no-dev --no-interaction --no-progress --prefer-dist --quiet
printf '#!/bin/sh\nXDEBUG_MODE=off exec php "%s/staticphp-src/bin/spc" "$@"\n' "$WORK" > "$WORK/bin/spc"
chmod +x "$WORK/bin/spc"
export PATH="$WORK/bin:$PATH"
spc --version

# PHP source: the php.net tarball, with the debugger added as a bundled extension.
# It goes where StaticPHP keeps the PHP source (source/php-src): for a local
# source it skips extraction and builds from that directory.
PHP_SRC="$WORK/source/php-src"
sh "$EXT_SRC/.github/scripts/fetch-php-source.sh" "$PHP_URL" "$PHP_SHA256" "$PHP_SRC"
cp -r "$EXT_SRC" "$PHP_SRC/ext/php_debugger"
rm -rf "$PHP_SRC/ext/php_debugger/.git"
mkdir -p "$PHP_SRC/m4"
cp "$EXT_SRC"/m4/*.m4 "$PHP_SRC/m4/"

# Link against glibc instead of musl, targeting the oldest version supported.
# With a target set, StaticPHP builds with its zig toolchain. The architecture
# is named explicitly: "native" would also mean the runner's CPU, and zig would
# use instructions that older CPUs (and Apple Silicon VMs) do not have.
export SPC_TARGET="$(uname -m)-linux-gnu.${MAX_GLIBC}"

spc doctor --auto-fix
# Registers the PHP source; the build downloads the libraries and toolchain it needs
spc download php-src --custom-local="php-src:$PHP_SRC"

# StaticPHP's default configure command (config/env.ini, [linux]) plus the
# debugger and the mhash functions, which StaticPHP has no option for, and two
# configure answers overridden for zig (see build-linux-binary.sh): no
# epoll_pwait2 (glibc 2.35+, declared by zig's newer headers), and no
# __builtin_cpu_supports/__builtin_cpu_init, which report CPU features the CPU
# does not have with zig's runtime library. PHP 8.6 bundles Libtool 2.5, which rejects --with-pic in favour of
# --enable-pic; 8.2-8.5 bundle Libtool 1.5, which only knows --with-pic.
case "$(grep -o 'PHP_VERSION "[0-9]*\.[0-9]*' "$PHP_SRC/main/php_version.h" | cut -d'"' -f2)" in
    8.[2-5]) PIC_FLAG=--with-pic ;;
    *) PIC_FLAG=--enable-pic ;;
esac
ZTS_ARG=""
[ "$TS" = "ts" ] && ZTS_ARG="--enable-zts"
SPC_CMD_PREFIX_PHP_CONFIGURE="./configure --prefix= --with-valgrind=no --disable-shared --enable-static --disable-all --disable-phpdbg --enable-rtld-now --enable-re2c-cgoto --disable-rpath $PIC_FLAG --with-mhash --enable-php-debugger ac_cv_have_decl_epoll_pwait2=no php_cv_have___builtin_cpu_supports=no php_cv_have___builtin_cpu_init=no" \
    spc build:php-cli "$EXTENSIONS" $ZTS_ARG \
        --disable-opcache-jit \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
    || { tail -n 60 "$WORK/log/spc.shell.log" >&2; exit 1; }

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
