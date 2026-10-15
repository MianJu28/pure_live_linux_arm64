#!/usr/bin/env bash
#
# Seed the ffmpeg_kit_extended_flutter Native Assets cache for a Linux build.
#
# Why this exists: three of the four platforms already seed this cache with a
# *pinned* archive before Flutter runs (Windows and Android through
# tool/prefetch_android_native.ps1 and tool/prefetch_windows_native.ps1). Linux
# did not. The hook would then fetch whatever archive its own default points at —
# a different builder release than the one `tool/verify_ffmpeg_native.py` pins —
# and the build ended at:
#
#   ValueError: Linux FFmpeg hook archive SHA-256 differs from pinned n9.0.2 asset
#
# because the release step verifies (and stages) exactly
# .dart_tool/hooks_runner/shared/ffmpeg_kit_extended_flutter/build/ffmpeg_kit_cache/linux/bundle-base-linux-<arch>-shared-lgpl.zip
# against the SHA-256 recorded in that script.
#
# Responsibilities:
#
# - download the pinned Linux archive and refuse it unless the hash matches
# - place it exactly where the hook looks, so the hook never downloads
#
# It does not:
#
# - extract anything (the hook does)
# - decide which variant to use (the pinned hash in verify_ffmpeg_native.py does)
#
# Architectures: the hook names the asset after the *target* CPU, so x86_64 and
# arm64 downloads are different files. The upstream ffmpeg-kit-builders releases
# only publish `linux-x86_64`, so the arm64 archive is built by
# tool/native/ffmpeg-kit-linux/build-arm64.sh and published beside the pinned
# x86_64 asset (release native-ffmpeg-9.0.2-b1). Its digest is pinned in
# tool/verify_ffmpeg_native.py; seed it locally with
# `--local-archive <zip>` until that upload exists.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: prefetch_linux_native.sh [--arch x86_64|arm64] [--local-archive PATH]

  --arch           Linux target architecture (default: host architecture)
  --local-archive  Seed from a locally built bundle-base-linux-<arch>-shared-lgpl.zip
                   instead of downloading it
EOF
}

arch=""
local_archive=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) arch="${2:?--arch needs a value}"; shift 2 ;;
    --local-archive) local_archive="${2:?--local-archive needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$arch" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) arch='x86_64' ;;
    aarch64|arm64) arch='arm64' ;;
    *) echo "error: unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
  esac
fi

case "$arch" in
  x86_64)
    archive_name='bundle-base-linux-x86_64-shared-lgpl.zip'
    url='https://github.com/wzgrx/pure_live/releases/download/native-ffmpeg-9.0.2-b1/bundle-base-linux-x86_64-shared-lgpl.zip'
    sha256='d6003c3feb2bdcdccd0d4ad5e7b76fa8e8951430c6a22c1db7be5e13da19403d'
    ;;
  arm64)
    archive_name='bundle-base-linux-arm64-shared-lgpl.zip'
    url='https://github.com/wzgrx/pure_live/releases/download/native-ffmpeg-9.0.2-b1/bundle-base-linux-arm64-shared-lgpl.zip'
    # Pinned to the arm64 bundle built locally by
    # tool/native/ffmpeg-kit-linux/build-arm64.sh; keep in sync with
    # LINUX_ARCHIVE_SHA256['arm64'] in tool/verify_ffmpeg_native.py.
    sha256='4420cf0a323d4400397507300ddd3369320d9aa6264fb410afcb2b46496aaa90'
    ;;
  *) echo "error: unsupported --arch: $arch" >&2; exit 1 ;;
esac

cache_dir="$repo_root/.dart_tool/hooks_runner/shared/ffmpeg_kit_extended_flutter/build/ffmpeg_kit_cache/linux"
target="$cache_dir/$archive_name"
scratch="$(mktemp -d)"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT

verify() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  printf '%s  %s\n' "$sha256" "$file" | sha256sum --check --strict --quiet
}

mkdir -p "$cache_dir"

is_elf_arch() {
  local file="$1" expected="$2"
  [[ -f "$file" ]] || return 1
  python3 - "$file" "$expected" <<'PY'
import sys, zipfile
archive, expected = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as package:
    name = next((item for item in package.namelist() if item.endswith('lib/libffmpegkit.so')), None)
    if name is None:
        sys.exit(1)
    header = package.read(name)[:20]
machines = {'x86_64': 62, 'arm64': 183}
sys.exit(0 if header[:5] == b'\x7fELF\x02' and int.from_bytes(header[18:20], 'little') == machines[expected] else 1)
PY
}

if [[ -n "$local_archive" ]]; then
  if ! is_elf_arch "$local_archive" "$arch"; then
    echo "error: $local_archive does not contain an $arch libffmpegkit.so." >&2
    exit 1
  fi
  local_digest="$(sha256sum "$local_archive" | cut -d' ' -f1)"
  if [[ -n "$sha256" && "$local_digest" != "$sha256" ]]; then
    echo "error: $local_archive SHA-256 differs from the pinned $arch archive." >&2
    echo "  expected $sha256" >&2
    echo "  actual   $local_digest" >&2
    exit 1
  fi
  cp "$local_archive" "$target"
  echo "Seeded $archive_name from $local_archive (sha256 $local_digest)"
  if [[ -z "$sha256" ]]; then
    echo "Pin this digest in tool/verify_ffmpeg_native.py and tool/prefetch_linux_native.sh:"
    echo "  LINUX_ARCHIVE_SHA256['$arch'] = '$local_digest'"
  fi
  exit 0
fi

if [[ -z "$sha256" ]]; then
  # No pinned digest and no local bundle: refuse rather than seed an archive
  # from a builder release that does not publish this architecture at all.
  echo "error: no pinned SHA-256 for the Linux $arch archive yet." >&2
  echo "  Build it first (tool/native/ffmpeg-kit-linux/README.md), then either" >&2
  echo "  pin its digest or pass --local-archive <zip>." >&2
  exit 1
fi

if verify "$target"; then
  echo "Verified $archive_name (already cached)"
  exit 0
fi

# A cached archive that fails the hash is either a partial download or another
# builder's build; neither is usable, and leaving it in place would make the hook
# silently reuse it.
if [[ -e "$target" ]]; then
  mv "$target" "$target.invalid-$(date -u +%Y%m%dT%H%M%SZ)"
fi

echo "Fetching $archive_name..."
curl --fail --location --retry 6 --retry-all-errors --retry-delay 2 \
  --connect-timeout 30 --max-time 900 --continue-at - \
  --output "$scratch/$archive_name" "$url"

if ! verify "$scratch/$archive_name"; then
  echo "error: $archive_name does not match the pinned SHA-256." >&2
  echo "  expected $sha256" >&2
  echo "  actual   $(sha256sum "$scratch/$archive_name" | cut -d' ' -f1)" >&2
  exit 1
fi

mv "$scratch/$archive_name" "$target"
echo "Verified $archive_name -> $target"
