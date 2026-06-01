const std = @import("std");

pub const Error = error{
	Truncated,
	InvalidCodebook,
	InvalidHuffmanCode,
	OutputLengthMismatch,
	InvalidMatchOffset,
} || std.mem.Allocator.Error;

pub const EncodeProgressFn = *const fn (?*anyopaque, usize, usize) void;

const window_size: usize = 8192;
const block_size: usize = 0x1FFF0;
const esc1: u8 = 0x81;
const esc2: u8 = 0x82;

const hash_bits: usize = 15;
const hash_size: usize = 1 << hash_bits;
const hash_mask: usize = hash_size - 1;
const chain_limit: usize = 64;
const min_match_len: usize = 3;
const max_match_len: usize = 63;
const progress_report_step: usize = 256 * 1024;
const token_segment_size: usize = 16 * 1024 * 1024;

/// Minimal spinlock for short progress-reporter critical sections.
/// Replaces `std.Thread.Mutex` (removed in Zig 0.16) without requiring an
/// `io: std.Io` parameter to be threaded through every worker entry point.
const SpinMutex = struct {
	state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

	fn lock(self: *SpinMutex) void {
		while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
			std.atomic.spinLoopHint();
		}
	}

	fn unlock(self: *SpinMutex) void {
		self.state.store(0, .release);
	}
};

const BitReader = struct {
	bytes: []const u8,
	byte_index: usize = 0,
	bit_index: u8 = 0,

	fn readByteAligned(self: *BitReader) Error!u8 {
		if (self.bit_index != 0) return Error.InvalidCodebook;
		if (self.byte_index >= self.bytes.len) return Error.Truncated;
		const b = self.bytes[self.byte_index];
		self.byte_index += 1;
		return b;
	}

	fn readBit(self: *BitReader) Error!u1 {
		if (self.byte_index >= self.bytes.len) return Error.Truncated;
		const b = self.bytes[self.byte_index];
		const shift: u3 = @intCast(7 - self.bit_index);
		const bit: u1 = @intCast((b >> shift) & 1);
		self.bit_index += 1;
		if (self.bit_index == 8) {
			self.bit_index = 0;
			self.byte_index += 1;
		}
		return bit;
	}

	fn readBits(self: *BitReader, n: usize) Error!u32 {
		var out: u32 = 0;
		for (0..n) |_| {
			out = (out << 1) | @as(u32, try self.readBit());
		}
		return out;
	}

	fn alignToByte(self: *BitReader) void {
		if (self.bit_index != 0) {
			self.bit_index = 0;
			self.byte_index += 1;
		}
	}

	fn byteOffset(self: *const BitReader) usize {
		return self.byte_index;
	}

	fn skipBytes(self: *BitReader, count: usize) Error!void {
		if (self.bit_index != 0) return Error.InvalidCodebook;
		if (self.byte_index + count > self.bytes.len) return Error.Truncated;
		self.byte_index += count;
	}
};

fn CodebookDecoder(comptime symbol_count: usize) type {
	return struct {
		const Self = @This();
		const slack: usize = 6;
		const max_nodes = symbol_count * 2 + slack;
		const TreeEntry = struct {
			value: i32 = 0,
			bit_len: usize = 0,
		};
		const TreeNode = struct {
			is_leaf: bool = false,
			symbol: i32 = -1,
			left: i32 = -1,
			right: i32 = -1,
		};

		nodes: [max_nodes]TreeNode = [_]TreeNode{.{}} ** max_nodes,

		fn reset(self: *Self) void {
			@memset(self.nodes[0..], .{});
		}

		fn initFromLengths(self: *Self, lengths: []const u8) Error!void {
			if (lengths.len != symbol_count) return Error.InvalidCodebook;
			self.reset();

			var counts = [_]i32{0} ** 32;
			var entries: [symbol_count]TreeEntry = undefined;
			var entry_count: usize = 0;
			var max_len: usize = 0;

			for (lengths, 0..) |bit_len, symbol| {
				if (bit_len == 0) continue;
				if (bit_len > 15) return Error.InvalidCodebook;
				if (bit_len > max_len) max_len = bit_len;
				counts[bit_len] += 1;
				entries[entry_count] = .{
					.value = @intCast(symbol),
					.bit_len = @intCast(bit_len),
				};
				entry_count += 1;
			}
			if (entry_count == 0) return Error.InvalidCodebook;

			var missing: i32 = 0;
			for (0..max_len + 1) |len| {
				missing = (missing << 1) + counts[len];
			}
			missing = (@as(i32, 1) << @intCast(max_len)) - missing;
			if (missing < 0) return Error.InvalidCodebook;

			for (0..@as(usize, @intCast(missing))) |_| {
				if (entry_count >= symbol_count) return Error.InvalidCodebook;
				entries[entry_count] = .{
					.value = @intCast(symbol_count),
					.bit_len = max_len,
				};
				entry_count += 1;
			}

			std.mem.sort(TreeEntry, entries[0..entry_count], {}, struct {
				fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
					if (a.bit_len != b.bit_len) return a.bit_len < b.bit_len;
					return a.value < b.value;
				}
			}.lessThan);

			var i: i32 = @intCast(entry_count - 1);
			var level_start: i32 = @intCast(max_nodes - 1);
			var next: i32 = level_start;
			var code_len: i32 = @intCast(max_len);

			while (code_len >= 1) : (code_len -= 1) {
				while (i >= 0 and entries[@intCast(i)].bit_len == @as(usize, @intCast(code_len))) : (i -= 1) {
					self.nodes[@intCast(next)].symbol = entries[@intCast(i)].value;
					self.nodes[@intCast(next)].is_leaf = true;
					next -= 1;
				}

				const parents = next;
				if (code_len > 1) {
					var j = level_start;
					while (j >= parents + 2) : (j -= 2) {
						self.nodes[@intCast(next)].right = j;
						self.nodes[@intCast(next)].left = j - 1;
						self.nodes[@intCast(next)].is_leaf = false;
						next -= 1;
					}
				}
				level_start = parents;
			}

			if (next + 2 >= @as(i32, @intCast(max_nodes)) or next + 1 < 0) return Error.InvalidCodebook;
			self.nodes[0].right = next + 2;
			self.nodes[0].left = next + 1;
			self.nodes[0].is_leaf = false;
		}

		fn decodeSymbol(self: *const Self, bits: *BitReader) Error!u16 {
			var node_idx: usize = 0;
			while (true) {
				const node = self.nodes[node_idx];
				if (node.is_leaf) {
					if (node.symbol < 0 or node.symbol >= symbol_count) return Error.InvalidHuffmanCode;
					return @intCast(node.symbol);
				}
				const bit = try bits.readBit();
				const next_idx = if (bit == 0) node.left else node.right;
				if (next_idx < 0 or next_idx >= max_nodes) return Error.InvalidHuffmanCode;
				node_idx = @intCast(next_idx);
			}
		}
	};
}

