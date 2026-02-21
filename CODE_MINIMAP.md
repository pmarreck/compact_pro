# CODE_MINIMAP

## Repository Summary

`compact_pro` now contains a full clean-room implementation baseline:
- Pure Zig core for Compact Pro parsing/extraction/writing (RLE + LZH profiles).
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
  - Encoder now emits repeat-run opcodes for repeated non-`0x81` bytes (thresholded to avoid size regressions on short runs).
  - Encoder `0x81` path now handles arbitrary runs of `0x81` bytes correctly (including `0x81,0x81,0x81,0x82` patterns) to avoid decode drift/checksum failures in external tools.
  - Encoder hot path now batches literal spans and uses vectorized repeated-byte run scanning plus slice-reserved run emission to reduce compress-time overhead on large inputs.
  - Decoder now writes into preallocated output and fills repeat runs in chunks to reduce extraction-time overhead.

- `src/lzh.zig`
  - Pure Compact Pro LZH codec with per-block Huffman codebook parsing/writing, LZSS window copy/match finding, and integrated Compact Pro RLE decode stage.
  - Supports extraction of LZH-compressed forks from legacy archives and creation of LZH-over-RLE fork payloads for new archives.
  - Encoder match finder now prefilters chain candidates using current best-match boundary bytes to reduce needless byte-by-byte scans on large multi-block inputs.
  - Encode path now supports concurrent block emission: sequential tokenization preserves dictionary semantics, while block Huffman/bitstream encoding runs in parallel with deterministic ordered merge (`encodeWithWorkerLimit`; `encode` auto-selects worker count).
  - Encode progress callbacks now span both tokenization and block-encode phases (single monotonic stream) so long-running encode work reports meaningful live progress/ETA.
  - Tokenization now has a bold parallel path for multi-segment inputs: deterministic fixed-size segments seeded with a window overlap prefix are tokenized concurrently, then globally reassembled into valid Compact Pro block boundaries (`block_count >= 0x1fff0`) before block encoding. Single-segment inputs stay on a direct fast path to avoid extra merge overhead.

- `src/core.zig`
  - Pure archive engine: metadata parser, recursive entry parsing (directories/files), extraction, archive creation, and add semantics.
  - Writer supports directory-structured entry encoding from slash-delimited archive paths.
  - Parser/writer now use legacy Compact Pro subtree-count semantics for root/directory entry counts (not immediate-child counts), improving external-tool compatibility.
  - Header CRC validation/generation now covers the full metadata envelope expected by legacy tooling: entry count, comment, and all serialized entry records up to payload start.
  - Returns explicit unsupported errors for encrypted paths.
  - Read path decodes LZH forks through `src/lzh.zig`.
  - Write path picks per-fork compression strategy (`RLE` vs `LZH(RLE)`) by encoded size and emits full multi-block LZH streams using legacy block-count termination semantics (`>= 0x1fff0` with overshoot-permitted final token).
  - Adds archive-create progress callback plumbing that reports encode work units (RLE + LZH stages) for CLI progress/ETA rendering without introducing I/O into core.
  - Progress accumulator is mutex-protected so callback dispatch remains safe when LZH block encoding runs concurrently.

- `src/ffi.zig`
  - C ABI layer over core.
  - Exposes create/add/extract/list functions and matching free functions.
  - Adds `cp_archive_create_with_progress` callback-enabled entrypoint for encode progress reporting.
  - Maps Zig errors to stable C error codes/messages.

- `src/main.zig`
  - Zig entry shim invoking C CLI main function.
  - Prints debug-build warning banner in Debug mode.

- `include/compact_pro.h`
  - Public C header: input/output structs, list structs, API calls, progress callback type (`cp_progress_fn`), free helpers, and error codes.

