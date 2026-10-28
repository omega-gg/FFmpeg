# FFmpeg build: implementation

What the build contains, why, and which line of `build.sh` controls it. Everything here can be
adjusted by changing that line; [resync.md](resync.md) covers moving to a new FFmpeg release.

## Goal

Sky's FFmpeg player backend (`WBackendFfmpeg`, `WFfmpegPlayer`) may replace libVLC. So the build
packs what VLC brings to playback: every codec and container, network sources, styled
subtitles, transcoding for Chromecast, and the hardware APIs behind each Qt RHI backend. It
leaves out what playback doesn't use (capture devices, programs, docs) and anything GPL.

## Versions

| What | Version | License | `build.sh` |
|---|---|---|---|
| FFmpeg | 9.0.2 | LGPL 3 | `FFmpeg_version` |
| zlib | 1.3.1 | zlib | `zlib_version` |
| mbedTLS | 3.6.7 (LTS) | Apache 2 | `mbedtls_version` |
| libxml2 | 2.14.6 | MIT | `libxml2_version` |
| FreeType | 2.14.1 | FreeType | `freetype_version` |
| FriBidi | 1.0.16 | LGPL 2.1 | `fribidi_version` |
| HarfBuzz | 14.5.1 | MIT | `harfbuzz_version` |
| libass | 0.17.4 | ISC | `libass_version` |
| dav1d | 1.5.3 | BSD 2 | `dav1d_version` |
| OpenH264 | 2.6.0 | BSD 2 | `openh264_version` |
| SRT | 1.5.4 | MPL 2 | `srt_version` |
| Vulkan-Headers | 1.4.341.0 | Apache 2 | `VulkanHeaders_version` |
| nv-codec-headers | 12.1.14.1 | MIT | `nvcodec_version` |
| AMF headers | 1.5.3 | MIT | `AMF_version` |
| llvm-mingw | 20260922 | Apache 2 with LLVM exception | `llvm_mingw_version` |

- **FFmpeg** comes from its releases only: a release branch gets bug and security fixes, no new
  features or API changes in between. Sky's backend was developed on a master commit from
  before 9.0 (`N-127021-ge0c94b2d1c`), with the same library majors (avcodec 63, avformat 63,
  avfilter 12), so the names and Sky's code stay the same.
- **mbedTLS** stays on the 3.6 LTS branch: FFmpeg's TLS code uses the entropy and CTR-DRBG
  APIs, which 4.x removed from the public API.
- **nv-codec-headers** stays on 12.1: version 13 requires NVIDIA drivers from 2025 on, while
  12.1 works with drivers from 530 on. FFmpeg needs 12.1.14 at least.
- **Vulkan-Headers:** FFmpeg needs 1.3.277 at least, and 1.4.317 for its newest Vulkan paths.
- **AMF:** FFmpeg needs 1.5.2 at least.
- **llvm-mingw** is the Windows toolchain. Only its C++ runtime and unwinder end up inside the
  DLLs, linked statically.

## Libraries

Built: avcodec, avformat, avfilter, avutil, swscale, swresample, shared.

Left out (`FFmpeg_flags`):

- `--disable-avdevice`: capture devices (webcams, screen capture), which VLC opens but Sky
  doesn't. Removing the flag brings them back; each platform's device APIs would then need
  enabling too, since autodetection is off.
- `--disable-programs`, `--disable-doc`: the `ffmpeg`, `ffprobe` and `ffplay` tools and the
  manuals.
- `--disable-debug`: no debug symbols, which roughly halves the size.

## Names

The libraries are named `sk-avcodec` and so on, so they never clash with Qt Multimedia's FFmpeg,
which ships the same libraries under FFmpeg's names (frameworks on iOS, `.so` files in the APK
on Android, where two files can't share a name).

FFmpeg only has a suffix option (`--build-suffix`), so the prefix uses its own make variables,
in `buildFfmpeg`:

- `SLIBPREF=sk-` on Windows, `SLIBPREF=libsk-` elsewhere: the file names.
- `LD_LIB=-lsk-%`: how FFmpeg's libraries link to each other while building. It only applies to
  FFmpeg's own libraries, not to the outside ones.

The `.pc` files FFmpeg installs still say `-lavcodec`; they are not deployed.

## Components

Every native component is in: there is no `--disable-everything`. That means all decoders,
demuxers, parsers, bitstream filters, protocols, filters, encoders and muxers FFmpeg has
without outside libraries. Compatibility comes first, and Qt's own build works the same way
(its avcodec is 14 MB on Windows).

