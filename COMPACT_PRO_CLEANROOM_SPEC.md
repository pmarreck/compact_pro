# Compact Pro (`.cpt`) Clean-Room Specification (Draft)

## 1. Scope

This document specifies a clean-room compatible reader/writer for Compact Pro archives, based on observed behavior from independent implementations and public format notes.

Primary goal:
- Implement a deterministic decompressor and compressor in another codebase (for example Zig) without copying legacy LGPL code.

Compatibility target:
- Standard single-volume `.cpt` files with directory trees, file metadata, data/resource forks, RLE stage, and optional LZH stage.

Out of scope for this draft:
- Encrypted entries (flag bit present but format details are not fully specified in public implementations).
- Full multi-volume authoring behavior (fields are known; writer policy is not yet fully validated).

## 2. Normative Terms

- `MUST`: required for compatibility.
- `SHOULD`: recommended for robust interoperability.
- `MAY`: optional behavior.

## 3. Source Provenance (Primary References)

- XADMaster Compact Pro parser: `XADCompactProParser.m`
- XADMaster Compact Pro RLE decoder: `XADCompactProRLEHandle.m`
- XADMaster Compact Pro LZH decoder: `XADCompactProLZHHandle.m`
- Independent Rust implementation (`cpt-rs`): container reader + RLE + LZH modules

These references agree on high-level structure: container metadata + per-fork codec pipeline (`LZH? -> RLE`).

## 4. Binary Conventions

- All fixed-width integers are big-endian.
- Mac timestamps are seconds since 1904-01-01 00:00:00 UTC (classic Mac epoch).
- Archive names are length-prefixed byte strings (historically MacRoman in many files; preserve raw bytes unless transcoding is explicitly requested).

## 5. Top-Level Container Layout

### 5.1 Preamble

At file offset `0`:
- `u8` marker, expected `0x01`
- `u8` archive volume number
- `u16` cross-volume archive marker (observed as metadata; preserve on rewrite)
- `u32` offset to main archive header

Reader behavior:
- MUST reject files where the marker byte is not `0x01`.
- MUST seek to `header_offset` for archive metadata parsing.

### 5.2 Main Archive Header (at `header_offset`)

- `u32` header CRC
- `u16` entry_count (number of top-level directory entries to parse)
- `u8` archive_comment_len
- `archive_comment_len` bytes: archive comment payload
- Followed by `entry_count` encoded entries (recursive format below)

Header CRC:
- Compute CRC over bytes starting at `entry_count` field (`u16`) through the end of the archive comment bytes.
- Polynomial: IEEE reversed `0xEDB88320`.
- Initial value: `0xFFFFFFFF`.
- No final XOR (JAMCRC-style result).

Reader SHOULD fail on CRC mismatch in strict mode and MAY allow a lenient mode.

## 6. Entry Encoding (Recursive Directory Tree)

Each encoded entry starts with:
- `u8` `name_len_and_kind`
  - bit 7 (`0x80`) set: directory entry
  - bits 0..6: `name_len`
- `name_len` bytes of entry name

If directory:
- `u16` `descendant_count`
- Then parse exactly `descendant_count` nested entries immediately after this field, depth-first.

If file:
- Parse file metadata block and fork sizes (section 7).

The recursive parse rule in legacy implementations is count-driven (not sentinel-driven).

## 7. File Entry Metadata Block

For non-directory entries, read in order:

- `u8` entry volume number
- `u32` fork_data_offset (absolute file offset to compressed resource fork start)
- `u32` file type (classic Mac `OSType`)
- `u32` creator code (classic Mac `OSType`)
- `u32` creation timestamp (Mac epoch)
- `u32` modification timestamp (Mac epoch)
- `u16` Finder flags
- `u32` file CRC (for combined decoded fork payload; see section 10)
- `u16` flags:
  - bit 0 (`0x0001`): encrypted
  - bit 1 (`0x0002`): resource fork uses LZH stage
  - bit 2 (`0x0004`): data fork uses LZH stage
- `u32` resource_uncompressed_len
- `u32` data_uncompressed_len
- `u32` resource_compressed_len
- `u32` data_compressed_len

Fork presence rules:
- If `resource_uncompressed_len > 0`, resource fork exists.
- Data fork exists if `data_uncompressed_len > 0` OR resource fork does not exist.
- Fork data offsets:
  - resource fork compressed stream starts at `fork_data_offset`
  - data fork compressed stream starts at `fork_data_offset + resource_compressed_len`

Encryption:
- If flag bit 0 is set, decoder SHOULD report unsupported-encryption unless an encryption spec is added.

## 8. Fork Decode Pipeline

For each present fork:
- Read its compressed byte span (`*_compressed_len`).
- If corresponding LZH bit is set, first decode with Compact Pro LZH.
- Decode resulting byte stream with Compact Pro RLE.
- Output MUST be exactly `*_uncompressed_len` bytes.

If decoded length differs from expected length, treat as corrupt stream.

## 9. Compact Pro RLE (0x81/0x82 Scheme)

