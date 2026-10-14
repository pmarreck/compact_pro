const std = @import("std");
const core = @import("core");

fn allocator() std.mem.Allocator {
	return std.testing.allocator;
}

/// In-memory range source that serves at most `max_chunk` bytes per call, so
/// buffer-refill boundaries inside the streaming decoders get exercised.
const MemorySource = struct {
	bytes: []const u8,
	max_chunk: usize = std.math.maxInt(usize),
	fail_at_or_after: ?u64 = null,
	reads: usize = 0,

	fn readAt(ctx: ?*anyopaque, offset: u64, buf: []u8) core.ReadError!usize {
		const self: *MemorySource = @ptrCast(@alignCast(ctx.?));
		self.reads += 1;
		if (self.fail_at_or_after) |limit| {
			if (offset + buf.len > limit) return error.ReadFailed;
		}
		if (offset >= self.bytes.len) return 0;
		const start: usize = @intCast(offset);
		const n = @min(@min(buf.len, self.max_chunk), self.bytes.len - start);
		@memcpy(buf[0..n], self.bytes[start..][0..n]);
		return n;
	}

	fn source(self: *MemorySource) core.RangeSource {
		return .{ .ctx = self, .size = self.bytes.len, .readAtFn = readAt };
	}
};

/// Sink that reassembles every fork so it can be compared with extractAll.
const CollectSink = struct {
	gpa: std.mem.Allocator,
	data: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,
	resource: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u8)) = .empty,
	abort_after_bytes: ?usize = null,
	seen: usize = 0,

	fn write(ctx: ?*anyopaque, entry_index: usize, fork: core.ForkKind, bytes: []const u8) core.SinkError!void {
		const self: *CollectSink = @ptrCast(@alignCast(ctx.?));
		self.seen += bytes.len;
		if (self.abort_after_bytes) |limit| {
			if (self.seen > limit) return error.SinkAborted;
		}
		const list = switch (fork) {
			.data => &self.data,
			.resource => &self.resource,
		};
		while (list.items.len <= entry_index) list.append(self.gpa, .empty) catch return error.SinkAborted;
		list.items[entry_index].appendSlice(self.gpa, bytes) catch return error.SinkAborted;
	}

	fn sink(self: *CollectSink) core.ForkSink {
		return .{ .ctx = self, .writeFn = write };
	}

	fn forkBytes(list: []const std.ArrayListUnmanaged(u8), index: usize) []const u8 {
		if (index >= list.len) return &.{};
		return list[index].items;
	}

	fn deinit(self: *CollectSink) void {
		for (self.data.items) |*l| l.deinit(self.gpa);
		for (self.resource.items) |*l| l.deinit(self.gpa);
		self.data.deinit(self.gpa);
		self.resource.deinit(self.gpa);
	}
};

/// Allocator wrapper recording peak live bytes, used to prove bounded memory.
const PeakAllocator = struct {
	child: std.mem.Allocator,
	live: usize = 0,
	peak: usize = 0,

	fn allocator(self: *PeakAllocator) std.mem.Allocator {
		return .{ .ptr = self, .vtable = &.{
			.alloc = alloc,
			.resize = resize,
			.remap = remap,
			.free = free,
		} };
	}

	fn note(self: *PeakAllocator, old: usize, new: usize) void {
		self.live = self.live - old + new;
		if (self.live > self.peak) self.peak = self.live;
	}

	fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
		const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
		const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
		self.note(0, len);
		return p;
	}

	fn resize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
		const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
		if (!self.child.rawResize(mem, alignment, new_len, ra)) return false;
		self.note(mem.len, new_len);
		return true;
	}

	fn remap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
		const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
		const p = self.child.rawRemap(mem, alignment, new_len, ra) orelse return null;
		self.note(mem.len, new_len);
		return p;
	}

	fn free(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
		const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
		self.child.rawFree(mem, alignment, ra);
		self.note(mem.len, 0);
	}
};

fn buildSampleArchive(gpa: std.mem.Allocator) ![]u8 {
	// Mix of an RLE-only fork, an LZH-winning fork, escape bytes and an empty
	// file, nested under a directory, so both decoders and the header walker run.
	var lzh_friendly: [600]u8 = undefined;
	for (&lzh_friendly, 0..) |*b, i| b.* = "the quick brown fox "[i % 20];
	const entries = [_]core.EntryInput{
		.{ .name = "dir/a.bin", .data = &[_]u8{ 0x81, 0x82, 0x00, 0x81, 0x81, 0x41, 0x41, 0x41, 0x41, 0x41, 0x42 }, .resource = "rsrc" },
		.{ .name = "dir/text.txt", .data = &lzh_friendly, .resource = &.{} },
		.{ .name = "empty", .data = &.{}, .resource = &.{} },
	};
	return core.createArchive(gpa, &entries, "comment");
}