- **Decoders, demuxers, parsers:** everything, subtitle decoders included (SRT, ASS, PGS,
  DVB, DVD, WebVTT, closed captions).
- **Protocols:** everything native: file, http, https, HLS, DASH (with libxml2), RTSP, RTMP,
  RTP, UDP and multicast, FTP, TCP, TLS, plus SRT (with libsrt).
- **Encoders and muxers:** kept for Chromecast, which needs a remux (MP4, Matroska, MPEG-TS,
  HLS) and a transcode when the device can't decode a codec, as VLC's stream output does.
- **Filters:** everything native, including deinterlacing (`bwdif`, `yadif`), `atempo` for
  audio speed and `subtitles` / `ass` with libass.

`--disable-autodetect` makes the build reproducible: no library is picked up because a runner
happens to have it. So threads, zlib and every hardware API are enabled explicitly.

**Trimming later:** a family can go with `--disable-encoders` then `--enable-encoder=aac,...`
(same for `muxers`, `filters`), added to `FFmpeg_flags`. The size each family costs is recorded
under [Measured](#measured).

## Outside libraries

All are built from source as static libraries, linked inside the FFmpeg libraries, so nothing
extra is deployed. Their symbols stay hidden (FFmpeg only exports its own).

| Library | Brings | FFmpeg flag | Build | Platforms |
|---|---|---|---|---|
| zlib | Matroska compression, PNG, HTTP gzip | `--enable-zlib` | `buildZlib` | win64; the system's elsewhere |
| mbedTLS | SRT encryption everywhere, https on Linux and Android | `--enable-mbedtls` (Linux, Android) | CMake | all |
| libxml2 | DASH manifests | `--enable-libxml2` | CMake | all |
| FreeType, FriBidi, HarfBuzz | font rendering and text shaping for libass | through libass | meson | all |
| libass | styled ASS/SSA subtitles, as VLC | `--enable-libass` | meson | all |
| dav1d | fast software AV1 | `--enable-libdav1d` | meson | all |
| OpenH264 | software H.264 encoding when no hardware encoder exists | `--enable-libopenh264` | meson | all |
| SRT | `srt://` live sources (OBS, broadcasters) | `--enable-libsrt` | CMake | all |
| Vulkan-Headers | Vulkan decoding and encoding | `--enable-vulkan` | headers | win64, linux |
| nv-codec-headers | NVDEC and NVENC | `--enable-ffnvcodec` | headers | win64, linux |
| AMF headers | AMD encoding | `--enable-amf` | headers | win64, linux |

What turning each off loses:

- **zlib:** zlib-compressed Matroska tracks (mostly subtitles), PNG frames, gzip HTTP.
- **mbedTLS:** SRT encryption, and https on Linux and Android. Windows and Apple use their
  system TLS for https (below).
- **libxml2:** DASH. HLS doesn't need it.
- **libass and its three dependencies:** styled ASS/SSA subtitles. Plain subtitles still decode
  to text for Sky to draw.
- **dav1d:** AV1 without a GPU that decodes it falls back to FFmpeg's slower native decoder.
- **OpenH264:** Chromecast transcoding on machines without a hardware H.264 encoder.
- **SRT:** `srt://` sources.
- **Vulkan, NVIDIA, AMD headers:** the matching hardware paths.

`build.sh` options per library:

- meson builds use `-Dauto_features=disabled`, so only what is listed is built in.
- **HarfBuzz:** FreeType only; no ICU, GLib or Cairo, and no C++ runtime needed.
- **FreeType:** built without HarfBuzz, PNG, bzip2 and Brotli, which breaks the
  FreeType/HarfBuzz loop.
- **libass:** its font provider per platform (`libass_fonts`): DirectWrite on Windows, CoreText
  on Apple, fontconfig on Linux, none on Android. Its assembly is off.
- **SRT:** mbedTLS for encryption, C++11 threads (`ENABLE_STDCXX_SYNC`) so it needs no pthreads
  library on Windows.
- **libxml2:** no iconv, ICU, zlib, LZMA, Python, programs or tests.

## TLS

FFmpeg verifies certificates by default (`tls_verify`), so its TLS needs the system's trusted
certificates. Each platform takes the TLS that has them (`FFmpeg_<platform>` in `build.sh`):

| Platform | https | Certificates |
|---|---|---|
| win64 | SChannel (`--enable-schannel`) | Windows' certificate store, corporate CAs included |
| macOS, iOS | SecureTransport (`--enable-securetransport`) | the system keychain |
| linux64, android | mbedTLS (`--enable-mbedtls`) | a CA file Sky passes (`ca_file`): the distribution's bundle on Linux, the system certificates on Android |

FFmpeg links one TLS only (SChannel and SecureTransport conflict with mbedTLS in its
`configure`). SRT links its own mbedTLS on every platform, through `srt.pc`, independently of
FFmpeg's TLS.

The first builds used mbedTLS everywhere: on Windows every https source then failed, as mbedTLS
can't read Windows' certificate store.

**Revocation on Windows:** with verification on, FFmpeg's SChannel code makes the revocation
check of the certificate mandatory. Where the revocation servers can't be reached (a corporate
proxy, a VPN), every https source fails with `0x80092012`, while browsers open them. Our
`patches/tls-schannel-revocation.patch` makes that check soft, as Chrome, Edge and curl's
`--ssl-revoke-best-effort` do: the certificate chain and the host name are still verified, a
certificate known as revoked is still refused, and only an unreachable revocation server no
longer blocks the source.

