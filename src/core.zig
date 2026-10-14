const std = @import("std");
const crc = @import("crc32jam.zig");
pub const lzh = @import("lzh.zig");
pub const rle8182 = @import("rle8182.zig");

pub const flag_encrypted: u16 = 0x0001;
pub const flag_lzh_resource: u16 = 0x0002;
pub const flag_lzh_data: u16 = 0x0004;
pub const CreateArchiveProgressFn = *const fn (?*anyopaque, usize, usize) callconv(.c) void;

pub const EntryInput = struct {
	name: []const u8,
	data: []const u8,
	resource: []const u8 = &.{},
	file_type: u32 = 0,
	creator: u32 = 0,
	created: u32 = 0,
	modified: u32 = 0,
	finder_flags: u16 = 0,
};

pub const MetadataEntry = struct {
	name: []u8,
	volume: u8,
	fork_data_offset: u32,
	file_type: u32,
	creator: u32,
	created: u32,
	modified: u32,
	finder_flags: u16,
	file_crc: u32,
	flags: u16,
	resource_uncompressed_len: u32,
	data_uncompressed_len: u32,
	resource_compressed_len: u32,
	data_compressed_len: u32,
};

pub const ParsedMetadata = struct {
	comment: []u8,
	entries: []MetadataEntry,

	pub fn deinit(self: ParsedMetadata, allocator: std.mem.Allocator) void {
		allocator.free(self.comment);
		for (self.entries) |entry| allocator.free(entry.name);
		allocator.free(self.entries);
	}
};

pub const ExtractedEntry = struct {
	name: []u8,
	data: []u8,
	resource: []u8,
	file_type: u32,
	creator: u32,
	created: u32,
	modified: u32,
	finder_flags: u16,
};

pub const ExtractedArchive = struct {
	comment: []u8,
	entries: []ExtractedEntry,

	pub fn deinit(self: ExtractedArchive, allocator: std.mem.Allocator) void {
		allocator.free(self.comment);
		for (self.entries) |entry| {
			allocator.free(entry.name);
			allocator.free(entry.data);
			allocator.free(entry.resource);
		}
		allocator.free(self.entries);
	}
};

pub const Error = error{
	InvalidMarker,
	Truncated,
	InvalidHeaderOffset,
	HeaderCrcMismatch,
	InvalidEntryCount,
	UnsupportedEncryptedEntry,
	UnsupportedLzhEntry,
	InvalidNameLength,
	TooManyEntries,
	CommentTooLong,
	EntryPathTooLong,
	InvalidEntryPath,
	DuplicateEntryPath,
	OffsetOutOfRange,
	FileCrcMismatch,
} || ReadError || SinkError || rle8182.Error || lzh.Error || std.mem.Allocator.Error;

pub const ReadError = error{ReadFailed};
pub const SinkError = error{SinkAborted};

/// Caller-supplied seekable input for `verifyStream`. `readAtFn` copies up to
/// `buf.len` bytes starting at `offset` and returns the count; a short count is
/// allowed, but returning 0 before `size` is reached is a read failure.
pub const RangeSource = struct {
	ctx: ?*anyopaque,
	size: u64,
	readAtFn: *const fn (ctx: ?*anyopaque, offset: u64, buf: []u8) ReadError!usize,
};

pub const ForkKind = enum(u8) { data = 0, resource = 1 };

/// Receives decoded fork bytes in order, chunk by chunk. Bytes of a fork are
/// unverified until `verifyStream` has checked that entry's CRC.
pub const ForkSink = struct {
	ctx: ?*anyopaque,
	writeFn: *const fn (ctx: ?*anyopaque, entry_index: usize, fork: ForkKind, bytes: []const u8) SinkError!void,
};

/// Where `verifyStream` detected a failure, for typed findings with offsets.
/// `error_offset` is the archive offset just past the last byte consumed when
/// the error was raised; for a header or file CRC mismatch it is the start of
/// the CRC-covered region (header offset, or the entry's fork data offset).
pub const VerifyDiagnostics = struct {
	error_offset: ?u64 = null,
};

pub const VerifySummary = struct {
	entry_count: usize,
	total_uncompressed: u64,
};

/// Size of each of the two fixed streaming buffers (input cursor, output sink).
pub const verify_stream_buffer_size: usize = 64 * 1024;
/// Upper bound on `verifyStream` heap use apart from the parsed entry table.
pub const verify_stream_memory_budget: usize = 4 * verify_stream_buffer_size;

const FileAccumulator = struct {
	allocator: std.mem.Allocator,
	items: std.ArrayListUnmanaged(MetadataEntry) = .empty,

	fn append(self: *FileAccumulator, entry: MetadataEntry) !void {
		try self.items.append(self.allocator, entry);
	}

	fn deinit(self: *FileAccumulator) void {
		for (self.items.items) |entry| self.allocator.free(entry.name);
		self.items.deinit(self.allocator);
	}
};

const Reader = struct {
	bytes: []const u8,
	index: usize,
	crc_start: usize = 0,

	fn beginCrc(self: *Reader) void {
		self.crc_start = self.index;
	}

	fn crcValue(self: *const Reader) u32 {
		return crc.jamcrc(self.bytes[self.crc_start..self.index]);
	}

	fn readU8(self: *Reader) Error!u8 {
		if (self.index + 1 > self.bytes.len) return Error.Truncated;
		const out = self.bytes[self.index];
		self.index += 1;
		return out;
	}

	fn readU16(self: *Reader) Error!u16 {
		if (self.index + 2 > self.bytes.len) return Error.Truncated;
		const out = std.mem.readInt(u16, self.bytes[self.index..][0..2], .big);
		self.index += 2;
		return out;
	}

	fn readU32(self: *Reader) Error!u32 {
		if (self.index + 4 > self.bytes.len) return Error.Truncated;
		const out = std.mem.readInt(u32, self.bytes[self.index..][0..4], .big);
		self.index += 4;
		return out;
	}

	fn readSlice(self: *Reader, len: usize) Error![]const u8 {
		if (self.index + len > self.bytes.len) return Error.Truncated;
		const out = self.bytes[self.index..][0..len];
		self.index += len;
		return out;
	}
};