const Outcome = union(enum) {
	ok,
	err: anyerror,
};

fn bufferedOutcome(archive: []const u8) Outcome {
	var extracted = core.extractAll(allocator(), archive, true) catch |e| return .{ .err = e };
	extracted.deinit(allocator());
	return .ok;
}

fn streamOutcome(archive: []const u8, max_chunk: usize) Outcome {
	var src = MemorySource{ .bytes = archive, .max_chunk = max_chunk };
	_ = core.verifyStream(allocator(), src.source(), true, null) catch |e| return .{ .err = e };
	return .ok;
}

fn expectSameOutcome(archive: []const u8, max_chunk: usize) !void {
	const want = bufferedOutcome(archive);
	const got = streamOutcome(archive, max_chunk);
	switch (want) {
		.ok => switch (got) {
			.ok => {},
			.err => |e| {
				std.debug.print("buffered ok, stream {s}\n", .{@errorName(e)});
				return error.TestUnexpectedResult;
			},
		},
		.err => |we| switch (got) {
			.ok => {
				std.debug.print("buffered {s}, stream ok\n", .{@errorName(we)});
				return error.TestUnexpectedResult;
			},
			.err => |ge| if (we != ge) {
				std.debug.print("buffered {s}, stream {s}\n", .{ @errorName(we), @errorName(ge) });
				return error.TestUnexpectedResult;
			},
		},
	}
}

fn expectSinkMatchesExtract(archive: []const u8, max_chunk: usize) !void {
	var extracted = try core.extractAll(allocator(), archive, true);
	defer extracted.deinit(allocator());

	var src = MemorySource{ .bytes = archive, .max_chunk = max_chunk };
	var collect = CollectSink{ .gpa = allocator() };
	defer collect.deinit();
	const summary = try core.verifyStream(allocator(), src.source(), true, collect.sink());

	try std.testing.expectEqual(extracted.entries.len, summary.entry_count);
	var total: u64 = 0;
	for (extracted.entries, 0..) |entry, i| {
		try std.testing.expectEqualSlices(u8, entry.data, CollectSink.forkBytes(collect.data.items, i));
		try std.testing.expectEqualSlices(u8, entry.resource, CollectSink.forkBytes(collect.resource.items, i));
		total += entry.data.len + entry.resource.len;
	}
	try std.testing.expectEqual(total, summary.total_uncompressed);
}

test "verifyStream sink output equals extractAll for a mixed RLE/LZH archive" {
	const archive = try buildSampleArchive(allocator());
	defer allocator().free(archive);
	try expectSinkMatchesExtract(archive, std.math.maxInt(usize));
	try expectSinkMatchesExtract(archive, 1);
	try expectSinkMatchesExtract(archive, 7);
}

test "verifyStream sink output equals extractAll for the MacEnvy LZH fixture" {
	const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/cpt/MacEnvy21.cpt", allocator(), .limited(1024 * 1024));
	defer allocator().free(fixture);
	try expectSinkMatchesExtract(fixture, std.math.maxInt(usize));
	try expectSinkMatchesExtract(fixture, 13);
}

test "verifyStream matches extractAll outcome for every single-bit flip of a small archive" {
	const archive = try buildSampleArchive(allocator());
	defer allocator().free(archive);
	const work = try allocator().dupe(u8, archive);
	defer allocator().free(work);

	var rejected: usize = 0;
	for (0..work.len) |byte_index| {
		for (0..8) |bit| {
			const mask = @as(u8, 1) << @intCast(bit);
			work[byte_index] ^= mask;
			defer work[byte_index] ^= mask;
			try expectSameOutcome(work, 5);
			if (bufferedOutcome(work) != .ok) rejected += 1;
		}
	}
	// Specificity control: the pristine archive verifies, and the sweep is not
	// vacuous (most flips must be rejected by the CRC-protected format).
	try expectSameOutcome(archive, 5);
	try std.testing.expect(rejected > work.len * 8 / 2);
}

test "verifyStream matches extractAll outcome for sampled bit flips of the LZH fixture" {
	const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "fixtures/cpt/MacEnvy21.cpt", allocator(), .limited(1024 * 1024));
	defer allocator().free(fixture);
	var prng = std.Random.DefaultPrng.init(0xC0A1_7E57);
	const rand = prng.random();
	for (0..300) |_| {
		const byte_index = rand.uintLessThan(usize, fixture.len);
		const mask = @as(u8, 1) << rand.int(u3);
		fixture[byte_index] ^= mask;
		defer fixture[byte_index] ^= mask;
		try expectSameOutcome(fixture, 4096);
	}
}

