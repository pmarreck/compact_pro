const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	const ffi_module = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});

	const lib = b.addLibrary(.{
		.name = "compact_pro",
		.linkage = .static,
		.root_module = ffi_module,
	});
	b.installArtifact(lib);

	const exe_module = b.createModule(.{
		.root_source_file = b.path("src/main.zig"),
		.target = target,
		.optimize = optimize,
		.link_libc = true,
	});
	exe_module.addCSourceFile(.{
		.file = b.path("csrc/compact_pro_cli.c"),
		.flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
	});
	exe_module.addIncludePath(b.path("include"));
	// On macOS in Nix sandbox, Zig's C compiler needs the SDK sysroot for system headers (e.g. sys/xattr.h).
	if (target.result.os.tag == .macos) {
		if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
			exe_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdkroot}) });
		}
	}
	exe_module.linkLibrary(lib);

	const exe = b.addExecutable(.{
		.name = "compact-pro",
		.root_module = exe_module,
	});
	b.installArtifact(exe);

	const unit_tests = b.addTest(.{
		.root_module = b.createModule(.{
			.root_source_file = b.path("tests/unit/zig_unit_tests.zig"),
			.target = target,
			.optimize = optimize,
			.imports = &.{
				.{ .name = "core", .module = b.createModule(.{ .root_source_file = b.path("src/core.zig"), .target = target, .optimize = optimize }) },
			},
		}),
	});
	const run_unit = b.addRunArtifact(unit_tests);

	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_unit.step);

	// Inline tests live alongside the code they exercise (e.g. private Huffman /
	// match-finder helpers in lzh.zig that cannot be reached from the out-of-line
	// suite). Zig only runs a file's `test {}` blocks when that file's containing
	// module is analyzed, so register each leaf module as its own test root. We
	// root only the leaf modules (each imports just std, none imports another) to
	// run every inline test exactly once: rooting the upper layers (core/ffi)
	// would re-analyze these leaves transitively and double-run their tests.
	const inline_test_sources = [_][]const u8{
		"src/crc32jam.zig",
		"src/rle8182.zig",
		"src/lzh.zig",
	};
	for (inline_test_sources) |src_path| {
		const mod_tests = b.addTest(.{
			.root_module = b.createModule(.{
				.root_source_file = b.path(src_path),
				.target = target,
				.optimize = optimize,
				.link_libc = true,
			}),
		});
		test_step.dependOn(&b.addRunArtifact(mod_tests).step);
	}
}