const Writer = struct {
	bytes: []u8,
	index: usize,

	fn writeU8(self: *Writer, value: u8) void {
		self.bytes[self.index] = value;
		self.index += 1;
	}

	fn writeU16(self: *Writer, value: u16) void {
		std.mem.writeInt(u16, self.bytes[self.index..][0..2], value, .big);
		self.index += 2;
	}

	fn writeU32(self: *Writer, value: u32) void {
		std.mem.writeInt(u32, self.bytes[self.index..][0..4], value, .big);
		self.index += 4;
	}

	fn writeSlice(self: *Writer, value: []const u8) void {
		@memcpy(self.bytes[self.index..][0..value.len], value);
		self.index += value.len;
	}
};

pub fn parseMetadata(allocator: std.mem.Allocator, archive: []const u8, strict_crc: bool) Error!ParsedMetadata {
	if (archive.len < 8) return Error.Truncated;
	var preamble = Reader{ .bytes = archive, .index = 0 };

	const marker = try preamble.readU8();
	if (marker != 0x01) return Error.InvalidMarker;
	_ = try preamble.readU8();
	_ = try preamble.readU16();
	const header_offset = try preamble.readU32();
	if (header_offset >= archive.len) return Error.InvalidHeaderOffset;

	var reader = Reader{ .bytes = archive, .index = header_offset };
	return parseHeader(allocator, &reader, strict_crc);
}

/// Walks the Compact Pro directory header (CRC, entry count, comment, nested
/// entry records) from any reader positioned at the header offset. Shared by
/// the in-memory parser and the streaming verifier so both validate alike.
fn parseHeader(allocator: std.mem.Allocator, reader: anytype, strict_crc: bool) Error!ParsedMetadata {
	const header_crc = try reader.readU32();
	reader.beginCrc();
	const entry_count = try reader.readU16();
	const comment_len = try reader.readU8();
	const comment_src = try reader.readSlice(comment_len);

	const comment = try allocator.alloc(u8, comment_src.len);
	@memcpy(comment, comment_src);
	errdefer allocator.free(comment);

	var acc = FileAccumulator{ .allocator = allocator };
	errdefer acc.deinit();
	try parseDirectoryEntries(allocator, reader, &acc, "", entry_count);

	if (strict_crc and reader.crcValue() != header_crc) return Error.HeaderCrcMismatch;

	return .{
		.comment = comment,
		.entries = try acc.items.toOwnedSlice(allocator),
	};
}

fn parseDirectoryEntries(
	allocator: std.mem.Allocator,
	reader: anytype,
	acc: *FileAccumulator,
	prefix: []const u8,
	entry_count: usize,
) Error!void {
	var remaining: usize = entry_count;
	while (remaining > 0) {
		const name_len_kind = try reader.readU8();
		const name_len: usize = name_len_kind & 0x7F;
		const is_dir = (name_len_kind & 0x80) != 0;
		const name_part = try reader.readSlice(name_len);
		const full_name = try joinPath(allocator, prefix, name_part);

		if (is_dir) {
			// Directory entries: full_name is only consumed as the recursion prefix.
			// A single `defer` frees on every exit (success continue and error unwind),
			// avoiding the double-free that an outer errdefer + inner defer would cause.
			defer allocator.free(full_name);
			const descendants = try reader.readU16();
			const subtree_count: usize = @as(usize, descendants) + 1;
			if (subtree_count > remaining) return Error.InvalidEntryCount;
			try parseDirectoryEntries(allocator, reader, acc, full_name, @intCast(descendants));
			remaining -= subtree_count;
			continue;
		}

		// File entries: full_name transfers to acc on successful append. errdefer
		// handles the error path; successful iteration leaves full_name owned by acc.
		errdefer allocator.free(full_name);

		const entry = MetadataEntry{
			.name = full_name,
			.volume = try reader.readU8(),
			.fork_data_offset = try reader.readU32(),
			.file_type = try reader.readU32(),
			.creator = try reader.readU32(),
			.created = try reader.readU32(),
			.modified = try reader.readU32(),
			.finder_flags = try reader.readU16(),
			.file_crc = try reader.readU32(),
			.flags = try reader.readU16(),
			.resource_uncompressed_len = try reader.readU32(),
			.data_uncompressed_len = try reader.readU32(),
			.resource_compressed_len = try reader.readU32(),
			.data_compressed_len = try reader.readU32(),
		};

		try acc.append(entry);
		remaining -= 1;
	}
}

fn joinPath(allocator: std.mem.Allocator, prefix: []const u8, part: []const u8) ![]u8 {
	if (prefix.len == 0) {
		const out = try allocator.alloc(u8, part.len);
		@memcpy(out, part);
		return out;
	}
	var out = try allocator.alloc(u8, prefix.len + 1 + part.len);
	@memcpy(out[0..prefix.len], prefix);
	out[prefix.len] = '/';
	@memcpy(out[prefix.len + 1 ..], part);
	return out;
}

/// Data fork bytes follow the resource fork; a sum past u32 is out of range
/// rather than a wrapped pointer back into the archive.
fn dataForkOffset(meta: MetadataEntry) Error!u32 {
	return std.math.add(u32, meta.fork_data_offset, meta.resource_compressed_len) catch Error.OffsetOutOfRange;
}

fn readForkSlice(archive: []const u8, offset: u32, len: u32) Error![]const u8 {
	const start: usize = @intCast(offset);
	const size: usize = @intCast(len);
	const end = start + size;
	if (end < start or end > archive.len) return Error.OffsetOutOfRange;
	return archive[start..end];
}

fn decodeFork(
	allocator: std.mem.Allocator,
	archive: []const u8,
	offset: u32,
	compressed_len: u32,
	uncompressed_len: u32,
	lzh_enabled: bool,
) Error![]u8 {
	if (uncompressed_len == 0 and compressed_len == 0) {
		return try allocator.alloc(u8, 0);
	}
	const compressed = try readForkSlice(archive, offset, compressed_len);
	if (lzh_enabled) {
		return try lzh.decode(allocator, compressed, @intCast(uncompressed_len));
	}
	return try rle8182.decode(allocator, compressed, @intCast(uncompressed_len), true);
}

