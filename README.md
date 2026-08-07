# CoreELEC p3i

This is a custom build based on the great work Jamal did with his [U3k line of CE builds](https://github.com/CE-Repo) and by proxy, [CPM](https://github.com/cpm-code), [avdvplus](https://github.com/avdvplus/Builds), and everyone else involved. p3i aims to continue the lineage of U3k by:
* providing a stable daily driver base for especially S922X-based SoC's (Ugoos AM6b+, FireTV Cube 2, ...)
* backporting significant improvements to CoreELEC and Kodi from upstream and other known custom builds
* ensuring full transparency in the development process (all changes are properly committed and comprehensible)
* providing significant performance improvements for complex UIs

p3i doesn't aim to reinvent the wheel, but ultimately, to replace the famous [CPM A14 build](https://github.com/cpm-code/xbmc/releases/tag/CoreELEC-Amlogic-ng.arm-21.2-Omega_20250302082815.A14) as a stable, well maintained, daily driver.

It's directly forked off of [U3k B11](https://github.com/CE-Repo/xbmc/releases/tag/B11), so its core is:
* Kodi Omega 21.3 with significant backports from Kodi 22 upstream
* Python 3.13.11
* FFMPEG 8.1.2

## Building

p3i builds like stock CoreELEC, with two things you need to get right: the build target variables, and the local source checkouts the core packages build from.

### PROJECT, DEVICE and ARCH

The build system picks its target from environment variables. **With nothing set it defaults to `PROJECT=Amlogic-ce`, `DEVICE=Amlogic-ne`, `ARCH=aarch64`**, so a bare `make` builds Amlogic-ne, not the Amlogic-ng (arm) images p3i primarily targets (S922X devices like the Ugoos AM6b+).

Every invocation needs the same variables: `make`, `./scripts/clean`, `./scripts/build`, all of them. Each PROJECT/DEVICE/ARCH combination is its own build tree, so a bare `./scripts/clean kodi` cleans the Amlogic-ne tree while your image builds in the Amlogic-ng one: you never actually cleaned.

```sh
# release image for Amlogic-ng (arm)
PROJECT=Amlogic-ce DEVICE=Amlogic-ng ARCH=arm make release

# clean/rebuild single packages in that same tree
PROJECT=Amlogic-ce DEVICE=Amlogic-ng ARCH=arm ./scripts/clean kodi
PROJECT=Amlogic-ce DEVICE=Amlogic-ng ARCH=arm ./scripts/build libdovi
```

### Setting the defaults permanently

Export them from your shell so every command agrees:

```sh
# bash: ~/.bashrc — zsh: ~/.zshrc
export PROJECT=Amlogic-ce
export DEVICE=Amlogic-ng
export ARCH=arm
```

```fish
# fish: run once (universal variables), or put in ~/.config/fish/config.fish
set -Ux PROJECT Amlogic-ce
set -Ux DEVICE Amlogic-ng
set -Ux ARCH arm
```

Don't use `~/.coreelec/options` for these three: the build system sources that file after the target defaults are resolved, so `DEVICE=Amlogic-ng` set there still leaves `ARCH=aarch64` and you end up with a broken hybrid build tree. That file is fine for build tweaks like `CONCURRENCY_MAKE_LEVEL`, not for target selection.

### Local source checkouts (branch `coreelec-21_local`)

Development happens on `coreelec-21_local`; `coreelec-21` carries the release states it is cut from. The core packages of this fork don't download release tarballs. Their `package.mk` points at a local working copy via a `file://` URL, and whatever is checked out there is what gets built. The build never pulls or resets these checkouts, so verify their state before packaging:

| package.mk | builds from local checkout | source repo |
|---|---|---|
| `projects/Amlogic-ce/packages/mediacenter/kodi` | `sources/kodi/xbmc-local` | [pannal/xbmc](https://github.com/pannal/xbmc/) |
| `projects/Amlogic-ce/packages/linux` | `$HOME/linux-amlogic-local` | [pannal/linux-amlogic](https://github.com/pannal/linux-amlogic) |
| `projects/Amlogic-ce/packages/linux-drivers/amlogic/media_modules-aml` | `sources/media_modules-aml/media_modules-aml-local` | [pannal/media_modules-aml](https://github.com/pannal/media_modules-aml) |
| `projects/Amlogic-ce/packages/mediacenter/CoreELEC-settings` | `sources/service.coreelec.settings/service.coreelec.settings-local` | [pannal/service.coreelec.settings](https://github.com/pannal/service.coreelec.settings) |
| `projects/Amlogic-ce/packages/mediacenter/skin.p3i.estuary` | `sources/skin.p3i.estuary/skin.p3i.estuary-local` | bundled skin |

Clone each repo to the listed path (the branch to check out follows from `PKG_VERSION`/`PKG_GIT_BRANCH` in the respective `package.mk`), or edit the `PKG_URL` in those files to point at your own checkouts.

One-time note: the first build also bootstraps the rust toolchain (for `libdovi` and `omniphony`), which adds roughly an hour of host compilation. Subsequent builds reuse it.

### Binaural headphone rendering

Kodi folds a surround soundtrack to stereo with a matrix downmix, which throws the direction away: on headphones every channel ends up inside your head. The `omniphony` package builds the [Omniphony](https://github.com/mgth/Omniphony) spatial audio engine, which Kodi uses instead to place each channel at a fixed position around the listener and render it through a head-related transfer function, so surround channels are heard from beside and behind rather than from within.

`projects/Amlogic-ce/packages/multimedia/omniphony` builds two objects with cargo and installs them into `/usr/lib/kodi/omniphony`, the first location Kodi's loader searches:

| file | role |
|---|---|
| `liborender.so.0` | the renderer, opened at runtime with `dlopen` |
| `libreference_bridge.so` | the decoder bridge that presents host PCM to it |

Together they add roughly 5.8 MB to the image. There is no build-time dependency between Kodi and the engine: Kodi resolves it at runtime and falls back to the ordinary downmix when it is missing, so an image built without this package behaves exactly as before.

The feature stays off until *Settings > System > Audio > Binaural rendering for headphones* is enabled. That switch is greyed out unless the audio output is stereo — which includes S/PDIF and other digital outputs that are always driven in stereo — and while passthrough is on, since an amplifier is then doing the decoding and the listener is on speakers. Turning it on reveals its settings:

| setting | what it does |
|---|---|
| Binaural level | Matches the render to the ordinary downmix, so turning the feature on does not also change the volume. The default is set for that, and adjusts itself for *Maintain original volume*. |
| LFE level | The low-frequency channel, which is fed to both ears as recorded rather than placed. Kodi's *Include LFE when downmixing* does not reach this path, so it has its own control. |
| Head-related transfer function | The measurements that place the sound: the engine's own, or a SOFA file of your own. Choosing *Personal* asks for the file straight away, and goes back to *Built-in* if you pick none; choosing *Built-in* discards the file you had. |
| Speaker distance | How far out the virtual speakers sit. |
| Room simulation | Early reflections, off through three room sizes. The most audible control here. |
| Reverb amount | The tail after those reflections. |

A personal HRTF must be a free-field HRIR measurement — SOFA convention `SimpleFreeFieldHRIR`. The file is checked and copied into the profile when you pick it, and you are told straight away whether it can be used; one that fails is refused and whatever you had before is kept.

Reading a SOFA file is far too slow to do between two blocks of audio, so the engine never does: it starts every stream on its built-in measurements and swaps yours in a second or two later, once a background thread has finished reading them. Expect the sound to settle shortly after playback starts, and again after a seek.

## Issues & Support

* [Issue-tracker](https://github.com/pannal/CoreELEC/issues)
* [Discussions](https://github.com/pannal/CoreELEC/discussions)
* **Discord:** [TRaSH-Guides #ugoos-mediaplayer and #support channels](https://trash-guides.info/discord)

## Links
As my Github profile isn't public at the moment, here are the significant source-code repository links for you, if you're interested:
* [Releases](https://github.com/pannal/CoreELEC/releases)
* [XBMC/Kodi base repository](https://github.com/pannal/xbmc/)
* [CoreELEC Settings Addon repository](https://github.com/pannal/service.coreelec.settings)
* [Linux Amlogic repository](https://github.com/pannal/linux-amlogic)
* [Amlogic media modules repository](https://github.com/pannal/media_modules-aml)

## Thanks
Massive thanks to all the testers, especially the ones from [TRaSH-Guides #ugoos-mediaplayer](https://trash-guides.info/discord), who initially spiked my interest in continuing Jamal's work by exposing potential long standing UI issues in Kodi.

Also massive thanks to (not limited to, in no particular order):
* CPM
* Jamal
* Team CoreELEC
* avdvplus, SamuriHL and others involved in the CoreELEC custom builds
* Team Kodi
* OSMC

## Donations

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/Z8Z8X6P9T)

## License

CoreELEC original code is released under [GPLv2](https://www.gnu.org/licenses/gpl-2.0.html).

## Copyright

As CoreELEC includes code from many upstream projects it includes many copyright owners. CoreELEC makes NO claim of copyright on any upstream code. Patches to upstream code have the same license as the upstream project, unless specified otherwise. For a complete copyright list please checkout the source code to examine license headers. Unless expressly stated otherwise all code submitted to the CoreELEC project (in any form) is licensed under [GPLv2](https://www.gnu.org/licenses/gpl-2.0.html). You are absolutely free to retain copyright. To retain copyright simply add a copyright header to each submitted code page. If you submit code that is not your own work it is your responsibility to place a header stating the copyright.
