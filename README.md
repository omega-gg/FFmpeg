FFmpeg build
---
[![build](https://github.com/omega-gg/FFmpeg/actions/workflows/build.yml/badge.svg)](https://github.com/omega-gg/FFmpeg/actions/workflows/build.yml)

FFmpeg for Sky's FFmpeg player backend, a possible replacement for libVLC: everything playback
needs, for Windows, macOS, Linux, iOS and Android.

    sh build.sh <win64 | macOS | iOS | linux | android>

The result goes to `deploy/`, the work files to `build/`. GitHub Actions builds the five
platforms on every push. A push to master publishes them as a release named after the version
in `build.sh`, once per version, which 3rdparty downloads:

    https://github.com/omega-gg/FFmpeg/releases/download/<version>/FFmpeg-<platform>.zip

## Building locally

- **Host:** Ubuntu for win64, linux and android (`linux` expects Ubuntu 22.04, as CI), macOS
  for macOS and iOS.
- **It changes the machine:** `build.sh` installs its tools with `sudo apt-get` or `brew`, and
  for android the NDK through `sdkmanager` (`ANDROID_HOME` must be set). meson, ninja and CMake
  go to a Python venv inside `build/`.
- **Each run starts clean:** `build/` and `deploy/` are deleted first.
- **Checking the result:** `python check.py deploy/bin` (Windows) or `deploy/lib` (macOS,
  Linux) loads the libraries and checks key components and the hardware devices.

## Documents

- [implementation.md](implementation.md): what the build contains and why, to adjust it.
- [resync.md](resync.md): how to move to a new FFmpeg commit.
- [doc/build.md](doc/build.md): the original plan.

## License

The libraries are LGPL version 3 (FFmpeg configured with `--enable-version3`), with nothing GPL
or nonfree inside. The libraries built in are under compatible licenses, listed in
[implementation.md](implementation.md).

OpenH264 is built from source here. Cisco's H.264 patent license only covers Cisco's own
binaries, so the hardware H.264 encoders are preferred, and OpenH264 is the fallback.