pub fn extractAll(allocator: std.mem.Allocator, archive: []const u8, strict_crc: bool) Error!ExtractedArchive {
	const metadata = try parseMetadata(allocator, archive, strict_crc);
	defer metadata.deinit(allocator);

	var out_entries: std.ArrayListUnmanaged(ExtractedEntry) = .empty;
	errdefer {
		for (out_entries.items) |entry| {
			allocator.free(entry.name);
			allocator.free(entry.data);
			allocator.free(entry.resource);
		}
		out_entries.deinit(allocator);
	}

	for (metadata.entries) |meta| {
		if ((meta.flags & flag_encrypted) != 0) return Error.UnsupportedEncryptedEntry;
		const resource_exists = meta.resource_uncompressed_len > 0;
		const data_exists = meta.data_uncompressed_len > 0 or !resource_exists;

		const resource = if (resource_exists)
			try decodeFork(
				allocator,
				archive,
				meta.fork_data_offset,
				meta.resource_compressed_len,
				meta.resource_uncompressed_len,
				(meta.flags & flag_lzh_resource) != 0,
			)
		else
			try allocator.alloc(u8, 0);
		errdefer allocator.free(resource);

		const data_offset = try dataForkOffset(meta);
		const data = if (data_exists)
			try decodeFork(
				allocator,
				archive,
				data_offset,
				meta.data_compressed_len,
				meta.data_uncompressed_len,
				(meta.flags & flag_lzh_data) != 0,
			)
		else
			try allocator.alloc(u8, 0);
		errdefer allocator.free(data);

		if (strict_crc) {
			var computed = crc.update(crc.initial, resource);
			computed = crc.update(computed, data);
			if (computed != meta.file_crc) return Error.FileCrcMismatch;
		}

		const copied_name = try allocator.alloc(u8, meta.name.len);
		@memcpy(copied_name, meta.name);
		try out_entries.append(allocator, .{
			.name = copied_name,
			.data = data,
			.resource = resource,
			.file_type = meta.file_type,
			.creator = meta.creator,
			.created = meta.created,
			.modified = meta.modified,
			.finder_flags = meta.finder_flags,
		});
	}

	return .{
		.comment = try allocator.dupe(u8, metadata.comment),
		.entries = try out_entries.toOwnedSlice(allocator),
	};
}

/// Buffered forward cursor over a `RangeSource` window [pos, end). Refills a
/// fixed heap buffer through the caller's read callback, so archive bytes are
/// never held beyond one buffer. `next` returns null at the window end.
const RangeCursor = struct {
	source: RangeSource,
	buf: []u8,
	pos: u64,
	end: u64,
	buf_start: u64 = 0,
	buf_len: usize = 0,

	fn init(source: RangeSource, buf: []u8, start: u64, end: u64) RangeCursor {
		return .{ .source = source, .buf = buf, .pos = start, .end = end };
	}

	fn refill(self: *RangeCursor) ReadError!void {
		const want: usize = @intCast(@min(@as(u64, self.buf.len), self.end - self.pos));
		var got: usize = 0;
		while (got < want) {
			const n = try self.source.readAtFn(self.source.ctx, self.pos + got, self.buf[got..want]);
			if (n == 0 or n > want - got) return error.ReadFailed;
			got += n;
		}
		self.buf_start = self.pos;
		self.buf_len = got;
	}

	pub inline fn next(self: *RangeCursor) ReadError!?u8 {
		if (self.pos >= self.end) return null;
		if (self.pos < self.buf_start or self.pos >= self.buf_start + self.buf_len) try self.refill();
		const b = self.buf[@intCast(self.pos - self.buf_start)];
		self.pos += 1;
		return b;
	}
};

/// Header reader over a `RangeCursor` with the same interface as `Reader`.
/// `readSlice` returns a view into scratch storage valid until the next read;
/// Compact Pro names (<=127) and comments (<=255) always fit.
const StreamReader = struct {
	cursor: *RangeCursor,
	scratch: [256]u8 = undefined,
	crc_active: bool = false,
	crc_state: u32 = crc.initial,

	fn readByte(self: *StreamReader) Error!u8 {
		const b = (try self.cursor.next()) orelse return Error.Truncated;
		if (self.crc_active) self.crc_state = crc.update(self.crc_state, &.{b});
		return b;
	}

	fn readU8(self: *StreamReader) Error!u8 {
		return self.readByte();
	}

	fn readU16(self: *StreamReader) Error!u16 {
		var out: u16 = 0;
		for (0..2) |_| out = (out << 8) | try self.readByte();
		return out;
	}

	fn readU32(self: *StreamReader) Error!u32 {
		var out: u32 = 0;
		for (0..4) |_| out = (out << 8) | try self.readByte();
		return out;
	}

	fn readSlice(self: *StreamReader, len: usize) Error![]const u8 {
		if (len > self.scratch.len) return Error.Truncated;
		for (self.scratch[0..len]) |*b| b.* = try self.readByte();
		return self.scratch[0..len];
	}

	fn beginCrc(self: *StreamReader) void {
		self.crc_active = true;
		self.crc_state = crc.initial;
	}

	fn crcValue(self: *const StreamReader) u32 {
		return self.crc_state;
	}
};