- `csrc/compact_pro_cli.c`
  - CLI command parser and implementations for `compress`, `expand`, `add`, `list`.
  - Performs all file/resource-fork I/O.
  - `compress`/`add` recursively expand directory inputs into file entries (including paths containing spaces).
  - `compress` defaults to no-clobber output and supports `--force`/`-f` for explicit overwrite.
  - Captures directory metadata recursively from directory inputs (including empty directories) and recreates metadata-recorded empty directories on expand.
  - `compress`/`expand` print completion stats to stderr (bytes, ratio/percent, MB/s, elapsed).
  - Progress UI now renders bar + percent + ETA (`progress: <phase> [====>----] 42% (done/total) (ETA: Ns)`), focused on meaningful long phases (`compress-encode`, `add-encode`, `expand-decode`, `expand-write`) with callback-driven encode updates from core.
  - macOS default resource-fork ingestion now reads only real `com.apple.ResourceFork` xattr content; it no longer blindly ingests `..namedfork/rsrc` bytes that may be filesystem-compression backing data.
  - Implements `expand --path` selective extraction.
  - Implements appended metadata trailer v2 with hierarchical file/dir metadata records and per-field masks.
  - Restores metadata best-effort and emits explicit per-field warnings for unsupported/unrestorable fields (including cross-OS NTFS/Apple metadata cases).
  - `list` prints trailer size accounting (`trailer_size`, `trailer_payload`) in addition to normal entries.
  - `compress` supports optional `-o` (default archive naming), `~` path expansion, auto `.cpt` suffix for named outputs, stdin input via `-`, and stdout output via `-`.

- `tests/unit/zig_unit_tests.zig`
  - Unit tests for RLE behavior (including repeated-byte compression, literal/run/escape boundary encoding, and `0x81,0x81,0x81,0x82` regression), archive roundtrip/create/add, fixture metadata parse, LZH fixture extraction/hash verification, single- and multi-block LZH encode/decode roundtrip, deterministic multi-worker LZH encoding (`worker_limit=1` vs `4`), deterministic multi-segment LZH encoding (`worker_limit=1` vs `4` on >16 MiB payload), LZH progress callback phase coverage (token + encode), write-path LZH flag selection, Compact Pro subtree-count encoding semantics, and header-CRC metadata coverage compatibility.

- `tests/cli/test_cli.sh`
  - End-to-end CLI tests for help surface, compress/expand/add/list, selective extraction, sidecar handling, directory path roundtrip (including directory input paths with spaces), empty-directory metadata roundtrip, no-clobber vs `--force` overwrite behavior, directory metadata restore, LZH fixture extraction, external `unar` compatibility regression for generated archives, progress flags (including bar + ETA output), trailer accounting output, cross-OS metadata warning behavior, and macOS default resource-fork gating behavior.

- `build.zig`
  - Zig build graph for static library, CLI executable, and unit-test step.
  - Default optimization mode is `ReleaseFast`.

- `flake.nix`
  - Dependency control and reproducible dev shell/build/check definitions.
  - Defines Garnix-facing CI checks directly in flake outputs (no `garnix.yaml`) for five targets: Linux `x86_64`/`aarch64`, macOS `aarch64`, Windows `x86_64`/`aarch64`.

- `.github/workflows/ci.yml`
  - GitHub Actions CI on `yolo`: platform matrix with Linux (`x86_64` + `aarch64`) and macOS (`aarch64`) Nix-based full test/build jobs, Windows `x86_64` native Zig test/build/smoke job, and Windows `aarch64` cross-compile artifact job.

- `build`
  - Project build wrapper (`ReleaseFast` default; `--debug`, `--test` supported).

- `test`
  - Full deterministic suite runner (Zig unit tests + CLI integration tests).

- `bm`
  - Benchmark suite comparing `compact-pro` against `zip` and `gzip`.
  - Measures compression/extraction speed (wall + CPU + throughput) and compression ratio.
  - Writes history to `tests/benchmark/history.tsv` and fails on sudden drift unless explicitly accepted.

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
