const std = @import("std");
const core = @import("core.zig");

const allocator = std.heap.c_allocator;

pub const CpEntryInput = extern struct {
	name_ptr: ?[*]const u8,
	name_len: usize,
	data_ptr: ?[*]const u8,
	data_len: usize,
	resource_ptr: ?[*]const u8,
	resource_len: usize,
	file_type: u32,
	creator: u32,
	created: u32,
	modified: u32,
	finder_flags: u16,
};

pub const CpBuffer = extern struct {
	ptr: ?[*]u8,
	len: usize,
};

pub const CpEntryOutput = extern struct {
	name_ptr: ?[*]u8,
	name_len: usize,
	data_ptr: ?[*]u8,
	data_len: usize,
	resource_ptr: ?[*]u8,
	resource_len: usize,
	file_type: u32,
	creator: u32,
	created: u32,
	modified: u32,
	finder_flags: u16,
};

pub const CpArchiveOutput = extern struct {
	comment_ptr: ?[*]u8,
	comment_len: usize,
	entries_ptr: ?[*]CpEntryOutput,
	entry_count: usize,
};

pub const CpListEntry = extern struct {
	name_ptr: ?[*]u8,
	name_len: usize,
	resource_uncompressed_len: u32,
	data_uncompressed_len: u32,
	flags: u16,
};

pub const CpArchiveListing = extern struct {
	comment_ptr: ?[*]u8,
	comment_len: usize,
	entries_ptr: ?[*]CpListEntry,
	entry_count: usize,
};

pub const CpProgressFn = ?*const fn (?*anyopaque, usize, usize) callconv(.c) void;

const ConversionError = error{ InvalidArgument } || std.mem.Allocator.Error;

const cp_ok = 0;
const cp_err_invalid_argument = 1;
const cp_err_invalid_marker = 2;
const cp_err_truncated = 3;
const cp_err_invalid_header_offset = 4;
const cp_err_header_crc_mismatch = 5;
const cp_err_unsupported_encrypted = 6;
const cp_err_unsupported_lzh = 7;
const cp_err_invalid_name_length = 8;
const cp_err_too_many_entries = 9;
const cp_err_comment_too_long = 10;
const cp_err_offset_out_of_range = 11;
const cp_err_file_crc_mismatch = 12;
const cp_err_invalid_run_length_one = 13;
const cp_err_output_length_mismatch = 14;
const cp_err_unexpected_end_of_stream = 15;
const cp_err_out_of_memory = 100;
const cp_err_unknown = 255;

fn mapError(err: anyerror) c_int {
	return switch (err) {
		error.InvalidArgument => cp_err_invalid_argument,
		error.InvalidMarker => cp_err_invalid_marker,
		error.Truncated => cp_err_truncated,
		error.InvalidHeaderOffset => cp_err_invalid_header_offset,
		error.HeaderCrcMismatch => cp_err_header_crc_mismatch,
		error.UnsupportedEncryptedEntry => cp_err_unsupported_encrypted,
		error.UnsupportedLzhEntry => cp_err_unsupported_lzh,
		error.InvalidNameLength => cp_err_invalid_name_length,
		error.TooManyEntries => cp_err_too_many_entries,
		error.CommentTooLong => cp_err_comment_too_long,
		error.OffsetOutOfRange => cp_err_offset_out_of_range,
		error.FileCrcMismatch => cp_err_file_crc_mismatch,
		error.InvalidRunLengthOne => cp_err_invalid_run_length_one,
		error.OutputLengthMismatch => cp_err_output_length_mismatch,
		error.UnexpectedEndOfStream => cp_err_unexpected_end_of_stream,
		error.OutOfMemory => cp_err_out_of_memory,
		else => cp_err_unknown,
	};
}

fn toConstSlice(ptr: ?[*]const u8, len: usize) ConversionError![]const u8 {
	if (len == 0) return &.{};
	if (ptr == null) return error.InvalidArgument;
	return ptr.?[0..len];
}

fn toMutableSlice(ptr: ?[*]u8, len: usize) ?[]u8 {
	if (len == 0 or ptr == null) return null;
	return ptr.?[0..len];
}

fn clearBuffer(out: *CpBuffer) void {
	out.ptr = null;
	out.len = 0;
}

fn clearArchiveOutput(out: *CpArchiveOutput) void {
	out.comment_ptr = null;
	out.comment_len = 0;
	out.entries_ptr = null;
	out.entry_count = 0;
}

fn clearArchiveListing(out: *CpArchiveListing) void {
	out.comment_ptr = null;
	out.comment_len = 0;
	out.entries_ptr = null;
	out.entry_count = 0;
}