/// Output side of streaming verification: batches decoded bytes into a fixed
/// buffer, folds each flush into the running file CRC and forwards it to the
/// optional caller sink.
const VerifySink = struct {
	buf: []u8,
	len: usize = 0,
	crc_state: u32 = crc.initial,
	track_crc: bool,
	user: ?ForkSink,
	entry_index: usize = 0,
	fork: ForkKind = .data,

	fn flush(self: *VerifySink) SinkError!void {
		if (self.len == 0) return;
		const chunk = self.buf[0..self.len];
		if (self.track_crc) self.crc_state = crc.update(self.crc_state, chunk);
		if (self.user) |u| try u.writeFn(u.ctx, self.entry_index, self.fork, chunk);
		self.len = 0;
	}

	pub inline fn put(self: *VerifySink, b: u8) SinkError!void {
		self.buf[self.len] = b;
		self.len += 1;
		if (self.len == self.buf.len) try self.flush();
	}

	pub fn fill(self: *VerifySink, b: u8, n: usize) SinkError!void {
		var left = n;
		while (left > 0) {
			const take = @min(left, self.buf.len - self.len);
			@memset(self.buf[self.len .. self.len + take], b);
			self.len += take;
			left -= take;
			if (self.len == self.buf.len) try self.flush();
		}
	}
};

fn streamFork(
	pos: *u64,
	source: RangeSource,
	in_buf: []u8,
	sink: *VerifySink,
	offset: u32,
	compressed_len: u32,
	uncompressed_len: u32,
	lzh_enabled: bool,
) Error!void {
	if (uncompressed_len == 0 and compressed_len == 0) return;
	const start: u64 = offset;
	const end = start + compressed_len;
	if (end > source.size) return Error.OffsetOutOfRange;
	var cursor = RangeCursor.init(source, in_buf, start, end);
	// The LZH bit reader prefetches; report the lazy (consumed) position.
	var prefetched: usize = 0;
	errdefer pos.* = cursor.pos - prefetched;
	if (lzh_enabled) {
		try lzh.decodeStream(&cursor, sink, uncompressed_len, &prefetched);
	} else {
		try rle8182.decodeStream(&cursor, sink, uncompressed_len, true);
	}
	try sink.flush();
}

/// Bounded-memory archive verification for consumers such as `validate`:
/// reads the archive through a range callback, decodes every fork with the
/// same RLE/LZH decoders as `extractAll`, checks header and per-file CRCs, and
/// streams decoded bytes to an optional sink instead of retaining them.
/// Returns the same errors as `extractAll` for the same archive bytes.
fn readPreamble(cursor: *RangeCursor, size: u64) Error!u32 {
	var preamble = StreamReader{ .cursor = cursor };
	if (try preamble.readU8() != 0x01) return Error.InvalidMarker;
	_ = try preamble.readU8();
	_ = try preamble.readU16();
	const header_offset = try preamble.readU32();
	if (header_offset >= size) return Error.InvalidHeaderOffset;
	return header_offset;
}

pub fn verifyStream(
	allocator: std.mem.Allocator,
	source: RangeSource,
	strict_crc: bool,
	sink: ?ForkSink,
	diag: ?*VerifyDiagnostics,
) Error!VerifySummary {
	var pos: u64 = 0;
	if (diag) |d| d.error_offset = null;
	return verifyStreamTracked(allocator, source, strict_crc, sink, &pos) catch |err| {
		if (diag) |d| d.error_offset = pos;
		return err;
	};
}

fn verifyStreamTracked(
	allocator: std.mem.Allocator,
	source: RangeSource,
	strict_crc: bool,
	sink: ?ForkSink,
	pos: *u64,
) Error!VerifySummary {
	const in_buf = try allocator.alloc(u8, verify_stream_buffer_size);
	defer allocator.free(in_buf);
	const out_buf = try allocator.alloc(u8, verify_stream_buffer_size);
	defer allocator.free(out_buf);

	const metadata = try readArchiveHeader(allocator, source, in_buf, strict_crc, pos);
	defer metadata.deinit(allocator);

	var total: u64 = 0;
	for (metadata.entries, 0..) |meta, index| {
		total += try verifyEntry(source, in_buf, out_buf, meta, index, strict_crc, sink, pos);
	}
	return .{ .entry_count = metadata.entries.len, .total_uncompressed = total };
}

/// Reads the preamble and directory header through `in_buf`, recording the
/// failure position in `pos` on error (header offset for a header CRC
/// mismatch, otherwise the consumed position).
fn readArchiveHeader(allocator: std.mem.Allocator, source: RangeSource, in_buf: []u8, strict_crc: bool, pos: *u64) Error!ParsedMetadata {
	if (source.size < 8) return Error.Truncated;
	var preamble_cursor = RangeCursor.init(source, in_buf, 0, 8);
	const header_offset = readPreamble(&preamble_cursor, source.size) catch |err| {
		pos.* = preamble_cursor.pos;
		return err;
	};

	var header_cursor = RangeCursor.init(source, in_buf, header_offset, source.size);
	var header = StreamReader{ .cursor = &header_cursor };
	return parseHeader(allocator, &header, strict_crc) catch |err| {
		pos.* = if (err == Error.HeaderCrcMismatch) header_offset else header_cursor.pos;
		return err;
	};
}

/// Decodes and CRC-checks one entry's resource and data forks with the
/// caller's fixed buffers; returns its decoded byte count. Entries are
/// independent of each other, which is what makes parallel verification safe.
fn verifyEntry(
	source: RangeSource,
	in_buf: []u8,
	out_buf: []u8,
	meta: MetadataEntry,
	index: usize,
	strict_crc: bool,
	sink: ?ForkSink,
	pos: *u64,
) Error!u64 {
	pos.* = meta.fork_data_offset;
	if ((meta.flags & flag_encrypted) != 0) return Error.UnsupportedEncryptedEntry;
	const resource_exists = meta.resource_uncompressed_len > 0;
	const data_exists = meta.data_uncompressed_len > 0 or !resource_exists;
	var out = VerifySink{ .buf = out_buf, .track_crc = strict_crc, .user = sink, .entry_index = index };

	if (resource_exists) {
		out.fork = .resource;
		try streamFork(pos, source, in_buf, &out, meta.fork_data_offset, meta.resource_compressed_len, meta.resource_uncompressed_len, (meta.flags & flag_lzh_resource) != 0);
	}
	const data_offset = try dataForkOffset(meta);
	if (data_exists) {
		out.fork = .data;
		try streamFork(pos, source, in_buf, &out, data_offset, meta.data_compressed_len, meta.data_uncompressed_len, (meta.flags & flag_lzh_data) != 0);
	}

	if (strict_crc and out.crc_state != meta.file_crc) {
		pos.* = meta.fork_data_offset;
		return Error.FileCrcMismatch;
	}
	var total: u64 = 0;
	if (resource_exists) total += meta.resource_uncompressed_len;
	if (data_exists) total += meta.data_uncompressed_len;
	return total;
}

