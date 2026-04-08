const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Version from .version file ---
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", @embedFile(".version"));

    // --- Main executable: mt ---
    const exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("version_string", version_options);

    // Compile vendored SQLite amalgamation
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_THREADSAFE=1",
        },
    });
    exe.root_module.addIncludePath(b.path("vendor/"));
    exe.root_module.addIncludePath(b.path("c/"));

    b.installArtifact(exe);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the mt binary");
    run_step.dependOn(&run_cmd.step);

    // --- Unit tests ---
    const test_modules = .{
        "tests/formula_test.zig",
        "tests/deps_test.zig",
        "tests/macho_test.zig",
        "tests/store_test.zig",
        "tests/linker_test.zig",
        "tests/rollback_test.zig",
        "tests/run_test.zig",
        "tests/version_update_test.zig",
    };

    const test_step = b.step("test", "Run all unit tests");

    inline for (test_modules) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        t.root_module.addCSourceFile(.{
            .file = b.path("vendor/sqlite3.c"),
            .flags = &.{
                "-DSQLITE_OMIT_LOAD_EXTENSION",
                "-DSQLITE_THREADSAFE=1",
            },
        });
        t.root_module.addIncludePath(b.path("vendor/"));
        t.root_module.addIncludePath(b.path("c/"));

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // --- Universal binary step (macOS only) ---
    const universal_step = b.step("universal", "Build universal binary (arm64 + x86_64) via lipo");

    const arm64_exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos }),
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    arm64_exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=1" },
    });
    arm64_exe.root_module.addIncludePath(b.path("vendor/"));
    arm64_exe.root_module.addIncludePath(b.path("c/"));
    arm64_exe.root_module.addOptions("version_string", version_options);

    const x86_exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos }),
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    x86_exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=1" },
    });
    x86_exe.root_module.addIncludePath(b.path("vendor/"));
    x86_exe.root_module.addIncludePath(b.path("c/"));
    x86_exe.root_module.addOptions("version_string", version_options);

    const lipo = b.addSystemCommand(&.{"lipo"});
    lipo.addArtifactArg(arm64_exe);
    lipo.addArtifactArg(x86_exe);
    lipo.addArgs(&.{ "-create", "-output" });
    const universal_output = lipo.addOutputFileArg("malt");

    const install_universal = b.addInstallBinFile(universal_output, "malt");
    universal_step.dependOn(&install_universal.step);
}