const RleState = enum {
	none,
	esc1_seen,
	esc2_seen,
};

const Decoder = struct {
	bits: BitReader,
	output: []u8,
	out_index: usize = 0,
	rle_state: RleState = .none,
	save_char: u8 = 0,
	lz_ptr: usize = 0,
	lz_window: [window_size]u8 = [_]u8{0} ** window_size,
	literal_code: CodebookDecoder(256) = .{},
	length_code: CodebookDecoder(64) = .{},
	offset_code: CodebookDecoder(128) = .{},
	has_previous_block: bool = false,
	block_start: usize = 0,

	fn emit(self: *Decoder, b: u8) Error!void {
		if (self.out_index >= self.output.len) return Error.OutputLengthMismatch;
		self.output[self.out_index] = b;
		self.out_index += 1;
	}

	fn outch(self: *Decoder, ch: u8) Error!void {
		self.lz_window[self.lz_ptr & (window_size - 1)] = ch;
		self.lz_ptr += 1;

		switch (self.rle_state) {
			.none => {
				if (ch == esc1 and (self.output.len - self.out_index) != 1) {
					self.rle_state = .esc1_seen;
					return;
				}
				self.save_char = ch;
				try self.emit(ch);
			},
			.esc1_seen => {
				if (ch == esc2) {
					self.rle_state = .esc2_seen;
					return;
				}
				self.save_char = esc1;
				try self.emit(esc1);
				if (self.out_index == self.output.len) return;

				if (ch == esc1 and (self.output.len - self.out_index) != 1) {
					return;
				}

				self.rle_state = .none;
				self.save_char = ch;
				try self.emit(ch);
			},
			.esc2_seen => {
				self.rle_state = .none;
				if (ch != 0) {
					var n = ch;
					while (n > 1) : (n -= 1) {
						try self.emit(self.save_char);
						if (self.out_index == self.output.len) return;
					}
				} else {
					try self.emit(esc1);
					if (self.out_index == self.output.len) return;
					self.save_char = esc2;
					try self.emit(self.save_char);
				}
			},
		}
	}

	fn readCodebook(
		self: *Decoder,
		comptime symbol_count: usize,
		codebook: *CodebookDecoder(symbol_count),
	) Error!void {
		const num_len_bytes = try self.bits.readByteAligned();
		if (@as(usize, num_len_bytes) * 2 > symbol_count) return Error.InvalidCodebook;

		var lengths = [_]u8{0} ** symbol_count;
		for (0..num_len_bytes) |i| {
			const b = try self.bits.readByteAligned();
			lengths[i * 2] = b >> 4;
			lengths[i * 2 + 1] = b & 0x0F;
		}
		try codebook.initFromLengths(lengths[0..]);
	}

	fn decodeAll(self: *Decoder) Error!void {
		self.lz_window[window_size - 1] = 0;
		self.lz_window[window_size - 2] = 0;
		self.lz_window[window_size - 3] = 0;
		self.lz_ptr = 0;

		while (self.out_index < self.output.len) {
			if (self.has_previous_block) {
				self.bits.alignToByte();
				const consumed = self.bits.byteOffset() - self.block_start;
				const skip = if ((consumed & 1) == 1) @as(usize, 3) else @as(usize, 2);
				try self.bits.skipBytes(skip);
			}

			try self.readCodebook(256, &self.literal_code);
			try self.readCodebook(64, &self.length_code);
			try self.readCodebook(128, &self.offset_code);

			self.has_previous_block = true;
			self.block_start = self.bits.byteOffset();

			var block_count: usize = 0;
			while (block_count < block_size and self.out_index < self.output.len) {
				const is_literal = (try self.bits.readBit()) == 1;
				if (is_literal) {
					const sym = try self.literal_code.decodeSymbol(&self.bits);
					try self.outch(@intCast(sym));
					block_count += 2;
				} else {
					const len_sym = try self.length_code.decodeSymbol(&self.bits);
					const off_hi = try self.offset_code.decodeSymbol(&self.bits);
					const off_lo = try self.bits.readBits(6);
					const lz_offset: usize = (@as(usize, off_hi) << 6) | @as(usize, off_lo);

					var remaining: usize = @intCast(len_sym);
					var back_ptr: isize = @as(isize, @intCast(self.lz_ptr)) - @as(isize, @intCast(lz_offset));
					while (remaining > 0 and self.out_index < self.output.len) : (remaining -= 1) {
						const idx: usize = @intCast(@mod(back_ptr, @as(isize, window_size)));
						const b = self.lz_window[idx];
						back_ptr += 1;
						try self.outch(b);
					}
					block_count += 3;
				}
			}
		}
	}
};

const Token = union(enum) {
	literal: u8,
	match: struct {
		len: u8,
		offset: u16,
	},
};

const BlockTokens = struct {
	tokens: []Token,
	input_len: usize,
	has_more: bool,
};

const SegmentTokens = struct {
	tokens: []Token,
	input_len: usize,
};

