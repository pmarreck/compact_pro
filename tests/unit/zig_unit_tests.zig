const std = @import("std");
const core = @import("core");

fn allocator() std.mem.Allocator {
	return std.testing.allocator;
}

fn readU16BE(bytes: []const u8, at: usize) u16 {
	return (@as(u16, bytes[at]) << 8) | @as(u16, bytes[at + 1]);
}

fn readU32BE(bytes: []const u8, at: usize) u32 {
	return (@as(u32, bytes[at]) << 24) |
		(@as(u32, bytes[at + 1]) << 16) |
		(@as(u32, bytes[at + 2]) << 8) |
		@as(u32, bytes[at + 3]);
}

test "rle decode literal and run extension" {
	const encoded = [_]u8{ 0x41, 0x81, 0x82, 0x05 };
	const decoded = try core.rle8182.decode(allocator(), &encoded, 5, true);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, "AAAAA", decoded);
}

test "rle roundtrip with escape bytes" {
	const raw = [_]u8{ 0x81, 0x82, 0x81, 0x33, 0x81 };
	const encoded = try core.rle8182.encode(allocator(), &raw);
	defer allocator().free(encoded);
	const decoded = try core.rle8182.decode(allocator(), encoded, raw.len, true);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, &raw, decoded);
}

test "rle encode compresses repeated non escape bytes" {
	const raw = "AAAAAAAAAA";
	const encoded = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(encoded);
	try std.testing.expect(encoded.len < raw.len);
	try std.testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x81, 0x82, 0x0A }, encoded);

	const decoded = try core.rle8182.decode(allocator(), encoded, raw.len, true);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

test "rle roundtrip handles triple 0x81 before 0x82" {
	const raw = [_]u8{ 0x9B, 0x9F, 0x82, 0x47, 0x6A, 0x51, 0x71, 0x49, 0x62, 0x8E, 0x82, 0x9B, 0x91, 0x81, 0x81, 0x81, 0x82, 0xA1, 0x99, 0x92 };
	const encoded = try core.rle8182.encode(allocator(), &raw);
	defer allocator().free(encoded);
	const decoded = try core.rle8182.decode(allocator(), encoded, raw.len, true);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, &raw, decoded);
}

test "rle encode boundaries for literal run and escape transitions" {
	const raw = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x13, 0x13, 0x13, 0x13, 0x20, 0x81, 0x82 };
	const encoded = try core.rle8182.encode(allocator(), &raw);
	defer allocator().free(encoded);
	try std.testing.expectEqualSlices(u8, &[_]u8{
		0x10, 0x11, 0x12,
		0x13, 0x81, 0x82, 0x05,
		0x20,
		0x81, 0x82, 0x00,
	}, encoded);
	const decoded = try core.rle8182.decode(allocator(), encoded, raw.len, true);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, &raw, decoded);
}

