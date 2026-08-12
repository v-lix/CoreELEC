# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2023-present Team CoreELEC (https://coreelec.org)

PKG_NAME="libdovi"
PKG_VERSION="3.4.0"
PKG_SHA256="8eac4d1c3134f53e8eb216db6450307a737425844113e480d1e9713c142a9fa2"
PKG_SITE="https://github.com/quietvoid/dovi_tool"
PKG_URL="https://github.com/quietvoid/dovi_tool/archive/${PKG_NAME}-${PKG_VERSION}.tar.gz"
# GitHub tag tarballs extract to <repo>-<tag>/, which scripts/unpack cannot
# auto-detect against ${PKG_NAME}-${PKG_VERSION}
PKG_SOURCE_DIR="dovi_tool-${PKG_NAME}-${PKG_VERSION}"
PKG_DEPENDS_TARGET="toolchain cargo-c:host"
PKG_LICENSE="MIT"
PKG_LONGDESC="dovi_tool is a CLI tool combining multiple utilities for working with Dolby Vision."
PKG_TOOLCHAIN="manual"

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
}
