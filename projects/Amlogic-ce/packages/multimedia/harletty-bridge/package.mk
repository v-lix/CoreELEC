# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present Team CoreELEC (https://coreelec.org)

PKG_NAME="harletty-bridge"
PKG_VERSION="eaea55403018632b522bbb331afaf418a21c9487"
PKG_SHA256="139692bbf4259ec113af610a790f9f32e887883d820db43263934b5c620ff368"
PKG_LICENSE="Apache-2.0"
PKG_SITE="https://github.com/harletty/harletty-bridge"
# The fork rather than PKG_SITE. This line descends from the commit the
# object-audio timings were measured against - #37, the E-AC-3 QMF scalar
# fallbacks rewritten with eight partial accumulators, most of what brought
# 32-bit DD+ Atmos under one core - and everything upstream has taken since.
#
# That now includes both JOC fixes this pin used to carry beyond main on its
# own: the parameter-band expansion (#43) and the core/object alignment delay
# (#44), credited to v-lix in harletty/harletty-bridge#46 once they landed.
#
# It also includes what the previous bump was for: DTS:X objects. Upstream #51
# to #54 read the private metadata wrapped around the XLL-X channel sets, so
# the alternate profiles stop being fixed channels at positions inferred from
# corpus correlation and become the objects the stream declares - each with
# the spherical position it transmits and the gains it was folded into the
# compatible 7.1 bed at, which the renderer must remove before placing the
# feed or it plays twice. D1 presents two objects over the bed and its four
# fixed heights, D3 four, and an object-only variant carries one object on
# a 5.1 bed with no height quartet; the DAMF labels follow as DTS:X-7.1.4+2,
# DTS:X-7.1.4+4 and DTS:X-5.1+1. A frame whose metadata does not parse keeps
# the bed as authored rather than guessing.
#
# Upstream #55 completes that set with D4, which this pin used to carry alone:
# five objects over the 7.1 bed and the same four fixed heights, labelled
# DTS:X-7.1.4+5. It is the envelope the DTS:X Pro samples use, and it was
# rejected at the syncword so those streams decoded as a plain 7.1 bed with no
# objects at all. Nine waveforms also needed the fold plan's masks widened past
# a byte, and its outer control needed one bit more range than D0 and D1 use -
# a form carried by 273 of 46,169 measured frames, in half the streams and
# never within the first fifteen seconds of any of them, so the narrower bound
# reads as correct right up until whole streams are measured rather than their
# opening minutes. All five objects move: each takes between 71 and 833
# distinct positions across the six streams. The matching ffmpeg patch is 0008
# in packages/multimedia/ffmpeg/patches, without which the same streams still
# carry no DTS:X label.
#
# What this bump adds on top is #56: an Auro-Codec side channel hidden in the
# low bits of the lossless DTS-HD integers, unfolded into the bed and height
# layer the carrier was made from. Every lossless DTS-HD frame now passes that
# stage on its way to the renderer, so it sits in front of the DTS:X objects
# above. A stream that is not a carrier goes through untouched, which the D4
# corpus confirms here: five objects still arrive, and still move.
#
# What is left on the fork is six commits upstream does not have yet, all of
# them E-AC-3. Sparse-coded JOC objects used to decode to a zero mix matrix -
# every object in a sparse-coded frame going silent - which clause 6.6.2
# Pseudocode 2 does not call for, and which the oldest of the six reconstructs
# instead. And a block that switched to the short transform decoded to a
# waveform unrelated to the encoded one, because the two 128-coefficient
# transforms were fed the flat array at the long transform's stride; the
# short-transform commit gives each of them its own coefficients, and rebases the JOC golden the
# correction moves. It is the short block that carries a transient, so it is
# heard as a click on the attack. That one is worth the pin on its own: both
# codecs reach the same transform, so it was not only the plain Dolby Digital
# this image started decoding here - on Dolby's published 7.1.4 Atmos
# channel-check file, DD+ JOC at 768 kbit/s, 172 of 36 210 blocks switch, and
# the corrected decode goes from a peak error against FFmpeg of 0,449 on the
# right surround to 0,000116 across every channel.
#
# Another dequantizes JOC coefficients at clause 6.6.4's
# exact step, 820/4096, rather than 0,2. The 0,098 % that reads like is not the
# point: the dense path wraps its differential chain in floating point, modulo
# a bound that is itself a multiple of the step, so the step has to be exactly
# representable or the wrap lands on the wrong side. 820/4096 is 205/1024 and
# every product is exact in f32; 0,2 is not representable in binary and drifts
# chains over the boundary, returning a band that belongs near the top of the
# quantizer near the bottom instead - wrong by the whole 19,2 range. On the
# same channel-check file one of the twenty-one master-set channels moves,
# 22 892 of its 72 192 samples with 10 645 sign flips, which is a near
# full-scale sample inverting rather than a rounding wobble.
#
# Another cold starts the object reconstruction at a splice.
# joc_sequence_counter exists for exactly that - clause 6.3.3.3 says so - and
# was parsed and discarded, so a cut carried the previous programme's mixing
# matrices, both QMF banks' 577 samples, the core's overlap-add tail and the
# differential OAMD state straight into the new one. On this image that is a
# channel change or a seek, not a rare event.
#
# The commit below this pin pairs an E-AC-3 dependent with the access unit it
# follows. The bridge buffered only legacy AC-3 cores, so an independent E-AC-3
# frame was emitted the moment it arrived and the dependent behind it had no
# core left to attach to - it was parked for some later, unrelated one, and the
# extension channels it carried never reached the bed. On a JOC stream whose
# payload rides in the dependent that is every object lost. The dependent's
# channels are also merged onto the core before the reconstruction sees it, so
# the seven-channel downmix configurations get the rear pair they read.
#
# This pin's own commit reads the downmix channels joc_dmx_config_idx declares
# rather than the same two every time. Clause 6.3.2.2 table 47 gives each
# configuration its own downmix - L, R, C, Ls, Rs in all of them, then a pair
# that is the back channels for 7.X and the top front channels for the two
# "5.X + 2" - and the mapper hard-wired that pair to the back channels, so a
# height downmix was reconstructed from the bed's rear slots, or from a second
# copy of the side surrounds where there were none. That duplication goes with
# it: the 5.1 downmix of a 7.1 bed has Ls = Ls + Lb, so one array in both
# inputs is not the missing channel but two coefficients applied to the same
# signal. A bed that cannot supply a declared channel is now an error, which
# playback answers with the merged bed rather than the interval. Beds can also
# carry the top front pair at last - TS 102 366 table E.1.4 puts Vhl/Vhr at
# chanmap bit 11 and Lts/Rts at 13, and the dependent mapper knew neither, so
# every 5.1.2 and 5.1.4 extension was declined. And an independent whose JOC
# declares more channels than the frame carries now waits for its dependents:
# an independent substream is 5.1 at most, so a seven-channel configuration's
# extension pair can only arrive behind it. On this image that is what the two
# height configurations need to work at all; the ordinary 5.1-core stream is
# configuration 3, decodes byte for byte as before, and keeps its latency.
# It also merges a dependent that carries no custom channel map, which
# clause E.2.8.2 of TS 102 366 says takes its layout from its own acmod and
# lfeon and overwrites the core's matching channels - declining it, as this
# did, left the reconstruction on channels the dependent had superseded -
# and lets a dependent's LFE replace the core's, which the same clause names
# outright.
#
# This bump also brings Auro-3D, which upstream added as a crate of its own and
# wired into the realtime DTS-HD path. Auro folds its height layer into the low
# bits of an ordinary 5.1 or 7.1 carrier: the track plays as plain surround on
# anything, and only a decoder that reads the side channel out of those bits
# gets the heights back. That makes it the one format here no container names -
# an Auro carrier is DTS-HD MA in every field a demuxer has - so the bridge
# also reports what it turned out to be once it knows, and the engine and the
# helper carry that up to the codec. A 9.1 disc reads "Auro 9.1" on the player
# screen, an 11.1 disc "Auro 11.1", where before both read as 5.1 and played
# as 5.1.
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