fn convertInputs(c_entries: ?[*]const CpEntryInput, count: usize) ConversionError![]core.EntryInput {
	if (count == 0) return try allocator.alloc(core.EntryInput, 0);
	if (c_entries == null) return error.InvalidArgument;

	const out = try allocator.alloc(core.EntryInput, count);
	errdefer allocator.free(out);
	for (0..count) |idx| {
		const src = c_entries.?[idx];
		out[idx] = .{
			.name = try toConstSlice(src.name_ptr, src.name_len),
			.data = try toConstSlice(src.data_ptr, src.data_len),
			.resource = try toConstSlice(src.resource_ptr, src.resource_len),
			.file_type = src.file_type,
			.creator = src.creator,
			.created = src.created,
			.modified = src.modified,
			.finder_flags = src.finder_flags,
		};
	}
	return out;
}

pub export fn cp_archive_create_with_progress(
	c_entries: ?[*]const CpEntryInput,
	entry_count: usize,
	comment_ptr: ?[*]const u8,
	comment_len: usize,
	out_archive: ?*CpBuffer,
	progress_cb: CpProgressFn,
	progress_ctx: ?*anyopaque,
) c_int {
	if (out_archive == null) return cp_err_invalid_argument;
	clearBuffer(out_archive.?);

	const comment = toConstSlice(comment_ptr, comment_len) catch |err| return mapError(err);
	const entries = convertInputs(c_entries, entry_count) catch |err| return mapError(err);
	defer allocator.free(entries);

	const bytes = core.createArchiveWithProgress(allocator, entries, comment, progress_cb, progress_ctx) catch |err| return mapError(err);
	out_archive.?.ptr = if (bytes.len == 0) null else bytes.ptr;
	out_archive.?.len = bytes.len;
	return cp_ok;
}

pub export fn cp_archive_create(
	c_entries: ?[*]const CpEntryInput,
	entry_count: usize,
	comment_ptr: ?[*]const u8,
	comment_len: usize,
	out_archive: ?*CpBuffer,
) c_int {
	return cp_archive_create_with_progress(
		c_entries,
		entry_count,
		comment_ptr,
		comment_len,
		out_archive,
		null,
		null,
	);
}

pub export fn cp_archive_add(
	archive_ptr: ?[*]const u8,
	archive_len: usize,
	c_entries: ?[*]const CpEntryInput,
	entry_count: usize,
	out_archive: ?*CpBuffer,
) c_int {
	if (out_archive == null) return cp_err_invalid_argument;
	clearBuffer(out_archive.?);

	const archive = toConstSlice(archive_ptr, archive_len) catch |err| return mapError(err);
	const entries = convertInputs(c_entries, entry_count) catch |err| return mapError(err);
	defer allocator.free(entries);

	const bytes = core.addEntries(allocator, archive, entries) catch |err| return mapError(err);
	out_archive.?.ptr = if (bytes.len == 0) null else bytes.ptr;
	out_archive.?.len = bytes.len;
	return cp_ok;
}

pub export fn cp_archive_extract(
	archive_ptr: ?[*]const u8,
	archive_len: usize,
	strict_crc: c_int,
	out_archive: ?*CpArchiveOutput,
) c_int {
	if (out_archive == null) return cp_err_invalid_argument;
	clearArchiveOutput(out_archive.?);

	const archive = toConstSlice(archive_ptr, archive_len) catch |err| return mapError(err);
	var extracted = core.extractAll(allocator, archive, strict_crc != 0) catch |err| return mapError(err);

	var c_entries: []CpEntryOutput = &.{};
	if (extracted.entries.len > 0) {
		c_entries = allocator.alloc(CpEntryOutput, extracted.entries.len) catch |err| {
			extracted.deinit(allocator);
			return mapError(err);
		};
	}
	errdefer if (c_entries.len > 0) allocator.free(c_entries);

	for (extracted.entries, 0..) |entry, idx| {
		c_entries[idx] = .{
			.name_ptr = if (entry.name.len == 0) null else entry.name.ptr,
			.name_len = entry.name.len,
			.data_ptr = if (entry.data.len == 0) null else entry.data.ptr,
			.data_len = entry.data.len,
			.resource_ptr = if (entry.resource.len == 0) null else entry.resource.ptr,
			.resource_len = entry.resource.len,
			.file_type = entry.file_type,
			.creator = entry.creator,
			.created = entry.created,
			.modified = entry.modified,
			.finder_flags = entry.finder_flags,
		};
	}

	const entries_meta = extracted.entries;
	out_archive.?.comment_ptr = if (extracted.comment.len == 0) null else extracted.comment.ptr;
	out_archive.?.comment_len = extracted.comment.len;
	out_archive.?.entries_ptr = if (c_entries.len == 0) null else c_entries.ptr;
	out_archive.?.entry_count = c_entries.len;
	allocator.free(entries_meta);
	return cp_ok;
}

