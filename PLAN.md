# PLAN

## Next

- [x] Add a bounded-memory streaming verifier C API (range-read input, decoded-byte sink) for `validate` deep checks, differential-tested against `cp_archive_extract`. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] `verify` must reject everything old `expand` rejects (superset), including metadata-trailer damage; any gap blocks commit. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Golden oracle: seeded `randomz` corpus compressed and expanded by pre-rework `220ca5d` and by the reworked build must match byte-for-byte, and `verify` must accept every archive. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Corruption differential: mutate oracle archives with `corruption_reader` profiles; old and new `expand` outcomes must match exactly and crashes/timeouts are reported separately. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Give LZH bitstream errors (bad codebook, bad Huffman code) their own C error codes and report the archive byte offset of any verify failure (validate request 2026-10-14). (done 2026-10-14 18:20 EDT)
- [ ] Put compact_pro on Mechatron Prime CI (targets manifest, webhook, dynamic badge) and retire the dead Garnix badge.
- [x] Add a CRC to the metadata trailer (new trailer version; old versions stay readable) so `verify` and `expand` detect trailer damage, which 307 of 2540 corruption cases showed is currently invisible. (done 2026-10-14 20:08 EDT)
- [ ] Investigate whether bytes after the Compact Pro header end, with no valid trailer, should be reported (115 truncations removing only the trailer footer pass today); needs real-archive evidence before any verdict.
- [ ] Decode speed pass after the verifier lands: profile first, then table/carry-less-multiply CRC-32, table-driven Huffman decode, and SIMD where the profile shows a win; golden oracle must stay byte-identical.
- [ ] When `./fuzz` gains real campaigns, use the 2026-09-29 mutation vocabulary (sniper, bolter, sparse shotgun, dense nuke) and record definition version plus parameters per run.
- [ ] Keep any future verdict or severity output aligned with the shared validate verdict memory (FAIL, KNOWN_DEFECT, WARN, reach).

## Done Criteria (current milestone)

- [x] Upgrade CLI progress UX: byte-based `compress-read`, real `compress-encode` progress via core/FFI callback, progress bar rendering, and ETA output in live/non-live modes. (completed 2026-02-20 23:29 EST)
- [x] Refine progress UX: remove low-value `compress-read` output and extend LZH encode progress callbacks across tokenization + parallel block encoding so `compress-encode` ETA remains informative during long runs. (completed 2026-02-20 23:38 EST)
- [x] Bold optimization pass: parallelize LZH tokenization over deterministic overlap-seeded segments with global block reassembly (preserving Compact Pro block semantics) plus a multi-segment worker-determinism regression test. (completed 2026-02-21 06:58 EST)
- [x] Fix macOS default resource-fork ingestion: avoid pulling filesystem-compression backing streams from `..namedfork/rsrc` by requiring real `com.apple.ResourceFork` xattr presence in default mode. (completed 2026-02-21 09:59 EST)

## Later

- [ ] Capture and assert the CLI suite's expected stderr (metadata warnings, stats lines) so `./test` output runs clean.
- [ ] Adopt the shared `performance_profiling` engine (`./cg`, `./mg`, external history) in place of ad-hoc benchmark comparisons.
