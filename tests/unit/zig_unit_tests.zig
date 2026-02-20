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
