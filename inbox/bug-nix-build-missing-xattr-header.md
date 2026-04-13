# Bug: nix build fails on macOS — missing sys/xattr.h

## Summary

`nix build` fails in the sandbox because `csrc/compact_pro_cli.c` includes `<sys/xattr.h>` which isn't available in the default `stdenv.mkDerivation` on macOS.

## Error

```
csrc/compact_pro_cli.c:33:10: error: 'sys/xattr.h' file not found
#include <sys/xattr.h>
         ^~~~~~~~~~~~~~
```

## Fix

The flake.nix derivation needs macOS SDK frameworks. Add to `buildInputs`:

```nix
buildInputs = pkgs.lib.optionals pkgs.stdenv.isDarwin [
  pkgs.darwin.apple_sdk.frameworks.CoreFoundation
];
```

Or use `pkgs.darwin.apple_sdk_14_4.MacOSX-SDK` to get the full SDK headers including `sys/xattr.h`.

The old `./build` script used `nix develop -c zig build` which had the SDK available via the shell environment, masking this issue.

## Discovered

2026-04-13 while applying the unified Zig + Nix build pattern across all projects.
