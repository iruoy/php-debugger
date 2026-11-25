# Build environment for the musl (Alpine) Linux release binaries, used by
# the build-linux job in .github/workflows/release.yml together with
# .github/scripts/build-linux-binary.sh.
#
# The base image decides the oldest musl the binaries run on: a binary built
# against a newer musl may not load on an older one. Alpine 3.23 has musl
# 1.2.5, the same as 3.21 and 3.22, so the binaries run on Alpine 3.21+,
# and is supported until about November 2027. Alpine 3.24 moves to musl
# 1.2.6, so do not bump the version without checking that; Dependabot only
# bumps the digest.
FROM alpine:3.23@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2

# PHP is built from a release tarball, which needs no bison or re2c
RUN apk add --no-cache build-base linux-headers autoconf automake libtool file curl xz tar
