# compact_pro

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fcompact_pro%3Fbranch%3Dyolo)](https://app.garnix.io/repo/pmarreck/compact_pro)
[![GitHub Actions](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml/badge.svg?branch=yolo)](https://github.com/pmarreck/compact_pro/actions/workflows/ci.yml)

`compact_pro` is a clean-room, cross-platform Compact Pro (`.cpt`) implementation.

- Pure Zig core for archive/container/codec logic.
- C ABI (FFI) for embedding.
- C CLI named `compact-pro` for all filesystem and platform I/O.

## CI Coverage

- Garnix is flake-driven (no `garnix.yaml`): it builds flake `checks` target entries.
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

Run benchmark suite (speed + compression performance):

```bash
./bm
```

## CLI

```text
compact-pro

Usage:
  compact-pro compress [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] [--force|-f] [-o <archive.cpt|->] <file...|->
  compact-pro expand [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] <archive.cpt> [-d <outdir>] [--path <entry> ...]
  compact-pro add [--sidecar|--rsrc <path>|--xattr <name>] [--progress|--no-progress] <archive.cpt> <file...>
  compact-pro list <archive.cpt>
  compact-pro --help
```

## Command Details

- `compress`
  - Creates a new `.cpt` archive from input files (or stdin via `-`).
  - Directory inputs are recursively expanded; archive paths are rooted at the input directory basename.
  - Empty directories are captured via metadata trailer records and recreated on extraction.
  - Default output behavior is no-clobber: if target archive exists, command fails.
  - Use `--force` (`-f`) to overwrite an existing output archive.
  - Prints completion stats to stderr: input bytes, compressed bytes, compressed percent, MB/s throughput, elapsed seconds.
  - Progress:
    - `--progress` forces progress output to stderr.
    - `--no-progress` disables progress output.
    - default is progress on TTY stderr.
  - `-o` is optional; default output is derived from filename (or cwd for multi-input).
  - If `-o` is provided without `.cpt`, `.cpt` is appended automatically.
  - `-o -` writes archive bytes to stdout.
  - `~`-prefixed paths are expanded to home directory.
  - Preserves relative input paths as archive paths (for directory-aware extraction).
  - Captures hierarchical metadata extension in an appended compatibility trailer outside normal Compact Pro entries.
  - Trailer metadata includes file and directory records with per-field masks (permissions, ownership, timestamps, Apple flags, and NTFS attributes/timestamps when present).

- `expand`
  - Extracts archive contents into `-d <outdir>` (default `.`).
  - Recreates metadata-recorded empty directories in addition to file-parent directories.
  - Prints completion stats to stderr: compressed bytes, expanded bytes (`compressed -> expanded`), expansion ratio, MB/s throughput, elapsed seconds.
  - Progress:
    - `--progress` forces progress output to stderr.
    - `--no-progress` disables progress output.
    - default is progress on TTY stderr.
  - `--path <entry>` may be repeated to extract only selected entries.
  - Restores file and directory metadata from the appended trailer when present.
  - Unsupported/unrestorable fields emit explicit warnings with the specific field name and do not abort data extraction.

- `add`
  - Adds files to an existing archive by rebuilding archive content via FFI.
  - Directory inputs are recursively expanded before add.
  - Progress:
    - `--progress` forces progress output to stderr.
    - `--no-progress` disables progress output.
    - default is progress on TTY stderr.
  - Regenerates the appended metadata trailer so metadata remains synchronized after updates.

- `list`
  - Lists archive entries and fork sizes.
  - Metadata trailer is out-of-band and never appears as a normal archive entry.
  - Prints trailer accounting line (`trailer_size`, `trailer_payload`) at the end so on-disk overhead is explicit.

## Resource Fork Policy

- `--sidecar`: AppleDouble sidecar (`._<name>`)
- `--rsrc <path>`: explicit sidecar path
- `--xattr <name>`: Linux xattr key (Linux only)

Defaults:
- macOS: native resource fork path (`..namedfork/rsrc`) for default behavior.
- non-macOS: sidecar output on extraction; no implicit resource-fork input unless selected.

## Compatibility Notes

- RLE profile implemented for read/write.
- LZH profile implemented for read/write.
- On write, each fork is encoded as RLE first, then optionally LZH-over-RLE when strictly smaller.
- Multi-block LZH writer now follows legacy block termination semantics (`block_count >= 0x1fff0` with token-cost overshoot permitted), matching The Unarchiver/`unar` expectations.
- Container entry-count fields follow legacy Compact Pro subtree-count semantics for root/directory metadata traversal.
- Metadata extension is appended as trailer bytes after canonical Compact Pro payload; legacy tools should ignore trailing bytes while this implementation restores metadata from that trailer.

## Benchmarking

- `./bm` runs comparative benchmarks against `compact-pro`, `zip`, and `gzip`.
- Captures:
  - compress speed (`wall`, `user`, `system`, throughput MiB/s)
  - extract speed (`wall`, `user`, `system`, throughput MiB/s)
  - compression performance (output size and `out/in` ratio)
- Persists history to `tests/benchmark/history.tsv`.
- Fails loudly on sudden drift (default 20%) versus the previous row unless accepted via `--accept` or `BENCH_ACCEPT=1`.