/// Upper bound on verification threads, whatever the caller requests.
pub const verify_max_workers: usize = 64;
/// Worker count used for `workers == 0`: the CPU count, capped so a large
/// host does not trade tens of megabytes of thread stacks for little speedup
/// (one large entry bounds the wall time anyway).
pub const verify_default_max_workers: usize = 16;
/// Thread stack for verification workers. The LZH decoder state (window,
/// Huffman trees and lookup tables) needs about 45 KiB, but with libc linked
/// std.Thread.spawn rejects stacks under 1 MiB (error.Unexpected), and a
/// rejected spawn silently degrades to fewer workers. Untouched stack pages
/// cost no resident memory.
const verify_worker_stack_size: usize = 1024 * 1024;

/// Multithreaded `verifyStream` without a sink: after the header is read,
/// entries are verified concurrently, each worker with its own fixed buffers
/// (heap use is about `workers * 2 * verify_stream_buffer_size` plus the entry
/// table). The result, error and `error_offset` are identical to sequential
/// verification: the lowest-index failing entry wins. `source.readAtFn` is
/// called from several threads at once and must be thread-safe.
/// `workers == 0` uses the CPU count, capped at `verify_default_max_workers`.
pub fn verifyStreamParallel(
	allocator: std.mem.Allocator,
	source: RangeSource,
	strict_crc: bool,
	workers: usize,
	diag: ?*VerifyDiagnostics,
) Error!VerifySummary {
	var pos: u64 = 0;
	if (diag) |d| d.error_offset = null;
	return verifyParallelTracked(allocator, source, strict_crc, workers, &pos) catch |err| {
		if (diag) |d| d.error_offset = pos;
		return err;
	};
}

const EntryOutcome = struct {
	err: ?Error = null,
	pos: u64 = 0,
	bytes: u64 = 0,
};

/// Work queue shared by verification workers: an atomic next-entry counter
/// and the lowest failing index seen so far, so workers stop claiming entries
/// that cannot affect the result.
const ParallelVerify = struct {
	source: RangeSource,
	strict_crc: bool,
	entries: []const MetadataEntry,
	outcomes: []EntryOutcome,
	next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
	first_failure: std.atomic.Value(usize) = std.atomic.Value(usize).init(std.math.maxInt(usize)),
};

const VerifyWorker = struct {
	shared: *ParallelVerify,
	in_buf: []u8,
	out_buf: []u8,
};

fn runVerifyWorker(w: *VerifyWorker) void {
	const s = w.shared;
	while (true) {
		const i = s.next.fetchAdd(1, .monotonic);
		// Claims are increasing, so once past a known failure nothing later matters.
		if (i >= s.entries.len or i > s.first_failure.load(.monotonic)) return;
		var pos: u64 = 0;
		if (verifyEntry(s.source, w.in_buf, w.out_buf, s.entries[i], i, s.strict_crc, null, &pos)) |bytes| {
			s.outcomes[i] = .{ .bytes = bytes };
		} else |err| {
			s.outcomes[i] = .{ .err = err, .pos = pos };
			_ = s.first_failure.fetchMin(i, .monotonic);
		}
	}
}

fn verifyParallelTracked(
	allocator: std.mem.Allocator,
	source: RangeSource,
	strict_crc: bool,
	requested_workers: usize,
	pos: *u64,
) Error!VerifySummary {
	const header_buf = try allocator.alloc(u8, verify_stream_buffer_size);
	defer allocator.free(header_buf);
	const metadata = try readArchiveHeader(allocator, source, header_buf, strict_crc, pos);
	defer metadata.deinit(allocator);
	if (metadata.entries.len == 0) return .{ .entry_count = 0, .total_uncompressed = 0 };

	const wanted = if (requested_workers == 0) @min(std.Thread.getCpuCount() catch 1, verify_default_max_workers) else requested_workers;
	const worker_count = @max(1, @min(@min(wanted, verify_max_workers), metadata.entries.len));

	const outcomes = try allocator.alloc(EntryOutcome, metadata.entries.len);
	defer allocator.free(outcomes);
	@memset(outcomes, .{});
	const buffers = try allocator.alloc(u8, worker_count * 2 * verify_stream_buffer_size);
	defer allocator.free(buffers);
	const ctxs = try allocator.alloc(VerifyWorker, worker_count);
	defer allocator.free(ctxs);
	const threads = try allocator.alloc(std.Thread, worker_count);
	defer allocator.free(threads);

	var shared = ParallelVerify{ .source = source, .strict_crc = strict_crc, .entries = metadata.entries, .outcomes = outcomes };
	for (ctxs, 0..) |*ctx, w| {
		const base = w * 2 * verify_stream_buffer_size;
		ctx.* = .{
			.shared = &shared,
			.in_buf = buffers[base..][0..verify_stream_buffer_size],
			.out_buf = buffers[base + verify_stream_buffer_size ..][0..verify_stream_buffer_size],
		};
	}
	// Worker 0 runs on this thread, so progress never depends on spawning.
	var spawned: usize = 0;
	for (ctxs[1..]) |*ctx| {
		threads[spawned] = std.Thread.spawn(.{ .stack_size = verify_worker_stack_size }, runVerifyWorker, .{ctx}) catch break;
		spawned += 1;
	}
	runVerifyWorker(&ctxs[0]);
	for (threads[0..spawned]) |t| t.join();

	var total: u64 = 0;
	for (outcomes) |o| {
		if (o.err) |err| {
			pos.* = o.pos;
			return err;
		}
		total += o.bytes;
	}
	return .{ .entry_count = metadata.entries.len, .total_uncompressed = total };
}