### 9.1 Decoder State

Maintain:
- `saved` (last emitted byte)
- `repeat` (remaining count of implicit repeats)
- `half_escaped` (boolean)

### 9.2 Decoding Rules

Algorithm:

1. If `repeat > 0`: emit `saved`, decrement `repeat`, return.
2. Read next input byte into `b0`, except:
   - if `half_escaped` is true, set `b0 = 0x81` and clear `half_escaped` without consuming input.
3. If `b0 != 0x81`:
   - set `saved = b0`, emit `b0`, return.
4. (`b0 == 0x81`) Read next byte `b1`:
   - If `b1 == 0x82`:
     - Read next byte `n`.
     - If `n == 0x00`:
       - emit `0x81`, then schedule one extra byte `saved = 0x82`, `repeat = 1`.
     - Else if `n >= 0x02`:
       - emit `saved`, then set `repeat = n - 2`.
     - Else (`n == 0x01`):
       - compatibility ambiguity in legacy implementations.
       - strict decoder: reject as invalid.
       - permissive decoder: treat as no-op repeat extension of length 0.
   - Else if `b1 == 0x81`:
     - emit `0x81`, set `saved = 0x81`, set `half_escaped = true`.
   - Else:
     - emit `0x81`, set `saved = b1`, set `repeat = 1`.

### 9.3 Encoder Guidance

A deterministic compatible encoder SHOULD:
- Track runs of the previous output byte.
- Emit literal bytes directly unless escape handling is required.
- For run extension of previous byte:
  - emit token `0x81 0x82 n` with `n` in `[0x02, 0xFF]`, representing `n - 1` emitted copies in token expansion.
- Never intentionally emit `n == 0x01`.
- For literal `0x81 0x82` sequence, use `0x81 0x82 0x00`.

## 10. Compact Pro LZH Stage

Compact Pro LZH is an LZSS-style stream with per-block dynamic Huffman tables.

### 10.1 Window and Block Constants

- Sliding window size: `8192` bytes.
- Block control counter limit: `0x1FFF0`.

### 10.2 Block Structure

Each block begins with 3 codebooks:
- Literal symbol codebook for 256 symbols.
- Match-length codebook for 64 symbols.
- Match-offset-prefix codebook for 128 symbols.

Codebook serialization:
- `u8` `num_len_bytes`
- Constraint: `num_len_bytes * 2 <= symbol_count`
- Read `num_len_bytes` bytes; each byte supplies two 4-bit code lengths:
  - high nibble = symbol index `2*i`
  - low nibble = symbol index `2*i + 1`
- Unspecified trailing symbols have code length 0.

Canonical code construction:
- Build prefix codes from code lengths (max observed length 15).
- Legacy decoders use "shortest code is zeros" canonical ordering.

### 10.3 Token Stream Inside a Block

Until internal `block_count >= 0x1FFF0`:
- Read one flag bit.
- If flag bit is `1` (literal token):
  - decode one literal symbol (0..255) from literal codebook.
  - output literal byte.
  - `block_count += 2`.
- If flag bit is `0` (match token):
  - decode `len_sym` from length codebook (0..63).
  - decode `off_hi` from offset-prefix codebook (0..127).
  - read 6 raw bits `off_lo`.
  - match offset code = `(off_hi << 6) | off_lo`.
  - emit LZSS backreference `(length = len_sym, offset = offset_code)`.
  - `block_count += 3`.

Note:
- Backreference copy semantics must match decoder's LZSS engine (overlapping copy allowed, circular window behavior).

### 10.4 Inter-Block Alignment Quirk

Legacy decoder logic includes a byte-alignment + 2/3-byte skip behavior at block boundaries based on parity of consumed block bits. This appears to be compatibility with historical encoder output framing.

Recommendation:
- Decoder: implement this quirk in strict-compat mode.
- Encoder: prefer single-block output when practical to minimize quirk exposure; if multi-block output is produced, mirror legacy framing once verified against fixtures.

## 11. CRC and Integrity

Two CRC domains are used:

1. Archive header CRC (section 5.2).
2. File payload CRC (`file CRC` metadata field):
   - computed over decoded fork payload stream in this order:
     - resource fork decoded bytes (if present), then
     - data fork decoded bytes (if present).
   - algorithm family matches JAMCRC-style usage in observed implementations.

Strict decoder SHOULD verify both CRCs.

## 12. Compressor Requirements (Clean-Room Writer)

A writer that aims for broad compatibility MUST:
- Emit valid top-level header with marker `0x01`.
- Emit directory entries using recursive count-driven encoding.
- Emit file metadata with correct sizes/flags/offsets.
- Encode each fork as:
  - optional LZH stage (if enabled for that fork),
  - required RLE stage.
- Set compressed lengths and offsets consistently.
- Compute and write header CRC and per-file CRC correctly.

Recommended staged implementation:

