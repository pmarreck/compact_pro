const std = @import("std");

pub const Error = error{
	Truncated,
	InvalidCodebook,
	InvalidHuffmanCode,
	OutputLengthMismatch,
	InvalidMatchOffset,
} || std.mem.Allocator.Error;

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

	while (candidate >= 0 and depth < chain_limit) : (depth += 1) {
		const cand: usize = @intCast(candidate);
		if (cand >= pos) break;
		const offset = pos - cand;
		if (offset == 0 or offset >= window_size) {
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

pub fn encode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
	var out: std.ArrayListUnmanaged(u8) = .{};
	errdefer out.deinit(allocator);
	try out.ensureTotalCapacity(allocator, input.len / 2 + 64);

	const head = try allocator.alloc(i32, hash_size);
	defer allocator.free(head);
	@memset(head, -1);

	const prev = try allocator.alloc(i32, window_size);
	defer allocator.free(prev);
	@memset(prev, -1);

	var tokens: std.ArrayListUnmanaged(Token) = .{};
	defer tokens.deinit(allocator);

	var pos: usize = 0;
	while (pos < input.len) {
		tokens.clearRetainingCapacity();
		var block_count: usize = 0;

		while (pos < input.len and block_count < block_size) {
			const match = findBestMatch(input, pos, head, prev);
			if (match.len >= min_match_len) {
				try tokens.append(allocator, .{
					.match = .{
						.len = @intCast(match.len),
						.offset = @intCast(match.offset),
					},
				});
				for (0..match.len) |k| insertMatcherPos(input, pos + k, head, prev);
				pos += match.len;
				block_count += 3;
				continue;
			}

			try tokens.append(allocator, .{ .literal = input[pos] });
			insertMatcherPos(input, pos, head, prev);
			pos += 1;
			block_count += 2;
		}

		if (tokens.items.len == 0) break;
		try encodeBlockTokens(allocator, &out, tokens.items, pos < input.len);
	}

	return try out.toOwnedSlice(allocator);
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
