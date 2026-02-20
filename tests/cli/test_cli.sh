#!/usr/bin/env bash
set -euo pipefail

zig build -Doptimize=ReleaseFast >/dev/null

output=$(./zig-out/bin/compact-pro --help)
[[ "$output" == *"compact-pro"* ]]
[[ "$output" == *"compress"* ]]
[[ "$output" == *"expand"* ]]
[[ "$output" == *"add"* ]]

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/compact-pro-cli.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

printf 'hello compact-pro\n' >"$tmp_dir/input.txt"
chmod 700 "$tmp_dir/input.txt"
./zig-out/bin/compact-pro compress -o "$tmp_dir/a.cpt" "$tmp_dir/input.txt"
mkdir -p "$tmp_dir/out-a"
./zig-out/bin/compact-pro expand "$tmp_dir/a.cpt" -d "$tmp_dir/out-a"
cmp "$tmp_dir/input.txt" "$tmp_dir/out-a/input.txt"

mode_src="$(stat --printf='%a' "$tmp_dir/input.txt")"
mode_dst="$(stat --printf='%a' "$tmp_dir/out-a/input.txt")"
[[ "$mode_src" == "$mode_dst" ]]

printf 'second file\n' >"$tmp_dir/second.txt"
./zig-out/bin/compact-pro add "$tmp_dir/a.cpt" "$tmp_dir/second.txt"
mkdir -p "$tmp_dir/out-b"
./zig-out/bin/compact-pro expand "$tmp_dir/a.cpt" -d "$tmp_dir/out-b"
cmp "$tmp_dir/second.txt" "$tmp_dir/out-b/second.txt"

mkdir -p "$tmp_dir/out-b-selective"
./zig-out/bin/compact-pro expand "$tmp_dir/a.cpt" -d "$tmp_dir/out-b-selective" --path second.txt
[[ -f "$tmp_dir/out-b-selective/second.txt" ]]
[[ ! -f "$tmp_dir/out-b-selective/input.txt" ]]

printf 'with resource fork\n' >"$tmp_dir/fork.txt"
printf 'resource bytes' >"$tmp_dir/._fork.txt"
./zig-out/bin/compact-pro compress --sidecar -o "$tmp_dir/fork.cpt" "$tmp_dir/fork.txt"
mkdir -p "$tmp_dir/out-c"
./zig-out/bin/compact-pro expand --sidecar "$tmp_dir/fork.cpt" -d "$tmp_dir/out-c"
cmp "$tmp_dir/._fork.txt" "$tmp_dir/out-c/._fork.txt"

mkdir -p "$tmp_dir/tree/sub"
printf 'nested payload\n' >"$tmp_dir/tree/sub/nested.txt"
(
	cd "$tmp_dir/tree"
	"$OLDPWD/zig-out/bin/compact-pro" compress -o "$tmp_dir/tree.cpt" sub/nested.txt
)
tree_list="$("./zig-out/bin/compact-pro" list "$tmp_dir/tree.cpt")"
[[ "$tree_list" == *"sub/nested.txt"* ]]
mkdir -p "$tmp_dir/out-tree"
./zig-out/bin/compact-pro expand "$tmp_dir/tree.cpt" -d "$tmp_dir/out-tree"
cmp "$tmp_dir/tree/sub/nested.txt" "$tmp_dir/out-tree/sub/nested.txt"
