# Build environment for the standalone Linux PHP interpreters, used by the
# build-php-linux job in .github/workflows/release.yml together with
# .github/scripts/build-linux-interpreter.sh.
#
# StaticPHP links every library into the interpreter statically except glibc,
# so the base image decides the oldest glibc it runs on, the same way as for
# the extension builds in ../glibc: AlmaLinux 9 has glibc 2.34 (Debian 12+,
# Ubuntu 22.04+, RHEL 9+) and is supported until 2032. Keep it on the same
# base as ../glibc; Dependabot only bumps the digest.
FROM almalinux:9@sha256:02df05719ef287ebd0df0a1eedb9172a00bd70703aed7b25660e426b8e0d6047

# The build fails if the interpreter needs a newer glibc than this
ENV MAX_GLIBC=2.34

# What StaticPHP's doctor asks for on RHEL-like systems (re2c is only in EPEL),
# plus what the libraries it builds need (cmake, perl for OpenSSL, a C++ compiler)
RUN dnf install -y -q epel-release \
    && dnf install -y -q gcc gcc-c++ make cmake autoconf automake libtool pkgconf-pkg-config \
        perl-core patch xz bzip2 unzip git which file diffutils findutils tar \
        bison re2c flex gettext-devel binutils \
    && dnf clean all
