# libdovi source-patches

Patches here are applied to the **dovi_tool Rust source** before rebuilding the
prebuilt tarball. They are **not** in `patches/` on purpose: CE's `scripts/unpack`
auto-applies `patches/*.patch` to every extraction, including the default
*prebuilt* tarball — which contains no Rust source, so the patch would fail the
normal (non-`BUILD_FROM_SRC`) build. This directory is never auto-applied; apply
it by hand during the rebuild.

## Applying when rebuilding the prebuilt

Follow the "Rebuilding the prebuilt tarball" tutorial in `../package.mk`, with one
extra step after the clone:

```sh
git clone https://github.com/quietvoid/dovi_tool.git && cd dovi_tool
git am < /path/to/source-patches/0001-capi-add-dovi_rpu_remove_cmv40_metadata.patch
# ...then the cargo cinstall / tar / sha256 steps from package.mk
```

(If `git am` rejects due to context drift in a newer libdovi, use
`git apply --3way` or `patch -p1`.)

## 0001-capi-add-dovi_rpu_remove_cmv40_metadata.patch

Adds the `dovi_rpu_remove_cmv40_metadata` C-API function (strip CMv4.0 → CMv2.9),
mirroring `dovi_rpu_add_cmv40_safe_default_metadata`. Consumed by Kodi's
`coreelec.amlogic.dolbyvision.cmv40.strip` setting for old DV TVs that fail to
fall back from CMv4.0.

**Interim only.** This is PR'd upstream (quietvoid/dovi_tool, branch
`feat/remove-cmv40-metadata-capi`). Once it merges and lands in a libdovi release,
drop this patch and just bump `PKG_VERSION` in `package.mk` to the release that
includes it (same as how `dovi_rpu_add_cmv40_safe_default_metadata` arrived).
