# Streaming verification API

Requested 2026-07-10 by the `validate` archive-streaming effort. `validate`
currently calls `cp_archive_list` and `cp_archive_extract` with the whole
archive in memory and receives owned extracted output only to discard it after
the CRC check.

## Requirements

- Additive C API; existing `cp_archive_*` functions keep their contracts.
- Input arrives through a caller-supplied range-read callback (seekable
  source), not an archive-sized slice.
- Decoded fork bytes go to an optional caller callback, or are discarded.
- Memory stays bounded independent of archive and fork size (header metadata
  is proportional to entry count, which is acceptable).
- Preserve existing error semantics: header CRC, per-file CRC, RLE run-length,
  output-length, truncation, encrypted and unsupported-entry codes.
- Tests: valid fixtures, corruption cases matching the buffered path's error
  codes (differential against `cp_archive_extract`), and a bounded-memory
  assertion using a counting allocator.

## Approach

Header parsing reads the header region through the range reader. Each fork is
decoded by incremental RLE and LZH decoders fed by fixed-size reads, emitting
decoded chunks to a sink that updates the running CRC and forwards bytes.

## Acceptance (BDFN, 2026-10-14)

- Streaming verification must catch at least every error the previous
  implementation caught, ideally more. Concretely, for any input the
  pre-rework `compact-pro expand` rejects, `compact-pro verify` must reject.
- `expand` strips and parses the project's appended metadata trailer before
  calling the core, and hands the core only the bytes before it. `verify`
  must apply the same trailer handling, or it accepts files `expand` rejects.
- Golden oracle: a deterministic corpus generated with the `random` project's
  Zig build (`randomz`, per-file seeds recorded in a manifest; Poisson,
  geometric mapped onto 0x80+n for RLE-escape stress, normal, exponential,
  log-normal, beta, uniform; sizes from 0 bytes through 20 MB to cross the
  16 MiB tokenizer segment). Archives and expansions from commit `220ca5d`
  and from the reworked build must be byte-identical.
- Corruption differential: oracle archives under 1 MiB mutated with
  `corruption_reader` built-in profiles (sniper, bolter, shotgun, nuke,
  robespierre, badonkachomp, header, tail) under a fixed master seed. Old and
  new `expand` must give identical exit codes and messages; crashes and
  timeouts are counted separately from rejections.

## Results (2026-10-14)

- Golden oracle: 40 seeded files (0 B to 20 MB) plus a whole-corpus tree
  archive. All 41 archives from `220ca5d` and the reworked build are
  byte-identical before the metadata trailer (the trailer differs only in
  recorded access times, which the oracle runs themselves change). Every
  expansion matches its input across builds; `verify` accepts all 41.
- Corruption differential: 2540 mutated archives (sniper, bolter, shotgun,
  nuke, robespierre, badonkachomp, header, tail; 10 rounds each, master seed
  0x20261014). Old and new `expand` agree on every case; no crashes or
  timeouts. Old `expand` rejected 2110, and `verify` rejects exactly those
  2110 (no gap, no extras).
- Undetected corruptions (430) land only in the project's metadata trailer
  (307, no checksum), in truncations that remove the trailer footer (115), or
  in the preamble volume/cross-volume bytes (8, which no checksum covers).
- Mutation check: breaking the data-fork overflow check, the streaming file
  CRC check, or the strict RLE run-length rule each fails the unit suite.

## Metadata trailer CRC (2026-10-14)

- Trailer version 2 stores a CRC-32 of the payload before the 16-byte footer.
  `verify` fails on a mismatch. `expand` warns, skips metadata restore and still
  extracts, because file data has its own CRCs and damaged timestamps or
  permissions should not make intact data unextractable. `add` drops damaged
  metadata rather than carrying it forward. Version 1 trailers are still read.
- The stored CRC is checked in tests against gzip's CRC-32 of the same payload.
- On version 2 archives from the oracle corpus (2540 mutations), `verify` now
  rejects 2254 against `expand`'s 2108, with no case `expand` rejects that
  `verify` accepts. Undetected corruptions fell from 430 to 286. What remains
  is mainly footer damage (a damaged footer means no trailer is found),
  truncations that remove the footer, and the preamble volume bytes.
