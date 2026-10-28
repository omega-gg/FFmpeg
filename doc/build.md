# FFmpeg: our own build for Sky, a possible libVLC replacement, on all platforms

> The original plan, kept as written. [implementation.md](../implementation.md) is the current
> reference. What changed while building it:
>
> - Windows builds with llvm-mingw rather than Ubuntu's mingw-w64, which lacks the Direct3D 12
>   video headers d3d12va needs.
> - FFmpeg comes from its releases (9.0.2), not a master commit: the release tarball names its
>   version itself, and moving to a new one is a plain version number.
> - The configure summaries are `configure/<target>.txt`, the four non-Linux jobs are one
>   matrix, and `buildFfmpeg` builds the dependencies itself.
> - The smoke test is `check.py`.
> - https uses the system TLS where there is one: SChannel on Windows, SecureTransport on Apple,
>   mbedTLS with a CA file from Sky on Linux and Android. FFmpeg verifies certificates by
>   default, and mbedTLS everywhere failed every https source on Windows. SRT keeps its own
>   mbedTLS.
> - FFmpeg gets small patches (`patches/`): SChannel's revocation check is soft, as browsers do,
>   so a revocation server behind a proxy or a VPN does not block https; `scale_d3d11` renders
>   into single textures, as D3D11 refuses NV12 and P010 render target arrays, and blits the
>   visible area of the decoded texture only; `scale_d3d12` gave empty NV12 frames for a
>   BT.2020 input, and labels every NV12 output BT.709 with gamma 2.2 on both sides.
> - Releases are published by pushes to master rather than by pushing a tag, named
>   `FFmpeg_version` (plus `FFmpeg_build` for a new name): a push creates the release, or
>   replaces its archives when it exists. Doc-only pushes build nothing.

## Context

Sky's FFmpeg backend (`WBackendFfmpeg` / `WFfmpegPlayer`, on the fork's `bunjee/dev-ffmpeg`)
links BtbN's LGPL build today: win64 and linux64 only, 148 MB of DLLs, about 55 ms to load.
The engine may replace libVLC, so we want our own FFmpeg that packs everything VLC brings to
playback (every codec and container, network sources, subtitles, Chromecast transcoding, the
hardware APIs behind each Qt RHI backend) for Windows, macOS, Linux, iOS and Android. It is
built by GitHub Actions (Azure is sunsetting public projects) and published so 3rdparty can
download it later.

The new repo is `FFmpeg` in the workspace (empty, no commits yet), remote
`github.com/omega-gg/FFmpeg`. It follows the `VLC` repo: a `.pro` listing the files, a
`build.sh <platform>` that downloads, configures, builds and fills `deploy/`, plus a workflow
shaped like splat's `.github/workflows/build.yml`.

**This task is the FFmpeg repo only.** 3rdparty and the Sky fork are wired later; `resync.md`
documents what they will need.

## Decisions

- **Source:** the FFmpeg master commit Sky already runs, `N-127021-ge0c94b2d1c`, from the
  GitHub mirror's archive of that commit. A `VERSION` file with that name goes into the source,
  so `av_version_info()` reports it.
- **License:** LGPL v3 (`--enable-version3`, required by mbedTLS and the Apache 2 libraries).
  Nothing GPL, nothing nonfree (so no SMB, whose libsmbclient is GPL, and no DVD menus).
- **Library names, prefix `sk-`:** FFmpeg only has a suffix option, so the prefix is FFmpeg's
  own `SLIBPREF` make variable, set on the `make` and `make install` command lines
  (`SLIBPREF=sk-` on Windows, `SLIBPREF=libsk-` elsewhere). Qt Multimedia's FFmpeg keeps its
  names, so both coexist on every platform, iOS frameworks and Android APKs included:

  | Platform | Files |
  |---|---|
  | win64 | `bin/sk-avcodec-63.dll`, `lib/sk-avcodec.lib`, `lib/libsk-avcodec.dll.a` |
  | macOS | `lib/libsk-avcodec.63.dylib` (universal arm64 + x86_64), install name `@rpath/...` |
  | linux64 | `lib/libsk-avcodec.so.63` (+ `.so` link) |
  | iOS | `lib/sk-avcodec.xcframework/{ios-arm64, ios-x86_64-simulator}/sk-avcodec.framework` |
  | android | `{armeabi-v7a, arm64-v8a, x86, x86_64}/libsk-avcodec.so` |

  Sky will link `-lsk-avcodec` etc. (in the wiring step). The iOS slice names match the ones
  Sky's `configure.sh` already uses for Qt's FFmpeg frameworks.
