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
	var out = try allocator.alloc(u8, expected_len);
	errdefer allocator.free(out);

	var i: usize = 0;
	var out_len: usize = 0;
	var saved: u8 = 0;
	var repeat: usize = 0;
	var half_escaped = false;

	while (out_len < expected_len) {
		if (repeat > 0) {
			const fill_len = @min(repeat, expected_len - out_len);
			@memset(out[out_len .. out_len + fill_len], saved);
			out_len += fill_len;
			repeat -= fill_len;
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
			out[out_len] = b0;
			out_len += 1;
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
				out[out_len] = 0x81;
				out_len += 1;
				saved = 0x82;
				repeat = 1;
			} else if (n >= 0x02) {
				out[out_len] = saved;
				out_len += 1;
				repeat = @as(usize, n) - 2;
			} else {
				if (strict) return Error.InvalidRunLengthOne;
			}
			continue;
		}

		if (b1 == 0x81) {
			out[out_len] = 0x81;
			out_len += 1;
			saved = 0x81;
			half_escaped = true;
			continue;
		}

		out[out_len] = 0x81;
		out_len += 1;
		saved = b1;
		repeat = 1;
	}

	if (out_len != expected_len) return Error.OutputLengthMismatch;
	return out;
}

pub fn encode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, raw.len);

	var i: usize = 0;
	while (i < raw.len) {
		const b = raw[i];
		if (b != 0x81) {
			var run_len: usize = 1;
			while (i + run_len < raw.len and raw[i + run_len] == b) : (run_len += 1) {}

			if (run_len >= 5) {
				try out.append(allocator, b);
				var remaining = run_len - 1;
				while (remaining > 0) {
					const additional: usize = @min(remaining, 254);
					try out.appendSlice(allocator, &[_]u8{ 0x81, 0x82, @intCast(additional + 1) });
					remaining -= additional;
				}
			} else {
				for (0..run_len) |_| {
					try out.append(allocator, b);
				}
			}
			i += run_len;
			continue;
		}

		var run_81: usize = 1;
		while (i + run_81 < raw.len and raw[i + run_81] == 0x81) : (run_81 += 1) {}

		if (i + run_81 == raw.len) {
			for (0..run_81 + 1) |_| try out.append(allocator, 0x81);
			i += run_81;
			continue;
		}

		for (0..run_81) |_| try out.append(allocator, 0x81);
		const next = raw[i + run_81];
		try out.append(allocator, next);
		if (next == 0x82) try out.append(allocator, 0x00);
		i += run_81 + 1;
	}

	return try out.toOwnedSlice(allocator);
}