const EncodeProgressReporter = struct {
	callback: ?EncodeProgressFn,
	ctx: ?*anyopaque,
	total_work: usize,
	base_work: usize,
	done_input: usize = 0,
	mutex: SpinMutex = .{},

	fn blockDone(self: *EncodeProgressReporter, block_input_len: usize) void {
		if (self.callback == null) return;
		self.mutex.lock();
		defer self.mutex.unlock();

		const next_done = std.math.add(usize, self.done_input, block_input_len) catch std.math.maxInt(usize);
		const max_done = if (self.total_work > self.base_work) self.total_work - self.base_work else 0;
		self.done_input = @min(next_done, max_done);
		const done = @min(self.base_work + self.done_input, self.total_work);
		self.callback.?(self.ctx, done, self.total_work);
	}

	fn complete(self: *EncodeProgressReporter) void {
		if (self.callback) |cb| cb(self.ctx, self.total_work, self.total_work);
	}
};

const TokenizeProgressReporter = struct {
	callback: ?EncodeProgressFn,
	ctx: ?*anyopaque,
	total_work: usize,
	phase_limit: usize,
	done_input: usize = 0,
	mutex: SpinMutex = .{},

	fn add(self: *TokenizeProgressReporter, delta: usize) void {
		if (self.callback == null or delta == 0) return;
		self.mutex.lock();
		defer self.mutex.unlock();

		const next_done = std.math.add(usize, self.done_input, delta) catch std.math.maxInt(usize);
		self.done_input = @min(next_done, self.phase_limit);
		self.callback.?(self.ctx, self.done_input, self.total_work);
	}

	fn complete(self: *TokenizeProgressReporter) void {
		if (self.callback == null) return;
		self.mutex.lock();
		self.done_input = self.phase_limit;
		self.mutex.unlock();
		self.callback.?(self.ctx, self.phase_limit, self.total_work);
	}
};

const TokenizeSegment = struct {
	start: usize,
	end: usize,
	prefix_start: usize,
};

const TokenizeWorkerCtx = struct {
	input: []const u8,
	segments: []const TokenizeSegment,
	results: []?SegmentTokens,
	worker_id: usize,
	step: usize,
	progress: ?*TokenizeProgressReporter = null,
	arena: std.heap.ArenaAllocator,
	err: ?Error = null,
};

const WorkerCtx = struct {
	blocks: []const BlockTokens,
	results: []?[]u8,
	worker_id: usize,
	step: usize,
	progress: ?*EncodeProgressReporter = null,
	arena: std.heap.ArenaAllocator,
	err: ?Error = null,
};

const BitWriter = struct {
	allocator: std.mem.Allocator,
	out: *std.ArrayListUnmanaged(u8),
	cur: u8 = 0,
	bits: u8 = 0,

	fn writeBit(self: *BitWriter, bit: u1) !void {
		self.cur |= @as(u8, bit) << @intCast(7 - self.bits);
		self.bits += 1;
		if (self.bits == 8) {
			try self.out.append(self.allocator, self.cur);
			self.cur = 0;
			self.bits = 0;
		}
	}

	fn writeBits(self: *BitWriter, code: u32, bit_len: u8) !void {
		var i: i32 = @intCast(bit_len);
		while (i > 0) {
			i -= 1;
			const bit: u1 = @intCast((code >> @intCast(i)) & 1);
			try self.writeBit(bit);
		}
	}

	fn alignToByte(self: *BitWriter) !void {
		if (self.bits == 0) return;
		try self.out.append(self.allocator, self.cur);
		self.cur = 0;
		self.bits = 0;
	}
};

fn hash3(data: []const u8, pos: usize) usize {
	const a = @as(usize, data[pos]);
	const b = @as(usize, data[pos + 1]);
	const c = @as(usize, data[pos + 2]);
	return ((a * 251 + b * 67 + c) & hash_mask);
}

fn insertMatcherPos(data: []const u8, pos: usize, head: []i32, prev: []i32) void {
	if (pos + 2 >= data.len) return;
	const h = hash3(data, pos);
	const slot = pos & (window_size - 1);
	prev[slot] = head[h];
	head[h] = @intCast(pos);
}

fn findBestMatch(data: []const u8, pos: usize, head: []i32, prev: []i32) struct { len: usize, offset: usize } {
	if (pos + min_match_len > data.len) return .{ .len = 0, .offset = 0 };

	const h = hash3(data, pos);
	var best_len: usize = 0;
	var best_offset: usize = 0;
	var depth: usize = 0;
	var candidate = head[h];
	const max_end = @min(data.len, pos + max_match_len);
	const max_len_here = max_end - pos;

	while (candidate >= 0 and depth < chain_limit) : (depth += 1) {
		const cand: usize = @intCast(candidate);
		if (cand >= pos) break;
		const offset = pos - cand;
		if (offset == 0 or offset >= window_size) {
			candidate = prev[cand & (window_size - 1)];
			continue;
		}
		if (best_len == max_len_here) break;
		if (data[cand] != data[pos]) {
			candidate = prev[cand & (window_size - 1)];
			continue;
		}
		if (best_len > 0 and best_len < max_len_here and data[cand + best_len] != data[pos + best_len]) {
			candidate = prev[cand & (window_size - 1)];
			continue;
		}

		var len: usize = 0;
		while (pos + len < max_end and data[cand + len] == data[pos + len]) : (len += 1) {}
		if (len > best_len) {
			best_len = len;
			best_offset = offset;
			if (best_len == max_match_len) break;
		}
		candidate = prev[cand & (window_size - 1)];
	}

	return .{ .len = best_len, .offset = best_offset };
}

fn heapLess(node_freq: []const u64, a: i32, b: i32) bool {
	const fa = node_freq[@intCast(a)];
	const fb = node_freq[@intCast(b)];
	if (fa != fb) return fa < fb;
	return a < b;
}

fn heapPush(node_freq: []const u64, heap: []i32, heap_len: *usize, idx: i32) void {
	var i = heap_len.*;
	heap_len.* += 1;
	heap[i] = idx;
	while (i > 0) {
		const p = (i - 1) / 2;
		if (!heapLess(node_freq, heap[i], heap[p])) break;
		const tmp = heap[i];
		heap[i] = heap[p];
		heap[p] = tmp;
		i = p;
	}
}

