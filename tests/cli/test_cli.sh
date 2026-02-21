#!/usr/bin/env bash
set -euo pipefail

zig build -Doptimize=ReleaseFast >/dev/null

output=$(./zig-out/bin/compact-pro --help)
[[ "$output" == *"compact-pro"* ]]
[[ "$output" == *"compress"* ]]
[[ "$output" == *"expand"* ]]
[[ "$output" == *"add"* ]]

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/compact-pro-cli.XXXXXX")"
home_tmp="$(mktemp -d "$HOME/.compact-pro-cli-home.XXXXXX")"
trap 'rm -rf "$tmp_dir" "$home_tmp"' EXIT

printf 'hello compact-pro\n' >"$tmp_dir/input.txt"
chmod 700 "$tmp_dir/input.txt"
./zig-out/bin/compact-pro compress -o "$tmp_dir/a.cpt" "$tmp_dir/input.txt"
progress_compress="$(./zig-out/bin/compact-pro compress --progress -o "$tmp_dir/a-progress.cpt" "$tmp_dir/input.txt" 2>&1 >/dev/null)"
[[ "$progress_compress" == *"progress"* ]]
[[ "$progress_compress" == *"compress-encode"* ]]
[[ "$progress_compress" == *"ETA:"* ]]
printf '%s' "$progress_compress" | grep -F "[" >/dev/null
printf '%s' "$progress_compress" | grep -F "]" >/dev/null
[[ "$progress_compress" == *"%"* ]]
no_progress_compress="$(./zig-out/bin/compact-pro compress --progress --no-progress -o "$tmp_dir/a-noprogress.cpt" "$tmp_dir/input.txt" 2>&1 >/dev/null)"
[[ "$no_progress_compress" != *"progress"* ]]
stats_compress="$(./zig-out/bin/compact-pro compress --no-progress -o "$tmp_dir/a-stats.cpt" "$tmp_dir/input.txt" 2>&1 >/dev/null)"
[[ "$stats_compress" == *"stats: compress"* ]]
[[ "$stats_compress" == *"MB/s"* ]]
[[ "$stats_compress" == *"percent="* ]]
mkdir -p "$tmp_dir/out-a"
./zig-out/bin/compact-pro expand "$tmp_dir/a.cpt" -d "$tmp_dir/out-a"
progress_expand="$(./zig-out/bin/compact-pro expand --progress "$tmp_dir/a.cpt" -d "$tmp_dir/out-a-progress" 2>&1 >/dev/null)"
[[ "$progress_expand" == *"progress"* ]]
[[ "$progress_expand" == *"expand-decode"* ]]
[[ "$progress_expand" == *"ETA:"* ]]
stats_expand="$(./zig-out/bin/compact-pro expand --no-progress "$tmp_dir/a.cpt" -d "$tmp_dir/out-a-stats" 2>&1 >/dev/null)"
[[ "$stats_expand" == *"stats: expand"* ]]
[[ "$stats_expand" == *"MB/s"* ]]
[[ "$stats_expand" == *"compressed="* ]]
[[ "$stats_expand" == *"expanded="* ]]
cmp "$tmp_dir/input.txt" "$tmp_dir/out-a/input.txt"

mode_src="$(stat --printf='%a' "$tmp_dir/input.txt")"
mode_dst="$(stat --printf='%a' "$tmp_dir/out-a/input.txt")"
[[ "$mode_src" == "$mode_dst" ]]

list_a="$("./zig-out/bin/compact-pro" list "$tmp_dir/a.cpt")"
[[ "$list_a" == *"input.txt"* ]]
[[ "$list_a" == *$'input.txt\tdata='* ]]
[[ "$list_a" == *"rsrc=0"* ]]
[[ "$list_a" != *".compact-pro.meta.bin"* ]]
[[ "$list_a" == *"trailer_size="* ]]

trailer_magic="$(xxd -p -l 8 -s -16 "$tmp_dir/a.cpt" | tr -d '\n')"
[[ "$trailer_magic" == "43505854524c5231" ]]
trailer_version="$(xxd -p -l 4 -s -4 "$tmp_dir/a.cpt" | tr -d '\n')"
[[ "$trailer_version" == "01000000" ]]

