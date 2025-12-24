# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2017-present Team LibreELEC (https://libreelec.tv)

PKG_NAME="pycryptodome"
PKG_VERSION="3.21.0"
PKG_SHA256="195e5cdfbb550b03f83f2af2aa4652c14b64783574d835fe61bb06c8fc06ba21"
PKG_LICENSE="BSD"
PKG_SITE="https://pypi.org/project/pycryptodome"
PKG_URL="https://github.com/Legrandin/${PKG_NAME}/archive/v${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain Python3"
PKG_LONGDESC="PyCryptodome is a self-contained Python package of low-level cryptographic primitives."
PKG_TOOLCHAIN="manual"

pre_configure_target() {
  cd ${PKG_BUILD}
  rm -rf .${TARGET_NAME}
}

make_target() {
  python_target_env python3 setup.py build
}

makeinstall_target() {
  exec_thread_safe python_target_env python3 setup.py install --root=${INSTALL} --prefix=/usr

  # Remove SelfTest bloat
  find ${INSTALL} -type d -name SelfTest -exec rm -fr "{}" \; 2>/dev/null || true
  find ${INSTALL} -name SOURCES.txt -exec sed -i "/\/SelfTest\//d;" "{}" \;

  # Create Cryptodome as an alternative namespace to Crypto (Kodi addons may use either)
  ln -sf /usr/lib/${PKG_PYTHON_VERSION}/site-packages/Crypto ${INSTALL}/usr/lib/${PKG_PYTHON_VERSION}/site-packages/Cryptodome
}

post_makeinstall_target() {
  python_remove_source
}
