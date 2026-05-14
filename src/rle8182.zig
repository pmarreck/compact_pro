const std = @import("std");

pub const Error = error{
	UnexpectedEndOfStream,
	InvalidRunLengthOne,
	OutputLengthMismatch,
} || std.mem.Allocator.Error;

pub const EncodeProgressFn = *const fn (?*anyopaque, usize, usize) void;

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

pub fn encodeWithProgress(
	allocator: std.mem.Allocator,
	raw: []const u8,
	progress_cb: ?EncodeProgressFn,
	progress_ctx: ?*anyopaque,
) ![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, raw.len + raw.len / 2 + 8);

	if (progress_cb) |cb| cb(progress_ctx, 0, raw.len);
	var last_report: usize = 0;
	const report_step: usize = 256 * 1024;
	var i: usize = 0;
	while (i < raw.len) {
		if (raw[i] != 0x81) {
			const literal_start = i;
			while (i < raw.len and raw[i] != 0x81) {
				if (i + 4 < raw.len and
					raw[i] == raw[i + 1] and
					raw[i] == raw[i + 2] and
					raw[i] == raw[i + 3] and
					raw[i] == raw[i + 4]) break;
				i += 1;
			}

			if (i > literal_start) {
				try out.appendSlice(allocator, raw[literal_start..i]);
				continue;
			}

			const run_byte = raw[i];
			const run_len = countByteRun(raw, i);
			const remaining = run_len - 1;
			const chunk_count = if (remaining == 0) @as(usize, 0) else (remaining + 253) / 254;
			const emit_len = 1 + chunk_count * 3;
			var emit = try out.addManyAsSlice(allocator, emit_len);
			emit[0] = run_byte;
			var pos: usize = 1;
			var rem = remaining;
			while (rem > 0) {
				const additional: usize = @min(rem, 254);
				emit[pos] = 0x81;
				emit[pos + 1] = 0x82;
				emit[pos + 2] = @intCast(additional + 1);
				pos += 3;
				rem -= additional;
			}
			i += run_len;
			if (progress_cb != null and (i == raw.len or i - last_report >= report_step)) {
				progress_cb.?(progress_ctx, i, raw.len);
				last_report = i;
			}
			continue;
		}

		const run_81 = countByteRun(raw, i);

		if (i + run_81 == raw.len) {
			const emit = try out.addManyAsSlice(allocator, run_81 + 1);
			@memset(emit, 0x81);
			i += run_81;
			continue;
		}

		const next = raw[i + run_81];
		const emit_len = run_81 + 1 + if (next == 0x82) @as(usize, 1) else @as(usize, 0);
		const emit = try out.addManyAsSlice(allocator, emit_len);
		@memset(emit[0..run_81], 0x81);
		emit[run_81] = next;
		if (next == 0x82) emit[run_81 + 1] = 0x00;
		i += run_81 + 1;
		if (progress_cb != null and (i == raw.len or i - last_report >= report_step)) {
			progress_cb.?(progress_ctx, i, raw.len);
			last_report = i;
		}
	}

	if (progress_cb != null and last_report != raw.len) progress_cb.?(progress_ctx, raw.len, raw.len);
	return try out.toOwnedSlice(allocator);
}

pub fn encode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
	return try encodeWithProgress(allocator, raw, null, null);
}

fn countByteRun(raw: []const u8, start: usize) usize {
	const b = raw[start];
	var idx = start + 1;
	const vec_len = comptime std.simd.suggestVectorLength(u8) orelse 16;
	const Vec = @Vector(vec_len, u8);
	const pattern: Vec = @splat(b);

	while (idx + vec_len <= raw.len) {
		const ptr: *align(1) const Vec = @ptrCast(raw.ptr + idx);
		const chunk = ptr.*;
		if (!@reduce(.And, chunk == pattern)) break;
		idx += vec_len;
	}
	while (idx < raw.len and raw[idx] == b) : (idx += 1) {}
	return idx - start;
}
