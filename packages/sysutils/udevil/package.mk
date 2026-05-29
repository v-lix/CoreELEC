# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2009-2016 Stephan Raue (stephan@openelec.tv)
# Copyright (C) 2016-present Team LibreELEC (https://libreelec.tv)

PKG_NAME="udevil"
PKG_VERSION="229453f52c5f54870a0c8026a72076b4ba9a803d"
PKG_SHA256="b99f5958939b0235ee05ea3845413d356bdad005310c5bd5f0a150880c4c2402"
PKG_LICENSE="GPL"
PKG_SITE="https://github.com/pannal/udevil"
PKG_URL="https://github.com/pannal/udevil/archive/${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain systemd glib"
PKG_LONGDESC="Mounts and unmounts removable devices and networks without a password."

PKG_CONFIGURE_OPTS_TARGET="--disable-systemd \
                           --with-mount-prog=/usr/bin/mount \
                           --with-umount-prog=/usr/bin/umount \
                           --with-losetup-prog=/usr/sbin/losetup \
                           --with-setfacl-prog=/usr/bin/setfacl"

makeinstall_target() {
 : # nothing to install
}

post_makeinstall_target() {
  mkdir -p ${INSTALL}/etc/udevil
    cp ${PKG_DIR}/config/udevil.conf ${INSTALL}/etc/udevil
    ln -sf /storage/.config/udevil.conf ${INSTALL}/etc/udevil/udevil-user-root.conf

  mkdir -p ${INSTALL}/usr/bin
    cp -PR src/udevil ${INSTALL}/usr/bin

  #mkdir -p ${INSTALL}/usr/sbin
  #echo -e '#!/bin/sh\nexec /usr/bin/mount -t ntfs3 "$@"' > ${INSTALL}/usr/sbin/mount.ntfs
  #chmod 755 ${INSTALL}/usr/sbin/mount.ntfs
}

post_install() {
  enable_service udevil-mount@.service
}
