#!/usr/bin/env bash
#
# Build bundle-base-linux-arm64-shared-lgpl.zip (FFmpeg 9.0.2 / FFmpegKit 0.11.1,
# base preset, LGPL) on an arm64 Linux host.
#
# See README.md for provenance and the checks the result must pass. The
# ffmpeg-kit-builders `runner.sh` needs root and its container image, and the
# published Linux deps archives only cover x86_64, so this script drives the
# upstream CMake layer directly with locally built dependencies.
#
# Environment:
#   PURELIVE_FFBUILD   work + output directory (default: ~/purelive-ffbuild)
#   FFMPEG_KIT_SRC     ffmpeg-kit-builders checkout; must contain FFmpegKit/
#                      (default: <work>/ffmpeg-kit-builders)
#   ANDROID_ABI_JOBS   parallel jobs (default: nproc)
set -euo pipefail

WORK="${PURELIVE_FFBUILD:-$HOME/purelive-ffbuild}"
SRC="${FFMPEG_KIT_SRC:-$WORK/ffmpeg-kit-builders}"
JOBS="$(nproc)"
FFMPEG_TAG='n9.0.2'
JSONCPP_VERSION='1.9.5'
SDL2_VERSION='2.32.8'

DEPS="$WORK/deps"                                   # jsoncpp/sdl2/libssl/libcrypto/libzstd
FFMPEG_PREFIX="$DEPS/ffmpeg-base-linux-arm64-static" # FFmpeg static libs + headers
KIT_PREFIX="$WORK/ffmpegkit-install-arm64"
BUNDLE_ROOT="$WORK/bundle-arm64"
BUNDLE="$BUNDLE_ROOT/bundle-base-linux-arm64-shared-lgpl"
ARCHIVE="$WORK/bundle-base-linux-arm64-shared-lgpl.zip"

die() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -m)" == 'aarch64' || "$(uname -m)" == 'arm64' ]] || die 'build-arm64.sh must run on an arm64 host'
[[ -d "$SRC/FFmpegKit" ]] || die "FFMPEG_KIT_SRC=$SRC does not contain FFmpegKit/ (clone akashskypatel/ffmpeg-kit-builders)"
for tool in cmake ninja pkg-config git zip python3; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

download() {
  # codeload tarballs; retried because large clones/proxies can drop.
  local url="$1" out="$2"
  [[ -s "$out" ]] && return 0
  for attempt in 1 2 3; do
    if curl -sSL --fail --retry 3 -o "$out.part" "$url"; then
      mv "$out.part" "$out"
      return 0
    fi
    echo "download failed (attempt $attempt): $url" >&2
    sleep 5
  done
  die "could not download $url"
}

mkdir -p "$WORK" "$DEPS"

# --- 1. jsoncpp (static) -----------------------------------------------------
# FfmpegKitDependencies.cmake requires jsoncpp through pkg-config even though
# FFmpeg itself does not link it.
if [[ ! -f "$DEPS/lib/libjsoncpp.a" ]]; then
  download "https://codeload.github.com/open-source-parsers/jsoncpp/tar.gz/refs/tags/$JSONCPP_VERSION" \
    "$WORK/jsoncpp-$JSONCPP_VERSION.tar.gz"
  tar xzf "$WORK/jsoncpp-$JSONCPP_VERSION.tar.gz" -C "$WORK"
  cmake -S "$WORK/jsoncpp-$JSONCPP_VERSION" -B "$WORK/jsoncpp-build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DJSONCPP_WITH_TESTS=OFF \
    -DJSONCPP_WITH_CMAKE_PACKAGE=OFF \
    -DJSONCPP_WITH_PKGCONFIG_SUPPORT=ON
  ninja -C "$WORK/jsoncpp-build" install
fi

# --- 2. SDL2 (static) --------------------------------------------------------
if [[ ! -f "$DEPS/lib/libSDL2.a" ]]; then
  download "https://codeload.github.com/libsdl-org/SDL/tar.gz/refs/tags/release-$SDL2_VERSION" \
    "$WORK/SDL-release-$SDL2_VERSION.tar.gz"
  tar xzf "$WORK/SDL-release-$SDL2_VERSION.tar.gz" -C "$WORK"
  cmake -S "$WORK/SDL-release-$SDL2_VERSION" -B "$WORK/sdl2-build-arm64" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$DEPS" \
    -DCMAKE_C_FLAGS=-fPIC \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_STATIC_PIC=ON \
    -DSDL_TEST=OFF -DSDL_TESTS=OFF -DSDL_HIDAPI=OFF
  ninja -C "$WORK/sdl2-build-arm64" install