const EncodedForks = struct {
	resource_encoded: []u8,
	data_encoded: []u8,
	resource_uncompressed_len: u32,
	data_uncompressed_len: u32,
	resource_compressed_len: u32,
	data_compressed_len: u32,
	flags: u16,
	file_crc: u32,

	fn deinit(self: EncodedForks, allocator: std.mem.Allocator) void {
		allocator.free(self.resource_encoded);
		allocator.free(self.data_encoded);
	}
};

const ForkEncoding = struct {
	bytes: []u8,
	compressed_len: u32,
	use_lzh: bool,
};

/// Minimal spinlock for short critical sections used by progress reporters.
/// Replaces `std.Thread.Mutex` (removed in Zig 0.16) without dragging the new
/// `std.Io.Mutex` plumbing across all worker entry points.
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

const CreateProgress = struct {
	callback: ?CreateArchiveProgressFn,
	ctx: ?*anyopaque,
	total_work: usize,
	done_work: usize = 0,
	mutex: SpinMutex = .{},

	fn init(callback: ?CreateArchiveProgressFn, ctx: ?*anyopaque, total_work_raw: usize) CreateProgress {
		return .{
			.callback = callback,
			.ctx = ctx,
			.total_work = if (total_work_raw == 0) 1 else total_work_raw,
		};
	}

	fn setDone(self: *CreateProgress, done: usize) void {
		self.mutex.lock();
		defer self.mutex.unlock();
		if (done >= self.total_work) {
			self.done_work = self.total_work;
		} else {
			self.done_work = done;
		}
		if (self.callback) |cb| cb(self.ctx, self.done_work, self.total_work);
	}
};

fn forkWorkUnits(raw_len: usize) usize {
	return std.math.mul(usize, raw_len, 2) catch std.math.maxInt(usize);
}

const ForkProgressCtx = struct {
	progress: *CreateProgress,
	base_work: usize,
	raw_len: usize,
};

fn onRleEncodeProgress(ctx_ptr: ?*anyopaque, done: usize, total: usize) void {
	if (ctx_ptr == null) return;
	const ctx: *ForkProgressCtx = @ptrCast(@alignCast(ctx_ptr.?));
	if (ctx.raw_len == 0) return;
	const scaled = if (total == 0) done else (std.math.mul(usize, done, ctx.raw_len) catch std.math.maxInt(usize)) / total;
	const step = if (scaled > ctx.raw_len) ctx.raw_len else scaled;
	const mapped = std.math.add(usize, ctx.base_work, step) catch std.math.maxInt(usize);
	ctx.progress.setDone(mapped);
}

fn onLzhEncodeProgress(ctx_ptr: ?*anyopaque, done: usize, total: usize) void {
	if (ctx_ptr == null) return;
	const ctx: *ForkProgressCtx = @ptrCast(@alignCast(ctx_ptr.?));
	if (ctx.raw_len == 0) return;
	const lzh_scaled = if (total == 0) done else (std.math.mul(usize, done, ctx.raw_len) catch std.math.maxInt(usize)) / total;
	const step = if (lzh_scaled > ctx.raw_len) ctx.raw_len else lzh_scaled;
	const with_rle = std.math.add(usize, ctx.base_work, ctx.raw_len) catch std.math.maxInt(usize);
	const mapped = std.math.add(usize, with_rle, step) catch std.math.maxInt(usize);
	ctx.progress.setDone(mapped);
}

fn encodeForkForArchive(
	allocator: std.mem.Allocator,
	raw: []const u8,
	progress: ?*CreateProgress,
	base_work: usize,
) Error!ForkEncoding {
	const use_progress = progress != null and raw.len > 0;
	var fork_progress = ForkProgressCtx{
		.progress = if (progress) |p| p else undefined,
		.base_work = base_work,
		.raw_len = raw.len,
	};
	const progress_ctx: ?*anyopaque = if (use_progress) @ptrCast(&fork_progress) else null;

	const rle_bytes = try rle8182.encodeWithProgress(
		allocator,
		raw,
		if (use_progress) onRleEncodeProgress else null,
		progress_ctx,
	);
	errdefer allocator.free(rle_bytes);
	const rle_len: u32 = @intCast(rle_bytes.len);
	if (progress) |p| p.setDone(std.math.add(usize, base_work, raw.len) catch std.math.maxInt(usize));
	if (rle_bytes.len == 0) {
		return .{
			.bytes = rle_bytes,
			.compressed_len = rle_len,
			.use_lzh = false,
		};
	}

	const lzh_bytes = try lzh.encodeWithWorkerLimitAndProgress(
		allocator,
		rle_bytes,
		0,
		if (use_progress) onLzhEncodeProgress else null,
		progress_ctx,
	);
	errdefer allocator.free(lzh_bytes);
	if (progress) |p| p.setDone(std.math.add(usize, base_work, forkWorkUnits(raw.len)) catch std.math.maxInt(usize));
	if (lzh_bytes.len < rle_bytes.len) {
		allocator.free(rle_bytes);
		return .{
			.bytes = lzh_bytes,
			.compressed_len = @intCast(lzh_bytes.len),
			.use_lzh = true,
		};
	}

	allocator.free(lzh_bytes);
	return .{
		.bytes = rle_bytes,
		.compressed_len = rle_len,
		.use_lzh = false,
	};
}

const PreparedEntry = struct {
	input: EntryInput,
	forks: EncodedForks,
	fork_data_offset: u32,
};

const TreeNode = struct {
	name: []const u8,
	is_dir: bool,
	file_index: ?usize,
	children: std.ArrayListUnmanaged(usize) = .empty,

	fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
		self.children.deinit(allocator);
	}
};

const TreeStats = struct {
	entries_meta_len: usize = 0,
	payload_len: usize = 0,
	file_order: std.ArrayListUnmanaged(usize) = .empty,

	fn deinit(self: *TreeStats, allocator: std.mem.Allocator) void {
		self.file_order.deinit(allocator);
	}
};

