"""Verify pinned FFmpeg 9.0.2 hook downloads and packaged native libraries."""

from __future__ import annotations

import argparse
import hashlib
import platform
import re
import struct
import sys
import zipfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
CACHE = REPO / '.dart_tool/hooks_runner/shared/ffmpeg_kit_extended_flutter/build/ffmpeg_kit_cache'
ARCHIVES = {
    'android': ('bundle-base-shared-lgpl-release.aar', 'c6c9b1ff7be756b0fb587f98e05972ca4dae97e8275c22961b443b4fd5f49bf7'),
    'windows': ('bundle-base-windows-x86_64-shared-lgpl.zip', 'e61684a91f7471ba00f1d5b36a24e93ab602ef72bd57000d94990e7e0c5dfe3a'),
    # The `linux` slot keeps the pinned x86_64 asset so every existing caller
    # (workflow, local scripts, tests) is unchanged. arm64 is selected through
    # LINUX_ARCHITECTURES below.
    'linux': ('bundle-base-linux-x86_64-shared-lgpl.zip', 'd6003c3feb2bdcdccd0d4ad5e7b76fa8e8951430c6a22c1db7be5e13da19403d'),
    'macos': ('bundle-base-macos-universal-lgpl.xcframework.zip', '9977fc0d3de38af4830c54f536146b2595843d7a45850c50c6205ffb56ca899a'),
    'ios': ('bundle-base-ios-universal-lgpl.xcframework.zip', 'f1758956e81d938bedf39e796dc99a3b34951cffcc681ab52e241d47b0c93aa4'),
}
WINDOWS_DLL_SHA256 = '302d978048f389dbb07f01c1a34a4988a92d1e3ebf0e960e2dd8314f83632b34'
VERSION = b'n9.0.2'

# Linux needs one archive per CPU architecture. ffmpeg_kit_extended_flutter's
# hook derives the file name from the *target* architecture
# (`bundle-base-linux-<archStr>-shared-lgpl.zip`, `arm64`/`x86_64`), while the
# upstream ffmpeg-kit-builders releases publish `linux-x86_64` assets only. The
# arm64 slot therefore has to be built and published here before its digest can
# be pinned; until then verification refuses an unpinned arm64 toolchain
# instead of silently accepting an arbitrary download.
LINUX_ARCHITECTURES = ('x86_64', 'arm64')
LINUX_ARCHIVE_NAMES = {
    'x86_64': 'bundle-base-linux-x86_64-shared-lgpl.zip',
    'arm64': 'bundle-base-linux-arm64-shared-lgpl.zip',
}
LINUX_LIBRARY_ENTRIES = {
    'x86_64': 'bundle-base-linux-x86_64-shared-lgpl/lib/libffmpegkit.so',
    'arm64': 'bundle-base-linux-arm64-shared-lgpl/lib/libffmpegkit.so',
}
# ELF e_machine values: EM_X86_64 = 62, EM_AARCH64 = 183.
LINUX_ELF_MACHINES = {'x86_64': 62, 'arm64': 183}
# SHA-256 of each Linux bundle. arm64 is built by
# tool/native/ffmpeg-kit-linux/build-arm64.sh from the FFmpeg n9.0.2 git tag
# (Lavc63.1) with the same base preset as the x86_64 asset, and must be uploaded
# next to it before CI can prefetch it.
LINUX_ARCHIVE_SHA256 = {
    'x86_64': ARCHIVES['linux'][1],
    'arm64': '4420cf0a323d4400397507300ddd3369320d9aa6264fb410afcb2b46496aaa90',
}

# Backwards-compatible aliases for the x86_64-only callers.
LINUX_ARCHIVE_NAME = LINUX_ARCHIVE_NAMES['x86_64']
LINUX_LIBRARY_ENTRY = LINUX_LIBRARY_ENTRIES['x86_64']


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def host_linux_arch() -> str:
    """Map ``platform.machine()`` onto a Linux bundle architecture."""
    machine = platform.machine().lower()
    if machine in ('aarch64', 'arm64'):
        return 'arm64'
    if machine in ('x86_64', 'amd64'):
        return 'x86_64'
    raise ValueError(f'Unsupported Linux host architecture: {machine}')


def linux_archive(arch: str) -> tuple[str, str]:
    """Return the ``(archive_name, pinned_sha256)`` of a Linux hook archive.

    ``x86_64`` is resolved through :data:`ARCHIVES` so the long-standing
    ``ARCHIVES['linux']`` patch point used by tests and callers keeps working.
    """
    if arch not in LINUX_ARCHITECTURES:
        raise ValueError(f'Unsupported Linux architecture {arch!r}; expected one of {", ".join(LINUX_ARCHITECTURES)}')
    if arch == 'x86_64':
        return ARCHIVES['linux']
    return LINUX_ARCHIVE_NAMES['arm64'], LINUX_ARCHIVE_SHA256['arm64']


def stage_linux_runtime(bundle: Path, archive: Path, arch: str = 'x86_64') -> Path:
    """Place the verified hook archive's runtime in the portable Linux bundle.

    Flutter's Linux Native Assets hook can resolve a CodeAsset without copying
    its ELF into the release bundle. Dart FFI also opens this library by name,
    so release packaging must include it beside the other plugin libraries.
    """
    if not bundle.is_dir():
        raise ValueError(f'Linux release bundle is missing: {bundle}')
    _, expected = linux_archive(arch)
    if not expected:
        raise ValueError(
            f'Linux {arch} FFmpeg hook archive has no pinned SHA-256 yet; '
            f'build the {arch} bundle (tool/native/ffmpeg-kit-linux) and publish it before packaging'
        )
    if digest(archive) != expected:
        raise ValueError(f'Linux {arch} FFmpeg hook archive SHA-256 differs from pinned n9.0.2 asset: {archive}')
    with zipfile.ZipFile(archive) as package:
        library = package.read(LINUX_LIBRARY_ENTRIES[arch])
    target = bundle / 'lib/libffmpegkit.so'
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f'{target.name}.tmp')
    temporary.write_bytes(library)
    temporary.replace(target)
    return target


