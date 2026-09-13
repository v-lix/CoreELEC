# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present Team CoreELEC (https://coreelec.org)

PKG_NAME="harletty-bridge"
PKG_VERSION="77511cfd399b53ded199591bf81d44aa626c922f"
PKG_SHA256="9813983ad197338a65b1bae1ef2e3b12ef2970d6cd84bd7f8754e2f91b83d053"
PKG_LICENSE="Apache-2.0"
PKG_SITE="https://github.com/harletty/harletty-bridge"
# The fork rather than PKG_SITE. It descends from #37 - the E-AC-3 QMF scalar
# fallbacks that brought 32-bit DD+ Atmos under one core - and carries
# everything upstream has taken since, which by now is most of what these pins
# used to add on their own: the JOC parameter-band expansion and core/object
# alignment delay (#43, #44); the DTS:X private metadata that turns the
# alternate profiles into the objects a stream declares, each with its
# transmitted position and the gains it was folded into the compatible bed at
# (#51 to #54); the D4 profile the DTS:X Pro samples use, five objects over the
# 7.1 bed (#55); Auro-3D carrier detection and unfolding (#56); D0's object read
# at the position it declares (#66); and three JOC decoder fixes of ours merged
# since the last pin (#47, #48, #61), with their expectations rewritten as
# multiples of the step (#65). The matching
# ffmpeg patch is 0008 in packages/multimedia/ffmpeg/patches, without which
# DTS:X streams reach the codec with no label.
#
# Seven commits are ahead of main. The first three are upstream's PR #68,
# opened against our branch and not merged at this pin, so they stay here until
# it lands:
#
#   - Cold start the object reconstruction at a splice. joc_sequence_counter was
#     parsed and discarded, so a channel change or a seek carried the previous
#     programme's mixing matrices, QMF state and differential OAMD state
#     straight into the new one.
#   - Pair an E-AC-3 dependent with the access unit it follows. Only legacy AC-3
#     cores were buffered, so a dependent carrying the JOC payload found no core
#     to attach to and every object was lost.
#   - Read the downmix channels joc_dmx_config_idx declares rather than the same
#     two every time (TS 102 366 clause 6.3.2.2 table 47), which is what the
#     5.1.2 and 5.1.4 height configurations need to reconstruct at all.
#
# Then the two Auro commits, which upstream has not asked for:
#
#   - Name the presentation an Auro carrier unfolds into. Auro is the one format
#     no container names - the carrier is DTS-HD MA in every field a demuxer has
#     - so the bridge reports it once the side channel is confirmed, and a disc
#     that read "5.1" now reads "Auro 11.1" on the player screen.
#   - Send every Auro channel under Auro's own label. Auro places its speakers
#     at its own angles, so the borrowed room-corner labels were wrong on the
#     floor before they were wrong overhead; the renderer knows Auro's angles
#     and now gets told which channel is which.
#
# And two added since the last pin:
#
#   - Guard the downmix a JOC reconstruction assumes. Upstream's own fourth
#     commit on #68, cherry-picked here so this pin matches the PR: a
#     5-channel joc_dmx_config_idx reached with a dependent overlaid would
#     place every surround-derived object against channels the encoder never
#     saw, so that combination now warns and emits the bed instead. No
#     measured stream asks for it.
#   - Decide a presentation from one parse, and emit its tail. The hold
#     decision read each access unit four times over, and on a JOC frame a
#     read decodes the whole payload; the common 5.1 JOC frame went from six
#     parses to three and a dependent pair from eleven to five. The same
#     commit stops cloning the bed on every paired object frame, and adds the
#     drain below.
#
# That drain is why this pin needs the matching omniphony one: an E-AC-3
# independent is held until the next access unit says whether a dependent
# follows it, so at the end of a stream one is always held and used to be
# dropped - the last 32 ms of every track. Releasing it needs
# FormatBridge::drain, which the omniphony pin adds to its ABI minor 8 set.
PKG_URL="https://github.com/v-lix/harletty-bridge/archive/${PKG_VERSION}.tar.gz"
# GitHub commit tarballs extract to <repo>-<githash>/, which scripts/unpack
# cannot auto-detect against ${PKG_NAME}-${PKG_VERSION}.
PKG_SOURCE_DIR="harletty-bridge-${PKG_VERSION}"
PKG_DEPENDS_TARGET="toolchain cargo:host"
# Not for what it links - the bridge is a plugin the engine dlopens, and links
# nothing of Omniphony's - but for what it compiles against: three of its
# crates are path dependencies on the Omniphony checkout. Sources, not objects,
# so this is an unpack dependency and not a build one.
PKG_DEPENDS_UNPACK="omniphony"
PKG_LONGDESC="harletty-bridge: the Dolby TrueHD and E-AC-3 (Atmos) decoder plugin for the Omniphony renderer. Turns an encoded bitstream into audio plus the object positions the renderer places in space."
PKG_TOOLCHAIN="manual"

# 64-bit only, and deliberately so. Kodi's object-audio codec runs the decode
# and the render in a helper process precisely because this image's userspace
# is 32-bit, where the same work costs roughly twice as much. The omniphony
# package copies what this produces into the 32-bit image.
PKG_ARCH="aarch64"

# Where the codec expects to find the bridge - see omniphony/package.mk.
PKG_OMNIPHONY_DIR="/usr/lib/kodi/omniphony"

pre_make_target() {
  # bridge/Cargo.toml reaches out of its own workspace for bridge_api, spdif
  # and sys, as `../../Omniphony/omniphony-renderer/...` - upstream's own
  # comment calls that "the workflow symlink locally and the second checkout in
  # CI". Relative to ${PKG_BUILD}/bridge that lands in ${BUILD}/build, where
  # both packages are unpacked, so the symlink is all that is missing.
  ln -sfn "$(get_build_dir omniphony)" "${BUILD}/build/Omniphony"
}

make_target() {
  export RUSTC_LINKER="${CC}"

  # No `neon` feature: it gates the 32-bit ARM QMF path, and on aarch64 the
  # vector unit is baseline and the compiler is already using it.
  cargo build --manifest-path ${PKG_BUILD}/Cargo.toml \
              --target ${TARGET_NAME} \
              --release \
              --package harletty-bridge
}

makeinstall_target() {
  # This pass builds no image; it installs so the 32-bit pass has somewhere to
  # copy from. Strip here, where ${STRIP} is the aarch64 one.
  mkdir -p ${INSTALL}${PKG_OMNIPHONY_DIR}
  cp ${PKG_BUILD}/.${TARGET_NAME}/target/${TARGET_NAME}/release/libharletty_bridge.so \
     ${INSTALL}${PKG_OMNIPHONY_DIR}/

  debug_strip ${INSTALL}${PKG_OMNIPHONY_DIR}/libharletty_bridge.so
}
