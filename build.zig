const std = @import("std");

const TranslatedCModules = struct {
    c_sqlite: *std.Build.Module,
    c_clonefile: *std.Build.Module,
    c_mount: *std.Build.Module,
};

// addTranslateC binds the target at creation time, so universal builds
// (which compile the same sources for two arches) need their own set.
fn addTranslatedCModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) TranslatedCModules {
    const c_sqlite = b.addTranslateC(.{
        .root_source_file = b.path("c/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    c_sqlite.addIncludePath(b.path("vendor/"));

    const c_clonefile = b.addTranslateC(.{
        .root_source_file = b.path("c/clonefile.h"),
        .target = target,
        .optimize = optimize,
    });

    const c_mount = b.addTranslateC(.{
        .root_source_file = b.path("c/mount.h"),
        .target = target,
        .optimize = optimize,
    });

    return .{
        .c_sqlite = c_sqlite.createModule(),
        .c_clonefile = c_clonefile.createModule(),
        .c_mount = c_mount.createModule(),
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(
        bool,
        "strip",
        "Strip debug info from release binaries (default: true for non-Debug)",
    ) orelse (optimize != .Debug);

    // --- Version from .version file ---
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", @embedFile(".version"));

    // Zig 0.16 prefers build-system `addTranslateC` over inline `@cImport`:
    // each header is translated once per build graph instead of once per
    // root source file.
    const host_c_mods = addTranslatedCModules(b, target, optimize);

    // --- Main executable: mt ---
    const exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });
    exe.root_module.addOptions("version_string", version_options);
    exe.root_module.addImport("c_sqlite", host_c_mods.c_sqlite);
    exe.root_module.addImport("c_clonefile", host_c_mods.c_clonefile);
    exe.root_module.addImport("c_mount", host_c_mods.c_mount);

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
        "tests/purge_test.zig",
        "tests/install_test.zig",
        "tests/deps_leak_test.zig",
        "tests/api_test.zig",
        "tests/clonefile_test.zig",
        "tests/dsl_lexer_test.zig",
        "tests/dsl_parser_test.zig",
        "tests/dsl_sandbox_test.zig",
        "tests/dsl_interpreter_test.zig",
        "tests/db_schema_v2_test.zig",
        "tests/bundle_manifest_test.zig",
        "tests/bundle_brewfile_test.zig",
        "tests/services_plist_test.zig",
        "tests/services_test.zig",
        "tests/bundle_test.zig",
        "tests/atomic_test.zig",
        "tests/lock_test.zig",
        "tests/tap_test.zig",
        "tests/values_test.zig",
        "tests/fallback_log_test.zig",
        "tests/help_test.zig",
        "tests/bottle_verify_test.zig",
        "tests/archive_test.zig",
        "tests/ghcr_test.zig",
        "tests/linker_core_test.zig",
        "tests/supervisor_pure_test.zig",
        "tests/install_pure_test.zig",
        "tests/dsl_builtins_test.zig",
        "tests/ruby_subprocess_test.zig",
        "tests/pins_test.zig",
        "tests/sandbox_macos_test.zig",
        "tests/services_validate_test.zig",
        "tests/spawn_invariant_test.zig",
        "tests/net_client_test.zig",
        "tests/term_sanitize_test.zig",
        "tests/perms_test.zig",
        "tests/cli_tap_test.zig",
        "tests/cli_services_test.zig",
        "tests/install_execute_test.zig",
        "tests/cask_extra_test.zig",
        "tests/dsl_interpreter_extra_test.zig",
        "tests/list_test.zig",
        "tests/search_test.zig",
        "tests/info_test.zig",
        "tests/uses_test.zig",
        "tests/output_test.zig",
        "tests/worker_arena_test.zig",
    };

    const test_step = b.step("test", "Run all unit tests");
    const test_bin_step = b.step("test-bin", "Install test binaries for coverage (kcov)");

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
    malt_lib.addImport("c_sqlite", host_c_mods.c_sqlite);
    malt_lib.addImport("c_clonefile", host_c_mods.c_clonefile);
    malt_lib.addImport("c_mount", host_c_mods.c_mount);

    @setEvalBranchQuota(16000);
    inline for (test_modules) |test_file| {
        // e.g. "tests/formula_test.zig" → "formula_test" (so each test binary
        // has a unique install name, which `test-bin` / kcov need).
        const test_name = comptime std.fs.path.stem(std.fs.path.basename(test_file));

        const t = b.addTest(.{
            .name = test_name,
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

        // Only installed when the user asks for `zig build test-bin`
        // (used by the coverage recipe and the coverage CI job).
        const install_t = b.addInstallArtifact(t, .{
            .dest_dir = .{ .override = .{ .custom = "test-bin" } },
        });
        test_bin_step.dependOn(&install_t.step);
    }

    // --- Universal binary step (macOS only) ---
    const universal_step = b.step("universal", "Build universal binary (arm64 + x86_64) via lipo");

    const arm64_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });
    const arm64_c_mods = addTranslatedCModules(b, arm64_target, optimize);
    const x86_c_mods = addTranslatedCModules(b, x86_target, optimize);

    const arm64_exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = arm64_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });
    arm64_exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=1" },
    });
    arm64_exe.root_module.addIncludePath(b.path("vendor/"));
    arm64_exe.root_module.addIncludePath(b.path("c/"));
    arm64_exe.root_module.addOptions("version_string", version_options);
    arm64_exe.root_module.addImport("c_sqlite", arm64_c_mods.c_sqlite);
    arm64_exe.root_module.addImport("c_clonefile", arm64_c_mods.c_clonefile);
    arm64_exe.root_module.addImport("c_mount", arm64_c_mods.c_mount);

    const x86_exe = b.addExecutable(.{
        .name = "malt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = x86_target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });
    x86_exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_THREADSAFE=1" },
    });
    x86_exe.root_module.addIncludePath(b.path("vendor/"));
    x86_exe.root_module.addIncludePath(b.path("c/"));
    x86_exe.root_module.addOptions("version_string", version_options);
    x86_exe.root_module.addImport("c_sqlite", x86_c_mods.c_sqlite);
    x86_exe.root_module.addImport("c_clonefile", x86_c_mods.c_clonefile);
    x86_exe.root_module.addImport("c_mount", x86_c_mods.c_mount);

    const lipo = b.addSystemCommand(&.{"lipo"});
    lipo.addArtifactArg(arm64_exe);
    lipo.addArtifactArg(x86_exe);
    lipo.addArgs(&.{ "-create", "-output" });
    const universal_output = lipo.addOutputFileArg("malt");

    const install_universal = b.addInstallBinFile(universal_output, "malt");
    universal_step.dependOn(&install_universal.step);

    // Ship the `mt` alias alongside the universal binary so the
    // release tarball contains both names — matches the default
    // `zig build` install layout and what the README promises.
    const install_universal_mt = b.addInstallBinFile(universal_output, "mt");
    universal_step.dependOn(&install_universal_mt.step);
}
