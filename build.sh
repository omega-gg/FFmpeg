#!/bin/sh
set -e

#--------------------------------------------------------------------------------------------------
# Settings
#--------------------------------------------------------------------------------------------------
# NOTE: See implementation.md for what each library brings, and resync.md to move to a new
#       FFmpeg commit.

FFmpeg_version="N-127021-ge0c94b2d1c"

#--------------------------------------------------------------------------------------------------
# Libraries built in

zlib_version="1.3.1"
mbedtls_version="3.6.7"
libxml2_version="2.14.6"
freetype_version="2.14.1"
fribidi_version="1.0.16"
harfbuzz_version="14.5.1"
libass_version="0.17.4"
dav1d_version="1.5.3"
openh264_version="2.6.0"
srt_version="1.5.4"

#--------------------------------------------------------------------------------------------------
# Headers only

VulkanHeaders_version="1.4.341.0"
nvcodec_version="12.1.14.1"
AMF_version="1.5.3"

#--------------------------------------------------------------------------------------------------
# Platforms

macOS_version="12.0"
iOS_version="16.0"

NDK_version="28.2.13676358"
android_api="28"

#--------------------------------------------------------------------------------------------------
# FFmpeg

# NOTE: Every native component is in, the outside libraries come only from this list.
FFmpeg_flags="--disable-autodetect --disable-programs --disable-doc --disable-avdevice
              --disable-debug --enable-shared --disable-static --enable-version3 --enable-pic
              --enable-network --enable-zlib --enable-mbedtls --enable-libxml2 --enable-libass
              --enable-libdav1d --enable-libopenh264 --enable-libsrt"

FFmpeg_win64="--enable-w32threads --enable-d3d11va --enable-d3d12va --enable-mediafoundation
              --enable-vulkan --enable-ffnvcodec --enable-nvdec --enable-nvenc --enable-amf"

FFmpeg_apple="--enable-pthreads --enable-videotoolbox"

FFmpeg_linux="--enable-pthreads --enable-vaapi --enable-vulkan --enable-ffnvcodec --enable-nvdec
              --enable-nvenc --enable-amf"

FFmpeg_android="--enable-pthreads --enable-jni --enable-mediacodec"

#--------------------------------------------------------------------------------------------------
# Functions
#--------------------------------------------------------------------------------------------------

download()
{
    echo ""
    echo "DOWNLOADING $1"
    echo $2

    mkdir -p "$source/$1"

    curl -L --retry 3 -o "$source/$1.tar" "$2"

    tar -xf "$source/$1.tar" -C "$source/$1" --strip-components=1

    rm "$source/$1.tar"
}

# NOTE: Writes the words of $1 as a meson list.
mesonList()
{
    list=""

    for word in $1; do

        list="$list, '$word'"
    done

    echo "[${list#, }]"
}

#--------------------------------------------------------------------------------------------------

# NOTE: Starts a target: where it builds, and its compilers and flags reset.
setTarget()
{
    echo ""
    echo "TARGET $1"

    target="$1"

    prefix="$build/$1"

    mkdir -p "$prefix/build"

    cflags=""
    ldflags=""
    libs=""

    windres=""

    meson_cross=""
    cmake_args=""

    slibpref="libsk-"

    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
}

# NOTE: The meson cross file of the target: crossFile <system> <cpu family> <cpu>.
crossFile()
{
    cat > "$prefix/cross.txt" <<EOF
[binaries]
c = $(mesonList "$cc")
cpp = $(mesonList "$cxx")
ar = '$ar'
strip = '$strip'
pkg-config = 'pkg-config'
$([ -n "$windres" ] && echo "windres = '$windres'")

[built-in options]
c_args = $(mesonList "$cflags")
cpp_args = $(mesonList "$cflags")
c_link_args = $(mesonList "$ldflags")
cpp_link_args = $(mesonList "$ldflags")

[host_machine]
system = '$1'
cpu_family = '$2'
cpu = '$3'
endian = 'little'
EOF

    meson_cross="--cross-file=$prefix/cross.txt"
}