fn heapPop(node_freq: []const u64, heap: []i32, heap_len: *usize) i32 {
	const out = heap[0];
	heap_len.* -= 1;
	if (heap_len.* == 0) return out;
	heap[0] = heap[heap_len.*];

	var i: usize = 0;
	while (true) {
		const left = i * 2 + 1;
		const right = left + 1;
		if (left >= heap_len.*) break;
		var smallest = left;
		if (right < heap_len.* and heapLess(node_freq, heap[right], heap[left])) smallest = right;
		if (!heapLess(node_freq, heap[smallest], heap[i])) break;
		const tmp = heap[i];
		heap[i] = heap[smallest];
		heap[smallest] = tmp;
		i = smallest;
	}

	return out;
}

fn buildCodeLengths(comptime N: usize, freqs: [N]u32) [N]u8 {
	var lengths = [_]u8{0} ** N;

	var used_syms = [_]u16{0} ** N;
	var used_count: usize = 0;
	for (freqs, 0..) |f, sym| {
		if (f == 0) continue;
		used_syms[used_count] = @intCast(sym);
		used_count += 1;
	}
	if (used_count == 0) return lengths;
	if (used_count == 1) {
		lengths[used_syms[0]] = 1;
		return lengths;
	}

	var node_freq = [_]u64{0} ** (N * 2);
	var left = [_]i32{-1} ** (N * 2);
	var right = [_]i32{-1} ** (N * 2);
	var leaf_sym = [_]i32{-1} ** (N * 2);
	var node_count: usize = 0;

	var heap = [_]i32{0} ** (N * 2);
	var heap_len: usize = 0;

	for (freqs, 0..) |f, sym| {
		if (f == 0) continue;
		node_freq[node_count] = f;
		leaf_sym[node_count] = @intCast(sym);
		heapPush(&node_freq, &heap, &heap_len, @intCast(node_count));
		node_count += 1;
	}

	while (heap_len > 1) {
		const a = heapPop(&node_freq, &heap, &heap_len);
		const b = heapPop(&node_freq, &heap, &heap_len);
		node_freq[node_count] = node_freq[@intCast(a)] + node_freq[@intCast(b)];
		left[node_count] = a;
		right[node_count] = b;
		heapPush(&node_freq, &heap, &heap_len, @intCast(node_count));
		node_count += 1;
	}
	const root = heapPop(&node_freq, &heap, &heap_len);

	var stack_nodes = [_]i32{0} ** (N * 2);
	var stack_depth = [_]u8{0} ** (N * 2);
	var sp: usize = 0;
	stack_nodes[sp] = root;
	stack_depth[sp] = 0;
	sp += 1;

	var too_deep = false;
	while (sp > 0) {
		sp -= 1;
		const n = stack_nodes[sp];
		const d = stack_depth[sp];
		if (left[@intCast(n)] < 0 and right[@intCast(n)] < 0) {
			const sym = leaf_sym[@intCast(n)];
			if (sym >= 0) {
				const depth = if (d == 0) @as(u8, 1) else d;
				if (depth > 15) too_deep = true;
				lengths[@intCast(sym)] = depth;
			}
			continue;
		}
		if (left[@intCast(n)] >= 0) {
			stack_nodes[sp] = left[@intCast(n)];
			stack_depth[sp] = d + 1;
			sp += 1;
		}
		if (right[@intCast(n)] >= 0) {
			stack_nodes[sp] = right[@intCast(n)];
			stack_depth[sp] = d + 1;
			sp += 1;
		}
	}

	if (!too_deep) return lengths;

	@memset(lengths[0..], 0);
	var depth: u8 = 0;
	var cap: usize = 1;
	while (cap < used_count) : (cap <<= 1) depth += 1;
	if (depth == 0) depth = 1;
	if (depth > 15) depth = 15;
	for (used_syms[0..used_count]) |sym| lengths[sym] = depth;
	return lengths;
}

fn buildCanonicalCodes(comptime N: usize, lengths: [N]u8) [N]u32 {
	var codes = [_]u32{0} ** N;
	var bl_count = [_]u32{0} ** 16;
	for (lengths) |len| {
		if (len > 0) bl_count[len] += 1;
	}

	var next_code = [_]u32{0} ** 16;
	var code: u32 = 0;
	var bits: usize = 1;
	while (bits <= 15) : (bits += 1) {
		code = (code + bl_count[bits - 1]) << 1;
		next_code[bits] = code;
	}

	for (lengths, 0..) |len, sym| {
		if (len == 0) continue;
		codes[sym] = next_code[len];
		next_code[len] += 1;
	}
	return codes;
}

fn writeCodebook(
	allocator: std.mem.Allocator,
	out: *std.ArrayListUnmanaged(u8),
	comptime N: usize,
	lengths: [N]u8,
) Error!void {
	var max_idx: ?usize = null;
	for (lengths, 0..) |len, idx| {
		if (len > 0) max_idx = idx;
	}
	if (max_idx == null) return Error.InvalidCodebook;
	const num_len_bytes: usize = (max_idx.? + 2) / 2;
	if (num_len_bytes > 255) return Error.InvalidCodebook;
	try out.append(allocator, @intCast(num_len_bytes));
	for (0..num_len_bytes) |i| {
		const hi = lengths[i * 2];
		const lo = if (i * 2 + 1 < N) lengths[i * 2 + 1] else 0;
		try out.append(allocator, (hi << 4) | (lo & 0x0F));
	}
}