pub export fn cp_archive_list(
	archive_ptr: ?[*]const u8,
	archive_len: usize,
	strict_crc: c_int,
	out_listing: ?*CpArchiveListing,
) c_int {
	if (out_listing == null) return cp_err_invalid_argument;
	clearArchiveListing(out_listing.?);

	const archive = toConstSlice(archive_ptr, archive_len) catch |err| return mapError(err);
	const parsed = core.parseMetadata(allocator, archive, strict_crc != 0) catch |err| return mapError(err);

	var c_entries: []CpListEntry = &.{};
	if (parsed.entries.len > 0) {
		c_entries = allocator.alloc(CpListEntry, parsed.entries.len) catch |err| {
			parsed.deinit(allocator);
			return mapError(err);
		};
	}
	errdefer if (c_entries.len > 0) allocator.free(c_entries);

	for (parsed.entries, 0..) |entry, idx| {
		c_entries[idx] = .{
			.name_ptr = if (entry.name.len == 0) null else entry.name.ptr,
			.name_len = entry.name.len,
			.resource_uncompressed_len = entry.resource_uncompressed_len,
			.data_uncompressed_len = entry.data_uncompressed_len,
			.flags = entry.flags,
		};
	}

	const entry_meta = parsed.entries;
	out_listing.?.comment_ptr = if (parsed.comment.len == 0) null else parsed.comment.ptr;
	out_listing.?.comment_len = parsed.comment.len;
	out_listing.?.entries_ptr = if (c_entries.len == 0) null else c_entries.ptr;
	out_listing.?.entry_count = c_entries.len;
	allocator.free(entry_meta);
	return cp_ok;
}

pub export fn cp_buffer_free(buffer: ?*CpBuffer) void {
	if (buffer == null) return;
	if (toMutableSlice(buffer.?.ptr, buffer.?.len)) |slice| allocator.free(slice);
	clearBuffer(buffer.?);
}

pub export fn cp_archive_output_free(archive: ?*CpArchiveOutput) void {
	if (archive == null) return;
	if (archive.?.entries_ptr) |entries_ptr| {
		const entries = entries_ptr[0..archive.?.entry_count];
		for (entries) |entry| {
			if (toMutableSlice(entry.name_ptr, entry.name_len)) |name| allocator.free(name);
			if (toMutableSlice(entry.data_ptr, entry.data_len)) |data| allocator.free(data);
			if (toMutableSlice(entry.resource_ptr, entry.resource_len)) |resource| allocator.free(resource);
		}
		allocator.free(entries);
	}
	if (toMutableSlice(archive.?.comment_ptr, archive.?.comment_len)) |comment| allocator.free(comment);
	clearArchiveOutput(archive.?);
}

pub export fn cp_archive_listing_free(listing: ?*CpArchiveListing) void {
	if (listing == null) return;
	if (listing.?.entries_ptr) |entries_ptr| {
		const entries = entries_ptr[0..listing.?.entry_count];
		for (entries) |entry| {
			if (toMutableSlice(entry.name_ptr, entry.name_len)) |name| allocator.free(name);
		}
		allocator.free(entries);
	}
	if (toMutableSlice(listing.?.comment_ptr, listing.?.comment_len)) |comment| allocator.free(comment);
	clearArchiveListing(listing.?);
}

pub export fn cp_error_string(code: c_int) [*:0]const u8 {
	return switch (code) {
		cp_ok => "ok",
		cp_err_invalid_argument => "invalid argument",
		cp_err_invalid_marker => "invalid marker",
		cp_err_truncated => "truncated archive",
		cp_err_invalid_header_offset => "invalid header offset",
		cp_err_header_crc_mismatch => "header crc mismatch",
		cp_err_unsupported_encrypted => "unsupported encrypted entry",
		cp_err_unsupported_lzh => "unsupported lzh entry",
		cp_err_invalid_name_length => "invalid entry name length",
		cp_err_too_many_entries => "too many entries",
		cp_err_comment_too_long => "comment too long",
		cp_err_offset_out_of_range => "offset out of range",
		cp_err_file_crc_mismatch => "file crc mismatch",
		cp_err_invalid_run_length_one => "invalid run length one",
		cp_err_output_length_mismatch => "output length mismatch",
		cp_err_unexpected_end_of_stream => "unexpected end of stream",
		cp_err_out_of_memory => "out of memory",
		else => "unknown error",
	};
}
