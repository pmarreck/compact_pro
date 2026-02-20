# compact_pro

[![Garnix](https://garnix.io/api/badges/pmarreck/compact_pro?branch=yolo)](https://garnix.io)
[![GitHub Actions](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml)

`compact_pro` is a clean-room, cross-platform Compact Pro (`.cpt`) implementation.

- Pure Zig core for archive/container/codec logic.
- C ABI (FFI) for embedding.
- C CLI named `compact-pro` for all filesystem and platform I/O.

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
  - Captures cross-platform metadata extension (`mode` + `mtime`) in hidden internal entry `.compact-pro.meta.bin`.

- `expand`
  - Extracts archive contents into `-d <outdir>` (default `.`).
  - `--path <entry>` may be repeated to extract only selected entries.
  - Restores metadata from `.compact-pro.meta.bin` when present; unsupported/failed metadata restores emit warnings and do not abort data extraction.

- `add`
  - Adds files to an existing archive by rebuilding archive content via FFI.
  - Regenerates `.compact-pro.meta.bin` so metadata remains synchronized after updates.

- `list`
  - Lists archive entries and fork sizes.
  - Internal metadata entry `.compact-pro.meta.bin` is hidden from normal output.

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
- Metadata extension is implemented as regular archive content for compatibility with legacy tools (legacy tools will see/extract the internal metadata file).
