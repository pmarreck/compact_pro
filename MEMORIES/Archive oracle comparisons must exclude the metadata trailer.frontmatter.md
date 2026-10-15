---
description: "compact-pro archives embed input timestamps (including atime) in the appended metadata trailer, so byte-for-byte oracle comparisons across builds must hash only the bytes before the trailer."
datetime: 2026-10-14T20:09:04-04:00 # EDT
tags: [compact-pro, cpt, oracle, golden-test, differential-testing, metadata-trailer, atime, determinism]
---

Found 2026-10-14 while comparing archives from two builds of the same corpus:
every archive hash differed, but only inside the trailer (offsets just past
the Compact Pro data), because reading the inputs in the first run changed
their access times, which the trailer records.

Compare the archive proper: SHA-256 of the first `size - trailer_size` bytes,
with `trailer_size` from `compact-pro list`. Trailer behavior itself is
covered by the CLI tests (layout, CRC against gzip, version 1 compatibility).