targetWindows()
{
    setTarget win64

    host="x86_64-w64-mingw32"

    # NOTE: The posix variants have the C++ threads SRT needs.
    cc="$host-gcc-posix"
    cxx="$host-g++-posix"
    ar="$host-ar"
    strip="$host-strip"
    windres="$host-windres"

    # NOTE: The GCC, C++ and pthread runtimes are linked in everywhere, so no DLL version of
    #       them is mixed in. Windows' own libraries stay import libraries.
    ldflags="-static"

    libs="-lstdc++ -lbcrypt"

    slibpref="sk-"

    libass_fonts="-Ddirectwrite=enabled"

    crossFile windows x86_64 x86_64

    cmake_args="-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=$cc -DCMAKE_CXX_COMPILER=$cxx
                -DCMAKE_RC_COMPILER=$windres"

    FFmpeg_target="--target-os=mingw32 --arch=x86_64 --enable-cross-compile
                   --cross-prefix=$host- --cc=$cc --cxx=$cxx $FFmpeg_win64"
}

# NOTE: targetApple <name> <arch> <sdk> <minimum version flag> [cmake system]
targetApple()
{
    setTarget $1

    sdk=$(xcrun --sdk $3 --show-sdk-path)

    cc="clang"
    cxx="clang++"
    ar="ar"
    strip="strip"

    cflags="-arch $2 -isysroot $sdk $4"
    ldflags="$cflags"

    libs="-lc++"

    libass_fonts="-Dcoretext=enabled"

    if [ $2 = "arm64" ]; then

        crossFile darwin aarch64 arm64
    else
        crossFile darwin x86_64 x86_64
    fi

    cmake_args="-DCMAKE_OSX_ARCHITECTURES=$2 -DCMAKE_OSX_SYSROOT=$sdk $5"

    FFmpeg_target="--target-os=darwin --arch=$2 --enable-cross-compile --cc=$cc --cxx=$cxx
                   --install-name-dir=@rpath $FFmpeg_apple"
}

targetLinux()
{
    setTarget linux

    # NOTE: libva, fontconfig and their dependencies come from the system.
    unset PKG_CONFIG_LIBDIR

    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

    libs="-lstdc++"

    libass_fonts="-Dfontconfig=enabled"

    FFmpeg_target="$FFmpeg_linux"
}

# NOTE: targetAndroid <abi>
targetAndroid()
{
    setTarget android-$1

    toolchain="$NDK/toolchains/llvm/prebuilt/linux-x86_64"

    extra=""

    if [ $1 = "armeabi-v7a" ]; then

        triple="armv7a-linux-androideabi"
        family="arm"
        cpu="armv7"
        arch="arm"
        extra="--cpu=armv7-a"

    elif [ $1 = "arm64-v8a" ]; then

        triple="aarch64-linux-android"
        family="aarch64"
        cpu="aarch64"
        arch="aarch64"

    elif [ $1 = "x86" ]; then

        triple="i686-linux-android"
        family="x86"
        cpu="i686"
        arch="x86"
        # NOTE: The 32 bits x86 assembly has text relocations, which Android refuses.
        extra="--disable-asm"
    else
        triple="x86_64-linux-android"
        family="x86_64"
        cpu="x86_64"
        arch="x86_64"
    fi

    cc="$toolchain/bin/$triple$android_api-clang"
    cxx="$toolchain/bin/$triple$android_api-clang++"
    ar="$toolchain/bin/llvm-ar"
    strip="$toolchain/bin/llvm-strip"

    # NOTE: Android 15 devices can have 16 KB pages.
    ldflags="-Wl,-z,max-page-size=16384"

    libs="-lc++_static -lc++abi"

    # NOTE: Android has no font provider, the fonts are given to libass when rendering.
    libass_fonts="-Drequire-system-font-provider=false"

    crossFile android $family $cpu

    cmake_args="-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake
                -DANDROID_ABI=$1 -DANDROID_PLATFORM=$android_api"

    FFmpeg_target="--target-os=android --arch=$arch --enable-cross-compile
                   --cross-prefix=$toolchain/bin/llvm- --cc=$cc --cxx=$cxx $extra
                   $FFmpeg_android"
}

#--------------------------------------------------------------------------------------------------

buildMeson()
{
    echo ""
    echo "BUILDING $1"

    meson setup "$prefix/build/$1" "$source/$1" --prefix="$prefix" --libdir=lib \
                --buildtype=release --default-library=static -Dauto_features=disabled \
                $meson_cross $2

    meson compile -C "$prefix/build/$1"
    meson install -C "$prefix/build/$1"
}