fn findChild(
	nodes: []const TreeNode,
	parent_idx: usize,
	name: []const u8,
	is_dir: bool,
) ?usize {
	for (nodes[parent_idx].children.items) |child_idx| {
		const child = nodes[child_idx];
		if (child.is_dir != is_dir) continue;
		if (std.mem.eql(u8, child.name, name)) return child_idx;
	}
	return null;
}

fn insertEntryPath(
	allocator: std.mem.Allocator,
	nodes: *std.ArrayListUnmanaged(TreeNode),
	entry_name: []const u8,
	file_index: usize,
) Error!void {
	var parent_idx: usize = 0;
	var cursor: usize = 0;
	if (entry_name.len == 0) return Error.InvalidEntryPath;
	if (entry_name[0] == '/' or entry_name[entry_name.len - 1] == '/') return Error.InvalidEntryPath;

	while (cursor < entry_name.len) {
		const sep = std.mem.indexOfScalarPos(u8, entry_name, cursor, '/') orelse entry_name.len;
		const part = entry_name[cursor..sep];
		if (part.len == 0) return Error.InvalidEntryPath;
		if (part.len > 127) return Error.InvalidNameLength;
		const last = sep == entry_name.len;
		const want_dir = !last;

		if (findChild(nodes.items, parent_idx, part, want_dir)) |found_idx| {
			if (last and !want_dir) return Error.DuplicateEntryPath;
			parent_idx = found_idx;
			cursor = sep + 1;
			continue;
		}
		if (!want_dir) {
			if (findChild(nodes.items, parent_idx, part, true) != null) return Error.InvalidEntryPath;
		} else {
			if (findChild(nodes.items, parent_idx, part, false) != null) return Error.InvalidEntryPath;
		}

		const new_idx = nodes.items.len;
		try nodes.append(allocator, .{
			.name = part,
			.is_dir = want_dir,
			.file_index = if (want_dir) null else file_index,
		});
		try nodes.items[parent_idx].children.append(allocator, new_idx);
		parent_idx = new_idx;
		cursor = sep + 1;
	}
}

fn measureTreeNode(
	allocator: std.mem.Allocator,
	nodes: []const TreeNode,
	node_idx: usize,
	prepared: []const PreparedEntry,
	stats: *TreeStats,
) Error!void {
	const node = nodes[node_idx];
	if (node.is_dir) {
		stats.entries_meta_len += 1 + node.name.len + 2;
		for (node.children.items) |child_idx| {
			try measureTreeNode(allocator, nodes, child_idx, prepared, stats);
		}
		return;
	}

	const prep = prepared[node.file_index.?];
	stats.entries_meta_len += 1 + node.name.len + 45;
	stats.payload_len += prep.forks.resource_encoded.len + prep.forks.data_encoded.len;
	try stats.file_order.append(allocator, node.file_index.?);
}

fn writeFileEntry(writer: *Writer, item: PreparedEntry, leaf_name: []const u8) void {
	writer.writeU8(@intCast(leaf_name.len));
	writer.writeSlice(leaf_name);
	writer.writeU8(1);
	writer.writeU32(item.fork_data_offset);
	writer.writeU32(item.input.file_type);
	writer.writeU32(item.input.creator);
	writer.writeU32(item.input.created);
	writer.writeU32(item.input.modified);
	writer.writeU16(item.input.finder_flags);
	writer.writeU32(item.forks.file_crc);
	writer.writeU16(item.forks.flags);
	writer.writeU32(item.forks.resource_uncompressed_len);
	writer.writeU32(item.forks.data_uncompressed_len);
	writer.writeU32(item.forks.resource_compressed_len);
	writer.writeU32(item.forks.data_compressed_len);
}

fn computeTreeEntryCounts(nodes: []const TreeNode, node_idx: usize, counts: []u32) Error!u32 {
	const node = nodes[node_idx];
	if (!node.is_dir) {
		counts[node_idx] = 1;
		return 1;
	}
	var total: u32 = 1;
	for (node.children.items) |child_idx| {
		const child_total = try computeTreeEntryCounts(nodes, child_idx, counts);
		total = std.math.add(u32, total, child_total) catch return Error.TooManyEntries;
	}
	counts[node_idx] = total;
	return total;
}

fn serializeTreeNode(
	writer: *Writer,
	nodes: []const TreeNode,
	entry_counts: []const u32,
	node_idx: usize,
	prepared: []const PreparedEntry,
) void {
	const node = nodes[node_idx];
	if (node.is_dir) {
		writer.writeU8(@as(u8, 0x80) | @as(u8, @intCast(node.name.len)));
		writer.writeSlice(node.name);
		const descendants = entry_counts[node_idx] - 1;
		writer.writeU16(@intCast(descendants));
		for (node.children.items) |child_idx| {
			serializeTreeNode(writer, nodes, entry_counts, child_idx, prepared);
		}
		return;
	}

	writeFileEntry(writer, prepared[node.file_index.?], node.name);
}

pub fn createArchive(
	allocator: std.mem.Allocator,
	entries: []const EntryInput,
	comment: []const u8,
) Error![]u8 {
	return try createArchiveWithProgress(allocator, entries, comment, null, null);
}