fn encodeBlockTokens(
	allocator: std.mem.Allocator,
	out: *std.ArrayListUnmanaged(u8),
	tokens: []const Token,
	has_more_blocks: bool,
) Error!void {
	var lit_freq = [_]u32{0} ** 256;
	var len_freq = [_]u32{0} ** 64;
	var off_freq = [_]u32{0} ** 128;

	for (tokens) |tok| {
		switch (tok) {
			.literal => |b| lit_freq[b] += 1,
			.match => |m| {
				len_freq[m.len] += 1;
				off_freq[m.offset >> 6] += 1;
			},
		}
	}

	if (std.mem.indexOfNone(u32, &lit_freq, &[_]u32{0}) == null) lit_freq[0] = 1;
	if (std.mem.indexOfNone(u32, &len_freq, &[_]u32{0}) == null) len_freq[0] = 1;
	if (std.mem.indexOfNone(u32, &off_freq, &[_]u32{0}) == null) off_freq[0] = 1;

	const lit_lens = buildCodeLengths(256, lit_freq);
	const len_lens = buildCodeLengths(64, len_freq);
	const off_lens = buildCodeLengths(128, off_freq);
	const lit_codes = buildCanonicalCodes(256, lit_lens);
	const len_codes = buildCanonicalCodes(64, len_lens);
	const off_codes = buildCanonicalCodes(128, off_lens);

	try writeCodebook(allocator, out, 256, lit_lens);
	try writeCodebook(allocator, out, 64, len_lens);
	try writeCodebook(allocator, out, 128, off_lens);

	const block_start = out.items.len;
	var bits = BitWriter{
		.allocator = allocator,
		.out = out,
	};

	for (tokens) |tok| {
		switch (tok) {
			.literal => |b| {
				try bits.writeBit(1);
				try bits.writeBits(lit_codes[b], lit_lens[b]);
			},
			.match => |m| {
				if (m.offset == 0 or m.offset >= window_size) return Error.InvalidMatchOffset;
				try bits.writeBit(0);
				try bits.writeBits(len_codes[m.len], len_lens[m.len]);
				const off_hi: u8 = @intCast(m.offset >> 6);
				const off_lo: u8 = @intCast(m.offset & 0x3F);
				try bits.writeBits(off_codes[off_hi], off_lens[off_hi]);
				try bits.writeBits(off_lo, 6);
			},
		}
	}
	try bits.alignToByte();

	if (has_more_blocks) {
		const consumed = out.items.len - block_start;
		const skip = if ((consumed & 1) == 1) @as(usize, 3) else @as(usize, 2);
		try out.appendNTimes(allocator, 0, skip);
	}
}

fn encodeBlockToOwned(
	allocator: std.mem.Allocator,
	tokens: []const Token,
	has_more_blocks: bool,
) Error![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	errdefer out.deinit(allocator);
	try encodeBlockTokens(allocator, &out, tokens, has_more_blocks);
	return try out.toOwnedSlice(allocator);
}

fn collectTokenBlocksForRange(
	allocator: std.mem.Allocator,
	input: []const u8,
	start: usize,
	end: usize,
	prefix_start: usize,
	progress: ?*TokenizeProgressReporter,
) Error!SegmentTokens {
	const head = try allocator.alloc(i32, hash_size);
	defer allocator.free(head);
	@memset(head, -1);

	const prev = try allocator.alloc(i32, window_size);
	defer allocator.free(prev);
	@memset(prev, -1);

	var tokens: std.ArrayListUnmanaged(Token) = .empty;

	var seed = prefix_start;
	while (seed < start) : (seed += 1) {
		insertMatcherPos(input, seed, head, prev);
	}

	var last_report = start;
	var pos = start;
	while (pos < end) {
		const best_match = findBestMatch(input, pos, head, prev);
		const remaining = end - pos;
		const match_len = @min(best_match.len, remaining);
		if (match_len >= min_match_len) {
			try tokens.append(allocator, .{
				.match = .{
					.len = @intCast(match_len),
					.offset = @intCast(best_match.offset),
				},
			});
			for (0..match_len) |k| insertMatcherPos(input, pos + k, head, prev);
			pos += match_len;
		} else {
			try tokens.append(allocator, .{ .literal = input[pos] });
			insertMatcherPos(input, pos, head, prev);
			pos += 1;
		}

		if (progress != null and (pos == end or pos - last_report >= progress_report_step)) {
			progress.?.add(pos - last_report);
			last_report = pos;
		}
	}

	if (progress != null and last_report < end) {
		progress.?.add(end - last_report);
	}

	return .{
		.tokens = try tokens.toOwnedSlice(allocator),
		.input_len = end - start,
	};
}

fn collectTokenBlocksSequentialDirect(
	allocator: std.mem.Allocator,
	input: []const u8,
	progress: ?*TokenizeProgressReporter,
) Error![]BlockTokens {
	var blocks: std.ArrayListUnmanaged(BlockTokens) = .empty;
	errdefer {
		for (blocks.items) |block| allocator.free(block.tokens);
		blocks.deinit(allocator);
	}

	const head = try allocator.alloc(i32, hash_size);
	defer allocator.free(head);
	@memset(head, -1);

	const prev = try allocator.alloc(i32, window_size);
	defer allocator.free(prev);
	@memset(prev, -1);

	var tokens: std.ArrayListUnmanaged(Token) = .empty;
	defer tokens.deinit(allocator);

	var last_report: usize = 0;
	var pos: usize = 0;
	while (pos < input.len) {
		const block_start = pos;
		tokens.clearRetainingCapacity();
		var block_count: usize = 0;

		while (pos < input.len and block_count < block_size) {
			const best_match = findBestMatch(input, pos, head, prev);
			if (best_match.len >= min_match_len) {
				try tokens.append(allocator, .{
					.match = .{
						.len = @intCast(best_match.len),
						.offset = @intCast(best_match.offset),
					},
				});
				for (0..best_match.len) |k| insertMatcherPos(input, pos + k, head, prev);
				pos += best_match.len;
				block_count += 3;
			} else {
				try tokens.append(allocator, .{ .literal = input[pos] });
				insertMatcherPos(input, pos, head, prev);
				pos += 1;
				block_count += 2;
			}
		}

		if (progress != null and (pos == input.len or pos - last_report >= progress_report_step)) {
			progress.?.add(pos - last_report);
			last_report = pos;
		}

		if (tokens.items.len == 0) break;
		const owned = try allocator.alloc(Token, tokens.items.len);
		@memcpy(owned, tokens.items);
		try blocks.append(allocator, .{
			.tokens = owned,
			.input_len = pos - block_start,
			.has_more = false,
		});
	}

	if (progress != null and last_report < input.len) {
		progress.?.add(input.len - last_report);
	}

	for (blocks.items, 0..) |*block, i| {
		block.has_more = i + 1 < blocks.items.len;
	}

	return try blocks.toOwnedSlice(allocator);
}

