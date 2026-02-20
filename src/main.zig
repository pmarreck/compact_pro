const std = @import("std");

extern fn compact_pro_cli_main(argc: c_int, argv: [*]const [*:0]u8) c_int;

pub fn main() !void {
	if (comptime @import("builtin").mode == .Debug) {
		var stderr_buf: [4096]u8 = undefined;
		var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
		const stderr = &stderr_writer.interface;
		try stderr.writeAll("\x1b[33mDEBUG BUILD\x1b[0m\n");
		try stderr.flush();
	}

	const argv = try std.process.argsAlloc(std.heap.c_allocator);
	defer std.process.argsFree(std.heap.c_allocator, argv);

	var argvz: [][*:0]u8 = try std.heap.c_allocator.alloc([*:0]u8, argv.len);
	defer std.heap.c_allocator.free(argvz);
	for (argv, 0..) |arg, idx| {
		const duped = try std.heap.c_allocator.allocSentinel(u8, arg.len, 0);
		@memcpy(duped[0..arg.len], arg);
		argvz[idx] = duped.ptr;
	}
	defer {
		for (argvz) |arg| std.heap.c_allocator.free(std.mem.span(arg));
	}

	const rc = compact_pro_cli_main(@intCast(argv.len), argvz.ptr);
	if (rc != 0) return error.CliFailed;
}
