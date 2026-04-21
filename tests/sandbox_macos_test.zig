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
    );
    defer testing.allocator.free(profile);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(allow file-read*)") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/Cellar/foo/1.0\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/etc\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/var\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/share\")") != null);
    try testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/opt\")") != null);
}

test "renderRubyProfile refuses unsafe cellar path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt\"/evil", "/opt/malt"),
    );
}

test "renderRubyProfile refuses unsafe prefix path" {
    try testing.expectError(
        error.UnsafePath,
        sandbox.renderRubyProfile(testing.allocator, "/opt/malt/Cellar/foo/1.0", "/opt/m)alt"),
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

test "SANDBOX_PATH restricts to system directories only" {
    // Nothing in the minimal PATH should be user-writable.
    try testing.expectEqualStrings("/usr/bin:/bin:/usr/sbin:/sbin", sandbox.SANDBOX_PATH);
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

fn childProcessExists(pid: std.c.pid_t) bool {
    // `kill(pid, 0)` returns 0 while the pid still names a live or
    // zombie process we own; -1/ESRCH once it has been reaped.
    return std.c.kill(pid, @enumFromInt(0)) == 0;
}

test "spawnFilteredWithHooks reaps child when first reader-thread spawn fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const argv = [_][]const u8{"/usr/bin/true"};
    const argv_z = try sandbox.buildArgv(testing.allocator, argv[0..]);
    defer sandbox.freeArgv(testing.allocator, argv_z);

    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = "/tmp",
        .path = sandbox.SANDBOX_PATH,
        .malt_prefix = "/tmp",
        .tmpdir = "/tmp",
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    var obs: ReapObserver = .{};
    const result = sandbox.spawnFilteredWithHooks(argv_z, envp, .{}, .{
        .fail_thread_spawn_on = 0,
        .on_child_reaped = ReapObserver.cb,
        .ctx = &obs,
    });

    try testing.expectError(error.ForkFailed, result);
    try testing.expectEqual(@as(u32, 1), obs.call_count);
    try testing.expect(obs.reaped_pid > 0);
    // Process must be gone — the reap fix waited on it before returning.
    try testing.expect(!childProcessExists(obs.reaped_pid));
}

test "spawnFilteredWithHooks reaps child and joins out-thread when second spawn fails" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const argv = [_][]const u8{"/usr/bin/true"};
    const argv_z = try sandbox.buildArgv(testing.allocator, argv[0..]);
    defer sandbox.freeArgv(testing.allocator, argv_z);

    const envp = try sandbox.buildEnvp(testing.allocator, .{
        .home = "/tmp",
        .path = sandbox.SANDBOX_PATH,
        .malt_prefix = "/tmp",
        .tmpdir = "/tmp",
    });
    defer sandbox.freeEnvp(testing.allocator, envp);

    var obs: ReapObserver = .{};
    const result = sandbox.spawnFilteredWithHooks(argv_z, envp, .{}, .{
        .fail_thread_spawn_on = 1,
        .on_child_reaped = ReapObserver.cb,
        .ctx = &obs,
    });

    try testing.expectError(error.ForkFailed, result);
    try testing.expectEqual(@as(u32, 1), obs.call_count);
    try testing.expect(obs.reaped_pid > 0);
    try testing.expect(!childProcessExists(obs.reaped_pid));
}
