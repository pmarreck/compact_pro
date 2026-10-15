#!/usr/bin/env bash
set -euo pipefail

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
		return
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
		return
	fi
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
		return
	fi
	echo "error: no SHA-256 tool available (need sha256sum, shasum, or openssl)" >&2
	exit 1
}

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
	zig build -Doptimize=ReleaseFast >/dev/null
fi

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
[[ "$trailer_version" == "02000000" ]]

payload_len_le="$(xxd -p -l 4 -s -8 "$tmp_dir/a.cpt" | tr -d '\n')"
payload_len_be="${payload_len_le:6:2}${payload_len_le:4:2}${payload_len_le:2:2}${payload_len_le:0:2}"
payload_len=$((16#$payload_len_be))
archive_size=$(wc -c < "$tmp_dir/a.cpt")
# Version 2 trailer: payload, CRC-32 of the payload (4 bytes), 16-byte footer.
base_size=$((archive_size - payload_len - 4 - 16))
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
[[ "$(sha256_file "$tmp_dir/out-lzh/._MacEnvy")" == "7168936e8b51b8e5eb5ea029cc7ab4b43d126c0a0c6ef811623e7872eae8f7cb" ]]

if command -v unar >/dev/null 2>&1; then
	awk 'BEGIN{srand(12345); n=6*1024*1024; for(i=0;i<n;i++){c=65+int(rand()*8); printf "%c", c}}' >"$tmp_dir/unar-multiblock.txt"
	./zig-out/bin/compact-pro compress -o "$tmp_dir/unar-multiblock.cpt" "$tmp_dir/unar-multiblock.txt"
	mkdir -p "$tmp_dir/out-unar"
	unar -force-overwrite -output-directory "$tmp_dir/out-unar" "$tmp_dir/unar-multiblock.cpt" >"$tmp_dir/unar-multiblock.out" 2>"$tmp_dir/unar-multiblock.err"
	cmp "$tmp_dir/unar-multiblock.txt" "$tmp_dir/out-unar/unar-multiblock.txt"
fi

# verify: bounded-memory integrity check through cp_archive_verify_stream.
verify_out="$("./zig-out/bin/compact-pro" verify "$tmp_dir/a.cpt")"
list_entries="$("./zig-out/bin/compact-pro" list "$tmp_dir/a.cpt" | grep -vc '^trailer_size=')"
list_bytes="$("./zig-out/bin/compact-pro" list "$tmp_dir/a.cpt" | awk -F'\t' '/\tdata=/ { sub("data=", "", $2); sub("rsrc=", "", $3); t += $2 + $3 } END { print t + 0 }')"
[[ "$verify_out" == $'ok\tentries='"$list_entries"$'\tbytes='"$list_bytes" ]]
verify_stdin="$("./zig-out/bin/compact-pro" verify - <"$tmp_dir/a.cpt")"
[[ "$verify_stdin" == "$verify_out" ]]
cp "$tmp_dir/a.cpt" "$tmp_dir/verify space.cpt"
[[ "$("./zig-out/bin/compact-pro" verify "$tmp_dir/verify space.cpt")" == "$verify_out" ]]
cp "$tmp_dir/a.cpt" "$tmp_dir/corrupt.cpt"
first_fork_byte="$(xxd -p -l 1 -s 8 "$tmp_dir/corrupt.cpt")"
printf "$(printf '\\x%02x' $(( 0x$first_fork_byte ^ 0xFF )))" | dd of="$tmp_dir/corrupt.cpt" bs=1 seek=8 conv=notrunc status=none
verify_rc=0
"./zig-out/bin/compact-pro" verify "$tmp_dir/corrupt.cpt" >"$tmp_dir/verify-corrupt.out" 2>"$tmp_dir/verify-corrupt.err" || verify_rc=$?
[[ "$verify_rc" == 1 ]]
[[ ! -s "$tmp_dir/verify-corrupt.out" ]]
[[ "$(cat "$tmp_dir/verify-corrupt.err")" == "error: verify failed: "* ]]

# verify must reject whatever expand rejects, including a damaged metadata
# trailer: claim the whole file as trailer payload so the archive proper is empty.
cp "$tmp_dir/a.cpt" "$tmp_dir/bad-trailer.cpt"
bad_size=$(stat -c %s "$tmp_dir/bad-trailer.cpt")
bad_len=$((bad_size - 4 - 16))
printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((bad_len & 255)) $(((bad_len >> 8) & 255)) $(((bad_len >> 16) & 255)) $(((bad_len >> 24) & 255)))" |
	dd of="$tmp_dir/bad-trailer.cpt" bs=1 seek=$((bad_size - 16 + 8)) conv=notrunc status=none
expand_bad_rc=0
"./zig-out/bin/compact-pro" expand --no-progress "$tmp_dir/bad-trailer.cpt" -d "$tmp_dir/out-bad-trailer" >/dev/null 2>"$tmp_dir/expand-bad-trailer.err" || expand_bad_rc=$?
[[ "$expand_bad_rc" != 0 ]]
verify_bad_rc=0
"./zig-out/bin/compact-pro" verify "$tmp_dir/bad-trailer.cpt" >/dev/null 2>"$tmp_dir/verify-bad-trailer.err" || verify_bad_rc=$?
[[ "$verify_bad_rc" == 1 ]]

# LZH bitstream damage gets a typed error and the archive offset where it was found.
awk 'BEGIN{for(i=0;i<4000;i++) printf "%s", substr("lzh wins on repetitive text. ", i % 29 + 1, 1)}' >"$tmp_dir/lzh-text.txt"
"./zig-out/bin/compact-pro" compress --no-progress -o "$tmp_dir/lzh-text.cpt" "$tmp_dir/lzh-text.txt" 2>/dev/null
[[ "$("./zig-out/bin/compact-pro" list "$tmp_dir/lzh-text.cpt" | head -1)" == *"flags=0x0004"* ]]
# The directory header precedes fork data; read the entry's fork_data_offset
# (after crc, count, comment length, name length byte, 12-byte name, volume).
lzh_header_at=$(od -An -tu4 --endian=big -j4 -N4 "$tmp_dir/lzh-text.cpt" | tr -d ' ')
lzh_fork_at=$(od -An -tu4 --endian=big -j $((lzh_header_at + 4 + 2 + 1 + 1 + 12 + 1)) -N4 "$tmp_dir/lzh-text.cpt" | tr -d ' ')
printf '\xff' | dd of="$tmp_dir/lzh-text.cpt" bs=1 seek="$lzh_fork_at" conv=notrunc status=none
lzh_rc=0
"./zig-out/bin/compact-pro" verify "$tmp_dir/lzh-text.cpt" >/dev/null 2>"$tmp_dir/lzh-verify.err" || lzh_rc=$?
[[ "$lzh_rc" == 1 ]]
[[ "$(head -1 "$tmp_dir/lzh-verify.err")" == "error: verify failed: invalid lzh codebook (archive offset $((lzh_fork_at + 1)))" ]]

# Metadata trailer v2 carries a CRC-32 of its payload. Damage there makes
# verify fail; expand warns, skips metadata restore and still extracts data.
cp "$tmp_dir/a.cpt" "$tmp_dir/trailer-crc.cpt"
tc_size=$(stat -c %s "$tmp_dir/trailer-crc.cpt")
tc_payload=$(od -An -tu4 --endian=little -j $((tc_size - 8)) -N4 "$tmp_dir/trailer-crc.cpt" | tr -d ' ')
tc_payload_at=$((tc_size - 16 - 4 - tc_payload))
tc_byte="$(xxd -p -l 1 -s "$tc_payload_at" "$tmp_dir/trailer-crc.cpt")"
printf "$(printf '\\x%02x' $(( 0x$tc_byte ^ 0x01 )))" | dd of="$tmp_dir/trailer-crc.cpt" bs=1 seek="$tc_payload_at" conv=notrunc status=none
tc_verify_rc=0
"./zig-out/bin/compact-pro" verify "$tmp_dir/trailer-crc.cpt" >/dev/null 2>"$tmp_dir/trailer-crc-verify.err" || tc_verify_rc=$?
[[ "$tc_verify_rc" == 1 ]]
[[ "$(head -1 "$tmp_dir/trailer-crc-verify.err")" == "error: verify failed: metadata trailer crc mismatch" ]]
mkdir -p "$tmp_dir/out-trailer-crc"
"./zig-out/bin/compact-pro" expand --no-progress "$tmp_dir/trailer-crc.cpt" -d "$tmp_dir/out-trailer-crc" >/dev/null 2>"$tmp_dir/trailer-crc-expand.err"
[[ "$(grep -c '^warning: metadata trailer crc mismatch; metadata restore skipped$' "$tmp_dir/trailer-crc-expand.err")" == 1 ]]
cmp "$tmp_dir/input.txt" "$tmp_dir/out-trailer-crc/input.txt"

# Version 1 trailers (no CRC) written by earlier releases stay readable.
v1_size=$(stat -c %s "$tmp_dir/a.cpt")
head -c $((v1_size - 16 - 4)) "$tmp_dir/a.cpt" >"$tmp_dir/a-v1.cpt"
tail -c 16 "$tmp_dir/a.cpt" | head -c 12 >>"$tmp_dir/a-v1.cpt"
printf '\x01\x00\x00\x00' >>"$tmp_dir/a-v1.cpt"
[[ "$("./zig-out/bin/compact-pro" verify "$tmp_dir/a-v1.cpt")" == "$verify_out" ]]
mkdir -p "$tmp_dir/out-a-v1"
"./zig-out/bin/compact-pro" expand --no-progress "$tmp_dir/a-v1.cpt" -d "$tmp_dir/out-a-v1" >/dev/null 2>"$tmp_dir/a-v1-expand.err"
cmp "$tmp_dir/input.txt" "$tmp_dir/out-a-v1/input.txt"
[[ "$(stat --printf='%a' "$tmp_dir/out-a-v1/input.txt")" == "$mode_src" ]]

# Independent oracle for the stored trailer CRC: gzip's trailer begins with
# the standard CRC-32 (little-endian) of its input.
g_size=$(stat -c %s "$tmp_dir/a.cpt")
g_payload=$(od -An -tu4 --endian=little -j $((g_size - 8)) -N4 "$tmp_dir/a.cpt" | tr -d ' ')
dd if="$tmp_dir/a.cpt" of="$tmp_dir/a-payload.bin" bs=1 skip=$((g_size - 16 - 4 - g_payload)) count="$g_payload" status=none
stored_crc="$(xxd -p -l 4 -s $((g_size - 16 - 4)) "$tmp_dir/a.cpt")"
gzip_crc="$(gzip -c "$tmp_dir/a-payload.bin" | tail -c 8 | head -c 4 | xxd -p)"
[[ "$stored_crc" == "$gzip_crc" ]]
