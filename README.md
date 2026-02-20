# compact_pro

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fcompact_pro%3Fbranch%3Dyolo)](https://garnix.io)
[![GitHub Actions](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml)

`compact_pro` is a clean-room, cross-platform Compact Pro (`.cpt`) implementation.

- Pure Zig core for archive/container/codec logic.
- C ABI (FFI) for embedding.
- C CLI named `compact-pro` for all filesystem and platform I/O.

## CI Coverage

- Linux x86_64 (Nix-based full test + build)
- Linux aarch64 (Nix-based full test + build)
- macOS aarch64 (Nix-based full test + build)
- Windows x86_64 (native Zig test + build + CLI smoke test)
- Windows aarch64 (cross-compile build check + artifact; runtime execution not yet validated on hosted ARM runner)

## Build

```bash
./build
```

Debug build:

```bash
./build --debug
```

Run full test suite:

```bash
./test
```

## CLI

```text
compact-pro

Usage:
  compact-pro compress [--sidecar|--rsrc <path>|--xattr <name>] -o <archive.cpt> <file...>
  compact-pro expand [--sidecar|--rsrc <path>|--xattr <name>] <archive.cpt> [-d <outdir>] [--path <entry> ...]
  compact-pro add [--sidecar|--rsrc <path>|--xattr <name>] <archive.cpt> <file...>
  compact-pro list <archive.cpt>
  compact-pro --help
```

## Command Details

- `compress`
  - Creates a new `.cpt` archive from input files.
  - Preserves relative input paths as archive paths (for directory-aware extraction).
  - Captures cross-platform metadata extension (`mode` + `mtime`) in an appended compatibility trailer outside normal Compact Pro entries.

- `expand`
  - Extracts archive contents into `-d <outdir>` (default `.`).
  - `--path <entry>` may be repeated to extract only selected entries.
  - Restores metadata from the appended trailer when present; unsupported/failed metadata restores emit warnings and do not abort data extraction.

- `add`
  - Adds files to an existing archive by rebuilding archive content via FFI.
  - Regenerates the appended metadata trailer so metadata remains synchronized after updates.

- `list`
  - Lists archive entries and fork sizes.
  - Metadata trailer is out-of-band and never appears as a normal archive entry.

## Resource Fork Policy

- `--sidecar`: AppleDouble sidecar (`._<name>`)
- `--rsrc <path>`: explicit sidecar path
- `--xattr <name>`: Linux xattr key (Linux only)

Defaults:
- macOS: native resource fork path (`..namedfork/rsrc`) for default behavior.
- non-macOS: sidecar output on extraction; no implicit resource-fork input unless selected.

## Compatibility Notes

- RLE profile implemented for read/write.
- LZH decode/write is not implemented yet; archives requiring LZH decode fail with explicit unsupported error.
- Metadata extension is appended as trailer bytes after canonical Compact Pro payload; legacy tools should ignore trailing bytes while this implementation restores metadata from that trailer.