## Patches

`build.sh` applies every `patches/*.patch` to FFmpeg's source after the download, with
`patch -p1`. Each one is small and explained here:

| Patch | Why |
|---|---|
| `tls-schannel-revocation.patch` | Soft revocation check with SChannel, see TLS above |
| `scale-d3d11-single-textures.patch` | `scale_d3d11` asks for its output as an array of 10 NV12 or P010 textures to render into. D3D11 allows such arrays only for decoding (`E_INVALIDARG` on NVIDIA and Intel), so the filter never ran. Its pool now makes single textures as needed. Sky uses it to bring 10-bit frames to 8 bits on the GPU before their copy to memory |
| `scale-d3d11-visible-area.patch` | `scale_d3d11` took its input size from the decoder's texture, which is taller than the frame (4K is decoded into 2176 rows), and set no source rectangle: the picture was squeezed and its padding showed as black rows at the bottom. It now blits the visible area only |
| `scale-d3d12-color-space.patch` | `scale_d3d12` gives its output the input's color space. For HDR10 or HLG brought to NV12, that's PQ or HLG in 8 bits, which has no DXGI form: the video processor accepts it, reports no error and writes nothing, so every frame came back as zeros (green). BT.2020 with gamma 2.2 gives empty frames too on NVIDIA. With an NV12 output it now uses BT.709 with gamma 2.2 on both sides, whatever the input: the filter never converts color (both sides always share one color space), so the label converts no pixel, and only the depth changes, as with `scale_d3d11` (which sets no color space). Sky uses it to bring 10-bit frames to 8 bits on the GPU under Qt's D3D12 renderer, where it decodes with d3d12va |

A patch that no longer applies stops the build (see resync.md). One FFmpeg takes upstream
makes it go.

## Left out on purpose

- **SMB** (`smb://`): libsmbclient is GPL 3.
- **DVD menus:** libdvdnav and libdvdread are GPL. DVD `.vob` files still play through the
  native demuxer.
- **RIST and SFTP:** niche, dropped on request. librist and libssh would build like SRT.
- **Blu-ray:** libbluray was not requested.
- **Intel QSV:** Intel GPUs decode through d3d11va and vaapi, and encode through Media
  Foundation and vaapi. QSV would add libvpl.
- **libplacebo:** HDR to SDR tone mapping belongs in Sky's video shader.
- **Capture devices:** see Libraries.
- **Anything GPL or nonfree:** x264, x265, fdk-aac and others. The build stays LGPL 3.

## Hardware

Sky renders through Qt's RHI, which can be D3D11, D3D12, Vulkan, OpenGL or Metal. Each platform
enables the APIs whose frames live on those backends. Sky can then decode on the device the RHI
renders with (zero copy, a later step), and copies frames from any of them meanwhile. The
encoders are the Chromecast side.

| Platform | RHI backends | Decoding | Encoding | `build.sh` |
|---|---|---|---|---|
| win64 | D3D11, D3D12, Vulkan, OpenGL | d3d11va, d3d12va, vulkan, nvdec | mediafoundation, nvenc, amf, vulkan | `FFmpeg_win64` |
| macOS | Metal, OpenGL | videotoolbox | videotoolbox | `FFmpeg_apple` |
| iOS | Metal | videotoolbox | videotoolbox | `FFmpeg_apple` |
| linux64 | Vulkan, OpenGL | vaapi, vulkan, nvdec | vaapi, nvenc, amf, vulkan | `FFmpeg_linux` |
| android | OpenGL ES, Vulkan | mediacodec | mediacodec | `FFmpeg_android` |

