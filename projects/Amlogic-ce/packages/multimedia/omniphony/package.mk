# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present Team CoreELEC (https://coreelec.org)

PKG_NAME="omniphony"
PKG_VERSION="74393b1c22691a87c6fba954ad72808429f1f26b"
PKG_SHA256="e1ab0cb1ba5966430fbeec735d51cbba07a513b8533953816649a9d772560150"
PKG_LICENSE="GPL-3.0-or-later"
PKG_SITE="https://github.com/mgth/Omniphony"
# The fork rather than PKG_SITE, for the tarball alone: upstream's main is this
# same commit, but the archive path under mgth/ answers 403 where the fork's
# serves the same bytes.
#
# Nothing of ours rides on the pin. The LFE trim this image exposes uses a
# mechanism the renderer already has: a virtual-bed entry's per-channel gain is
# summed onto that channel's render gain, direct-routed or spatialized alike,
# so Kodi writes two bed rows rather than needing a key of its own. That gain
# is a float here, which the setting's half-decibel steps need.
#
# The binaural stage has been rebuilt across these bumps, and the part a
# listener meets is the level of the room. Reflections and the reverb send are
# scaled relative to the direct sound now, rather than by absolute laws that
# saturated a metre out, so both track unit_scale_m - which the speaker
# distance setting drives and which used to do almost nothing. At the 3 m
# default that is several dB more room than the earlier pins, partly given
# back since by the reflection room growing to contain the scene and by each
# reflection being low-passed by its wall and its own air path. Worth setting
# by ear against the binaural level rather than assuming either default still
# holds.
#
# The rest is quality with no key of ours behind it: measured sets interpolated
# over their spherical triangulation, minimum-phase HRIRs, ITD from the lateral
# angle, a denser reverb that dropped its chorus modulation, and a silent
# channel draining instead of freezing a quarter second of audio. The embedded
# KEMAR grid is 5 degrees rather than 10, which is about 8 MB against 2 - worth
# knowing on this box, since upstream sized it for a PC. Diffuse-field
# equalisation is opt-in and this image asks for it; the codec's WriteConfig
# says why.
#
# The C ABI is 0.7.
PKG_URL="https://github.com/v-lix/Omniphony/archive/${PKG_VERSION}.tar.gz"
# GitHub commit tarballs extract to <repo>-<githash>/, which scripts/unpack
# cannot auto-detect against ${PKG_NAME}-${PKG_VERSION}.
PKG_SOURCE_DIR="Omniphony-${PKG_VERSION}"
PKG_LONGDESC="Omniphony: spatial audio engine. Kodi's object-audio codec runs it in a 64-bit helper process to render Dolby Atmos and DTS:X objects binaurally for headphones."
PKG_TOOLCHAIN="manual"

# This feature is 64-bit whatever the image is. A shared library takes the word
# size of whoever loads it, so an engine loaded by a 32-bit Kodi would be
# 32-bit, where the same work costs roughly twice as much - measured on an
# S922X, Dolby Digital Plus Atmos decodes at 0.419 of realtime in 32-bit
# against 0.204 in 64-bit. So the engine, the decoder bridge and the helper are
# always built aarch64, and this package has two jobs depending on which pass
# is running it:
#
#   aarch64  build liborender.so, and pull in the other two 64-bit packages so
#            one command produces the whole 64-bit side. On an aarch64 image
#            that is also the end of it - everything installs natively.
#   arm      compile nothing; assemble what the aarch64 pass left behind into
#            the image, together with the 64-bit runtime it needs to start
#
# glibc and gcc are in the aarch64 list for their install trees, not for
# anything they compile: they own the loader, the C library and libgcc_s that a
# 64-bit process needs on a 32-bit image. Without them here, gcc:target is
# never built by a `scripts/build omniphony` - only the virtual image package
# pulls it - and libgcc_s.so.1 exists nowhere the 32-bit pass can find it.
if [ "${TARGET_ARCH}" = "aarch64" ]; then
  PKG_DEPENDS_TARGET="toolchain cargo:host harletty-bridge omniphony-helper glibc gcc"
else
  PKG_DEPENDS_TARGET="toolchain"
fi

# The cargo workspace sits in a subdirectory of the repository; the rest of the
# repo (the standalone player, the studio GUIs) is not built here.
PKG_OMNIPHONY_MANIFEST="omniphony-renderer/Cargo.toml"

# CDVDAudioCodecOmniphony names four files, all under special://xbmcbin/omniphony/:
# the helper, the engine, the decoder bridge and cascade-12.yaml. On this image
# special://xbmcbin resolves to the directory kodi.bin was started from, which
# is /usr/lib/kodi, so the payload sits one level below it.
PKG_OMNIPHONY_DIR="/usr/lib/kodi/omniphony"

