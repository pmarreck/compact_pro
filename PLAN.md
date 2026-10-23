# PLAN

## Next

- [x] Add a bounded-memory streaming verifier C API (range-read input, decoded-byte sink) for `validate` deep checks, differential-tested against `cp_archive_extract`. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] `verify` must reject everything old `expand` rejects (superset), including metadata-trailer damage; any gap blocks commit. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Golden oracle: seeded `randomz` corpus compressed and expanded by pre-rework `220ca5d` and by the reworked build must match byte-for-byte, and `verify` must accept every archive. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Corruption differential: mutate oracle archives with `corruption_reader` profiles; old and new `expand` outcomes must match exactly and crashes/timeouts are reported separately. (context: docs/plan_context/streaming_verifier.md) (done 2026-10-14 17:50 EDT)
- [x] Give LZH bitstream errors (bad codebook, bad Huffman code) their own C error codes and report the archive byte offset of any verify failure (validate request 2026-10-14). (done 2026-10-14 18:20 EDT)
- [x] Put compact_pro on Mechatron Prime CI (targets manifest, webhook, dynamic badge) and retire the dead Garnix badge. (done 2026-10-14 20:18 EDT)
- [x] Add a CRC to the metadata trailer (new trailer version; old versions stay readable) so `verify` and `expand` detect trailer damage, which 307 of 2540 corruption cases showed is currently invisible. (done 2026-10-14 20:08 EDT)
- [x] Report bytes after the Compact Pro data that are not a valid trailer as a CLI stderr warning (`data_end` in the C API) and otherwise ignore them. (done 2026-10-23 12:10 EDT)
- [x] Publish under the MIT license and run CI only on Mechatron Prime CI (GitHub Actions workflow retired). (done 2026-10-23 12:10 EDT)
- [x] Keep `.github/workflows/ci.yml` in the repo for reference but disable GitHub Actions for the repository, so it never runs. (done 2026-10-23 14:05 EDT)
- [x] Run the native macOS check on Mechatron Prime CI through its aarch64-darwin remote builder (add `checks.aarch64-darwin.ci-macos-aarch64` to the targets manifest). (done 2026-10-23 12:50 EDT)
- [x] Decode speed pass after the verifier lands: profile first, then table/carry-less-multiply CRC-32, table-driven Huffman decode, and SIMD where the profile shows a win; golden oracle must stay byte-identical. (done 2026-10-14 20:18 EDT)
- [ ] When `./fuzz` gains real campaigns, use the 2026-09-29 mutation vocabulary (sniper, bolter, sparse shotgun, dense nuke) and record definition version plus parameters per run.
- [ ] Keep any future verdict or severity output aligned with the shared validate verdict memory (FAIL, KNOWN_DEFECT, WARN, reach).

## Done Criteria (current milestone)

- [x] Fix macOS default resource-fork ingestion: avoid pulling filesystem-compression backing streams from `..namedfork/rsrc` by requiring real `com.apple.ResourceFork` xattr presence in default mode. (completed 2026-02-21 09:59 EST)

## Later

- [x] Capture and assert the CLI suite's expected stderr (metadata warnings, stats lines) so `./test` output runs clean. (done 2026-10-14 20:14 EDT)
- [ ] Adopt the shared `performance_profiling` engine (`./cg`, `./mg`, external history) in place of ad-hoc benchmark comparisons.
- [ ] Evaluate the original Compact Pro in a 680x0 Mac emulator as an oracle for encrypted and multi-volume archives before supporting either.