# NOTE: The prefix is also a find root, toolchains like the NDK's only search under their roots.
buildCmake()
{
    echo ""
    echo "BUILDING $1"

    cmake -S "$source/$1" -B "$prefix/build/$1" -G Ninja -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
          -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH="$prefix" \
          -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON $cmake_args $2

    cmake --build "$prefix/build/$1"

    cmake --install "$prefix/build/$1"
}

# NOTE: zlib has no cross build for MinGW in its configure, only this makefile.
buildZlib()
{
    echo ""
    echo "BUILDING zlib"

    cp -r "$source/zlib" "$prefix/build/zlib"

    make -C "$prefix/build/zlib" -f win32/Makefile.gcc PREFIX=$host- \
         BINARY_PATH="$prefix/bin" INCLUDE_PATH="$prefix/include" LIBRARY_PATH="$prefix/lib" \
         install
}

# NOTE: Vulkan, NVIDIA and AMD are headers only, FFmpeg loads their libraries at run time.
installHeaders()
{
    echo ""
    echo "INSTALLING headers"

    mkdir -p "$prefix/include"

    cp -r "$source/VulkanHeaders"/include/* "$prefix/include"

    cp -r "$source/AMF/AMF" "$prefix/include"

    make -C "$source/nvcodec" PREFIX="$prefix" install
}

buildDependencies()
{
    if [ $platform = "win64" -o $platform = "linux" ]; then

        installHeaders
    fi

    if [ $platform = "win64" ]; then

        buildZlib
    fi

    buildCmake mbedtls "-DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DGEN_FILES=OFF"

    buildCmake libxml2 "-DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_ICONV=OFF
                        -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF -DLIBXML2_WITH_ICU=OFF
                        -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_PROGRAMS=OFF"

    buildMeson freetype
    buildMeson fribidi  "-Ddocs=false -Dbin=false -Dtests=false"
    # NOTE: Its utilities and GPU part default to on, whatever auto_features says.
    buildMeson harfbuzz "-Dfreetype=enabled -Dutilities=disabled -Dgpu=disabled"
    buildMeson libass   "$libass_fonts"

    buildMeson dav1d "-Denable_tools=false -Denable_tests=false -Denable_examples=false"

    buildMeson openh264

    # NOTE: Its CMakeLists asks for a CMake older than 3.5, which CMake 4 refuses by default.
    #       mbedTLS is given by name, so srt.pc links it after SRT rather than by file paths
    #       that pkg-config would put first.
    buildCmake srt "-DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF
                    -DENABLE_UNITTESTS=OFF -DUSE_ENCLIB=mbedtls -DENABLE_STDCXX_SYNC=ON
                    -DSSL_INCLUDE_DIRS=$prefix/include -DSSL_LIBRARY_DIRS=$prefix/lib
                    -DSSL_LIBRARIES=mbedtls;mbedcrypto -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
}

# NOTE: Our libraries are named sk-avcodec and so on: SLIBPREF names them, LD_LIB links them to
#       each other. Qt Multimedia's FFmpeg keeps its names, both load side by side.
buildFfmpeg()
{
    buildDependencies

    echo ""
    echo "BUILDING FFmpeg"

    mkdir -p "$prefix/build/ffmpeg"

    cd "$prefix/build/ffmpeg"

    "$source/ffmpeg/configure" --prefix="$prefix/ffmpeg" $FFmpeg_flags $FFmpeg_target \
                               --pkg-config=pkg-config --pkg-config-flags=--static \
                               --extra-cflags="-I$prefix/include $cflags" \
                               --extra-ldflags="-L$prefix/lib $ldflags" \
                               --extra-libs="$libs" > "$prefix/configure.txt" || {

        tail -n 50 ffbuild/config.log

        exit 1
    }

    cat "$prefix/configure.txt"

    make -j$jobs SLIBPREF=$slibpref LD_LIB=-lsk-%

    make install SLIBPREF=$slibpref LD_LIB=-lsk-%

    cd "$root"

    mkdir -p "$deploy/configure"

    cp "$prefix/configure.txt" "$deploy/configure/$target.txt"
}

#--------------------------------------------------------------------------------------------------

# NOTE: The framework name of a library file: libsk-avcodec.63.dylib gives sk-avcodec.
frameworkName()
{
    name=$(basename "$1")
    name=${name%%.*}

    echo ${name#lib}
}

# NOTE: Wraps the libraries of an iOS target into frameworks, as Qt does with its FFmpeg.
frameworks()
{
    for file in "$build/$1/ffmpeg/lib"/libsk-*.dylib; do

        if [ -L "$file" ]; then continue; fi

        name=$(frameworkName "$file")

        path="$build/$1/frameworks/$name.framework"

        mkdir -p "$path"

        cp "$file" "$path/$name"

        install_name_tool -id "@rpath/$name.framework/$name" "$path/$name"

        for dependency in $(otool -L "$path/$name" | grep -o "@rpath/libsk-[^ ]*"); do

            library=$(frameworkName "$dependency")

            install_name_tool -change "$dependency" "@rpath/$library.framework/$library" \
                              "$path/$name"
        done

        cat > "$path/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$name</string>
    <key>CFBundleIdentifier</key>
    <string>gg.omega.$name</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>$iOS_version</string>
</dict>
</plist>
EOF
    done
}

#--------------------------------------------------------------------------------------------------
# Syntax
#--------------------------------------------------------------------------------------------------

if [ $# != 1 ] \
   || \
   [ $1 != "win64" -a $1 != "macOS" -a $1 != "iOS" -a $1 != "linux" -a $1 != "android" ]; then

    echo "Usage: build <win64 | macOS | iOS | linux | android>"

    exit 1
fi

#--------------------------------------------------------------------------------------------------
# Configuration
#--------------------------------------------------------------------------------------------------

platform="$1"

root="$PWD"

build="$root/build"
source="$build/source"
deploy="$root/deploy"

jobs=$(getconf _NPROCESSORS_ONLN)

github="https://github.com"

#--------------------------------------------------------------------------------------------------
# Clean
#--------------------------------------------------------------------------------------------------

echo "CLEANING"

rm -rf build deploy

mkdir -p "$source"

mkdir  deploy
touch  deploy/.gitignore

#--------------------------------------------------------------------------------------------------
# Install
#--------------------------------------------------------------------------------------------------

echo ""
echo "INSTALLING tools"

if [ $platform = "macOS" -o $platform = "iOS" ]; then

    brew install nasm pkgconf
else
    sudo apt-get update

    sudo apt-get -y install build-essential pkg-config nasm curl xz-utils bzip2 python3-venv

    if [ $platform = "win64" ]; then

        sudo apt-get -y install mingw-w64

    elif [ $platform = "linux" ]; then

        sudo apt-get -y install libva-dev libfontconfig-dev libexpat1-dev
    fi
fi

# NOTE: Recent meson, ninja and CMake on every runner, the dependencies need them.
python3 -m venv "$build/venv"

"$build/venv/bin/pip" install meson ninja cmake

export PATH="$build/venv/bin:$PATH"

if [ $platform = "android" ]; then

    yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "ndk;$NDK_version" > /dev/null

    NDK="$ANDROID_HOME/ndk/$NDK_version"
fi

#--------------------------------------------------------------------------------------------------
# Download
#--------------------------------------------------------------------------------------------------

download ffmpeg $github/FFmpeg/FFmpeg/archive/${FFmpeg_version##*-g}.tar.gz

# NOTE: FFmpeg reads its version from this file when it is not a git checkout.
echo "$FFmpeg_version" > "$source/ffmpeg/VERSION"

v=$mbedtls_version
download mbedtls $github/Mbed-TLS/mbedtls/releases/download/mbedtls-$v/mbedtls-$v.tar.bz2

v=$libxml2_version
download libxml2 https://download.gnome.org/sources/libxml2/${v%.*}/libxml2-$v.tar.xz

v=$freetype_version
download freetype https://download.savannah.gnu.org/releases/freetype/freetype-$v.tar.xz

v=$fribidi_version
download fribidi $github/fribidi/fribidi/releases/download/v$v/fribidi-$v.tar.xz

v=$harfbuzz_version
download harfbuzz $github/harfbuzz/harfbuzz/releases/download/$v/harfbuzz-$v.tar.xz

v=$libass_version
download libass $github/libass/libass/releases/download/$v/libass-$v.tar.xz

v=$dav1d_version
download dav1d https://downloads.videolan.org/pub/videolan/dav1d/$v/dav1d-$v.tar.xz

download openh264 $github/cisco/openh264/archive/refs/tags/v$openh264_version.tar.gz

download srt $github/Haivision/srt/archive/refs/tags/v$srt_version.tar.gz

if [ $platform = "win64" ]; then

    v=$zlib_version
    download zlib $github/madler/zlib/releases/download/v$v/zlib-$v.tar.xz
fi

if [ $platform = "win64" -o $platform = "linux" ]; then

    v=$VulkanHeaders_version
    download VulkanHeaders \
             $github/KhronosGroup/Vulkan-Headers/archive/refs/tags/vulkan-sdk-$v.tar.gz

    v=$nvcodec_version
    download nvcodec \
             $github/FFmpeg/nv-codec-headers/releases/download/n$v/nv-codec-headers-$v.tar.gz

    v=$AMF_version
    download AMF $github/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v$v/AMF-headers-v$v.tar.gz
fi

#--------------------------------------------------------------------------------------------------
# Build
#--------------------------------------------------------------------------------------------------

if [ $platform = "win64" ]; then

    targetWindows
    buildFfmpeg

elif [ $platform = "macOS" ]; then

    flag="-mmacosx-version-min=$macOS_version"

    cmake="-DCMAKE_OSX_DEPLOYMENT_TARGET=$macOS_version"

    targetApple macOS-arm64 arm64 macosx $flag "$cmake"
    buildFfmpeg

    targetApple macOS-x86_64 x86_64 macosx $flag "$cmake"
    buildFfmpeg

elif [ $platform = "iOS" ]; then

    cmake="-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=$iOS_version"

    targetApple iOS-arm64 arm64 iphoneos -miphoneos-version-min=$iOS_version "$cmake"
    buildFfmpeg

    targetApple iOS-x86_64 x86_64 iphonesimulator -mios-simulator-version-min=$iOS_version \
                "$cmake"
    buildFfmpeg

elif [ $platform = "linux" ]; then

    targetLinux
    buildFfmpeg
else
    for abi in armeabi-v7a arm64-v8a x86 x86_64; do

        targetAndroid $abi
        buildFfmpeg
    done
fi

#--------------------------------------------------------------------------------------------------
# Deploy
#--------------------------------------------------------------------------------------------------

echo ""
echo "DEPLOYING FFmpeg"

if [ $platform = "win64" ]; then

    path="$build/win64/ffmpeg"

    cp -r "$path/include" "$deploy"

    mkdir "$deploy/bin" "$deploy/lib"

    cp "$path"/bin/sk-*.dll "$deploy/bin"

    # NOTE: FFmpeg installs the MSVC import libraries beside the DLLs.
    cp "$path"/bin/sk-*.lib       "$deploy/lib"
    cp "$path"/lib/libsk-*.dll.a "$deploy/lib"

elif [ $platform = "macOS" ]; then

    path="$build/macOS-arm64/ffmpeg"

    cp -r "$path/include" "$deploy"

    mkdir "$deploy/lib"

    # NOTE: One universal library per FFmpeg library, under the name its install name gives.
    for file in "$path"/lib/libsk-*.dylib; do

        if [ -L "$file" ]; then continue; fi

        name=$(basename "$(otool -D "$file" | tail -n 1)")

        lipo -create "$file" "$build/macOS-x86_64/ffmpeg/lib/$(basename "$file")" \
             -output "$deploy/lib/$name"

        ln -s "$name" "$deploy/lib/${name%%.*}.dylib"
    done

elif [ $platform = "iOS" ]; then

    cp -r "$build/iOS-arm64/ffmpeg/include" "$deploy"

    mkdir "$deploy/lib"

    frameworks iOS-arm64
    frameworks iOS-x86_64

    for path in "$build/iOS-arm64/frameworks"/*.framework; do

        name=$(basename "$path" .framework)

        xcodebuild -create-xcframework -framework "$path" \
                   -framework "$build/iOS-x86_64/frameworks/$name.framework" \
                   -output "$deploy/lib/$name.xcframework"
    done

elif [ $platform = "linux" ]; then

    path="$build/linux/ffmpeg"

    cp -r "$path/include" "$deploy"

    mkdir "$deploy/lib"

    cp -P "$path"/lib/libsk-*.so* "$deploy/lib"
else
    cp -r "$build/android-arm64-v8a/ffmpeg/include" "$deploy"

    for abi in armeabi-v7a arm64-v8a x86 x86_64; do

        mkdir "$deploy/$abi"

        cp "$build/android-$abi/ffmpeg"/lib/libsk-*.so "$deploy/$abi"
    done
fi
