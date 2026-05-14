const std = @import("std");

extern fn compact_pro_cli_main(argc: c_int, argv: [*]const [*:0]u8) c_int;

pub fn main(init: std.process.Init) !void {
	if (comptime @import("builtin").mode == .Debug) {
		var stderr_buf: [4096]u8 = undefined;
		var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
		const stderr = &stderr_writer.interface;
		try stderr.writeAll("\x1b[33mDEBUG BUILD\x1b[0m\n");
		try stderr.flush(init.io);
	}

	const arena_alloc = init.arena.allocator();
	const argv = try init.minimal.args.toSlice(arena_alloc);

	// The C FFI entry point wants `[*]const [*:0]u8`. `Args.toSlice` already
	// yields `[]const [:0]const u8` (NUL-terminated argv entries) in argv[i].
	// Build a `[*:0]u8`-compatible pointer array by stripping the `const` —
	// the C side does not modify these strings.
	var argvz: [][*:0]u8 = try arena_alloc.alloc([*:0]u8, argv.len);
	for (argv, 0..) |arg, idx| {
		argvz[idx] = @constCast(arg.ptr);
	}

	const rc = compact_pro_cli_main(@intCast(argv.len), argvz.ptr);
	if (rc != 0) return error.CliFailed;
}
