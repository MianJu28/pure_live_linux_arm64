# Linux libffmpegkit (FFmpeg 9.0.2, arm64)

`ffmpeg_kit_extended_flutter` resolves its native runtime through the
`ffmpeg-kit-builders` release that its build hook computes from the *target*
CPU:

```
https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-<platform>/bundle-base-<platform>-<arch>-shared-lgpl.zip
```

Those releases publish `linux-x86_64` only. For Linux arm64 the hook therefore
asks for `bundle-base-linux-arm64-shared-lgpl.zip`, which does not exist
upstream, and the build stops at:

```
Exception: FFmpegKit [Build Hook]: Failed to download from
https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v0.11.1-linux/bundle-base-linux-arm64-shared-lgpl.zip
```

`build-arm64.sh` reproduces the upstream `base` bundle for arm64. The result is
consumed exactly like the x86_64 asset: upload it next to
`bundle-base-linux-x86_64-shared-lgpl.zip`, pin its SHA-256 in
`tool/verify_ffmpeg_native.py` (`LINUX_ARCHIVE_SHA256['arm64']`) and
`tool/prefetch_linux_native.sh` (`--arch arm64`), then `--local-archive` can be
dropped.

## Upstream provenance

The bundle must match the pinned x86_64 asset, which is built by
`ffmpeg-kit-builders` `0.11.1` with the `base` preset:

- FFmpeg **n9.0.2** (`Lavc63.1`, `Lavf63.1`), the upstream git tag — not the
  `release/9.0` branch, which reports `9.0.2` and fails the `n9.0.2` check in
  `tool/verify_ffmpeg_native.py`.
- `FFMPEG_KIT_BUNDLE_TYPE=base`, LGPL-3.0, no GPL components. The enabled
  external libraries are only ALSA, OpenSSL, iconv and SDL2; every `LIB*`
  switch (x264, vpx, mp3lame, freetype, harfbuzz, dav1d, …) is off.
- C++ API linked against FFmpeg's **static** `libav*.a` with
  `BUILD_SHARED_LIBS=ON`, so `libffmpegkit.so` needs only libasound/libm/
  libstdc++/libgcc_s/libc — the same `NEEDED` set as the x86_64 asset.

## Build

On an arm64 host with a C/C++ toolchain, `cmake`, `ninja` and `pkg-config`:

```bash
./build-arm64.sh                 # deps and archive land in $PURELIVE_FFBUILD (default: ~/purelive-ffbuild)
```

The script:

1. checks out FFmpeg at tag `n9.0.2` and configures a static arm64 build with
   the exact upstream flags (`--disable-autodetect --enable-version3
   --enable-pic --enable-swscale --enable-alsa --enable-sdl2 --enable-iconv
   --enable-openssl --enable-static --disable-shared --enable-stripping
   --enable-optimizations`); `$DEPS/lib/pkgconfig` is placed first on
   `PKG_CONFIG_LIBDIR` so `--enable-sdl2` resolves the locally built,
   dlopen-based `libSDL2.a` instead of a distro copy whose unresolved
   Wayland/pulse symbols would silently drop `CONFIG_SDL2`/`CONFIG_FFPLAY`;
2. builds `jsoncpp` 1.9.5 and `SDL2` 2.32.8 as static libraries into the same
   prefix, since FFmpegKit's `FfmpegKitDependencies.cmake` requires `jsoncpp`
   and `sdl2` through `pkg-config` regardless of what FFmpeg linked;
3. stages the FFmpeg internal headers (`config.h`, `config_components.h`) into
   the prefix, which `FFmpegKit/CMakeLists.txt` makes a hard requirement;
4. configures `FFmpegKit` with `-DFFMPEG_STATIC=ON -DBUILD_SHARED_LIBS=ON
   -DFFMPEG_KIT_BUNDLE_TYPE=base` and links `libffmpegkit.so`;
5. assembles `bundle-base-linux-arm64-shared-lgpl/{bin,lib,include,licenses}`
   and zips it, then prints the SHA-256 to pin. `licenses/` is copied verbatim
   from the asset `tool/prefetch_linux_native.sh` pins for x86_64
   (`native-ffmpeg-9.0.2-b1`), because the texts are architecture-independent
   and the upstream `v0.11.1-linux` release only carries one of the six notices.

`FFMPEG_KIT_SRC` must point at an `ffmpeg-kit-builders` checkout (the script
expects `$FFMPEG_KIT_SRC/FFmpegKit`). Note the upstream `runner.sh` requires
root and a container image; this script drives its CMake layer directly, which
is what the arm64 build needs because the published deps archives for Linux
only cover `x86_64`.

### Verified build

Built on Deepin 25 (aarch64), glibc 2.38, clang 17.0.6 + cmake 3.31.4 + ninja
1.12.1:

- `libffmpegkit.so`: `ELF 64-bit LSB shared object, ARM aarch64`, 33,136,408 B
- `FFmpeg version n9.0.2`, `Lavc63.1`, `CONFIG_SDL2 1`, `CONFIG_FFPLAY 1`
  (matching the x86_64 asset's `include/config.h`)
- `NEEDED`: `libasound.so.2 libm.so.6 libstdc++.so.6 libgcc_s.so.1 libc.so.6
  ld-linux-aarch64.so.1` (identical set to the x86_64 asset)
- highest glibc symbol `GLIBC_2.38`, matching the Ubuntu 24.04 ceiling enforced
  by `tool/verify_ffmpeg_native.py`

## Checks

```bash
python3 tool/verify_ffmpeg_native.py linux <bundle>/lib/libffmpegkit.so --arch arm64
unzip -p bundle-base-linux-arm64-shared-lgpl.zip \
  'bundle-base-linux-arm64-shared-lgpl/lib/libffmpegkit.so' | strings | grep 'FFmpeg version n9.0.2'
```

The archive must contain exactly one `lib/libffmpegkit.so` (the hook scans
`bin/` and `lib/` for `.so` files; `bin/` may stay empty) and match the official
bundle layout: `bin/`, `include/`, `lib/libffmpegkit.so`,
`lib/ffmpegkit.pc`, `lib/pkgconfig/`, `licenses/`.