- **Libraries:** avcodec, avformat, avfilter, avutil, swscale, swresample. No avdevice
  (capture devices), no programs, no docs.
- **Components: every native one.** No `--disable-everything`: all native decoders, demuxers,
  parsers, bitstream filters, protocols and filters, plus the native encoders and muxers
  (Chromecast transcoding and remuxing, as VLC's stream output does). `--disable-autodetect`
  keeps the build reproducible: outside libraries come only from the list below. Qt's own
  build works this way and its avcodec is 14 MB, so the total should land around 35 to 55 MB
  per platform with the libraries below, against BtbN's 148 MB (measured in verification).
- **Outside libraries, all static inside the FFmpeg libraries** (no extra file to deploy):

  | Library | For | Build |
  |---|---|---|
  | dav1d | fast software AV1 | meson |
  | mbedTLS | TLS for https and SRT encryption, one TLS on every platform | CMake |
  | zlib | Matroska compression, PNG, HTTP gzip (system zlib on Apple, Linux, Android) | CMake |
  | libxml2 | DASH manifests | CMake |
  | freetype, fribidi, harfbuzz, libass | styled ASS/SSA subtitle rendering, as VLC | meson |
  | libopenh264 | software H.264 encoding for Chromecast where no hardware encoder exists | meson |
  | libsrt | SRT live sources (OBS, broadcasters); RIST and SFTP left out | CMake |
  | Vulkan-Headers, nv-codec-headers, AMF headers | Vulkan, NVDEC/NVENC, AMF (header only, loaded at run time) | copy |

  libass finds fonts through DirectWrite on Windows, CoreText on Apple and the system
  fontconfig on Linux (a runtime dependency, as libva); Android has no font provider, so Sky
  will pass `/system/fonts` when rendering (wiring step). OpenH264 built from source is not
  covered by Cisco's patent license (which covers Cisco's binary only), so Sky prefers the
  hardware encoders and documents this.