fn buildTokenSegments(allocator: std.mem.Allocator, input_len: usize) ![]TokenizeSegment {
	if (input_len == 0) return try allocator.alloc(TokenizeSegment, 0);
	const count = (input_len + token_segment_size - 1) / token_segment_size;
	const prefix_len = window_size - 1;
	const segments = try allocator.alloc(TokenizeSegment, count);
	for (segments, 0..) |*segment, idx| {
		const start = idx * token_segment_size;
		const end = @min(start + token_segment_size, input_len);
		segment.* = .{
			.start = start,
			.end = end,
			.prefix_start = if (start > prefix_len) start - prefix_len else 0,
		};
	}
	return segments;
}

fn workerCollectTokenSegments(ctx: *TokenizeWorkerCtx) void {
	const allocator = ctx.arena.allocator();
	var idx = ctx.worker_id;
	while (idx < ctx.segments.len) : (idx += ctx.step) {
		const segment = ctx.segments[idx];
		const blocks = collectTokenBlocksForRange(
			allocator,
			ctx.input,
			segment.start,
			segment.end,
			segment.prefix_start,
			ctx.progress,
		) catch |err| {
			ctx.err = err;
			return;
		};
		ctx.results[idx] = blocks;
	}
}

fn tokenCost(tok: Token) usize {
	return switch (tok) {
		.literal => 2,
		.match => 3,
	};
}

fn tokenInputLen(tok: Token) usize {
	return switch (tok) {
		.literal => 1,
		.match => |m| @as(usize, m.len),
	};
}

fn appendFinalizedBlock(
	allocator: std.mem.Allocator,
	blocks: *std.ArrayListUnmanaged(BlockTokens),
	tokens: *std.ArrayListUnmanaged(Token),
	input_len: usize,
) !void {
	if (tokens.items.len == 0) return;
	const owned = try tokens.toOwnedSlice(allocator);
	try blocks.append(allocator, .{
		.tokens = owned,
		.input_len = input_len,
		.has_more = false,
	});
}

fn collectTokenBlocks(
	allocator: std.mem.Allocator,
	input: []const u8,
	worker_limit: usize,
	progress_cb: ?EncodeProgressFn,
	progress_ctx: ?*anyopaque,
	total_work: usize,
) Error![]BlockTokens {
	const segments = try buildTokenSegments(allocator, input.len);
	defer allocator.free(segments);

	if (segments.len == 0) return try allocator.alloc(BlockTokens, 0);

	var progress = TokenizeProgressReporter{
		.callback = progress_cb,
		.ctx = progress_ctx,
		.total_work = total_work,
		.phase_limit = input.len,
	};
	const progress_ptr: ?*TokenizeProgressReporter = if (progress_cb != null) &progress else null;

	if (segments.len == 1) {
		const blocks = try collectTokenBlocksSequentialDirect(allocator, input, progress_ptr);
		if (progress_ptr) |p| p.complete();
		return blocks;
	}

	const worker_count = chooseWorkerCount(worker_limit, segments.len);
	const results = try allocator.alloc(?SegmentTokens, segments.len);
	defer allocator.free(results);
	@memset(results, null);

	var contexts = try allocator.alloc(TokenizeWorkerCtx, worker_count);
	defer {
		for (contexts) |*ctx| ctx.arena.deinit();
		allocator.free(contexts);
	}

	for (contexts, 0..) |*ctx, worker_id| {
		ctx.* = .{
			.input = input,
			.segments = segments,
			.results = results,
			.worker_id = worker_id,
			.step = worker_count,
			.progress = progress_ptr,
			.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
		};
	}

	var threads = try allocator.alloc(std.Thread, worker_count - 1);
	defer allocator.free(threads);

	var spawned: usize = 0;
	var spawn_failed = false;
	var worker_id: usize = 1;
	while (worker_id < worker_count) : (worker_id += 1) {
		threads[spawned] = std.Thread.spawn(.{}, workerCollectTokenSegments, .{&contexts[worker_id]}) catch {
			spawn_failed = true;
			break;
		};
		spawned += 1;
	}

	workerCollectTokenSegments(&contexts[0]);

	for (threads[0..spawned]) |thread| thread.join();

	if (spawn_failed) {
		var fallback_worker = spawned + 1;
		while (fallback_worker < worker_count) : (fallback_worker += 1) {
			workerCollectTokenSegments(&contexts[fallback_worker]);
		}
	}

	for (contexts) |ctx| {
		if (ctx.err) |err| return err;
	}

	var merged_blocks: std.ArrayListUnmanaged(BlockTokens) = .empty;
	errdefer {
		for (merged_blocks.items) |block| allocator.free(block.tokens);
		merged_blocks.deinit(allocator);
	}

	var current_tokens: std.ArrayListUnmanaged(Token) = .empty;
	errdefer current_tokens.deinit(allocator);
	var current_block_cost: usize = 0;
	var current_input_len: usize = 0;

	for (results) |maybe_segment| {
		const segment = maybe_segment orelse continue;
		for (segment.tokens) |tok| {
			try current_tokens.append(allocator, tok);
			current_block_cost = std.math.add(usize, current_block_cost, tokenCost(tok)) catch std.math.maxInt(usize);
			current_input_len = std.math.add(usize, current_input_len, tokenInputLen(tok)) catch std.math.maxInt(usize);
			if (current_block_cost >= block_size) {
				try appendFinalizedBlock(allocator, &merged_blocks, &current_tokens, current_input_len);
				current_block_cost = 0;
				current_input_len = 0;
			}
		}
	}
	try appendFinalizedBlock(allocator, &merged_blocks, &current_tokens, current_input_len);
	current_tokens.deinit(allocator);

	const merged = try merged_blocks.toOwnedSlice(allocator);
	if (merged.len > 0) {
		for (merged[0 .. merged.len - 1]) |*block| block.has_more = true;
		merged[merged.len - 1].has_more = false;
	}

	if (progress_ptr) |p| p.complete();
	return merged;
}

