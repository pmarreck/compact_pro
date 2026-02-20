const std = @import("std");
const crc = @import("crc32jam.zig");
pub const lzh = @import("lzh.zig");
pub const rle8182 = @import("rle8182.zig");

pub const flag_encrypted: u16 = 0x0001;
pub const flag_lzh_resource: u16 = 0x0002;
pub const flag_lzh_data: u16 = 0x0004;

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
} || rle8182.Error || lzh.Error || std.mem.Allocator.Error;

const FileAccumulator = struct {
	allocator: std.mem.Allocator,
	items: std.ArrayListUnmanaged(MetadataEntry) = .{},

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
	const header_crc = try reader.readU32();
	const crc_start = reader.index;
	const entry_count = try reader.readU16();
	const comment_len = try reader.readU8();
	const comment_src = try reader.readSlice(comment_len);

	const comment = try allocator.alloc(u8, comment_src.len);
	@memcpy(comment, comment_src);
	errdefer allocator.free(comment);

	var acc = FileAccumulator{ .allocator = allocator };
	errdefer acc.deinit();
	try parseDirectoryEntries(allocator, &reader, &acc, "", entry_count);
	const crc_end = reader.index;

	if (strict_crc) {
		const computed = crc.jamcrc(archive[crc_start..crc_end]);
		if (computed != header_crc) return Error.HeaderCrcMismatch;
	}

	return .{
		.comment = comment,
		.entries = try acc.items.toOwnedSlice(allocator),
	};
}

fn parseDirectoryEntries(
	allocator: std.mem.Allocator,
	reader: *Reader,
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
		errdefer allocator.free(full_name);

		if (is_dir) {
			const descendants = try reader.readU16();
			const subtree_count: usize = @as(usize, descendants) + 1;
			if (subtree_count > remaining) return Error.InvalidEntryCount;
			defer allocator.free(full_name);
			try parseDirectoryEntries(allocator, reader, acc, full_name, @intCast(descendants));
			remaining -= subtree_count;
			continue;
		}

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

	var out_entries: std.ArrayListUnmanaged(ExtractedEntry) = .{};
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

		const data_offset = meta.fork_data_offset + meta.resource_compressed_len;
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

fn encodeForkForArchive(allocator: std.mem.Allocator, raw: []const u8) Error!ForkEncoding {
	const rle_bytes = try rle8182.encode(allocator, raw);
	errdefer allocator.free(rle_bytes);
	const rle_len: u32 = @intCast(rle_bytes.len);
	if (rle_bytes.len == 0) {
		return .{
			.bytes = rle_bytes,
			.compressed_len = rle_len,
			.use_lzh = false,
		};
	}

	const lzh_bytes = try lzh.encode(allocator, rle_bytes);
	errdefer allocator.free(lzh_bytes);
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
	children: std.ArrayListUnmanaged(usize) = .{},

	fn deinit(self: *TreeNode, allocator: std.mem.Allocator) void {
		self.children.deinit(allocator);
	}
};

const TreeStats = struct {
	entries_meta_len: usize = 0,
	payload_len: usize = 0,
	file_order: std.ArrayListUnmanaged(usize) = .{},

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
	if (entries.len > std.math.maxInt(u16)) return Error.TooManyEntries;
	if (comment.len > std.math.maxInt(u8)) return Error.CommentTooLong;

	var prepared: std.ArrayListUnmanaged(PreparedEntry) = .{};
	errdefer {
		for (prepared.items) |item| item.forks.deinit(allocator);
		prepared.deinit(allocator);
	}

	for (entries) |entry| {
		if (entry.name.len == 0) return Error.InvalidNameLength;
		const resource_encoded = try encodeForkForArchive(allocator, entry.resource);
		errdefer allocator.free(resource_encoded.bytes);
		const data_encoded = try encodeForkForArchive(allocator, entry.data);
		errdefer allocator.free(data_encoded.bytes);

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

	var nodes: std.ArrayListUnmanaged(TreeNode) = .{};
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

	var combined: std.ArrayListUnmanaged(EntryInput) = .{};
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