test "verifyStream matches extractAll outcome for every truncation of a small archive" {
	const archive = try buildSampleArchive(allocator());
	defer allocator().free(archive);
	for (0..archive.len) |len| {
		try expectSameOutcome(archive[0..len], 3);
	}
}

test "verifyStream reports encrypted entries like extractAll" {
	const entries = [_]core.EntryInput{.{ .name = "x", .data = "payload", .resource = &.{} }};
	const archive = try core.createArchive(allocator(), &entries, "");
	defer allocator().free(archive);
	// Record layout after the 1-byte name: volume, offset, type, creator,
	// created, modified (1+4*5), finder flags (2), file crc (4), then flags.
	const header_off: usize = std.mem.readInt(u32, archive[4..8], .big);
	const flags_at = header_off + 4 + 2 + 1 + 1 + 1 + 21 + 2 + 4;
	archive[flags_at + 1] |= @intCast(core.flag_encrypted);
	// Header CRC now mismatches, so compare non-strict outcomes.
	try std.testing.expectError(error.UnsupportedEncryptedEntry, core.extractAll(allocator(), archive, false));
	var src = MemorySource{ .bytes = archive };
	try std.testing.expectError(error.UnsupportedEncryptedEntry, core.verifyStream(allocator(), src.source(), false, null));
}

test "verifyStream propagates read failures and sink aborts" {
	const archive = try buildSampleArchive(allocator());
	defer allocator().free(archive);

	var failing = MemorySource{ .bytes = archive, .fail_at_or_after = 20 };
	try std.testing.expectError(error.ReadFailed, core.verifyStream(allocator(), failing.source(), true, null));

	var src = MemorySource{ .bytes = archive };
	var collect = CollectSink{ .gpa = allocator(), .abort_after_bytes = 4 };
	defer collect.deinit();
	try std.testing.expectError(error.SinkAborted, core.verifyStream(allocator(), src.source(), true, collect.sink()));
}

test "verifyStream peak memory stays bounded while extractAll grows with fork size" {
	const fork_len: usize = 4 * 1024 * 1024;
	const raw = try allocator().alloc(u8, fork_len);
	defer allocator().free(raw);
	var prng = std.Random.DefaultPrng.init(42);
	const rand = prng.random();
	// Compressible but not trivially so, so the LZH path is exercised.
	for (raw, 0..) |*b, i| b.* = if (i % 64 < 48) @truncate(i / 64) else rand.int(u8);
	const entries = [_]core.EntryInput{.{ .name = "big.bin", .data = raw, .resource = &.{} }};
	const archive = try core.createArchive(allocator(), &entries, "");
	defer allocator().free(archive);

	var stream_peak = PeakAllocator{ .child = allocator() };
	var src = MemorySource{ .bytes = archive };
	const summary = try core.verifyStream(stream_peak.allocator(), src.source(), true, null);
	try std.testing.expectEqual(@as(u64, fork_len), summary.total_uncompressed);

	var buffered_peak = PeakAllocator{ .child = allocator() };
	var extracted = try core.extractAll(buffered_peak.allocator(), archive, true);
	extracted.deinit(buffered_peak.allocator());

	// Control: the counter sees the buffered path hold the whole fork.
	try std.testing.expect(buffered_peak.peak >= fork_len);
	try std.testing.expect(stream_peak.peak <= core.verify_stream_memory_budget);
	try std.testing.expect(core.verify_stream_memory_budget < fork_len / 8);
}

test "data fork offset overflow is OffsetOutOfRange on both paths (regression)" {
	// fork_data_offset + resource_compressed_len used to be a wrapping u32 add,
	// silently pointing the data fork at the start of the archive.
	const entries = [_]core.EntryInput{.{ .name = "x", .data = "payload", .resource = &.{} }};
	const archive = try core.createArchive(allocator(), &entries, "");
	defer allocator().free(archive);
	const header_off: usize = std.mem.readInt(u32, archive[4..8], .big);
	const record = header_off + 4 + 2 + 1 + 1 + 1; // volume byte of the "x" record
	std.mem.writeInt(u32, archive[record + 1 ..][0..4], 0xFFFF_FFF0, .big); // fork_data_offset
	const lens = record + 21 + 2 + 4 + 2; // resource_uncompressed_len
	std.mem.writeInt(u32, archive[lens + 8 ..][0..4], 0x20, .big); // resource_compressed_len
	try std.testing.expectError(error.OffsetOutOfRange, core.extractAll(allocator(), archive, false));
	var src = MemorySource{ .bytes = archive };
	try std.testing.expectError(error.OffsetOutOfRange, core.verifyStream(allocator(), src.source(), false, null));
}
