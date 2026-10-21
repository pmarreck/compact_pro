# TERMINOLOGY

- **Data fork**: a file's primary bytes.
- **Resource fork**: the classic Mac secondary fork of a file (structured
  resources such as icons and code).
- **Sidecar**: an AppleDouble file (`._<name>`) that stores resource fork bytes
  on hosts without native forks.
- **RLE (0x81/0x82)**: Compact Pro's run-length encoding, where `0x81` is the
  escape byte and `0x81 0x82 n` repeats the previous byte.
- **LZH**: Compact Pro's LZSS compression with an 8 KiB window and per-block
  Huffman codebooks, applied on top of RLE output.
- **JAMCRC**: CRC-32 without the final complement; Compact Pro's header and
  per-file checksums.
- **Metadata trailer**: bytes this project appends after the Compact Pro data to
  carry host metadata (permissions, owners, timestamps, Apple and NTFS
  attributes, empty directories). Version 2 adds a CRC-32 of its payload. Other
  readers ignore it as trailing bytes.
- **Verify parity**: the rule that `compact-pro verify` rejects every archive
  `compact-pro expand` rejects.
