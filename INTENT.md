# INTENT

## Purpose

`compact_pro` is a clean-room implementation of Compact Pro (`.cpt`) archive
handling, the classic Macintosh archive format. It lets people and programs on
current systems list, extract, verify, create and extend `.cpt` archives,
including resource forks and Mac metadata, without the original software.

It serves two kinds of users:

- People with legacy Compact Pro archives, through the `compact-pro` CLI.
- Programs that embed it through its C ABI. The known consumer is `validate`,
  which uses the streaming verifier for deep integrity checks of `.cpt` files.

Terms are defined in [TERMINOLOGY.md](TERMINOLOGY.md).

## Desired outcomes

- Deterministic archive parsing, extraction and writing from a modern codebase.
- Archives written here open in other Compact Pro readers (The Unarchiver's
  `unar`/`lsar` is the reference checked in tests).
- Integrity checking that never misses damage the extractor would catch:
  `compact-pro verify` must reject every archive `expand` rejects, and should
  catch more where the data allows (BDFN, 2026-10-14).
- Verification in bounded memory, independent of archive and fork size, so
  consumers need not load whole archives (requested by `validate`).
- Damage reported as typed findings with archive offsets rather than generic
  errors, so consumers can classify it.
- Fast decoding that uses multiple cores where the format allows, while keeping
  memory constrained (BDFN, 2026-10-14).
- Cross-platform builds for macOS aarch64, Linux x86_64/aarch64 and Windows
  x86_64/aarch64.

## Architecture constraints

These are owner directives; `RULES.md` holds the enforced invariants.

- All codec and container logic lives in a pure Zig core with no filesystem or
  process I/O.
- The C ABI is the public API, with explicit ownership and matching free
  functions.
- The `compact-pro` CLI is written in C, performs all I/O and calls the core only
  through the C header (it dogfoods the ABI).

## Scope and non-goals

- In scope: single-volume archives with directory trees, data and resource
  forks, the RLE and LZH(RLE) codecs, and the project's appended metadata
  trailer for host metadata that Compact Pro cannot store.
- Not supported today: encrypted entries (reported as unsupported) and
  multi-volume archive authoring (format fields are known; writer policy is not
  validated). See `COMPACT_PRO_CLEANROOM_SPEC.md`. Either would need an
  independent oracle first; the candidate is the original Compact Pro running
  in a 680x0 Macintosh emulator (BDFN, 2026-10-23).
- Bytes after the Compact Pro data that are not a valid metadata trailer are
  reported on stderr by the CLI and otherwise ignored; they do not fail
  `verify` (BDFN, 2026-10-23).
- The project is public under the MIT license (`LICENSE`).

## How success is verified

- `./test`: Zig unit tests and the CLI integration suite, including `unar`
  interoperability, verify/expand parity and clean stderr.
- Mechatron Prime CI, the project's only continuous-integration service, builds
  `.mechatron-prime/targets` on every push to `yolo`.
- Changes to decoding are additionally checked against independent baselines:
  a seeded random corpus compared byte-for-byte with an earlier build, and
  `corruption_reader` mutation runs comparing outcomes. See
  `docs/plan_context/streaming_verifier.md`.

## Open questions

- Can an emulated original Compact Pro serve as a practical oracle for
  encrypted and multi-volume archives (emulator, system software and Compact
  Pro licensing, scripted operation)?

Current work lives in [PLAN.md](PLAN.md).