fi

# --- 3. FFmpeg n9.0.2 (static, base preset) ----------------------------------
# FFmpegKit/CMakeLists.txt hard-requires include/config.h and
# include/config_components.h next to the FFmpeg libraries, and FFmpegKit
# sources include a handful of FFmpeg-internal headers that `make install`
# deliberately omits, so stage them by hand.
stage_ffmpeg_internal_headers() {
  local src="$1" build="$2" inc="$3"
  mkdir -p "$inc/libavcodec/arm" "$inc/libavutil/aarch64" "$inc/libavutil/arm" \
    "$inc/libavformat" "$inc/stdbit"
  cp "$build/config.h" "$inc/config.h"
  cp "$build/config_components.h" "$inc/config_components.h"
  cp "$src/libavcodec/mathops.h" "$inc/libavcodec/mathops.h"
  cp "$src/libavcodec/arm/mathops.h" "$inc/libavcodec/arm/mathops.h"
  cp "$src/libavformat/network.h" "$inc/libavformat/network.h"
  cp "$src/libavformat/os_support.h" "$inc/libavformat/os_support.h"
  cp "$src/libavformat/url.h" "$inc/libavformat/url.h"
  for header in attributes_internal bprint getenv_utf8 internal libm reverse thread timer wchar_filename; do
    cp "$src/libavutil/$header.h" "$inc/libavutil/$header.h"
  done
  cp "$src/libavutil/aarch64/timer.h" "$inc/libavutil/aarch64/timer.h"
  cp "$src/libavutil/arm/timer.h" "$inc/libavutil/arm/timer.h"
  cp "$src/compat/stdbit/stdbit.h" "$inc/stdbit/stdbit.h"
}

# The official asset is built from the n9.0.2 *git tag*; the release/9.0 tarball
# reports "9.0.2" and fails the pinned-version check.
if [[ ! -f "$FFMPEG_PREFIX/lib/libavcodec.a" ]]; then
  if [[ ! -d "$WORK/ffmpeg-$FFMPEG_TAG/.git" ]]; then
    git -c http.version=HTTP/1.1 clone --depth 1 --branch "$FFMPEG_TAG" \
      https://github.com/FFmpeg/FFmpeg.git "$WORK/ffmpeg-$FFMPEG_TAG"
  fi
  FFMPEG_SRC="$WORK/ffmpeg-$FFMPEG_TAG"
  FFMPEG_BUILD="$WORK/ffmpeg-build-$FFMPEG_TAG"
  rm -rf "$FFMPEG_BUILD"; mkdir -p "$FFMPEG_BUILD"
  # The pkg-config search path must put $DEPS before the system dirs: a distro
  # sdl2.pc resolves to an X11-linked libSDL2.a whose unresolved Wayland/pulse
  # symbols fail FFmpeg's --enable-sdl2 link test, which silently drops
  # CONFIG_SDL2/CONFIG_FFPLAY from the official x86_64 configuration.
  export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  export PKG_CONFIG_SYSROOT_DIR=''
  (
    cd "$FFMPEG_BUILD"
    "$FFMPEG_SRC/configure" \
      --disable-autodetect --enable-pthreads \
      --pkg-config=pkg-config --pkg-config-flags=--static \
      --enable-version3 --arch=aarch64 --enable-pic --enable-swscale \
      --prefix="$FFMPEG_PREFIX" \
      --extra-cflags="-ffunction-sections -fdata-sections -fPIC -DPIC -std=gnu17" \
      --extra-cxxflags="-ffunction-sections -fdata-sections -fPIC -DPIC" \
      --extra-ldflags=" -Wl,--allow-multiple-definition " \
      --disable-doc --disable-htmlpages --disable-manpages --disable-podpages --disable-txtpages \
      --disable-outdev=fbdev --disable-indev=fbdev \
      --enable-alsa --enable-sdl2 --enable-iconv --enable-openssl \
      --enable-static --disable-shared --enable-pic \
      --disable-debug --enable-stripping --enable-optimizations \
      --extra-libs="-Wl,--start-group -lpthread -lrt -lm -ldl -lstdc++ -Wl,--end-group"
    make -j"$JOBS"
    make install
  )
  # FFmpegKit/CMakeLists.txt hard-requires include/config.h and
  # include/config_components.h next to the FFmpeg libraries.
  stage_ffmpeg_internal_headers "$FFMPEG_SRC" "$FFMPEG_BUILD" "$FFMPEG_PREFIX/include"