- **Hardware for each Qt RHI backend.** Sky renders through Qt's RHI (D3D11, D3D12, Vulkan,
  OpenGL, Metal). Each build enables the hardware whose frames live on those APIs, so Sky can
  later decode on the device the RHI renders with (zero copy) and today copies from any of
  them; the encoders are the Chromecast side:

  | Platform | RHI backends | Decoding | Encoding |
  |---|---|---|---|
  | win64 | D3D11, D3D12, Vulkan, OpenGL | d3d11va, d3d12va, vulkan, nvdec | mf, nvenc, amf, vulkan |
  | macOS | Metal, OpenGL | videotoolbox | videotoolbox |
  | iOS | Metal | videotoolbox | videotoolbox |
  | linux64 | Vulkan, OpenGL | vaapi (OpenGL through EGL dma-buf), vulkan, nvdec | vaapi, nvenc, amf, vulkan |
  | android | OpenGL ES, Vulkan | mediacodec (jni) | mediacodec |

  FFmpeg loads the Vulkan loader and the NVIDIA and AMD drivers at run time, so they add no
  link dependency; vaapi links libva, a runtime dependency on Linux (as BtbN's build). Today
  Sky picks one device per OS (`FFMPEGPLAYER_DEVICE`); choosing it from the RHI backend
  (`QSGRendererInterface::graphicsApi()`), calling `av_jni_set_java_vm` for MediaCodec and
  passing fonts to libass are Sky changes for the wiring step, recorded in `resync.md`.
- **Per platform:**

  | Platform | Runner | Toolchain |
  |---|---|---|
  | win64 | ubuntu, cross | mingw-w64 gcc, `-static-libgcc`, w32threads |
  | macOS | macos-14 | Xcode clang, arm64 + x86_64 joined with `lipo`, min macOS 12.0 |
  | iOS | macos-14 | Xcode clang, arm64 device + x86_64 simulator, min iOS 16.0 |
  | linux64 | ubuntu:22.04 docker (glibc, as splat) | gcc, libva-dev, libfontconfig-dev |
  | android | ubuntu | NDK 28.2.13676358 (Sky's Qt 6 NDK), API 28, 4 ABIs, 16 KB pages |

  The mingw cross build writes the `.lib` import libraries itself through `dlltool` (FFmpeg's
  `configure`, mingw32 target), so MSVC links them directly.

## Repo layout

```
FFmpeg/
  FFmpeg.pro                  OTHER_FILES, as VLC.pro
  build.sh                    build.sh <win64 | macOS | iOS | linux | android>
  README.md                   what it is, build badge, license (LGPL v3), the OpenH264 note
  implementation.md           what the build contains and why, to adjust it later
  resync.md                   how to move to a new FFmpeg commit
  doc/build.md                this plan, without local paths
  deploy/.gitignore           as VLC's
  .gitignore                  build/
  .github/workflows/build.yml
```

## build.sh

VLC's `build.sh` shape: `set -e`, Settings (versions), Syntax check, Configuration, Clean,
Download, Build, Deploy sections with the same banner comments and `echo` steps.

- **Settings:** `FFmpeg_version="N-127021-ge0c94b2d1c"` (commit taken from the `-g` part), one
  version per outside library, `NDK_version`, `android_api=28`, the hardware flags per
  platform.
- **Functions** (one per build system, so each library is one line):
  - `download <name> <url>`: fetch and extract into `build/`.
  - `buildMeson <name> <options>` and `buildCmake <name> <options>`: static, release, into the
    target's prefix, with the target's cross file or toolchain.
  - `crossFiles <target>`: writes the meson cross file and CMake toolchain for mingw, the NDK
    ABIs and the Apple arch or SDK that is not the host.
  - `buildDependencies <target>`: the outside libraries in order (zlib, mbedTLS, libxml2,
    freetype, fribidi, harfbuzz, libass, dav1d, openh264, srt), skipping the ones
    a platform takes from the system.
  - `buildFfmpeg <target> <flags>`: the common configure line (`--disable-autodetect
    --disable-programs --disable-doc --disable-avdevice --enable-shared --disable-static
    --enable-version3 --enable-pic`, the outside libraries, `--pkg-config-flags=--static`),
    the platform's hardware flags, `make -j`, `make install SLIBPREF=...`, and `configure.txt`
    (the enabled components and libraries).
- **Per platform:**
  - win64 and linux: one build.
  - macOS: arm64 and x86_64 builds, then `lipo` each dylib into `deploy/lib`; headers from one.
  - iOS: device and simulator builds; each dylib is wrapped into a `.framework` (binary,
    minimal `Info.plist`, `install_name_tool` for its id and the references between the
    libraries), then `xcodebuild -create-xcframework` per library.
  - android: four ABI builds into `deploy/<abi>`, headers once into `deploy/include`. x86
    builds without FFmpeg's x86 asm if it produces text relocations (checked when building).
- **Deploy:** `deploy/{include, lib, bin}` for desktop, the layouts above for iOS and Android,
  plus `deploy/configure.txt`.

## Workflow (.github/workflows/build.yml)

splat's file as the model: `on: [push, pull_request, workflow_dispatch]` plus tags, one job per
platform (`win64`, `macOS`, `iOS`, `linux64`, `android`), each `sh build.sh <platform>`, zip of
`deploy/` (`zip -rqy`, keeping symbolic links), `actions/upload-artifact@v4` as
`FFmpeg-<platform>`.

A `release` job runs on tag pushes only, after all five: downloads the artifacts and publishes
them with `gh release create <tag> FFmpeg-*.zip` (`permissions: contents: write`). GitHub
artifacts need a login to download, releases do not, so 3rdparty will download:

`https://github.com/omega-gg/FFmpeg/releases/download/<FFmpeg_version>/FFmpeg-<platform>.zip`

The tag is the FFmpeg version; a rebuild of the same commit with other options gets `-2`, `-3`.

## implementation.md

The reference of what the build contains, written so any choice can be revisited by changing
one line of `build.sh`. Each entry says what it is, why it is in (or out), and the variable or
flag that controls it:

- **Versions:** FFmpeg commit and each outside library's version, with its license.
- **Libraries built and left out:** the six FFmpeg libraries; avdevice, programs and docs out.
- **Components:** every native component in, with the reason (VLC replacement, compatibility
  first); the encoders and muxers kept for Chromecast; how to trim later (a
  `--disable-encoders` / `--enable-encoder=...` example) and what each family costs in size,
  measured from the first build.
- **Outside libraries:** the table above, each with its configure flag, its build system, the
  platforms it is built on or taken from the system, and what turning it off loses.
- **Left out on purpose:** SMB and DVD menus (GPL), RIST and SFTP (niche, asked to drop),
  avdevice, QSV (Intel decodes through d3d11va and encodes through Media Foundation), libplacebo
  (HDR tone mapping belongs in Sky's shader), GPL and nonfree libraries.
- **Hardware per platform:** the RHI table above, the flags enabling each API, and its runtime
  requirement (libva and fontconfig on Linux, drivers loaded at run time elsewhere).
- **Per platform:** toolchain, architectures, minimum OS and API, TLS, deploy layout and file
  names (the `sk-` prefix and how `SLIBPREF` sets it).
- **Sky's side:** what the wiring step must change in Sky (library names, device from the RHI
  backend, MediaCodec's Java VM, libass fonts on Android, OpenH264's patent note).
- **Measured:** sizes and load times per platform, filled in from verification.

## resync.md

Steps to move to a new FFmpeg master commit:

1. Pick the commit, get its name with `git describe --tags --match N <commit>` in an FFmpeg
   clone, and set `FFmpeg_version` in `build.sh`.
2. Check `configure --help` and the `APIchanges` file between the two commits: renamed or
   removed options and components, library major bumps (file names change, so Sky's deploy
   lists may need updating), deprecations in the APIs Sky uses (listed in the file).
3. Bump the outside libraries if needed (FFmpeg's `configure` states the minimum versions it
   accepts, Vulkan headers especially); check the NDK against Sky's Qt.
4. Push, check the five jobs and each `configure.txt`, tag `FFmpeg_version`, check the release.
5. In 3rdparty and Sky: set the new `FFmpeg_version` (3rdparty's `generate.sh`, Sky's
   `configure.sh` and `deploy.sh`), rebuild, run Sky's FFmpeg checks (frame exactness against
   the ffmpeg CLI, YouTube playback with audio, speeds, seeks).

It also lists what 3rdparty and Sky expect from each archive (the layouts above) and the Sky
changes the wiring step needs (library names, device from the RHI backend, MediaCodec's Java
VM, libass fonts on Android).

## Conventions

Sky's script style (as VLC's `build.sh`), 99 columns, American spelling, no `--` or spaced dash
joins in comments and docs, docs without local paths. No commit until asked.

