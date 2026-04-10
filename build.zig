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
            "-DSQLITE_DQS=0",
        },
    });
    exe.root_module.addIncludePath(b.path("vendor/"));
    exe.root_module.addIncludePath(b.path("c/"));

    b.installArtifact(exe);

    // Install "mt" as a copy of "malt" so both names work out of the box
    const mt_copy = b.addInstallBinFile(exe.getEmittedBin(), "mt");
    b.getInstallStep().dependOn(&mt_copy.step);

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
        "tests/cask_test.zig",
        "tests/cellar_test.zig",
        "tests/progress_test.zig",
        "tests/progress_e2e_test.zig",
        "tests/completions_test.zig",
        "tests/backup_test.zig",
    };

    const test_step = b.step("test", "Run all unit tests");

    // Shared library module — single root that re-exports all source modules.
    // This avoids "file exists in multiple modules" errors from Zig's module system.
    const malt_lib = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    malt_lib.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_DQS=0",
        },
    });
    malt_lib.addIncludePath(b.path("vendor/"));
    malt_lib.addIncludePath(b.path("c/"));
    malt_lib.addOptions("version_string", version_options);

    inline for (test_modules) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        // SQLite is already compiled in the malt_lib module — don't duplicate it here.
        t.root_module.addIncludePath(b.path("vendor/"));
        t.root_module.addIncludePath(b.path("c/"));
        t.root_module.addOptions("version_string", version_options);
        t.root_module.addImport("malt", malt_lib);

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
