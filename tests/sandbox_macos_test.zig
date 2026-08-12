//! malt — sandbox/macos module tests
//!
//! Covers the profile renderer and path-safety guard. The fork/exec
//! path itself is integration-tested via a small Ruby fixture under
//! tests/fixtures/ (see sandbox_macos_exec_test.zig — TODO once the
//! Ruby interpreter is available in CI) — this file stays pure so it
//! runs without a Ruby toolchain.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const sandbox = @import("malt").sandbox_macos;
const test_io = @import("test_io");

test "validatePathForProfile accepts clean absolute paths" {
    try sandbox.validatePathForProfile("/opt/malt");
    try sandbox.validatePathForProfile("/opt/malt/Cellar/foo/1.2.3");
    try sandbox.validatePathForProfile("/tmp/x-y_z.0+1");
}

test "validatePathForProfile rejects SCL metacharacters" {
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/\"hack"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha(ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha)ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha\\ck"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("/tmp/ha\nck"));
}

test "validatePathForProfile rejects relative / empty" {
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile(""));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("relative"));
    try testing.expectError(error.UnsafePath, sandbox.validatePathForProfile("./also"));
}

test "renderRubyProfile deny-by-default, network denied, cellar + prefix subpaths allowed" {
    const profile = try sandbox.renderRubyProfile(
        testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
        .{},
    );
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow file-read*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny file-read-data") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/Users\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/System/Volumes/Data\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/Cellar/foo/1.0\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/etc\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/var\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/share\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/opt\")") != null);
    // lib is granted only at the two cache subtrees, never the whole farm.
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib/gdk-pixbuf-2.0\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib/gio\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib\")\n") == null);
    // IPC is opt-in; the default profile omits it.
    try testing.expect(std.mem.indexOf(u8, profile, "ipc-sysv-shm") == null);
}

test "renderRubyProfile grants IPC only under allow_ipc" {
    const profile = try sandbox.renderRubyProfile(
        testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
        .{ .allow_ipc = true },
    );
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-sysv-shm)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-posix-shm)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-sysv-sem)") != null);
}

test "renderRubyProfile refuses unsafe cellar path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt\"/evil", "/opt/malt", .{}),
    );
}

test "renderRubyProfile refuses unsafe prefix path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt/Cellar/foo/1.0", "/opt/m)alt", .{}),
    );
}

test "ScrubbedEnv type smoke — only allowlisted keys" {
    // Compile-time check: the struct has exactly the four allowed env
    // slots and nothing else. If someone ever adds a field here without
    // also thinking through the trust implications, this test fails.
    const info = @typeInfo(sandbox.ScrubbedEnv).@"struct";
    try testing.expectEqual(@as(usize, 4), info.fields.len);
    try testing.expectEqualStrings("home", info.fields[0].name);
    try testing.expectEqualStrings("path", info.fields[1].name);
    try testing.expectEqualStrings("malt_prefix", info.fields[2].name);
    try testing.expectEqualStrings("tmpdir", info.fields[3].name);
}

test "sandbox_path restricts to system directories only" {
    // Nothing in the minimal PATH should be user-writable.
    try testing.expectEqualStrings("/usr/bin:/bin:/usr/sbin:/sbin", sandbox.sandbox_path);
}

test "sandbox profile refuses copying a source from outside the prefix" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    const root = try test_io.uniqueTempPath(testing.allocator, "sandbox_macos", "read_source");
    defer testing.allocator.free(root);
    test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};

    const prefix = try std.fmt.allocPrint(testing.allocator, "{s}/prefix", .{root});
    defer testing.allocator.free(prefix);
    const keg = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/foo/1.0", .{prefix});
    defer testing.allocator.free(keg);
    const share = try std.fmt.allocPrint(testing.allocator, "{s}/share", .{prefix});
    defer testing.allocator.free(share);
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/private", .{root});
    defer testing.allocator.free(victim);
    const leaked = try std.fmt.allocPrint(testing.allocator, "{s}/leaked", .{share});
    defer testing.allocator.free(leaked);
    try test_io.cwd().createDirPath(std.Options.debug_io, keg);
    try test_io.cwd().createDirPath(std.Options.debug_io, share);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, victim, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "PRIVATE");
    }

    const profile = try sandbox.renderRubyProfile(testing.allocator, keg, prefix, .{});
    defer testing.allocator.free(profile);
    const argv = [_][]const u8{
        "/usr/bin/sandbox-exec", "-p", profile, "/bin/cp", victim, leaked,
    };
    const argv_z = try sandbox.buildArgv(testing.allocator, &argv);
    defer sandbox.freeArgv(testing.allocator, argv_z);
    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = prefix,
        .path = sandbox.sandbox_path,
        .malt_prefix = prefix,
        .tmpdir = prefix,
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    const sink = test_io.testSink();
    const exit_code = try sandbox.spawnFilteredWithHooks(
        argv_z,
        envp,
        .{},
        .{ .out = sink.handle, .err = sink.handle },
        .{},
    );
    try testing.expectError(
        error.FileNotFound,
        test_io.accessAbsolute(std.Options.debug_io, leaked, .{}),
    );
    try testing.expect(exit_code != 0);
}