def macho_architectures(binary: bytes) -> set[int]:
    """Return Mach-O CPU types from thin or universal executables."""
    if len(binary) < 8:
        raise ValueError('Apple FFmpeg Mach-O header is incomplete')
    magic = binary[:4]
    if magic == b'\xcf\xfa\xed\xfe':
        return {struct.unpack_from('<I', binary, 4)[0]}
    if magic not in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        raise ValueError(f'Apple FFmpeg binary has unexpected Mach-O magic: {magic.hex()}')
    count = struct.unpack_from('>I', binary, 4)[0]
    stride = 20 if magic == b'\xca\xfe\xba\xbe' else 32
    if count < 1 or len(binary) < 8 + count * stride:
        raise ValueError('Apple FFmpeg universal Mach-O header is incomplete')
    return {struct.unpack_from('>I', binary, 8 + index * stride)[0] for index in range(count)}


def verify(
    platform: str,
    artifact: Path,
    cache_archive: Path | None = None,
    abi: str = 'arm64-v8a',
    arch: str = 'x86_64',
) -> dict[str, str]:
    if platform == 'linux':
        name, expected = linux_archive(arch)
    else:
        name, expected = ARCHIVES[platform]
    archive = cache_archive or CACHE / platform / name
    if not expected:
        raise ValueError(
            f'Linux {arch} FFmpeg hook archive has no pinned SHA-256 yet; '
            f'build and publish the {arch} bundle before verifying'
        )
    if digest(archive) != expected:
        raise ValueError(f'{platform} FFmpeg hook archive SHA-256 differs from pinned n9.0.2 asset: {archive}')

    if platform == 'linux' and artifact.is_dir():
        candidates = list(artifact.rglob('libffmpegkit.so'))
        if len(candidates) != 1:
            raise ValueError(f'Expected one packaged Linux FFmpeg library under {artifact}, found {len(candidates)}')
        artifact = candidates[0]
    if platform in ('macos', 'ios') and artifact.is_dir():
        candidates = [path for path in artifact.rglob('ffmpegkit') if path.parent.name == 'ffmpegkit.framework' and path.is_file()]
        if len(candidates) != 1:
            raise ValueError(f'Expected one packaged {platform} FFmpeg framework binary under {artifact}, found {len(candidates)}')
        artifact = candidates[0]

    if platform == 'android':
        with zipfile.ZipFile(artifact) as apk:
            library = apk.read(f'lib/{abi}/libffmpegkit.so')
    else:
        library = artifact.read_bytes()
    if VERSION not in library:
        raise ValueError(f'{platform} packaged FFmpeg library does not contain n9.0.2: {artifact}')

    if platform == 'windows' and digest(artifact) != WINDOWS_DLL_SHA256:
        raise ValueError(f'Windows FFmpeg DLL hash differs from pinned bundle: {artifact}')
    if platform == 'linux':
        if library[:5] != b'\x7fELF\x02' or int.from_bytes(library[18:20], 'little') != LINUX_ELF_MACHINES[arch]:
            raise ValueError(f'Linux FFmpeg library is not an {arch} ELF: {artifact}')
        glibc_versions = [tuple(map(int, version)) for version in re.findall(rb'GLIBC_(\d+)\.(\d+)', library)]
        if not glibc_versions or max(glibc_versions) > (2, 39):
            raise ValueError(f'Linux FFmpeg library exceeds Ubuntu 24.04 glibc baseline: {artifact}')
    if platform == 'macos':
        if macho_architectures(library) != {0x01000007, 0x0100000C}:
            raise ValueError(f'macOS FFmpeg library lacks x86_64 and arm64 slices: {artifact}')
    if platform == 'ios':
        architectures = macho_architectures(library)
        if architectures != {0x0100000C}:
            raise ValueError(f'iOS FFmpeg library is not arm64 Mach-O ({architectures}): {artifact}')

    return {'platform': platform, 'version': VERSION.decode(), 'archive_sha256': expected, 'library_sha256': hashlib.sha256(library).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=ARCHIVES)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--cache-archive', type=Path)
    parser.add_argument('--abi', choices=('arm64-v8a', 'armeabi-v7a', 'x86_64'), default='arm64-v8a')
    parser.add_argument(
        '--arch',
        choices=LINUX_ARCHITECTURES,
        default=host_linux_arch(),
        help='Linux CPU architecture (default: host architecture)',
    )
    parser.add_argument('--stage-linux', action='store_true', help='copy verified ELF from hook ZIP into Linux release bundle')
    parser.add_argument('--print-digest', action='store_true', help='print the SHA-256 of --cache-archive without verifying it')
    args = parser.parse_args()
    try:
        if args.print_digest:
            if not args.cache_archive:
                raise ValueError('--print-digest requires --cache-archive')
            print(digest(args.cache_archive))
            return 0
        if args.stage_linux:
            if args.platform != 'linux':
                raise ValueError('--stage-linux requires the linux platform')
            archive = args.cache_archive or CACHE / 'linux' / linux_archive(args.arch)[0]
            stage_linux_runtime(args.artifact, archive, args.arch)
        print(verify(args.platform, args.artifact, args.cache_archive, args.abi, args.arch))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f'FFmpeg native verification failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
