# PLAN

## Done Criteria (current milestone)

- [x] Implement pure Zig core for Compact Pro archive parse/create/extract/add (RLE profile first, deterministic behavior). (completed 2026-02-20 12:00 EST)
- [x] Provide stable C FFI over core for archive operations and memory ownership. (completed 2026-02-20 12:00 EST)
- [x] Ship C CLI binary named `compact-pro` with `--help`, `compress`, `expand`, `add`, `list`, and resource-fork options (`--sidecar`, `--rsrc`, `--xattr`). (completed 2026-02-20 12:00 EST)
- [x] Add selective extraction (`expand --path`) and directory-aware archive path preservation. (completed 2026-02-20 12:00 EST)
- [x] Add cross-platform metadata extension (`.compact-pro.meta.bin`) with best-effort restore + warnings on unsupported/failed metadata restore paths. (completed 2026-02-20 12:00 EST)
- [x] Add cross-platform build/test scripts: `./build`, `./test`, plus `./bm` and `./fuzz` placeholders. (completed 2026-02-20 12:00 EST)
- [x] Add dependency management via `flake.nix` and Garnix + GitHub Actions CI scaffolding. (completed 2026-02-20 12:00 EST)
- [x] Write `README.md` with CI badges (Garnix + GitHub Actions), project description, and CLI options. (completed 2026-02-20 12:00 EST)
- [ ] Create/push GitHub repo `compact_pro` via `gh` and confirm badge links resolve against the created remote.
- [ ] Update `CODE_MINIMAP.md` to reflect all new code/docs.

## Continuity

- [x] Spec and fixture groundwork complete. (completed 2026-02-20 02:36 EST)
