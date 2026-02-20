# CODE_MINIMAP

## Repository Summary

`compact_pro` now contains a full clean-room implementation baseline:
- Pure Zig core for Compact Pro parsing/extraction/writing (RLE profile).
- C ABI for embedding.
- C CLI (`compact-pro`) handling all filesystem/resource-fork/metadata I/O.
- Nix-based dev/build/test environment and CI.

## File Index

- `COMPACT_PRO_CLEANROOM_SPEC.md`
  - Clean-room binary/codec/container specification and host fork policy.

- `src/crc32jam.zig`
  - JAMCRC implementation used for header and file payload CRC verification.

- `src/rle8182.zig`
  - Compact Pro RLE (`0x81/0x82`) encoder/decoder.

- `src/core.zig`
  - Pure archive engine: metadata parser, recursive entry parsing (directories/files), extraction, archive creation, and add semantics.
  - Writer supports directory-structured entry encoding from slash-delimited archive paths.
  - Returns explicit unsupported errors for encrypted/LZH decode paths.

- `src/ffi.zig`
  - C ABI layer over core.
  - Exposes create/add/extract/list functions and matching free functions.
  - Maps Zig errors to stable C error codes/messages.

- `src/main.zig`
  - Zig entry shim invoking C CLI main function.
  - Prints debug-build warning banner in Debug mode.

- `include/compact_pro.h`
  - Public C header: input/output structs, list structs, API calls, free helpers, and error codes.

- `csrc/compact_pro_cli.c`
  - CLI command parser and implementations for `compress`, `expand`, `add`, `list`.
  - Performs all file/resource-fork I/O.
  - Implements `expand --path` selective extraction.
  - Implements metadata extension (`.compact-pro.meta.bin`) capture/restore with warning behavior on restore failures.

- `tests/unit/zig_unit_tests.zig`
  - Unit tests for RLE behavior, archive roundtrip/create/add, and fixture metadata parse.

- `tests/cli/test_cli.sh`
  - End-to-end CLI tests for help surface, compress/expand/add/list, selective extraction, sidecar handling, directory path roundtrip, and metadata mode restoration.

- `build.zig`
  - Zig build graph for static library, CLI executable, and unit-test step.
  - Default optimization mode is `ReleaseFast`.

- `flake.nix`
  - Dependency control and reproducible dev shell/build/check definitions.

- `.garnix.yaml`
  - Garnix build/check configuration using flake outputs.

- `.github/workflows/ci.yml`
  - GitHub Actions CI on `yolo`: full tests, release build, and downloadable artifacts per platform matrix.

- `build`
  - Project build wrapper (`ReleaseFast` default; `--debug`, `--test` supported).

- `test`
  - Full deterministic suite runner (Zig unit tests + CLI integration tests).

- `bm`
  - Benchmark entrypoint placeholder.

- `fuzz`
  - Fuzz entrypoint placeholder.

- `README.md`
  - Project description, CI badges, command surface, behavior notes, and compatibility caveats.

- `PROJECT_OVERVIEW.md`
  - Goal and terminology overview.

- `RULES.md`
  - Local always-on implementation constraints.

- `fixtures/cpt/MacEnvy21.cpt`
  - Real Compact Pro fixture for metadata/parser compatibility tests.
