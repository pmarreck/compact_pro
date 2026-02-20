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

test "jamcrc deterministic" {
	try std.testing.expectEqual(@as(u32, 0x66CDA069), jamcrc("abc"));
}
