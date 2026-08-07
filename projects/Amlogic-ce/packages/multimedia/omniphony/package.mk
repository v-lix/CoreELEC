# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present Team CoreELEC (https://coreelec.org)

PKG_NAME="omniphony"
PKG_VERSION="c48808f509ab5b56525e1df1765ff81146bc4e4b"
PKG_SHA256="96a3685e01102b00b0e66c4d8ad4f7e8543e00f66ae55112b41ce8599528b1ba"
PKG_LICENSE="GPL-3.0-or-later"
PKG_SITE="https://github.com/mgth/Omniphony"
PKG_URL="https://github.com/mgth/Omniphony/archive/${PKG_VERSION}.tar.gz"
# GitHub commit tarballs extract to <repo>-<githash>/, which scripts/unpack
# cannot auto-detect against ${PKG_NAME}-${PKG_VERSION}
PKG_SOURCE_DIR="Omniphony-${PKG_VERSION}"
PKG_DEPENDS_TARGET="toolchain cargo:host"
PKG_LONGDESC="Omniphony: spatial audio engine. Kodi loads liborender at runtime to render a multichannel soundtrack binaurally for headphones, placing each channel around the listener, instead of folding it to stereo with a matrix downmix."
PKG_TOOLCHAIN="manual"

# The cargo workspace sits in a subdirectory of the repository; the rest of the
# repo (the standalone player, the studio GUIs) is not built here.
PKG_OMNIPHONY_MANIFEST="omniphony-renderer/Cargo.toml"

# Kodi searches special://xbmcbin/omniphony/ first, and on this image
# special://xbmcbin is /usr/lib/kodi - kodi.bin sits beside this directory.
# Keeping both objects there confines the engine to Kodi's own tree rather than
# the system library path, where nothing else has any use for it.
PKG_OMNIPHONY_DIR="/usr/lib/kodi/omniphony"

pre_make_target() {
  # orender_ffi builds liborender.so, the renderer's C ABI; reference_bridge
  # builds the decoder bridge that presents host PCM to it. Nothing else in the
  # workspace is wanted, so the two are selected explicitly.
  CARGO_OMNIPHONY_OPTS="--manifest-path ${PKG_BUILD}/${PKG_OMNIPHONY_MANIFEST} \
                        --target ${TARGET_NAME} \
                        --release \
                        --package orender_ffi \
                        --package reference_bridge"
}

make_target() {
  cargo fetch --manifest-path ${PKG_BUILD}/${PKG_OMNIPHONY_MANIFEST} --target ${TARGET_NAME}
  cargo build ${CARGO_OMNIPHONY_OPTS}
}

makeinstall_target() {
  local _out="${PKG_BUILD}/.${TARGET_NAME}/target/${TARGET_NAME}/release"

  mkdir -p ${INSTALL}${PKG_OMNIPHONY_DIR}
    # Installed under the soname the release build stamps into the object, which
    # is also the name Kodi hands to dlopen.
    cp ${_out}/liborender.so ${INSTALL}${PKG_OMNIPHONY_DIR}/liborender.so.0
    # The bridge is opened by the absolute path Kodi writes into the engine's
    # generated config, so it keeps its plain name.
    cp ${_out}/libreference_bridge.so ${INSTALL}${PKG_OMNIPHONY_DIR}

  # debug_strip rather than a bare ${STRIP}: it honours the tree's own DEBUG
  # switch, so `DEBUG=omniphony make release` keeps the symbol table and a
  # backtrace into the engine names its frames instead of printing "??".
  # A Rust release build carries no DWARF, but the symbol table alone is what
  # turns an unreadable stack into function names.
  debug_strip ${INSTALL}${PKG_OMNIPHONY_DIR}
}
