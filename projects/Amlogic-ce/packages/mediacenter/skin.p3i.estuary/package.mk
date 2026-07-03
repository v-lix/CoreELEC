# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2018-present Team CoreELEC (https://coreelec.org)

PKG_NAME="skin.p3i.estuary"
PKG_VERSION="8.8.15"
PKG_LICENSE="CC-BY-SA-4.0"
PKG_SITE="https://github.com/xbmc/skin.estuary/"
# Using local skin checkout; ship raw sources and pack the XBT bundles at build
# time (mirrors kodi's copy_skin_to_buildtree), so the CoreELEC icon overlay can
# be baked in before TexturePacker runs.
PKG_URL="file://${ROOT}/sources/skin.p3i.estuary/skin.p3i.estuary-local"
PKG_SOURCE_NAME="skin.p3i.estuary-local"
PKG_DEPENDS_TARGET="toolchain TexturePacker:host"
PKG_TOOLCHAIN="manual"
PKG_LONGDESC="p3i.Estuary: the CoreELEC default skin."

makeinstall_target() {
  local addon="${INSTALL}/usr/share/kodi/addons/${PKG_NAME}"
  mkdir -p "${addon}/media"

  # Ship everything except the raw media/ and themes/ sources; those are packed
  # into XBT bundles below.
  cp -PR addon.xml LICENSE.txt changelog.txt colors extras fonts \
         language playlists resources xml "${addon}/"

  # CoreELEC branding overlay onto the default media before packing: the plug
  # power icon and the CoreELEC calibration mark (same files CE drops onto
  # vanilla estuary). Must happen pre-pack because the XBT shadows loose files.
  cp -PR "${PKG_DIR}/overlay/." media/

  # Pack the default theme and each theme, exactly like kodi's pack_xbt.
  ${TOOLCHAIN}/bin/TexturePacker -input media -output "${addon}/media/Textures.xbt" -dupecheck
  for theme in themes/*/; do
    t="$(basename "${theme}")"
    ${TOOLCHAIN}/bin/TexturePacker -input "themes/${t}" -output "${addon}/media/${t}.xbt" -dupecheck
  done

  # Never ship Windows alternate-data-stream junk that may ride along.
  find "${addon}" -name "*:Zone.Identifier" -delete
}
