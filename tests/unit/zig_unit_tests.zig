const std = @import("std");
const core = @import("core");

fn allocator() std.mem.Allocator {
	return std.testing.allocator;
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
