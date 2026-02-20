const std = @import("std");

pub const Error = error{
	UnexpectedEndOfStream,
	InvalidRunLengthOne,
	OutputLengthMismatch,
} || std.mem.Allocator.Error;

pub fn decode(
	allocator: std.mem.Allocator,
	input: []const u8,
	expected_len: usize,
	strict: bool,
) Error![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, expected_len);

	var i: usize = 0;
	var saved: u8 = 0;
	var repeat: usize = 0;
	var half_escaped = false;

	while (out.items.len < expected_len) {
		if (repeat > 0) {
			try out.append(allocator, saved);
			repeat -= 1;
			continue;
		}

		const b0: u8 = blk: {
			if (half_escaped) {
				half_escaped = false;
				break :blk 0x81;
			}
			if (i >= input.len) return Error.UnexpectedEndOfStream;
			defer i += 1;
			break :blk input[i];
		};

		if (b0 != 0x81) {
			saved = b0;
			try out.append(allocator, b0);
			continue;
		}

		if (i >= input.len) return Error.UnexpectedEndOfStream;
		const b1 = input[i];
		i += 1;

		if (b1 == 0x82) {
			if (i >= input.len) return Error.UnexpectedEndOfStream;
			const n = input[i];
			i += 1;
			if (n == 0x00) {
				try out.append(allocator, 0x81);
				saved = 0x82;
				repeat = 1;
			} else if (n >= 0x02) {
				try out.append(allocator, saved);
				repeat = @as(usize, n) - 2;
			} else {
				if (strict) return Error.InvalidRunLengthOne;
			}
			continue;
		}

		if (b1 == 0x81) {
			try out.append(allocator, 0x81);
			saved = 0x81;
			half_escaped = true;
			continue;
		}

		try out.append(allocator, 0x81);
		saved = b1;
		repeat = 1;
	}

	if (out.items.len != expected_len) return Error.OutputLengthMismatch;
	return try out.toOwnedSlice(allocator);
}

pub fn encode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);

	var i: usize = 0;
	while (i < raw.len) {
		const b = raw[i];
		if (b != 0x81) {
			try out.append(allocator, b);
			i += 1;
			continue;
		}

		if (i + 1 >= raw.len) {
			try out.appendSlice(allocator, &[_]u8{ 0x81, 0x81 });
			i += 1;
			continue;
		}

		const b1 = raw[i + 1];
		if (b1 == 0x81) {
			if (i + 2 < raw.len) {
				const b2 = raw[i + 2];
				if (b2 == 0x82) {
					try out.appendSlice(allocator, &[_]u8{ 0x81, 0x81, 0x82, 0x00 });
				} else {
					try out.appendSlice(allocator, &[_]u8{ 0x81, 0x81, b2 });
				}
				i += 3;
			} else {
				try out.appendSlice(allocator, &[_]u8{ 0x81, 0x81, 0x81 });
				i += 2;
			}
			continue;
		}

		if (b1 == 0x82) {
			try out.appendSlice(allocator, &[_]u8{ 0x81, 0x82, 0x00 });
		} else {
			try out.appendSlice(allocator, &[_]u8{ 0x81, b1 });
		}
		i += 2;
	}

	return try out.toOwnedSlice(allocator);
}
