# FFmpeg build: resync

How to move the build to a new FFmpeg commit, and then Sky onto the new build.

## 1. Pick the commit

FFmpeg's master moves fast, so pick a commit that BtbN's daily builds or FFmpeg's FATE results
show as building cleanly. Then get its version name in an FFmpeg clone:

    git clone https://github.com/FFmpeg/FFmpeg
    git -C FFmpeg describe --tags --match N <commit>

That prints `N-<count>-g<hash>`. Set it as `FFmpeg_version` in `build.sh`: the archive is
downloaded from the hash after `-g`, and the name goes into the `VERSION` file FFmpeg reports.

## 2. Check what changed

Between the old commit and the new one, in the clone:

    git -C FFmpeg diff <old>..<new> -- doc/APIchanges
    git -C FFmpeg diff <old>..<new> -- configure

Look for:

- **Library major bumps** (`LIBAVCODEC_VERSION_MAJOR` and so on, in each `version_major.h`): the
  file names change (`sk-avcodec-63.dll` becomes `-64`), so Sky's `deploy.sh` and anything
  naming them must follow.
- **APIs Sky uses** that are deprecated or removed. Sky's FFmpeg code is
  `SkMedia/src/ffmpeg/WFfmpegPlayer.cpp` and `SkMedia/src/media/WBackendFfmpeg.cpp`.
- **Configure options** renamed or removed, used in `FFmpeg_flags` and the `FFmpeg_<platform>`
  lists of `build.sh`.
- **New minimum versions** of outside libraries (`check_pkg_config` / `require_pkg_config`
  lines: Vulkan headers, ffnvcodec, AMF, dav1d, libass, SRT, mbedTLS).
- **New hardware APIs** worth enabling (in `HWACCEL_AUTODETECT_LIBRARY_LIST`): autodetection
  is off, so a new API needs its `--enable-` flag.

## 3. Bump the outside libraries if needed

Each version is one line in the Settings of `build.sh`. Before bumping, check:

- **mbedTLS:** stay on 3.6 until FFmpeg's TLS code supports 4.x (see implementation.md).
- **nv-codec-headers:** a major version raises the minimum NVIDIA driver.
- **NDK:** match the NDK of Sky's Qt (3rdparty's `generate.sh`, `Qt6_ndk`).
- **meson options:** a new release can rename them. The build fails on an unknown option,
  which shows it.

## 4. Build and publish

1. Push to a branch: GitHub Actions builds the five platforms.
2. Check each job, and each archive's `configure/*.txt`: the outside libraries and the
   platform's hardware must all be listed as enabled.
3. Run the checks from implementation.md (load the libraries, find the key decoders, filters
   and protocols, create the hardware devices), and update its Measured table.
4. Merge, then tag the commit with the `FFmpeg_version` name:

       git tag N-<count>-g<hash>
       git push origin N-<count>-g<hash>

   The release job publishes `FFmpeg-<platform>.zip` under that tag. A rebuild of the same
   FFmpeg commit with other options gets `-2`, `-3` appended to the tag.

## 5. Move Sky onto it

- **3rdparty's `generate.sh`:** set the new version; it downloads
  `https://github.com/omega-gg/FFmpeg/releases/download/<version>/FFmpeg-<platform>.zip` into
  `<platform>/FFmpeg/<version>`.
- **Sky's `configure.sh` and `deploy.sh`:** set the same `FFmpeg_version`.
- **Rebuild Sky and test the FFmpeg engine:**
  - frames at given times equal the ones the `ffmpeg` command line extracts;
  - YouTube playback with its separate audio, to the end;
  - speeds 0.5x and 2x, exact seeks paused and playing, seek spam;
  - 4K and HDR playback with hardware decoding.

## What Sky expects from each archive

The layouts and names are in implementation.md, under Archives. They must stay the same from
one version to the next, apart from the library major numbers.
