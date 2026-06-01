const std = @import("std");

pub const initial: u32 = 0xFFFF_FFFF;
const poly: u32 = 0xEDB8_8320;

pub fn update(start: u32, data: []const u8) u32 {
	var crc = start;
	for (data) |b| {
		crc ^= @as(u32, b);
		for (0..8) |_| {
			if ((crc & 1) == 1) {
				crc = (crc >> 1) ^ poly;
			} else {
				crc >>= 1;
			}
		}
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