pub fn createArchiveWithProgress(
	allocator: std.mem.Allocator,
	entries: []const EntryInput,
	comment: []const u8,
	progress_cb: ?CreateArchiveProgressFn,
	progress_ctx: ?*anyopaque,
) Error![]u8 {
	if (entries.len > std.math.maxInt(u16)) return Error.TooManyEntries;
	if (comment.len > std.math.maxInt(u8)) return Error.CommentTooLong;

	var total_raw: usize = 0;
	for (entries) |entry| {
		const entry_raw = std.math.add(usize, entry.resource.len, entry.data.len) catch std.math.maxInt(usize);
		total_raw = std.math.add(usize, total_raw, entry_raw) catch std.math.maxInt(usize);
	}
	var progress = CreateProgress.init(progress_cb, progress_ctx, forkWorkUnits(total_raw));
	progress.setDone(0);
	var encoded_work_done: usize = 0;

	var prepared: std.ArrayListUnmanaged(PreparedEntry) = .empty;
	errdefer {
		for (prepared.items) |item| item.forks.deinit(allocator);
		prepared.deinit(allocator);
	}

	for (entries) |entry| {
		if (entry.name.len == 0) return Error.InvalidNameLength;
		const resource_encoded = try encodeForkForArchive(allocator, entry.resource, &progress, encoded_work_done);
		errdefer allocator.free(resource_encoded.bytes);
		encoded_work_done = std.math.add(usize, encoded_work_done, forkWorkUnits(entry.resource.len)) catch std.math.maxInt(usize);
		const data_encoded = try encodeForkForArchive(allocator, entry.data, &progress, encoded_work_done);
		errdefer allocator.free(data_encoded.bytes);
		encoded_work_done = std.math.add(usize, encoded_work_done, forkWorkUnits(entry.data.len)) catch std.math.maxInt(usize);

		const resource_len_u32: u32 = @intCast(entry.resource.len);
		const data_len_u32: u32 = @intCast(entry.data.len);
		var flags: u16 = 0;
		if (resource_encoded.use_lzh) flags |= flag_lzh_resource;
		if (data_encoded.use_lzh) flags |= flag_lzh_data;

		var file_crc = crc.update(crc.initial, entry.resource);
		file_crc = crc.update(file_crc, entry.data);

		try prepared.append(allocator, .{
			.input = entry,
			.forks = .{
				.resource_encoded = resource_encoded.bytes,
				.data_encoded = data_encoded.bytes,
				.resource_uncompressed_len = resource_len_u32,
				.data_uncompressed_len = data_len_u32,
				.resource_compressed_len = resource_encoded.compressed_len,
				.data_compressed_len = data_encoded.compressed_len,
				.flags = flags,
				.file_crc = file_crc,
			},
			.fork_data_offset = 0,
		});
	}

	var nodes: std.ArrayListUnmanaged(TreeNode) = .empty;
	errdefer {
		for (nodes.items) |*node| node.deinit(allocator);
		nodes.deinit(allocator);
	}
	try nodes.append(allocator, .{
		.name = "",
		.is_dir = true,
		.file_index = null,
	});
	for (prepared.items, 0..) |item, idx| {
		try insertEntryPath(allocator, &nodes, item.input.name, idx);
	}
	const entry_counts = try allocator.alloc(u32, nodes.items.len);
	defer allocator.free(entry_counts);
	@memset(entry_counts, 0);
	const root_total = try computeTreeEntryCounts(nodes.items, 0, entry_counts);
	const root_descendants = root_total - 1;
	if (root_descendants > std.math.maxInt(u16)) return Error.TooManyEntries;
	for (nodes.items, 0..) |node, idx| {
		if (!node.is_dir) continue;
		const descendants = entry_counts[idx] - 1;
		if (descendants > std.math.maxInt(u16)) return Error.TooManyEntries;
	}

	const preamble_len: usize = 8;
	const header_fixed_len: usize = 4 + 2 + 1 + comment.len;
	var stats = TreeStats{};
	defer stats.deinit(allocator);
	for (nodes.items[0].children.items) |child_idx| {
		try measureTreeNode(allocator, nodes.items, child_idx, prepared.items, &stats);
	}

	const payload_offset = preamble_len + header_fixed_len + stats.entries_meta_len;
	var cursor: usize = payload_offset;
	for (stats.file_order.items) |file_idx| {
		prepared.items[file_idx].fork_data_offset = @intCast(cursor);
		const item = prepared.items[file_idx];
		cursor += item.forks.resource_encoded.len + item.forks.data_encoded.len;
	}
	if (cursor > std.math.maxInt(u32)) return Error.OffsetOutOfRange;

	var out = try allocator.alloc(u8, cursor);
	errdefer allocator.free(out);
	@memset(out, 0);

	var writer = Writer{ .bytes = out, .index = 0 };
	writer.writeU8(0x01);
	writer.writeU8(1);
	writer.writeU16(0);
	writer.writeU32(8);

	const header_crc_at = writer.index;
	writer.writeU32(0);
	const crc_start = writer.index;
	writer.writeU16(@intCast(root_descendants));
	writer.writeU8(@intCast(comment.len));
	writer.writeSlice(comment);

	for (nodes.items[0].children.items) |child_idx| {
		serializeTreeNode(&writer, nodes.items, entry_counts, child_idx, prepared.items);
	}
	const crc_end = writer.index;

	for (stats.file_order.items) |file_idx| {
		const item = prepared.items[file_idx];
		writer.writeSlice(item.forks.resource_encoded);
		writer.writeSlice(item.forks.data_encoded);
	}

	const header_crc = crc.jamcrc(out[crc_start..crc_end]);
	std.mem.writeInt(u32, out[header_crc_at..][0..4], header_crc, .big);
	progress.setDone(progress.total_work);

	for (prepared.items) |item| item.forks.deinit(allocator);
	prepared.deinit(allocator);
	for (nodes.items) |*node| node.deinit(allocator);
	nodes.deinit(allocator);
	return out;
}

pub fn addEntries(
	allocator: std.mem.Allocator,
	archive: []const u8,
	additional: []const EntryInput,
) Error![]u8 {
	var extracted = try extractAll(allocator, archive, false);
	defer extracted.deinit(allocator);

	var combined: std.ArrayListUnmanaged(EntryInput) = .empty;
	defer combined.deinit(allocator);
	try combined.ensureTotalCapacity(allocator, extracted.entries.len + additional.len);

	for (extracted.entries) |entry| {
		try combined.append(allocator, .{
			.name = entry.name,
			.data = entry.data,
			.resource = entry.resource,
			.file_type = entry.file_type,
			.creator = entry.creator,
			.created = entry.created,
			.modified = entry.modified,
			.finder_flags = entry.finder_flags,
		});
	}
	for (additional) |entry| try combined.append(allocator, entry);

	return try createArchive(allocator, combined.items, extracted.comment);
}