1. Implement parser + raw metadata dumper.
2. Implement RLE decoder + encoder with round-trip tests.
3. Implement LZH decoder only and verify against known archives.
4. Implement extractor with CRC verification.
5. Implement RLE-only writer mode.
6. Add LZH writer mode and differential tests against independent decoders.

## 13. Conformance Test Plan

Minimum deterministic suite:

- Container parsing:
  - valid marker/header/entry recursion cases
  - truncated fields and out-of-range offsets
  - CRC mismatch handling (strict vs lenient)
- RLE:
  - literals, escaped `0x81`, escaped `0x81 0x82`, run extensions, malformed token handling
- LZH:
  - table decode, literal-only block, mixed literal/match block, invalid codebook lengths
- Full archive extraction:
  - files with only data fork
  - files with only resource fork
  - files with both forks
  - LZH-on/off permutations per fork
- Round-trip compressor:
  - decode(original) == decode(recompressed)
  - metadata and CRC consistency

Stress tests:
- random-but-valid codebooks
- large overlapping backreferences
- fuzzed corrupted streams with deterministic error classification

## 14. Known Unknowns / Open Questions

- Encrypted file format and key derivation are not fully specified here.
- Multi-volume authoring behavior needs additional fixture-driven validation.
- LZH inter-block skip/alignment behavior should be finalized with a dedicated corpus of multi-block files.
- Character encoding normalization policy for names/comments (raw bytes vs MacRoman/UTF-8 conversion) should be chosen explicitly by product requirements.

## 15. Legal/Process Notes for Clean-Room Work

- Do not copy legacy LGPL implementation code into target implementation.
- Use this spec + black-box fixtures + independent behavior tests.
- Keep derivation logs: each rule should map to observed byte-level behavior in fixtures.

## 16. Suggested Next Step for Zig Implementation

Start with a `decode-only` milestone and deterministic fixtures:
- parser module (container + entries)
- `rle8182` module
- `lzh` module
- crc module
- extractor CLI

Then add writer mode only after decode parity is stable.

### 16.1 Implementation Readiness Caution

This specification is sufficient to begin a clean-room decompressor and compressor implementation.

Compatibility caution:
- Do not claim full compressor compatibility until LZH multi-block framing/alignment behavior is validated against real fixture archives and independent decoders.
- Single-block LZH output is the recommended first compatibility milestone for writer mode.

## 17. Host Fork Mapping Policy (Normative)

This section defines how decoded/encoded resource forks map to host filesystem representations.

### 17.1 CLI Surface

- `--sidecar`:
  - use AppleDouble sidecar representation for resource fork input/output.
- `--rsrc <path>`:
  - use explicit AppleDouble resource sidecar file path for input/output.
- `--xattr <name>` (Linux only):
  - use named xattr for resource fork input/output.
  - unsupported on non-Linux hosts.

If multiple fork-output selectors are provided, the command MUST fail with a clear conflict error.

### 17.2 macOS Behavior

Defaults on macOS:
- Output MUST target native resource fork storage (not sidecar) unless `--sidecar` or `--rsrc` is provided.
- Input SHOULD first attempt native resource fork; sidecar MAY be selected explicitly via `--sidecar` or `--rsrc`.

Native resource fork path:
- Writer/reader SHOULD use `<file_path>/..namedfork/rsrc` (the special fork path on macOS).

`--sidecar` on macOS:
- Output uses AppleDouble naming beside the data file.
- Input reads AppleDouble sidecar instead of native resource fork.

### 17.3 Non-macOS Behavior (All Other Hosts)

Defaults on non-macOS:
- Output MUST use AppleDouble sidecar representation.
- Input MUST read resource fork data from AppleDouble sidecar only when `--sidecar` or `--rsrc` is provided.
- If no sidecar selector is provided and no native fork mechanism is available, treat resource fork as absent.

### 17.4 Linux `--xattr` Extension

Linux-only behavior:
- `--xattr <name>` MAY be used on input, output, or both.
- On output with `--xattr`, decoded resource fork bytes MUST be written to xattr key `<name>` on the data file.
- On input with `--xattr`, compressor MUST read resource fork bytes from xattr key `<name>`.

Precedence when multiple selectors are provided:
- `--xattr` conflicts with `--sidecar` and `--rsrc`; command MUST fail unless the tool supports an explicit dual-write mode.

### 17.5 AppleDouble Naming Rules

Default sidecar naming policy:
- For data file path `<dir>/<name>`, sidecar path is `<dir>/._<name>`.
- For explicit `--rsrc <path>`, writer MUST use exactly the provided sidecar path.

### 17.6 Deterministic Test Matrix

Add explicit host-policy tests:
- macOS default extract writes native fork and no sidecar.
- macOS `--sidecar` extract writes AppleDouble sidecar.
- macOS compress reads native fork by default; with `--sidecar` reads sidecar.
- non-macOS default extract writes AppleDouble sidecar.
- non-macOS compress reads sidecar only when selected with `--sidecar` or `--rsrc`.
- Linux `--xattr` round-trip for named xattr key.
- conflict handling for incompatible selector combinations.
