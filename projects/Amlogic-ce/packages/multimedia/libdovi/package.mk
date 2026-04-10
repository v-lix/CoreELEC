# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2023-present Team CoreELEC (https://coreelec.org)
#
# Rebuilding from source after patching libdovi:
#
# The default prebuilt path uses a pre-compiled tarball. When source-patches/
# modify the Rust source, the prebuilt must be regenerated:
#
#   CE_TOOLCHAIN="<CE_BUILD>/build.CoreELEC-Amlogic-ng.arm-21/toolchain"
#   CE_CC="${CE_TOOLCHAIN}/bin/armv8a-libreelec-linux-gnueabihf-gcc"
#   CE_AR="${CE_TOOLCHAIN}/bin/armv8a-libreelec-linux-gnueabihf-ar"
#   RUST_TARGET="arm-unknown-linux-gnueabihf"
#
#   # Requires: rustup, cargo-c (cargo install cargo-c),
#   #           rustup target add arm-unknown-linux-gnueabihf
#   export CC_arm_unknown_linux_gnueabihf="$CE_CC"
#   export AR_arm_unknown_linux_gnueabihf="$CE_AR"
#   export CARGO_TARGET_ARM_UNKNOWN_LINUX_GNUEABIHF_LINKER="$CE_CC"
#
#   # Download, extract, and patch:
#   wget https://github.com/quietvoid/dovi_tool/archive/libdovi-3.3.1.tar.gz
#   tar xf libdovi-3.3.1.tar.gz && cd dovi_tool-libdovi-3.3.1
#   patch -p1 < /path/to/source-patches/01-libdovi-store-cmv29-payload-end-bit.patch
#
#   # Build and install to staging directory:
#   cargo cinstall --manifest-path dolby_vision/Cargo.toml \
#     --target $RUST_TARGET --library-type staticlib \
#     --profile release --prefix /usr --destdir /tmp/libdovi-install
#
#   # Package with required prefix (must match libdovi-${ARCH}-${PKG_VERSION}):
#   mkdir -p /tmp/libdovi-pkg/libdovi-arm-3.3.1
#   cp -a /tmp/libdovi-install/usr /tmp/libdovi-pkg/libdovi-arm-3.3.1/
#   tar cJf libdovi-arm-3.3.1.tar.xz -C /tmp/libdovi-pkg libdovi-arm-3.3.1
#   cp libdovi-arm-3.3.1.tar.xz <CE_SRC>/sources/libdovi/
#   # Update PKG_SHA256 for "arm" below with: sha256sum libdovi-arm-3.3.1.tar.xz

PKG_NAME="libdovi"
PKG_VERSION="3.3.1"
PKG_SITE="https://github.com/quietvoid/dovi_tool"
PKG_DEPENDS_TARGET="toolchain"
if [ "${BUILD_FROM_SRC}" = "yes" ]; then
  PKG_SHA256="4cd7a4c418fd8af1da13278ce7524c15b7fdf61e1fe53663aa291c68c5062777"
  PKG_URL="https://github.com/quietvoid/dovi_tool/archive/${PKG_NAME}-${PKG_VERSION}.tar.gz"
  PKG_DEPENDS_TARGET+=" cargo-c:host"
else
  case "${TARGET_ARCH}" in
    "arm")
      PKG_SHA256="7c0b0af11aa1919942ade07737d81cbb5b97ceb2d3220b68f87d58c034c181c3"
      ;;
    "aarch64")
      PKG_SHA256="e6e0bb82198a58a58cd38bbb2a6d286ff9d024ad35f490ff4b127ea415521457"
      ;;
  esac
  PKG_SOURCE_NAME="${PKG_NAME}-${ARCH}-${PKG_VERSION}.tar.xz"
  PKG_URL="https://sources.coreelec.org/${PKG_SOURCE_NAME}"
fi
PKG_LICENSE="MIT"
PKG_LONGDESC="dovi_tool is a CLI tool combining multiple utilities for working with Dolby Vision."
PKG_TOOLCHAIN="manual"

if [ "${BUILD_FROM_SRC}" = "yes" ]; then
pre_make_target() {
  CARGO_BASE_OPTS="--manifest-path ${PKG_BUILD}/dolby_vision/Cargo.toml \
                   --target ${TARGET_NAME}"
  CARGO_BUILD_OPTS="--library-type staticlib \
                    --profile release \
                    --prefix /usr
                    ${CARGO_BASE_OPTS}"
}

make_target() {
  cargo fetch ${CARGO_BASE_OPTS}
  cargo cbuild ${CARGO_BUILD_OPTS}
}

makeinstall_target() {
  cargo cinstall ${CARGO_BUILD_OPTS} --destdir ${SYSROOT_PREFIX}
  cargo cinstall ${CARGO_BUILD_OPTS} --destdir ${INSTALL}
}
else
make_target() {
  cp -PR * ${SYSROOT_PREFIX}
}

makeinstall_target() {
  : #
}
fi