test "lzh roundtrip over rle payload" {
	const segment = "ABCDEFGH01234567";
	const repeat_count = 8192;
	const raw = try allocator().alloc(u8, segment.len * repeat_count);
	defer allocator().free(raw);
	for (0..repeat_count) |i| {
		const at = i * segment.len;
		@memcpy(raw[at .. at + segment.len], segment);
	}

	const rle_payload = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(rle_payload);
	try std.testing.expect(rle_payload.len > 0);

	const lzh_payload = try core.lzh.encode(allocator(), rle_payload);
	defer allocator().free(lzh_payload);
	const decoded = try core.lzh.decode(allocator(), lzh_payload, raw.len);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

test "lzh roundtrip over multi block payload" {
	const len = 200_000;
	const raw = try allocator().alloc(u8, len);
	defer allocator().free(raw);

	var x: u32 = 0x1234ABCD;
	for (raw) |*b| {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		b.* = @truncate(x);
	}

	const rle_payload = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(rle_payload);
	try std.testing.expect(rle_payload.len > 70_000);

	const lzh_payload = try core.lzh.encode(allocator(), rle_payload);
	defer allocator().free(lzh_payload);
	const decoded = try core.lzh.decode(allocator(), lzh_payload, raw.len);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

test "lzh encode output is deterministic across worker limits" {
	const len = 350_000;
	const raw = try allocator().alloc(u8, len);
	defer allocator().free(raw);

	var x: u32 = 0xA5C3_9E17;
	for (raw) |*b| {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		b.* = @truncate(x);
	}

	const rle_payload = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(rle_payload);
	try std.testing.expect(rle_payload.len > 70_000);

	const single = try core.lzh.encodeWithWorkerLimit(allocator(), rle_payload, 1);
	defer allocator().free(single);
	const parallel = try core.lzh.encodeWithWorkerLimit(allocator(), rle_payload, 4);
	defer allocator().free(parallel);
	try std.testing.expectEqualSlices(u8, single, parallel);

	const decoded = try core.lzh.decode(allocator(), parallel, raw.len);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

test "lzh encode output is deterministic across worker limits for multi-segment payload" {
	const len = 20_500_000;
	const raw = try allocator().alloc(u8, len);
	defer allocator().free(raw);

	var x: u32 = 0x9E37_79B9;
	for (raw) |*b| {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		b.* = @truncate(x);
	}

	const rle_payload = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(rle_payload);
	try std.testing.expect(rle_payload.len > 16_500_000);

	const single = try core.lzh.encodeWithWorkerLimit(allocator(), rle_payload, 1);
	defer allocator().free(single);
	const parallel = try core.lzh.encodeWithWorkerLimit(allocator(), rle_payload, 4);
	defer allocator().free(parallel);

	try std.testing.expectEqualSlices(u8, single, parallel);

	const decoded = try core.lzh.decode(allocator(), parallel, raw.len);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

const LzhProgressProbe = struct {
	call_count: usize = 0,
	last_done: usize = 0,
	total: usize = 0,
	stage_two_threshold: usize = 0,
	saw_stage_two: bool = false,
	monotonic: bool = true,
};

fn lzhProgressProbe(ctx: ?*anyopaque, done: usize, total: usize) void {
	if (ctx == null) return;
	const probe: *LzhProgressProbe = @ptrCast(@alignCast(ctx.?));
	probe.call_count += 1;
	if (done < probe.last_done) probe.monotonic = false;
	probe.last_done = done;
	probe.total = total;
	if (done > probe.stage_two_threshold) probe.saw_stage_two = true;
}

test "lzh progress callback advances through token and encode phases" {
	const len = 500_000;
	const raw = try allocator().alloc(u8, len);
	defer allocator().free(raw);

	var x: u32 = 0xC01D_F00D;
	for (raw) |*b| {
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		b.* = @truncate(x);
	}

	const rle_payload = try core.rle8182.encode(allocator(), raw);
	defer allocator().free(rle_payload);

	var probe = LzhProgressProbe{
		.stage_two_threshold = rle_payload.len,
	};

	const encoded = try core.lzh.encodeWithWorkerLimitAndProgress(
		allocator(),
		rle_payload,
		4,
		lzhProgressProbe,
		&probe,
	);
	defer allocator().free(encoded);

	const expected_total = rle_payload.len * 2;
	try std.testing.expect(probe.call_count > 2);
	try std.testing.expect(probe.monotonic);
	try std.testing.expectEqual(@as(usize, expected_total), probe.total);
	try std.testing.expectEqual(@as(usize, expected_total), probe.last_done);
	try std.testing.expect(probe.saw_stage_two);

	const decoded = try core.lzh.decode(allocator(), encoded, raw.len);
	defer allocator().free(decoded);
	try std.testing.expectEqualSlices(u8, raw, decoded);
}

test "archive create sets lzh data flag when lzh wins" {
	const segment = "LZH-PATTERN-0123456789";
	const repeat_count = 16384;
	const data = try allocator().alloc(u8, segment.len * repeat_count);
	defer allocator().free(data);
	for (0..repeat_count) |i| {
		const at = i * segment.len;
		@memcpy(data[at .. at + segment.len], segment);
	}

	const rle_data = try core.rle8182.encode(allocator(), data);
	defer allocator().free(rle_data);
	try std.testing.expect(rle_data.len > 0);

	const entries = [_]core.EntryInput{
		.{ .name = "data.bin", .data = data, .resource = &.{} },
	};
	const archive = try core.createArchive(allocator(), &entries, "");
	defer allocator().free(archive);

	const meta = try core.parseMetadata(allocator(), archive, true);
	defer meta.deinit(allocator());
	try std.testing.expectEqual(@as(usize, 1), meta.entries.len);
	try std.testing.expect((meta.entries[0].flags & core.flag_lzh_data) != 0);
	try std.testing.expect(meta.entries[0].data_compressed_len < @as(u32, @intCast(rle_data.len)));

	var extracted = try core.extractAll(allocator(), archive, true);
	defer extracted.deinit(allocator());
	try std.testing.expectEqualSlices(u8, data, extracted.entries[0].data);
}

test "archive create and extract roundtrip" {
	const entries = [_]core.EntryInput{
		.{ .name = "hello.txt", .data = "hello compact pro", .resource = "rsrc" },
		.{ .name = "notes.md", .data = "second file", .resource = &.{} },
	};

	const archive = try core.createArchive(allocator(), &entries, "test-comment");
	defer allocator().free(archive);

	var extracted = try core.extractAll(allocator(), archive, true);
	defer extracted.deinit(allocator());

	try std.testing.expectEqual(@as(usize, 2), extracted.entries.len);
	try std.testing.expectEqualSlices(u8, "hello.txt", extracted.entries[0].name);
	try std.testing.expectEqualSlices(u8, "hello compact pro", extracted.entries[0].data);
	try std.testing.expectEqualSlices(u8, "rsrc", extracted.entries[0].resource);
	try std.testing.expectEqualSlices(u8, "notes.md", extracted.entries[1].name);
	try std.testing.expectEqualSlices(u8, "second file", extracted.entries[1].data);
}

test "archive add entries preserves old and appends new" {
	const initial = [_]core.EntryInput{
		.{ .name = "a.bin", .data = "A", .resource = &.{} },
	};
	const append = [_]core.EntryInput{
		.{ .name = "b.bin", .data = "B", .resource = "R" },
	};

	const archive1 = try core.createArchive(allocator(), &initial, "");
	defer allocator().free(archive1);
	const archive2 = try core.addEntries(allocator(), archive1, &append);
	defer allocator().free(archive2);

	var extracted = try core.extractAll(allocator(), archive2, true);
	defer extracted.deinit(allocator());
	try std.testing.expectEqual(@as(usize, 2), extracted.entries.len);
	try std.testing.expectEqualSlices(u8, "a.bin", extracted.entries[0].name);
	try std.testing.expectEqualSlices(u8, "b.bin", extracted.entries[1].name);
}

test "archive parse fixture header" {
	const fixture = try std.fs.cwd().readFileAlloc(allocator(), "fixtures/cpt/MacEnvy21.cpt", 1024 * 1024);
	defer allocator().free(fixture);

	const meta = try core.parseMetadata(allocator(), fixture, false);
	defer meta.deinit(allocator());
	try std.testing.expect(meta.entries.len > 0);
}

test "archive extract fixture with lzh resource fork" {
	const fixture = try std.fs.cwd().readFileAlloc(allocator(), "fixtures/cpt/MacEnvy21.cpt", 1024 * 1024);
	defer allocator().free(fixture);

	var extracted = try core.extractAll(allocator(), fixture, true);
	defer extracted.deinit(allocator());
	try std.testing.expectEqual(@as(usize, 1), extracted.entries.len);
	try std.testing.expectEqualSlices(u8, "MacEnvy", extracted.entries[0].name);
	try std.testing.expectEqual(@as(usize, 0), extracted.entries[0].data.len);
	try std.testing.expectEqual(@as(usize, 36336), extracted.entries[0].resource.len);
	var digest: [32]u8 = undefined;
	std.crypto.hash.sha2.Sha256.hash(extracted.entries[0].resource, &digest, .{});
	try std.testing.expectEqualSlices(u8, &[_]u8{
		0x71, 0x68, 0x93, 0x6e, 0x8b, 0x51, 0xb8, 0xe5,
		0xeb, 0x5e, 0xa0, 0x29, 0xcc, 0x7a, 0xb4, 0xb4,
		0x3d, 0x12, 0x6c, 0x0a, 0x0c, 0x6e, 0xf8, 0x11,
		0x62, 0x3e, 0x78, 0x72, 0xea, 0xe8, 0xf7, 0xcb,
	}, &digest);
}

test "archive writer uses compact pro entry count semantics" {
	const entries = [_]core.EntryInput{
		.{ .name = "a/b/c.txt", .data = "x", .resource = &.{} },
	};
	const archive = try core.createArchive(allocator(), &entries, "");
	defer allocator().free(archive);

	const header_off = readU32BE(archive, 4);
	var i: usize = @intCast(header_off);
	_ = readU32BE(archive, i); // header crc
	i += 4;
	const top_count = readU16BE(archive, i);
	i += 2;
	try std.testing.expectEqual(@as(u16, 3), top_count);
	const comment_len = archive[i];
	i += 1 + comment_len;

	try std.testing.expectEqual(@as(u8, 0x80 | 1), archive[i]); // "a" directory
	i += 1;
	try std.testing.expectEqual(@as(u8, 'a'), archive[i]);
	i += 1;
	const a_desc = readU16BE(archive, i);
	i += 2;
	try std.testing.expectEqual(@as(u16, 2), a_desc);

	try std.testing.expectEqual(@as(u8, 0x80 | 1), archive[i]); // "b" directory
	i += 1;
	try std.testing.expectEqual(@as(u8, 'b'), archive[i]);
	i += 1;
	const b_desc = readU16BE(archive, i);
	try std.testing.expectEqual(@as(u16, 1), b_desc);
}

test "archive header crc changes when entry metadata changes" {
	const entries_a = [_]core.EntryInput{
		.{ .name = "a.txt", .data = "x", .resource = &.{} },
	};
	const entries_b = [_]core.EntryInput{
		.{ .name = "b.txt", .data = "x", .resource = &.{} },
	};
	const archive_a = try core.createArchive(allocator(), &entries_a, "");
	defer allocator().free(archive_a);
	const archive_b = try core.createArchive(allocator(), &entries_b, "");
	defer allocator().free(archive_b);

	const off_a = readU32BE(archive_a, 4);
	const off_b = readU32BE(archive_b, 4);
	const crc_a = readU32BE(archive_a, @intCast(off_a));
	const crc_b = readU32BE(archive_b, @intCast(off_b));
	try std.testing.expect(crc_a != crc_b);
}
