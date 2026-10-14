//! Minimal pull-source / push-sink adapters over in-memory slices. The RLE and
//! LZH decoders are generic over these duck-typed interfaces (`next() !?u8`,
//! `put(u8)`, `fill(u8, n)`), so the buffered extractor and the streaming
//! verifier run the same decoding code. Holds no tests, so importing it from
//! several leaf test roots does not duplicate test runs.

/// Byte source over a slice; `next` returns null at end of input.
pub const SliceSource = struct {
	bytes: []const u8,
	index: usize = 0,

	pub inline fn next(self: *SliceSource) error{}!?u8 {
		if (self.index >= self.bytes.len) return null;
		defer self.index += 1;
		return self.bytes[self.index];
	}
};

/// Byte sink writing into a preallocated slice; callers bound the length.
pub const SliceSink = struct {
	out: []u8,
	len: usize = 0,

	pub inline fn put(self: *SliceSink, b: u8) error{}!void {
		self.out[self.len] = b;
		self.len += 1;
	}

	pub inline fn fill(self: *SliceSink, b: u8, n: usize) error{}!void {
		@memset(self.out[self.len .. self.len + n], b);
		self.len += n;
	}
};