# config/path composes BUILD from ${TARGET_ARCH}, and nothing else in the name
# changes between the two passes, so the aarch64 tree is a deterministic
# sibling of this one.
OMNI_A64_BUILD="${BUILD%.${TARGET_ARCH}-${OS_MAJOR}}.aarch64-${OS_MAJOR}"

# Where a package installed to in the aarch64 pass. PKG_INSTALL is composed
# from ${BUILD}, which is the only part of the path that differs between the
# passes, so the substitution is enough - no second copy of the naming rule.
omni_a64_install_dir() {
  local _dir="$(get_install_dir "${1}")"
  echo "${_dir/${BUILD}/${OMNI_A64_BUILD}}"
}

# ELF header: e_ident[EI_CLASS] at offset 4 is 2 for 64-bit, and the low byte of
# the little-endian e_machine at offset 18 is 183, EM_AARCH64. Read with od
# because readelf is target-prefixed in this pass and an unprefixed one is not
# guaranteed to be on PATH.
omni_is_aarch64() {
  [ -f "${1}" ] || return 1
  [ "$(od -An -tu1 -j4 -N1 "${1}" | tr -d ' ')" = "2" ] || return 1
  [ "$(od -An -tu1 -j18 -N1 "${1}" | tr -d ' ')" = "183" ]
}

# Install the first candidate that really is an aarch64 object, or return 1.
# The architecture check is part of the choice rather than an assertion after
# it, so a host copy sharing a name is skipped instead of being fatal.
omni_try_a64_libs() {
  local _dest="${1}" _cand
  shift

  for _cand in "$@"; do
    [ -e "${_cand}" ] || continue
    OMNI_TRIED+="
    ${_cand}"
    if omni_is_aarch64 "${_cand}"; then
      cp -L "${_cand}" "${_dest}"
      return 0
    fi
  done
  return 1
}

# Where one 64-bit runtime library is expected to be, best first.
omni_a64_lib_candidates() {
  local _name="${1}"

  # The compiler that built the objects knows which copy they were linked
  # against, and it is a host binary, so this pass can simply ask it. This is
  # the only source that is right by construction rather than by convention.
  [ -n "${OMNI_A64_CC}" ] && ${OMNI_A64_CC} -print-file-name=${_name}

  # The install trees glibc and gcc produce in that pass: the same files, and
  # what a 64-bit image would ship.
  echo "$(omni_a64_install_dir glibc)/usr/lib/${_name}"
  echo "$(omni_a64_install_dir gcc)/usr/lib/${_name}"
  echo ${OMNI_A64_BUILD}/toolchain/aarch64-*/sysroot/usr/lib/${_name}
}

omni_install_a64_lib() {
  local _dest="${1}" _name="${2}"
  OMNI_TRIED=""

  omni_try_a64_libs "${_dest}" $(omni_a64_lib_candidates "${_name}") && return 0

  # Not where it was expected. Widen to a bounded search of that pass's whole
  # toolchain before giving up - reached only when the layout is not what this
  # package believes, which is exactly when guessing harder is worth the walk.
  omni_try_a64_libs "${_dest}" \
    $(find ${OMNI_A64_BUILD}/toolchain -name "${_name}" -type f 2>/dev/null) && return 0

  die "omniphony: the aarch64 pass has no ${_name}.
Existing files considered, none of them aarch64 objects:${OMNI_TRIED:-
    (none)}"
}

make_target() {
  # Only the 64-bit pass compiles anything.
  [ "${TARGET_ARCH}" = "aarch64" ] || return 0

  export RUSTC_LINKER="${CC}"

  cargo build --manifest-path ${PKG_BUILD}/${PKG_OMNIPHONY_MANIFEST} \
              --target ${TARGET_NAME} \
              --release \
              --package orender_ffi
}

