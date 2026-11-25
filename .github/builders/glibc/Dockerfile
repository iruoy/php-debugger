# Build environment for the glibc Linux release binaries, used by the
# build-linux job in .github/workflows/release.yml together with
# .github/scripts/build-linux-binary.sh.
#
# The base image decides the oldest glibc the binaries run on: glibc is only
# backward compatible, so a binary needs at least the glibc it was built
# against. AlmaLinux 9 has glibc 2.34 (Debian 12+, Ubuntu 22.04+, RHEL 9+)
# and is supported until 2032. Do not move to AlmaLinux 10 (glibc 2.39)
# without deciding to drop those systems; Dependabot only bumps the digest.
FROM almalinux:9@sha256:02df05719ef287ebd0df0a1eedb9172a00bd70703aed7b25660e426b8e0d6047

# The build fails if the binary needs a newer glibc than this
ENV MAX_GLIBC=2.34

# PHP is built from a release tarball, which needs no bison or re2c
RUN dnf install -y -q gcc make autoconf automake libtool file diffutils findutils xz \
    && dnf clean all