fn chooseWorkerCount(worker_limit: usize, block_count: usize) usize {
	if (block_count == 0) return 1;
	var workers = if (worker_limit == 0)
		(std.Thread.getCpuCount() catch 1)
	else
		worker_limit;
	if (workers == 0) workers = 1;
	return @min(workers, block_count);
}

fn workerEncodeBlocks(ctx: *WorkerCtx) void {
	const allocator = ctx.arena.allocator();
	var idx = ctx.worker_id;
	while (idx < ctx.blocks.len) : (idx += ctx.step) {
		const block = ctx.blocks[idx];
		const encoded = encodeBlockToOwned(allocator, block.tokens, block.has_more) catch |err| {
			ctx.err = err;
			return;
		};
		ctx.results[idx] = encoded;
		if (ctx.progress) |progress| progress.blockDone(block.input_len);
	}
}

fn encodeBlocksSequential(
	allocator: std.mem.Allocator,
	blocks: []const BlockTokens,
	progress: ?*EncodeProgressReporter,
) Error![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .empty;
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, blocks.len * 8);
	for (blocks) |block| {
		try encodeBlockTokens(allocator, &out, block.tokens, block.has_more);
		if (progress) |p| p.blockDone(block.input_len);
	}
	return try out.toOwnedSlice(allocator);
}

fn encodeBlocksParallel(
	allocator: std.mem.Allocator,
	blocks: []const BlockTokens,
	worker_count: usize,
	progress: ?*EncodeProgressReporter,
) Error![]u8 {
	const results = try allocator.alloc(?[]u8, blocks.len);
	defer allocator.free(results);
	@memset(results, null);

	var contexts = try allocator.alloc(WorkerCtx, worker_count);
	defer {
		for (contexts) |*ctx| ctx.arena.deinit();
		allocator.free(contexts);
	}

	for (contexts, 0..) |*ctx, worker_id| {
		ctx.* = .{
			.blocks = blocks,
			.results = results,
			.worker_id = worker_id,
			.step = worker_count,
			.progress = progress,
			.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
		};
	}

	var threads = try allocator.alloc(std.Thread, worker_count - 1);
	defer allocator.free(threads);

	var spawned: usize = 0;
	var spawn_failed = false;
	var worker_id: usize = 1;
	while (worker_id < worker_count) : (worker_id += 1) {
		threads[spawned] = std.Thread.spawn(.{}, workerEncodeBlocks, .{&contexts[worker_id]}) catch {
			spawn_failed = true;
			break;
		};
		spawned += 1;
	}

	workerEncodeBlocks(&contexts[0]);

	for (threads[0..spawned]) |thread| thread.join();

	if (spawn_failed) {
		var fallback_worker = spawned + 1;
		while (fallback_worker < worker_count) : (fallback_worker += 1) {
			workerEncodeBlocks(&contexts[fallback_worker]);
		}
	}

	for (contexts) |ctx| {
		if (ctx.err) |err| return err;
	}

	var total_len: usize = 0;
	for (results) |maybe_encoded| {
		const encoded = maybe_encoded orelse unreachable;
		total_len = std.math.add(usize, total_len, encoded.len) catch return error.OutOfMemory;
	}

	const out = try allocator.alloc(u8, total_len);
	errdefer allocator.free(out);
	var cursor: usize = 0;
	for (results) |maybe_encoded| {
		const encoded = maybe_encoded orelse unreachable;
		@memcpy(out[cursor .. cursor + encoded.len], encoded);
		cursor += encoded.len;
	}

	return out;
}

pub fn encodeWithWorkerLimitAndProgress(
	allocator: std.mem.Allocator,
	input: []const u8,
	worker_limit: usize,
	progress_cb: ?EncodeProgressFn,
	progress_ctx: ?*anyopaque,
) Error![]u8 {
	const total_work = if (input.len == 0)
		@as(usize, 1)
	else
		(std.math.mul(usize, input.len, 2) catch std.math.maxInt(usize));
	if (progress_cb) |cb| cb(progress_ctx, 0, total_work);

	const blocks = try collectTokenBlocks(allocator, input, worker_limit, progress_cb, progress_ctx, total_work);
	defer {
		for (blocks) |block| allocator.free(block.tokens);
		allocator.free(blocks);
	}

	if (blocks.len == 0) {
		if (progress_cb) |cb| cb(progress_ctx, total_work, total_work);
		return try allocator.alloc(u8, 0);
	}

	var reporter = EncodeProgressReporter{
		.callback = progress_cb,
		.ctx = progress_ctx,
		.total_work = total_work,
		.base_work = input.len,
	};
	const reporter_ptr: ?*EncodeProgressReporter = if (progress_cb != null) &reporter else null;

	const worker_count = chooseWorkerCount(worker_limit, blocks.len);
	const encoded = if (worker_count <= 1 or blocks.len < 2)
		try encodeBlocksSequential(allocator, blocks, reporter_ptr)
	else
		try encodeBlocksParallel(allocator, blocks, worker_count, reporter_ptr);

	if (reporter_ptr) |ptr| ptr.complete();
	return encoded;
}

pub fn encodeWithWorkerLimit(allocator: std.mem.Allocator, input: []const u8, worker_limit: usize) Error![]u8 {
	return try encodeWithWorkerLimitAndProgress(allocator, input, worker_limit, null, null);
}

pub fn encode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
	return try encodeWithWorkerLimitAndProgress(allocator, input, 0, null, null);
}

pub fn decode(allocator: std.mem.Allocator, compressed: []const u8, expected_len: usize) Error![]u8 {
	const out = try allocator.alloc(u8, expected_len);
	errdefer allocator.free(out);

	var decoder = Decoder{
		.bits = .{ .bytes = compressed },
		.output = out,
	};
	try decoder.decodeAll();
	if (decoder.out_index != expected_len) return Error.OutputLengthMismatch;
	return out;
}