test "std.posix.rlimit_resource tags resolve on macOS for CPU/FSIZE/AS" {
    // Pin: the three rlimit tags applyRlimits relies on must round-trip
    // through the kernel on macOS. If a stdlib rename ever loses one of
    // these, this test fails before fork/exec tests do.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    _ = try std.posix.getrlimit(.CPU);
    _ = try std.posix.getrlimit(.FSIZE);
    _ = try std.posix.getrlimit(.AS);
}

// Reap-on-error tests: drive the thread-spawn-failure path via the
// `SpawnHooks` injector and assert the parent reaped the child before
// returning. /usr/bin/true is a stable short-lived child on macOS — the
// exact binary does not matter since we're testing parent behaviour.

const ReapObserver = struct {
    reaped_pid: std.c.pid_t = -1,
    call_count: u32 = 0,
    fn cb(pid: std.c.pid_t, ctx: ?*anyopaque) void {
        // ctx is always &ReapObserver from the test caller below.
        const self: *ReapObserver = @ptrCast(@alignCast(ctx.?));
        self.reaped_pid = pid;
        self.call_count += 1;
    }
};

test "spawnFilteredWithHooks reaps child when first reader-thread spawn fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    const argv = [_][]const u8{"/usr/bin/true"};
    const argv_z = try sandbox.buildArgv(testing.allocator, argv[0..]);
    defer sandbox.freeArgv(testing.allocator, argv_z);

    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = "/tmp",
        .path = sandbox.sandbox_path,
        .malt_prefix = "/tmp",
        .tmpdir = "/tmp",
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    var obs: ReapObserver = .{};
    const result = sandbox.spawnFilteredWithHooks(argv_z, envp, .{}, .{}, .{
        .fail_thread_spawn_on = 0,
        .on_child_reaped = ReapObserver.cb,
        .ctx = &obs,
    });

    try testing.expectError(error.ForkFailed, result);
    try testing.expectEqual(@as(u32, 1), obs.call_count);
    try testing.expect(obs.reaped_pid > 0);
}

test "spawnFilteredWithHooks reaps child and joins out-thread when second spawn fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    const argv = [_][]const u8{"/usr/bin/true"};
    const argv_z = try sandbox.buildArgv(testing.allocator, argv[0..]);
    defer sandbox.freeArgv(testing.allocator, argv_z);

    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = "/tmp",
        .path = sandbox.sandbox_path,
        .malt_prefix = "/tmp",
        .tmpdir = "/tmp",
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    var obs: ReapObserver = .{};
    const result = sandbox.spawnFilteredWithHooks(argv_z, envp, .{}, .{}, .{
        .fail_thread_spawn_on = 1,
        .on_child_reaped = ReapObserver.cb,
        .ctx = &obs,
    });

    try testing.expectError(error.ForkFailed, result);
    try testing.expectEqual(@as(u32, 1), obs.call_count);
    try testing.expect(obs.reaped_pid > 0);
}

// Pin the Stdio seam: the filter loop must route child stderr to
// `stdio.err` rather than the parent's hardcoded fd 2 — tests rely on
// that to keep subprocess chatter out of the build runner's
// `result_error_msgs` (which would otherwise print a misleading
// `failed command:` against a passing test).
test "spawnFilteredWithHooks routes child stderr to the configured fd" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    const argv = [_][]const u8{ "/bin/sh", "-c", "printf %s err-via-fd >&2" };
    const argv_z = try sandbox.buildArgv(testing.allocator, argv[0..]);
    defer sandbox.freeArgv(testing.allocator, argv_z);

    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = "/tmp",
        .path = sandbox.sandbox_path,
        .malt_prefix = "/tmp",
        .tmpdir = "/tmp",
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(pipe_fds[0]);

    const exit = try sandbox.spawnFilteredWithHooks(
        argv_z,
        envp,
        .{},
        .{ .out = std.posix.STDOUT_FILENO, .err = pipe_fds[1] },
        .{},
    );
    // Drop the parent's write end so the read end sees EOF after the
    // filter thread closes its dup'd copy.
    _ = std.c.close(pipe_fds[1]);
    try testing.expectEqual(@as(u8, 0), exit);

    var buf: [128]u8 = undefined;
    const n = std.c.read(pipe_fds[0], &buf, buf.len);
    try testing.expect(n > 0);
    try testing.expectEqualStrings("err-via-fd", buf[0..@intCast(n)]);
}
