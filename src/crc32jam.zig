const std = @import("std");

pub const initial: u32 = 0xFFFF_FFFF;
const poly: u32 = 0xEDB8_8320;

/// Slice-by-16 tables for reflected CRC-32 (poly 0xEDB88320): tables[0] is the
/// classic byte table; tables[k][i] advances tables[k-1][i] by one more zero
/// byte, so 16 input bytes fold in with 16 independent lookups per step.
const tables: [16][256]u32 = blk: {
	@setEvalBranchQuota(100_000);
	var t: [16][256]u32 = undefined;
	for (0..256) |i| {
		var c: u32 = @intCast(i);
		for (0..8) |_| c = if ((c & 1) == 1) (c >> 1) ^ poly else c >> 1;
		t[0][i] = c;
	}
	for (1..16) |k| {
		for (0..256) |i| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xFF];
	}
	break :blk t;
};

/// Continues a JAMCRC/CRC-32 state over `data` using slice-by-16 table lookups
/// (portable, no SIMD or carry-less multiply needed), with a byte-at-a-time tail.
pub fn update(start: u32, data: []const u8) u32 {
	var crc = start;
	var i: usize = 0;
	while (i + 16 <= data.len) : (i += 16) {
		const p = data[i..][0..16];
		const w = crc ^ std.mem.readInt(u32, p[0..4], .little);
		crc = tables[15][w & 0xFF] ^ tables[14][(w >> 8) & 0xFF] ^
			tables[13][(w >> 16) & 0xFF] ^ tables[12][w >> 24] ^
			tables[11][p[4]] ^ tables[10][p[5]] ^ tables[9][p[6]] ^ tables[8][p[7]] ^
			tables[7][p[8]] ^ tables[6][p[9]] ^ tables[5][p[10]] ^ tables[4][p[11]] ^
			tables[3][p[12]] ^ tables[2][p[13]] ^ tables[1][p[14]] ^ tables[0][p[15]];
	}
	while (i < data.len) : (i += 1) {
		crc = (crc >> 8) ^ tables[0][(crc ^ data[i]) & 0xFF];
	}
	return crc;
}

pub fn jamcrc(data: []const u8) u32 {
	return update(initial, data);
}

pub fn jamcrc2(first: []const u8, second: []const u8) u32 {
	var crc = update(initial, first);
	crc = update(crc, second);
	return crc;
}

test "jamcrc known vectors" {
	// Canonical CRC-32/JAMCRC check value (the published "123456789" vector).
	// JAMCRC = CRC-32/ISO-HDLC with the final XOR removed, i.e. ~CRC32.
	try std.testing.expectEqual(@as(u32, 0x340BC6D9), jamcrc("123456789"));
	try std.testing.expectEqual(@as(u32, 0xCADBBE3D), jamcrc("abc"));
}

test "jamcrc empty input is the initial value" {
	// With no bytes consumed, the result is just the (unfinalized) init constant.
	try std.testing.expectEqual(initial, jamcrc(""));
	try std.testing.expectEqual(initial, jamcrc(&[_]u8{}));
}

test "jamcrc single byte" {
	// One pass of the bit-reflected algorithm over a single zero byte.
	var expected = initial;
	for (0..8) |_| {
		expected = if (expected & 1 == 1) (expected >> 1) ^ poly else expected >> 1;
	}
	try std.testing.expectEqual(expected, jamcrc(&[_]u8{0}));
}

test "jamcrc2 equals jamcrc of concatenation" {
	const a = "compact";
	const b = "_pro";
	const joined = a ++ b;
	try std.testing.expectEqual(jamcrc(joined), jamcrc2(a, b));
	// Splitting at a boundary must not change the result.
	try std.testing.expectEqual(jamcrc("hello world"), jamcrc2("hello", " world"));
}

test "update matches std CRC-32 (independent oracle) across lengths, offsets and splits" {
	// JAMCRC is CRC-32/ISO-HDLC without the final complement, so jamcrc(x) must
	// equal ~std.hash.Crc32.hash(x). Unaligned starts and every length up to 600
	// cover the head/body/tail paths of any multi-byte (sliced) implementation.
	var buf: [4096 + 16]u8 = undefined;
	var prng = std.Random.DefaultPrng.init(0x5EED_C3C3);
	const rand = prng.random();
	rand.bytes(&buf);
	for (0..16) |offset| {
		for (0..600) |len| {
			const data = buf[offset..][0..len];
			try std.testing.expectEqual(~std.hash.Crc32.hash(data), jamcrc(data));
		}
	}
	for (0..2000) |_| {
		const len = rand.uintLessThan(usize, 4096);
		const split = rand.uintLessThan(usize, len + 1);
		const data = buf[0..len];
		const whole = ~std.hash.Crc32.hash(data);
		try std.testing.expectEqual(whole, update(update(initial, data[0..split]), data[split..]));
	}
}