payload_len_le="$(xxd -p -l 4 -s -8 "$tmp_dir/a.cpt" | tr -d '\n')"
payload_len_be="${payload_len_le:6:2}${payload_len_le:4:2}${payload_len_le:2:2}${payload_len_le:0:2}"
payload_len=$((16#$payload_len_be))
archive_size=$(wc -c < "$tmp_dir/a.cpt")
base_size=$((archive_size - payload_len - 16))
dd if="$tmp_dir/a.cpt" of="$tmp_dir/a-notrailer.cpt" bs=1 count="$base_size" status=none

mkdir -p "$tmp_dir/out-a-notrailer"
./zig-out/bin/compact-pro expand "$tmp_dir/a-notrailer.cpt" -d "$tmp_dir/out-a-notrailer"
cmp "$tmp_dir/input.txt" "$tmp_dir/out-a-notrailer/input.txt"
mode_no_trailer="$(stat --printf='%a' "$tmp_dir/out-a-notrailer/input.txt")"
[[ "$mode_no_trailer" != "$mode_src" ]]

if [[ "$(uname -s)" != "Windows_NT" ]]; then
	cat "$tmp_dir/a-notrailer.cpt" >"$tmp_dir/a-ntfswarn.cpt"
	printf '43504d455441320a01000000ffffffff0109000000696e7075742e747874000f000020000000010000000000000002000000000000000300000000000000' | xxd -r -p >"$tmp_dir/meta-v2-ntfs.bin"
	cat "$tmp_dir/meta-v2-ntfs.bin" >>"$tmp_dir/a-ntfswarn.cpt"
	printf 'CPXTRLR1' >>"$tmp_dir/a-ntfswarn.cpt"
	printf '\x3e\x00\x00\x00\x01\x00\x00\x00' >>"$tmp_dir/a-ntfswarn.cpt"
	mkdir -p "$tmp_dir/out-ntfswarn"
	warn_out="$(./zig-out/bin/compact-pro expand "$tmp_dir/a-ntfswarn.cpt" -d "$tmp_dir/out-ntfswarn" 2>&1 >/dev/null)"
	[[ "$warn_out" == *"ntfs file attributes"* ]]
	[[ "$warn_out" == *"ntfs creation time"* ]]
	[[ "$warn_out" == *"ntfs access time"* ]]
	[[ "$warn_out" == *"ntfs write time"* ]]
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
	printf 'fork carrier\n' >"$tmp_dir/hasfork.txt"
	printf 'resource-bytes' >"$tmp_dir/hasfork.txt/..namedfork/rsrc"
	./zig-out/bin/compact-pro compress -o "$tmp_dir/hasfork.cpt" "$tmp_dir/hasfork.txt"
	hasfork_line="$("./zig-out/bin/compact-pro" list "$tmp_dir/hasfork.cpt" | grep 'hasfork.txt')"
	rsrc_size="$(printf '%s\n' "$hasfork_line" | sed -E 's/.*rsrc=([0-9]+).*/\1/')"
	[[ "$rsrc_size" -gt 0 ]]
fi

space_input="$home_tmp/A Good Night's Sleep - Anna Wahlgren.pdf"
printf 'space path payload\n' >"$space_input"
tilde_input="~${space_input#$HOME}"
default_archive="$(basename "$space_input").cpt"
rm -f "$default_archive"
./zig-out/bin/compact-pro compress "$tilde_input"
[[ -f "$default_archive" ]]
mkdir -p "$tmp_dir/out-default"
./zig-out/bin/compact-pro expand "$default_archive" -d "$tmp_dir/out-default"
cmp "$space_input" "$tmp_dir/out-default/$(basename "$space_input")"
rm -f "$default_archive"

./zig-out/bin/compact-pro compress -o "$tmp_dir/noext" "$tmp_dir/input.txt"
[[ -f "$tmp_dir/noext.cpt" ]]

printf 'old output\n' >"$tmp_dir/existing.cpt"
if ./zig-out/bin/compact-pro compress -o "$tmp_dir/existing.cpt" "$tmp_dir/input.txt" >/dev/null 2>&1; then
	echo "expected compress to fail when output exists without --force" >&2
	exit 1
fi
./zig-out/bin/compact-pro compress --force -o "$tmp_dir/existing.cpt" "$tmp_dir/input.txt" >/dev/null
[[ "$("./zig-out/bin/compact-pro" list "$tmp_dir/existing.cpt")" == *"input.txt"* ]]

./zig-out/bin/compact-pro compress -o - "$tmp_dir/input.txt" >"$tmp_dir/stdout.cpt"
mkdir -p "$tmp_dir/out-stdout"
./zig-out/bin/compact-pro expand "$tmp_dir/stdout.cpt" -d "$tmp_dir/out-stdout"
cmp "$tmp_dir/input.txt" "$tmp_dir/out-stdout/input.txt"

printf 'stdin payload\n' | ./zig-out/bin/compact-pro compress -o "$tmp_dir/stdin.cpt" -
mkdir -p "$tmp_dir/out-stdin"
./zig-out/bin/compact-pro expand "$tmp_dir/stdin.cpt" -d "$tmp_dir/out-stdin"
cmp <(printf 'stdin payload\n') "$tmp_dir/out-stdin/-"

printf 'second file\n' >"$tmp_dir/second.txt"
./zig-out/bin/compact-pro add "$tmp_dir/a.cpt" "$tmp_dir/second.txt"
printf 'third file\n' >"$tmp_dir/third.txt"
progress_add="$(./zig-out/bin/compact-pro add --progress "$tmp_dir/a.cpt" "$tmp_dir/third.txt" 2>&1 >/dev/null)"
[[ "$progress_add" == *"progress"* ]]
[[ "$progress_add" == *"add-encode"* ]]
[[ "$progress_add" == *"ETA:"* ]]
mkdir -p "$tmp_dir/out-b"
./zig-out/bin/compact-pro expand "$tmp_dir/a.cpt" -d "$tmp_dir/out-b"
cmp "$tmp_dir/second.txt" "$tmp_dir/out-b/second.txt"
cmp "$tmp_dir/third.txt" "$tmp_dir/out-b/third.txt"

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
chmod 711 "$tmp_dir/tree/sub"
touch -m -d '2020-01-02 03:04:05 UTC' "$tmp_dir/tree/sub"
(
	cd "$tmp_dir/tree"
	"$OLDPWD/zig-out/bin/compact-pro" compress -o "$tmp_dir/tree.cpt" sub/nested.txt
)
tree_list="$("./zig-out/bin/compact-pro" list "$tmp_dir/tree.cpt")"
[[ "$tree_list" == *"sub/nested.txt"* ]]
mkdir -p "$tmp_dir/out-tree"
./zig-out/bin/compact-pro expand "$tmp_dir/tree.cpt" -d "$tmp_dir/out-tree"
cmp "$tmp_dir/tree/sub/nested.txt" "$tmp_dir/out-tree/sub/nested.txt"
dir_mode_src="$(stat --printf='%a' "$tmp_dir/tree/sub")"
dir_mode_dst="$(stat --printf='%a' "$tmp_dir/out-tree/sub")"
[[ "$dir_mode_src" == "$dir_mode_dst" ]]
dir_mtime_src="$(stat --printf='%Y' "$tmp_dir/tree/sub")"
dir_mtime_dst="$(stat --printf='%Y' "$tmp_dir/out-tree/sub")"
[[ "$dir_mtime_src" == "$dir_mtime_dst" ]]

mkdir -p "$tmp_dir/My Games/Fallout4/Saves"
printf 'slot data\n' >"$tmp_dir/My Games/Fallout4/Saves/slot1.sav"
./zig-out/bin/compact-pro compress -o "$tmp_dir/fallout.cpt" "$tmp_dir/My Games/Fallout4"
mkdir -p "$tmp_dir/out-fallout"
./zig-out/bin/compact-pro expand "$tmp_dir/fallout.cpt" -d "$tmp_dir/out-fallout"
cmp "$tmp_dir/My Games/Fallout4/Saves/slot1.sav" "$tmp_dir/out-fallout/Fallout4/Saves/slot1.sav"

mkdir -p "$tmp_dir/empty-root/inner-empty"
chmod 701 "$tmp_dir/empty-root/inner-empty"
touch -m -d '2021-06-07 08:09:10 UTC' "$tmp_dir/empty-root/inner-empty"
./zig-out/bin/compact-pro compress -o "$tmp_dir/empty.cpt" "$tmp_dir/empty-root"
mkdir -p "$tmp_dir/out-empty"
./zig-out/bin/compact-pro expand "$tmp_dir/empty.cpt" -d "$tmp_dir/out-empty"
[[ -d "$tmp_dir/out-empty/empty-root" ]]
[[ -d "$tmp_dir/out-empty/empty-root/inner-empty" ]]
empty_mode_src="$(stat --printf='%a' "$tmp_dir/empty-root/inner-empty")"
empty_mode_dst="$(stat --printf='%a' "$tmp_dir/out-empty/empty-root/inner-empty")"
[[ "$empty_mode_src" == "$empty_mode_dst" ]]

mkdir -p "$tmp_dir/out-lzh"
./zig-out/bin/compact-pro expand --sidecar fixtures/cpt/MacEnvy21.cpt -d "$tmp_dir/out-lzh"
[[ -f "$tmp_dir/out-lzh/MacEnvy" ]]
[[ -f "$tmp_dir/out-lzh/._MacEnvy" ]]
[[ "$(wc -c < "$tmp_dir/out-lzh/MacEnvy" | tr -d '[:space:]')" == "0" ]]
[[ "$(wc -c < "$tmp_dir/out-lzh/._MacEnvy" | tr -d '[:space:]')" == "36336" ]]
[[ "$(shasum -a 256 "$tmp_dir/out-lzh/._MacEnvy" | awk '{print $1}')" == "7168936e8b51b8e5eb5ea029cc7ab4b43d126c0a0c6ef811623e7872eae8f7cb" ]]

if command -v unar >/dev/null 2>&1; then
	awk 'BEGIN{srand(12345); n=6*1024*1024; for(i=0;i<n;i++){c=65+int(rand()*8); printf "%c", c}}' >"$tmp_dir/unar-multiblock.txt"
	./zig-out/bin/compact-pro compress -o "$tmp_dir/unar-multiblock.cpt" "$tmp_dir/unar-multiblock.txt"
	mkdir -p "$tmp_dir/out-unar"
	unar -force-overwrite -output-directory "$tmp_dir/out-unar" "$tmp_dir/unar-multiblock.cpt" >"$tmp_dir/unar-multiblock.out" 2>"$tmp_dir/unar-multiblock.err"
	cmp "$tmp_dir/unar-multiblock.txt" "$tmp_dir/out-unar/unar-multiblock.txt"
fi
