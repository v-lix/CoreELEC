# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2023-present Team CoreELEC (https://coreelec.org)

PKG_NAME="cargo-c"
PKG_VERSION="0.10.20"
PKG_SHA256="9bdf7c10b44466a7c01dc4ed152da5031793cca9e0c8009d73223a32522cf2c3"
PKG_LICENSE="MIT"
PKG_SITE="https://github.com/lu-zero/cargo-c"
PKG_URL="https://github.com/lu-zero/cargo-c/archive/refs/tags/v${PKG_VERSION}.tar.gz"
PKG_DEPENDS_HOST="cargo:host"
PKG_LONGDESC="Use Cargo-c to build and install C-compatible libraries"
PKG_TOOLCHAIN="manual"

# no committed Cargo.lock upstream; a plain resolve picks latest crates whose
# MSRV exceeds our pinned rustc, so prefer MSRV-compatible versions
export CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS="fallback"

make_host() {
  cargo build --release --manifest-path ${PKG_BUILD}/Cargo.toml
}

makeinstall_host() {
  cargo install --profile release --path ${PKG_BUILD}
}
