#!/bin/sh
# DBGp smoke test: a debug client attaches to PHP with php_debugger and drives
# a script (tests/debugger/bug00530.phpt). Runs from a copy of the source tree,
# since the test runner writes files next to the tests.
#
# Usage: smoke-test.sh <php binary> <extension source dir> [php options, e.g. -d zend_extension=...]
set -eu

PHP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
SRC=$(cd "$2" && pwd)
shift 2

WORK=$(mktemp -d)
cp -r "$SRC/." "$WORK"
cd "$WORK"
# The test runner splits TEST_PHP_ARGS on single spaces into its own arguments,
# so no trailing space: an empty argument would select every test
ARGS="-n"
[ $# -eq 0 ] || ARGS="-n $*"
TEST_PHP_EXECUTABLE="$PHP" TEST_PHP_ARGS="$ARGS" "$PHP" -n run-xdebug-tests.php -q tests/debugger/bug00530.phpt