makeinstall_target() {
  mkdir -p ${INSTALL}${PKG_OMNIPHONY_DIR}

  # The virtual speaker layout the codec names when it falls back to cascaded
  # rendering. Twelve spatialized positions plus an LFE that is routed rather
  # than placed - a cascaded render costs one convolution per spatialized
  # speaker, so the LFE deliberately carries spatialize: false.
  cp ${PKG_DIR}/config/cascade-12.yaml ${INSTALL}${PKG_OMNIPHONY_DIR}/

  if [ "${TARGET_ARCH}" = "aarch64" ]; then
    # On a 64-bit image this is the whole job: the engine here, the bridge and
    # the helper from their own packages, all native, nothing to bridge across
    # a word size. On a 32-bit image the same install_pkg is instead what the
    # 32-bit pass below copies from. Strip here either way, where ${STRIP} is
    # the aarch64 one - the 32-bit pass could not strip these if it tried.
    local _out="${PKG_BUILD}/.${TARGET_NAME}/target/${TARGET_NAME}/release"

    # The real file takes the soname the engine's build.rs stamps into it, and
    # the plain name is the symlink - the codec hands the helper the plain one.
    cp ${_out}/liborender.so ${INSTALL}${PKG_OMNIPHONY_DIR}/liborender.so.0
    ln -sf liborender.so.0 ${INSTALL}${PKG_OMNIPHONY_DIR}/liborender.so

    debug_strip ${INSTALL}${PKG_OMNIPHONY_DIR}/liborender.so.0
    return 0
  fi

  # --- the 32-bit pass: assemble what the image ships -----------------------

  if [ ! -d "${OMNI_A64_BUILD}" ]; then
    die "omniphony: no aarch64 build at ${OMNI_A64_BUILD}.

Object audio decodes and renders in a 64-bit helper process, so that pass has
to happen before the image is built:

  PROJECT=${PROJECT} DEVICE=${DEVICE} ARCH=aarch64 ./scripts/build omniphony

That builds the engine, the decoder bridge and the helper. Then build the
image as usual."
  fi

  local _a64_omni="$(omni_a64_install_dir omniphony)"
  local _a64_bridge="$(omni_a64_install_dir harletty-bridge)"
  local _a64_helper="$(omni_a64_install_dir omniphony-helper)"

  # Taken by explicit path rather than a wildcard, so a tree left over from an
  # older version is a hard error instead of a silent mismatch: the bridge ABI
  # is abi_stable-checked when the engine loads it, and a mismatched pair fails
  # at runtime rather than here.
  local _dir
  for _dir in "${_a64_omni}" "${_a64_bridge}" "${_a64_helper}"; do
    [ -d "${_dir}${PKG_OMNIPHONY_DIR}" ] || \
      die "omniphony: the aarch64 pass has not installed ${_dir}${PKG_OMNIPHONY_DIR}"
  done

  cp -a ${_a64_omni}${PKG_OMNIPHONY_DIR}/liborender.so.0 ${INSTALL}${PKG_OMNIPHONY_DIR}/
  ln -sf liborender.so.0 ${INSTALL}${PKG_OMNIPHONY_DIR}/liborender.so
  cp -a ${_a64_bridge}${PKG_OMNIPHONY_DIR}/libharletty_bridge.so ${INSTALL}${PKG_OMNIPHONY_DIR}/
  cp -a ${_a64_helper}${PKG_OMNIPHONY_DIR}/omniphony-helper ${INSTALL}${PKG_OMNIPHONY_DIR}/

  # The 64-bit runtime. A 64-bit process cannot borrow this image's libraries,
  # so it brings its own - taken from the aarch64 pass that built the objects,
  # so the loader, the C library and the objects are one matched set.
  #
  # That pass's compiler is a host binary sitting in the sibling tree, so it
  # runs here and can be asked directly where each library is, rather than this
  # pass having to know the toolchain's layout.
  OMNI_A64_CC="$(ls ${OMNI_A64_BUILD}/toolchain/bin/aarch64-*-gcc 2>/dev/null | head -1)"

  mkdir -p ${INSTALL}${PKG_OMNIPHONY_DIR}/lib
  local _lib
  for _lib in libc.so.6 libm.so.6 libgcc_s.so.1; do
    omni_install_a64_lib "${INSTALL}${PKG_OMNIPHONY_DIR}/lib/${_lib}" "${_lib}"
  done

  # The loader is the one file that cannot live in a private directory: the
  # linker bakes its path into the helper's PT_INTERP, and the kernel resolves
  # that before anything in the process can influence a search. So it goes
  # where the aarch64 ABI says it goes. Nothing collides - this image's own
  # loader is ld-linux-armhf.so.3 - and scripts/image links /lib to /usr/lib,
  # so both spellings of the interpreter path resolve to this file.
  mkdir -p ${INSTALL}/usr/lib
  omni_install_a64_lib "${INSTALL}/usr/lib/ld-linux-aarch64.so.1" ld-linux-aarch64.so.1

  # --force-rpath writes DT_RPATH instead of DT_RUNPATH. Either tag would do
  # here, because every object that needs the private directory is given one
  # directly - the engine and the bridge are dlopened rather than linked, so
  # neither is reached through the helper's own tag. RPATH is chosen because it
  # is inherited down the dependency chain where RUNPATH is not, so it keeps
  # covering these three if they pick up a new dependency later. The usual
  # reason to prefer RUNPATH, that it can be overridden with LD_LIBRARY_PATH,
  # does not apply: nothing on this image sets one for Kodi.
  local _obj
  for _obj in omniphony-helper liborender.so.0 libharletty_bridge.so; do
    patchelf --force-rpath --set-rpath '$ORIGIN/lib' ${INSTALL}${PKG_OMNIPHONY_DIR}/${_obj}
  done
}
