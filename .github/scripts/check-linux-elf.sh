#!/bin/sh
# Checks a Linux binary's dynamic linking: it links no libraries other than the
# allowed ones, and (when a maximum is given) needs no glibc newer than that.
#
# Usage: check-linux-elf.sh <binary> <max glibc version, or "" to skip> <allowed library glob>...
set -eu

BINARY="$1"
MAX_GLIBC="$2"
shift 2

NEEDED=$(readelf -d "$BINARY" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
echo "Linked libraries:" $NEEDED
for lib in $NEEDED; do
    allowed=""
    for pattern in "$@"; do
        # shellcheck disable=SC2254 # the pattern is a glob on purpose
        case "$lib" in $pattern) allowed=1 ;; esac
    done
    [ -n "$allowed" ] || { echo "error: $(basename "$BINARY") links $lib dynamically" >&2; exit 1; }
done

[ -n "$MAX_GLIBC" ] || exit 0
REQUIRED_GLIBC=$(grep -ao 'GLIBC_[0-9][0-9.]*' "$BINARY" | sed 's/^GLIBC_//' | sort -uV | tail -1)
echo "Requires glibc: ${REQUIRED_GLIBC} (at most ${MAX_GLIBC})"
if [ -z "$REQUIRED_GLIBC" ] || [ "$(printf '%s\n%s\n' "$REQUIRED_GLIBC" "$MAX_GLIBC" | sort -V | tail -1)" != "$MAX_GLIBC" ]; then
    echo "error: $(basename "$BINARY") needs glibc '${REQUIRED_GLIBC}', not at most ${MAX_GLIBC}" >&2
    exit 1
fi