## Verification

1. **CI:** push to a test branch of `omega-gg/FFmpeg` (only when you say so): all five jobs
   green; each archive has the expected files, and `configure.txt` lists every outside library
   and the platform's hardware.
2. **Sizes:** total per platform, against BtbN's 148 MB, recorded in `implementation.md`.
3. **Windows smoke test, locally:** a small Python ctypes script loads the six win64 DLLs
   (proves no MinGW runtime dependency), checks decoders (h264, hevc, vp9, av1, libdav1d, aac,
   opus, ass), encoders (h264_mf, libopenh264), the `atempo` and `subtitles` filters, the
   `https`, `srt`, `rtsp` and `rtmp` protocols, the d3d11va, d3d12va and vulkan device types
   (and that each creates a device on this laptop), and times the load against BtbN's 55 ms.
4. **macOS and Linux in CI:** the same check with a tiny C program compiled and run against the
   build (videotoolbox on macOS; vaapi and vulkan types on Linux; `lipo -info` shows both
   archs, `ldd` shows only system libraries, libva and fontconfig).
5. **iOS and Android:** `xcodebuild` accepted the xcframeworks; `readelf -d` shows the
   `libsk-*.so` sonames and 16 KB page alignment on arm64; `configure.txt` lists the
   mediacodec decoders and encoders.
6. Full playback is checked when Sky is wired to it (later step, per resync.md).
