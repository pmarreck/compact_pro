# RULES

- Core codec and container logic must remain pure (no filesystem or process I/O in Zig core modules).
- C FFI must expose explicit ownership boundaries and provide matching free functions.
- CLI binary name is `compact-pro`; repository name is `compact_pro`.
- `./test` must run the full deterministic test suite and return non-zero on failure.
- `./build` must produce optimized builds by default.