// ---------------------------------------------------------------------------
// Inline tests for private Huffman / match-finder helpers. These cannot be
// reached from the out-of-line suite (the helpers are file-private), so they
// live here and run via the per-leaf test roots wired in build.zig.
// ---------------------------------------------------------------------------

test "buildCanonicalCodes matches RFC 1951 worked example" {
	// RFC 1951 section 3.2.2: alphabet A..H with code lengths
	// (3,3,3,3,3,2,4,4) yields canonical codes
	// A=010 B=011 C=100 D=101 E=110 F=00 G=1110 H=1111.
	const lengths = [_]u8{ 3, 3, 3, 3, 3, 2, 4, 4 };
	const codes = buildCanonicalCodes(8, lengths);
	const expected = [_]u32{ 0b010, 0b011, 0b100, 0b101, 0b110, 0b00, 0b1110, 0b1111 };
	try std.testing.expectEqualSlices(u32, &expected, &codes);
}

test "buildCanonicalCodes assigns zero to unused symbols" {
	const lengths = [_]u8{ 0, 0, 0, 0 };
	const codes = buildCanonicalCodes(4, lengths);
	try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 0, 0, 0 }, &codes);
}

test "buildCanonicalCodes: equal-length codes are consecutive integers" {
	// Four symbols all length 2 -> codes 00,01,10,11 in symbol order.
	const lengths = [_]u8{ 2, 2, 2, 2 };
	const codes = buildCanonicalCodes(4, lengths);
	try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2, 3 }, &codes);
}

test "buildCodeLengths produces a complete, monotone, depth-bounded code" {
	const freqs = [_]u32{ 1, 1, 2, 3, 5, 8, 13, 21 };
	const lengths = buildCodeLengths(8, freqs);

	// Every used symbol gets a positive length; unused symbols stay zero.
	for (freqs, 0..) |f, sym| {
		if (f > 0) {
			try std.testing.expect(lengths[sym] > 0);
		} else {
			try std.testing.expectEqual(@as(u8, 0), lengths[sym]);
		}
		try std.testing.expect(lengths[sym] <= 15);
	}

	// Monotonicity: a strictly more frequent symbol is never given a longer code.
	for (freqs, 0..) |fa, a| {
		for (freqs, 0..) |fb, b| {
			if (fa > fb and lengths[a] != 0 and lengths[b] != 0) {
				try std.testing.expect(lengths[a] <= lengths[b]);
			}
		}
	}

	// Kraft equality for a complete prefix code: sum(2^-len) == 1, computed in
	// fixed point as sum(2^(15-len)) == 2^15.
	var kraft: u32 = 0;
	for (lengths) |len| {
		if (len > 0) kraft += @as(u32, 1) << @intCast(15 - len);
	}
	try std.testing.expectEqual(@as(u32, 1) << 15, kraft);
}

test "buildCodeLengths edge cases: empty and single symbol" {
	const none = buildCodeLengths(4, [_]u32{ 0, 0, 0, 0 });
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &none);

	// A lone symbol still needs a 1-bit code (a zero-length code is unusable).
	const one = buildCodeLengths(4, [_]u32{ 0, 7, 0, 0 });
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0, 0 }, &one);
}

test "heap pops in (freq, index) order" {
	const node_freq = [_]u64{ 5, 1, 4, 1, 3, 0, 0, 0 };
	var heap = [_]i32{0} ** 8;
	var heap_len: usize = 0;
	for (0..5) |i| heapPush(&node_freq, &heap, &heap_len, @intCast(i));

	// Tie-break is by index, so (freq,idx) order is (1,1)(1,3)(3,4)(4,2)(5,0).
	const expected = [_]i32{ 1, 3, 4, 2, 0 };
	var prev_freq: u64 = 0;
	for (expected) |want| {
		const got = heapPop(&node_freq, &heap, &heap_len);
		try std.testing.expectEqual(want, got);
		// And the popped frequencies are non-decreasing (min-heap invariant).
		try std.testing.expect(node_freq[@intCast(got)] >= prev_freq);
		prev_freq = node_freq[@intCast(got)];
	}
	try std.testing.expectEqual(@as(usize, 0), heap_len);
}

test "hash3 is deterministic and within table bounds" {
	const a = "abcxyz";
	const b = "abc---";
	// Same first three bytes hash identically regardless of what follows.
	try std.testing.expectEqual(hash3(a, 0), hash3(b, 0));
	// Result is always a valid table index.
	try std.testing.expect(hash3(a, 0) < hash_size);
	try std.testing.expect(hash3("zzz", 0) < hash_size);
	// Matches the documented mixing formula.
	const manual = (('a' * 251) + ('b' * 67) + 'c') & hash_mask;
	try std.testing.expectEqual(manual, hash3(a, 0));
}

test "findBestMatch finds an obvious back-reference" {
	const data = "abcabc";
	const head = try std.testing.allocator.alloc(i32, hash_size);
	defer std.testing.allocator.free(head);
	const prev = try std.testing.allocator.alloc(i32, window_size);
	defer std.testing.allocator.free(prev);
	@memset(head, -1);
	@memset(prev, -1);

	// Index positions 0,1,2 of the first "abc".
	for (0..3) |pos| insertMatcherPos(data, pos, head, prev);

	// At position 3 ("abc" again) the best match is the copy 3 bytes back.
	const m = findBestMatch(data, 3, head, prev);
	try std.testing.expectEqual(@as(usize, 3), m.offset);
	try std.testing.expectEqual(@as(usize, 3), m.len);
}

test "findBestMatch returns no match when nothing is indexed" {
	const data = "abcdef";
	const head = try std.testing.allocator.alloc(i32, hash_size);
	defer std.testing.allocator.free(head);
	const prev = try std.testing.allocator.alloc(i32, window_size);
	defer std.testing.allocator.free(prev);
	@memset(head, -1);
	@memset(prev, -1);

	const m = findBestMatch(data, 0, head, prev);
	try std.testing.expectEqual(@as(usize, 0), m.len);
	try std.testing.expectEqual(@as(usize, 0), m.offset);
}
