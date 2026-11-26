#!/bin/sh
# Installs a pinned zig and creates C/C++ compiler wrappers for one target, so
# the Linux release builds can run on a GitHub runner of any glibc version and
# still produce binaries for an older glibc (e.g. x86_64-linux-gnu.2.34) or for
# musl (x86_64-linux-musl): the target decides which libc the binary needs,
# not the machine that builds it.
#
# Afterwards, put <dir>/bin on PATH and use CC=zcc CXX=zcxx AR=zar RANLIB=zranlib.
#
# Usage: setup-zig.sh <zig target> <dir>
set -eu

TARGET="$1"
DIR="$2"

# Bump together with the checksums, from https://ziglang.org/download/index.json
ZIG_VERSION=0.17.1
case "$(uname -m)" in
    x86_64) ZIG_ARCH=x86_64; ZIG_SHA256=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;;
    aarch64|arm64) ZIG_ARCH=aarch64; ZIG_SHA256=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;;
    *) echo "error: no zig for $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$DIR/zig" "$DIR/bin"
curl -fsSL --retry 3 -o "$DIR/zig.tar.xz" "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"
echo "$ZIG_SHA256  $DIR/zig.tar.xz" | sha256sum -c -
tar -xJf "$DIR/zig.tar.xz" --strip-components=1 -C "$DIR/zig"
rm -f "$DIR/zig.tar.xz"

# -fno-sanitize=all: zig enables UBSan unless optimizing, which must not end up
# in release binaries (and aborts PHP 8.6's build-time JIT generators).
# -Wno-error=date-time: zig makes __DATE__/__TIME__ an error (for reproducible
# builds), and PHP uses them for the build date in phpinfo().
for tool in cc:zcc c++:zcxx; do
    cat > "$DIR/bin/${tool#*:}" <<EOF
#!/bin/sh
exec "$DIR/zig/zig" ${tool%%:*} -target $TARGET -fno-sanitize=all -Wno-error=date-time "\$@"
EOF
done
printf '#!/bin/sh\nexec "%s/zig/zig" ar "$@"\n' "$DIR" > "$DIR/bin/zar"
printf '#!/bin/sh\nexec "%s/zig/zig" ranlib "$@"\n' "$DIR" > "$DIR/bin/zranlib"
chmod +x "$DIR/bin/zcc" "$DIR/bin/zcxx" "$DIR/bin/zar" "$DIR/bin/zranlib"
"$DIR/zig/zig" version
