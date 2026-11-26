#!/bin/sh
# Runs a PHP binary on the oldest CPU model of the runner's architecture, under
# QEMU user-mode emulation (needs qemu-user): Cortex-A53 (ARMv8.0) for arm64,
# the baseline x86-64 model for x86_64. GitHub's runners have recent CPUs, so a
# binary built for their CPU (instead of the architecture's baseline) passes
# every other check and only crashes, with "Illegal instruction", on users'
# older machines. Here it crashes in CI instead.
#
# Run it in a Debian 12 container, not on the runner itself: the binary uses the
# system's dynamic loader and glibc, and the ubuntu-26.04 runner's are built
# for AVX-capable CPUs, so even a baseline binary crashes there. Debian 12's
# are built for baseline x86-64, and its glibc (2.36) is new enough for our
# binaries.
#
# Usage: check-baseline-cpu.sh <php binary> <extension source dir> [php options, e.g. -d zend_extension=...]
set -eu

PHP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
EXT_SRC=$(cd "$2" && pwd)
shift 2

case "$(uname -m)" in
    aarch64) QEMU=qemu-aarch64; CPU=cortex-a53 ;;
    x86_64) QEMU=qemu-x86_64; CPU=qemu64 ;;
    *) echo "error: no baseline CPU known for $(uname -m)" >&2; exit 1 ;;
esac

WORK="${RUNNER_TEMP:-/tmp}/baseline-cpu"
rm -rf "$WORK"
mkdir -p "$WORK"
# A php that always runs on the baseline CPU, with the given options
cat > "$WORK/php" <<WRAPPER
#!/bin/sh
exec $QEMU -cpu $CPU "$PHP" $* "\$@"
WRAPPER
chmod +x "$WORK/php"

echo "Running on QEMU $CPU"
"$WORK/php" -n -v
# Exercise whatever is compiled in, so optimized code paths actually run
"$WORK/php" -n -r '
    $s = str_repeat("Grüße, debugger! ", 2000);
    hash("sha256", $s); md5($s); crc32($s);
    preg_match_all("/\w+/u", $s, $m);
    json_decode(json_encode(range(1, 5000)));
    $a = range(1, 20000); shuffle($a); sort($a);
    if (function_exists("mb_strtoupper")) { mb_strtoupper($s); }
    if (function_exists("gzcompress")) { gzuncompress(gzcompress($s)); }
    if (function_exists("openssl_digest")) { openssl_digest($s, "sha512"); }
    if (function_exists("sodium_crypto_secretbox")) { sodium_crypto_secretbox($s, random_bytes(24), random_bytes(32)); }
    if (defined("PASSWORD_ARGON2ID")) { password_verify("x", password_hash("x", PASSWORD_ARGON2ID)); }
    if (class_exists("PDO") && in_array("sqlite", PDO::getAvailableDrivers(), true)) { (new PDO("sqlite::memory:"))->query("SELECT 1")->fetchAll(); }
    if (function_exists("simplexml_load_string")) { simplexml_load_string("<a><b>1</b></a>"); }
    if (!function_exists("xdebug_info")) { fwrite(STDERR, "php_debugger missing\n"); exit(1); }
    echo "Workload passed\n";
'

# DBGp smoke test: the debugger itself, on the baseline CPU
cp -r "$EXT_SRC" "$WORK/src"
cd "$WORK/src"
TEST_PHP_EXECUTABLE="$WORK/php" TEST_PHP_ARGS="-n" "$WORK/php" -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt
