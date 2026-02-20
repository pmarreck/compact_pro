# PROJECT_OVERVIEW

`compact_pro` is a clean-room implementation of Compact Pro (`.cpt`) archive handling.

Goals:
- Provide deterministic archive parsing/extraction and archive writing from a modern codebase.
- Keep compression/decompression logic pure and testable in Zig.
- Expose a C ABI for external consumers.
- Provide a C CLI (`compact-pro`) that uses the C ABI and performs all filesystem I/O.

Terminology:
- Data fork: primary file bytes.
- Resource fork: classic Mac secondary fork bytes.
- Sidecar: AppleDouble file (`._<name>`) used to store resource fork bytes on hosts without native forks.