fi

# --- 4. libffmpegkit.so ------------------------------------------------------
# The system libssl/libcrypto/libzstd are matched to the static copies so the
# linked result keeps the official x86_64 asset's narrow NEEDED set.
for lib in ssl crypto zstd; do
  for candidate in /usr/lib/aarch64-linux-gnu/lib$lib.a "$DEPS/lib/lib$lib.a"; do
    [[ -f "$candidate" ]] && cp -f "$candidate" "$DEPS/lib/" && break
  done
done

export PKG_CONFIG_LIBDIR="$FFMPEG_PREFIX/lib/pkgconfig:$DEPS/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_SYSROOT_DIR=''

rm -rf "$WORK/ffmpegkit-build-arm64"
cmake -S "$SRC/FFmpegKit" -B "$WORK/ffmpegkit-build-arm64" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$KIT_PREFIX" \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTS=OFF \
  -DFFMPEG_STATIC=ON \
  -DFFMPEG_BUILD_DIR="$FFMPEG_PREFIX" \
  -DDEPENDENCY_BUILD_DIR="$DEPS" \
  -DFFMPEG_KIT_BUNDLE_TYPE=base \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,--allow-multiple-definition"
ninja -C "$WORK/ffmpegkit-build-arm64"
ninja -C "$WORK/ffmpegkit-build-arm64" install

# --- 5. Assemble the bundle --------------------------------------------------
# Mirrors the official archive: bin/, include/, lib/libffmpegkit.so,
# lib/ffmpegkit.pc, lib/pkgconfig/, licenses/. bin/ stays empty (the hook also
# scans it for .so files and would otherwise pick up ffmpeg/ffprobe).
rm -rf "$BUNDLE_ROOT"
mkdir -p "$BUNDLE/bin" "$BUNDLE/lib/pkgconfig" "$BUNDLE/licenses"
cp -a "$KIT_PREFIX/include/." "$BUNDLE/include/"
cp -a "$FFMPEG_PREFIX/include/." "$BUNDLE/include/"
cp "$KIT_PREFIX/lib/libffmpegkit.so" "$BUNDLE/lib/"
cp "$KIT_PREFIX/lib/pkgconfig/ffmpegkit.pc" "$BUNDLE/lib/ffmpegkit.pc"
# License texts are architecture-independent, so reuse the x86_64 asset's
# copies. Fetch the same internal asset tool/prefetch_linux_native.sh pins for
# x86_64: it carries all six notices (ffmpeg-kit, ffmpeg, jsoncpp, meson,
# openssl, sdl2) the upstream builders release no longer ships. Falls back to
# the checkout's own LICENSE files when the reference archive is unavailable.
X64_REF="$WORK/ref-bundle-base-linux-x86_64-shared-lgpl.zip"
if [[ ! -s "$X64_REF" ]]; then
  download "https://github.com/wzgrx/pure_live/releases/download/native-ffmpeg-9.0.2-b1/bundle-base-linux-x86_64-shared-lgpl.zip" "$X64_REF"
fi
if unzip -o -q -j "$X64_REF" 'bundle-base-linux-x86_64-shared-lgpl/licenses/*' -d "$BUNDLE/licenses"; then
  echo "licenses: copied from the pinned x86_64 asset"
else
  echo "licenses: reference archive extraction failed; using checkout licenses" >&2
  for license in "$SRC"/LICENSE* "$SRC"/FFmpegKit/LICENSE*; do
    [[ -f "$license" ]] || continue
    cp "$license" "$BUNDLE/licenses/ffmpeg-kit_license.txt"
  done
fi

# Fixed mtime so the archive digest is reproducible.
find "$BUNDLE" -exec touch -h -d '2026-10-15T00:00:00Z' {} +
rm -f "$ARCHIVE"
(cd "$BUNDLE_ROOT" && zip -qr -X "$ARCHIVE" "$(basename "$BUNDLE")")

echo
echo "bundle: $ARCHIVE"
echo "sha256: $(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
echo
echo "Next: upload it beside bundle-base-linux-x86_64-shared-lgpl.zip, then pin the"
echo "digest in tool/verify_ffmpeg_native.py (LINUX_ARCHIVE_SHA256['arm64']) and"
echo "tool/prefetch_linux_native.sh (--arch arm64)."
