# Linux libmpv (mpv 0.41.0 + FFmpeg 9.0.2)

media_kit's Linux `libmpv.so.2` came from Predidit/libmpv-linux-build `20260810` (FFmpeg 7.1.5). Pure Live rebuilds the x86_64 library from the same scripts with FFmpeg 9, matching the Android (`../libmpv-android`) and Windows libraries.

- Base: Predidit/libmpv-linux-build `ca3a20ed` (2026-08-10), same `ffmpeg_options` / `mpv_options` as its workflow, with these changes:
  - `./use-ffmpeg-custom n9.0.2` (upstream n7.1.5). dav1d 1.5.4, libplacebo `4c426e46` and mpv `f011d73d` (v0.41.0-11) are unchanged.
  - The upstream FFmpeg patches (Kazumi HLS ad-filter / fake-image segment probing) are VOD-only and not carried; the vendored media_kit no longer sets `hls_ad_filter`. Both mpv patches apply unchanged.
- Build: `build-x86_64.sh` inside `docker.io/library/ubuntu:24.04`, so the library needs at most glibc 2.38:

  ```bash
  podman run --rm --network host \
    -v "$PWD/libmpv-linux-build:/src:ro" -v "$PWD/out:/out" -v "$PWD/mpv_build:/tmp/mpv_build" \
    -v "$PWD/build-x86_64.sh:/build.sh:ro" docker.io/library/ubuntu:24.04 bash /build.sh
  ```

  `/tmp/mpv_build` is a host volume so finished clones survive a retry; `./update` is retried because large clones through a proxy can drop. The script points apt at the Tsinghua mirror (drop that line outside China) and adds `hwdata` (libdisplay-info needs `pnp.ids`), which GitHub's runner image preinstalls.
- Package: `libmpv.so.2` alone, mtime fixed to 2026-09-25 00:00 UTC, `zip -j -X libmpv_x86_64.zip libmpv.so.2`.
- Checks: `Lavc63.1` / `Lavf63.1`, `FFmpeg version n9.0.2`, `mpv v0.41.0-11-gf011d73d5`, highest glibc symbol `GLIBC_2.38`, same `NEEDED` libraries as the upstream build.
- Published as an internal dependency asset (prerelease `native-libmpv-linux-0.41.0-ff9.0.2-b1`, SHA-256 `e21b80a3…d21ee63c`) and referenced from media_kit's `hook/native_bundles.json` (`linux_x64`). The `third_party/` tree was removed when media_kit moved to Native Asset bundles; the pin now lives in the `media_core_media_kit` dependency's media_kit checkout.

## arm64

`linux_arm64` is **not** rebuilt here. media_kit's `hook/native_bundles.json` already pins
`https://github.com/Predidit/libmpv-linux-build/releases/download/20260810/libmpv_aarch64.zip`
(SHA-256 `da0609556e2864dbe828102972edea96173a4be1ad1427a7493942dccb039b9f`), and the
arm64 Linux build consumes it unchanged: the bundle's `lib/libmpv.so.2` is a real
18 MB `ELF 64-bit LSB shared object, ARM aarch64` whose embedded version strings are
`FFmpeg version n7.1.5` / `Lavc61.19`.

That means arm64 Linux plays through FFmpeg 7.1.5 from libmpv while the FFmpeg Kit
runtime used for recording/remuxing is n9.0.2 — the same split the upstream
`20260810` x86_64 asset had before Pure Live rebuilt it. `build-aarch64.sh` is the
mirror of `build-x86_64.sh` for closing that gap later: run it inside
`docker.io/library/ubuntu:24.04` on an arm64 host, package the result as
`libmpv_aarch64.zip` (mtime fixed to 2026-09-25 00:00 UTC), and update the
`linux_arm64` URL and SHA-256 in media_kit's `hook/native_bundles.json` together.

```bash
podman run --rm --network host \
  -v "$PWD/libmpv-linux-build:/src:ro" -v "$PWD/out:/out" -v "$PWD/mpv_build:/tmp/mpv_build" \
  -v "$PWD/build-aarch64.sh:/build.sh:ro" docker.io/library/ubuntu:24.04 bash /build.sh
```

The same checks apply (`Lavc63.1` / `Lavf63.1`, `FFmpeg version n9.0.2`,
`mpv v0.41.0-11-gf011d73d5`, highest glibc symbol `GLIBC_2.38`).
