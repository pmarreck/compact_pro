const std = @import("std");

pub fn build(b: *std.Build) void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseFast)") orelse .ReleaseFast;

	const ffi_module = b.createModule(.{
		.root_source_file = b.path("src/ffi.zig"),
		.target = target,
		.optimize = optimize,
	});

	const lib = b.addLibrary(.{
		.name = "compact_pro",
		.linkage = .static,
		.root_module = ffi_module,
	});
	lib.linkLibC();
	b.installArtifact(lib);

	const exe = b.addExecutable(.{
		.name = "compact-pro",
		.root_module = b.createModule(.{
			.root_source_file = b.path("src/main.zig"),
			.target = target,
			.optimize = optimize,
		}),
	});
	exe.addCSourceFile(.{
		.file = b.path("csrc/compact_pro_cli.c"),
		.flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
	});
	exe.addIncludePath(b.path("include"));
	exe.linkLibrary(lib);
	exe.linkLibC();
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
}