- **D3D11 and D3D12 on Windows:** both are in every build, and FFmpeg loads `d3d11.dll` and
  `d3d12.dll` at run time. Which one Sky uses follows its RHI backend: Qt's MinGW kit only has
  the D3D11 backend, so a MinGW Sky decodes with d3d11va; Qt's MSVC kit also has D3D12, so an
  MSVC Sky uses d3d12va when it renders with D3D12. The same DLLs serve both, with `.lib` for
  MSVC and `.dll.a` for MinGW.
- **OpenGL on Windows** takes d3d11va frames through a copy, or WGL's DX interop.
- **OpenGL on Linux** takes vaapi frames through EGL dma-buf import.
- **Vulkan, NVIDIA and AMD** are loaded at run time (`vulkan-1.dll` / `libvulkan.so.1`, the
  drivers), so they add no link dependency: they work where a driver has them, and fail
  softly elsewhere.
- **vaapi** links libva: on Linux, `libva.so.2` must be installed for the libraries to load (as
  with BtbN's build). Every desktop distribution has it.
- **MediaCodec** needs `av_jni_set_java_vm` from the app before use.

## Platforms

| Platform | Runner | Toolchain | Architectures | Minimum |
|---|---|---|---|---|
| win64 | Ubuntu 24.04, cross | llvm-mingw `20260922` (`llvm_mingw_version`), UCRT | x86_64 | Windows 10, as Qt 6 |
| macOS | macOS 14 | Xcode clang | arm64 + x86_64, universal | macOS 12.0 (`macOS_version`) |
| iOS | macOS 14 | Xcode clang | arm64 device, x86_64 simulator | iOS 16.0 (`iOS_version`) |
| linux64 | Ubuntu 22.04 docker | GCC | x86_64 | glibc 2.35, as Qt 6 |
| android | Ubuntu 24.04 | NDK 28.2.13676358 (`NDK_version`) | armeabi-v7a, arm64-v8a, x86, x86_64 | API 28 (`android_api`) |

- **win64:** llvm-mingw (clang, libc++), as VLC builds with. Ubuntu's own mingw-w64 is too old
  for d3d12va: it lacks the Direct3D 12 video headers. libc++ and libunwind are linked
  statically, so the DLLs only need Windows' own. FFmpeg writes the MSVC `.lib` import
  libraries itself through `dlltool`.
- **macOS:** each library is built for both architectures, then joined with `lipo`. Install
  names are `@rpath/libsk-avcodec.63.dylib`.
- **iOS:** each library is wrapped into a framework, then into an xcframework with the
  `ios-arm64` and `ios-x86_64-simulator` slices, the names Sky's `configure.sh` already uses
  for Qt's FFmpeg.
- **Linux:** the libraries need these from the system: libva and libva-drm (hardware
  decoding), fontconfig (libass), zlib, and the C++ runtime (libstdc++, libgcc_s, for OpenH264
  and SRT). All are standard on desktop distributions, and Qt 6 needs them too, apart from
  libva. The rest is built in.
- **Android:** x86 (emulators only) builds without assembly, which has text relocations Android
  refuses. Libraries are aligned for 16 KB pages, as Android 15 devices can use them. The C++
  runtime is linked statically.

## Archives

`FFmpeg-<platform>.zip`, from `deploy/`:

| Platform | Content |
|---|---|
| win64 | `include/`, `bin/sk-avcodec-63.dll`, `lib/sk-avcodec.lib`, `lib/libsk-avcodec.dll.a` |
| macOS | `include/`, `lib/libsk-avcodec.63.dylib` and `lib/libsk-avcodec.dylib` (link) |
| iOS | `include/`, `lib/sk-avcodec.xcframework` |
| linux64 | `include/`, `lib/libsk-avcodec.so.63.*` and its links |
| android | `include/`, `<abi>/libsk-avcodec.so` |

Each archive also has `configure/<target>.txt`: FFmpeg's configure summary, with every enabled
library and component, to review what a build contains.

They are published as a GitHub release, public and without a login, named `FFmpeg_version`
with `-<FFmpeg_build>` when that is set. Each push to master that changes the build creates
that release or updates it in place (the workflow's release job; resync.md covers when to give
a rebuild a new name instead). The first, `N-127021-ge0c94b2d1c`, was built from that
master commit, before the build moved to releases.

## Adding or removing a library

Bringing back RIST or Blu-ray, for example, takes four changes in `build.sh`:

1. A version line in Settings (`librist_version="..."`).
2. A `download` line in Download, behind a platform test if it's not for every platform.
3. A `buildMeson` or `buildCmake` line in `buildDependencies`, after the libraries it needs
   (librist after mbedTLS). The options turn off its tools, tests and docs; meson builds
   already have `-Dauto_features=disabled`.
4. Its `--enable-...` flag in `FFmpeg_flags`, or in a platform's list.

Then a row in the Versions and Outside libraries tables here. Removing a library is the same
four lines in reverse. FFmpeg finds each library through its pkg-config file with
`--pkg-config-flags=--static`, so its own dependencies follow without extra flags.

## Debugging a build

- **One platform alone:** `sh build.sh <platform>` locally, or the workflow's manual run
  (`workflow_dispatch`). The other platforms keep building when one fails.
- **FFmpeg's configure fails:** the log shows the last 50 lines of `ffbuild/config.log`, which
  name the check that failed (usually a library's pkg-config file or a missing header).
- **What a build contains:** `configure/<target>.txt` in each archive is configure's summary:
  the outside libraries, hardware APIs and components enabled.
- **A dependency fails:** its meson or CMake output is just above, under `BUILDING <name>`.
  Its build folder is `build/<target>/build/<name>`.
- **Reading CI logs:** they need a GitHub login, even on a public repository: without one, the
  API shows the jobs and their status but not their logs. Use `gh run view --log-failed`, or the
  API (`/repos/omega-gg/FFmpeg/actions/jobs/<id>/logs`) with a token that can read Actions.
- **Checking a build:** `python check.py <folder>` (`deploy/bin` on Windows, `deploy/lib` on
  macOS and Linux) loads the libraries, looks for key decoders, encoders, demuxers, filters
  and protocols, and creates each hardware device the build has. A missing component fails it,
  a device the machine can't create is only reported. Tested on Windows.

## Sky's side

The wiring step in Sky (on `bunjee/dev-ffmpeg`) needs:

- **3rdparty:** its `generate.sh` downloads `FFmpeg-<platform>.zip` from the release into
  `<platform>/FFmpeg/<version>`, in an FFmpeg block before VLC's (Qt 6, every platform but
  win32 and linux32).
- **Sky's `configure.sh` and `deploy.sh`:** copy the new names (`sk-*` instead of `av*`), plus
  the macOS dylibs, the iOS xcframeworks and the Android libraries per ABI.
- **`SkMedia.pro`:** link `-lsk-avformat -lsk-avcodec -lsk-avfilter -lsk-avutil -lsk-swscale
  -lsk-swresample`.
- **`WFfmpegPlayer`:**
  - choose the hardware device from the RHI backend (`QSGRendererInterface::graphicsApi()`)
    rather than one per OS (`FFMPEGPLAYER_DEVICE`): d3d11va for D3D11 (the only backend of
    Qt's MinGW kit), d3d12va for D3D12, vulkan for Vulkan, videotoolbox for Metal;
  - on Android, call `av_jni_set_java_vm` and use the `*_mediacodec` decoders;
  - give libass a fonts directory on Android (`/system/fonts`);
  - prefer the hardware H.264 encoders to OpenH264 (see the README's patent note).

## Measured

From the first CI builds (October 2026). Sizes are the six libraries together.

| Platform | Total size | Load time |
|---|---|---|
| win64 | 36 MB | 42 ms (1.15 s the first time, while Windows Defender scans the new DLLs) |
| macOS | 57 MB, both architectures | |
| iOS | 26 MB, device slice | |
| linux64 | 33 MB | |
| android | 28 MB arm64-v8a, 25 MB armeabi-v7a, 33 MB x86, 34 MB x86_64 | |

For comparison, BtbN's LGPL build is 148 MB on win64 and loads in 53 to 62 ms on the same
laptop.

**win64 smoke test** (Intel Iris Xe laptop with an NVIDIA GPU): the DLLs depend only on Windows
and its Universal C Runtime. The h264, hevc, vp9, av1, libdav1d, aac, opus and ass decoders, the
h264_mf, h264_nvenc, h264_amf and libopenh264 encoders, the atempo, subtitles and bwdif filters
and the https, srt, rtmp and udp protocols are all found, and the d3d11va, d3d12va, vulkan and
cuda devices are all created.

**Checked in the archives:**

- **Exports:** the Windows DLLs and the macOS libraries export FFmpeg's symbols only, none of
  dav1d, mbedTLS, libass or the other libraries built in.
- **macOS:** install names `@rpath/libsk-*.dylib`, minimum macOS 12.0.
- **iOS:** each framework links the others as `@rpath/sk-*.framework`, minimum iOS 16.0.
- **Linux:** the system libraries listed under Platforms, nothing else.
