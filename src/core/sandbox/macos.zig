//! malt — macOS sandbox-exec wrapper for `--use-system-ruby` post_install.
//! Confines writes, blocks network, scrubs env, and clamps resource limits.

const std = @import("std");
const builtin = @import("builtin");
const term_sanitize = @import("../../ui/term_sanitize.zig");

pub const SandboxError = error{
    SandboxUnsupported,
    UnsafePath,
    ProfileBuildFailed,
    EnvBuildFailed,
    ForkFailed,
    RlimitFailed,
    WaitFailed,
    ChildSignaled,
    ChildCrashed,
    ChildExited,
};

/// Resource caps applied before `execve`. Conservative defaults.
pub const Limits = struct {
    /// Wall-clock CPU seconds (user+system).
    cpu_seconds: u64 = 300,
    /// RLIMIT_AS ceiling.
    address_space_bytes: u64 = 2 * 1024 * 1024 * 1024,
    /// RLIMIT_FSIZE per-file cap.
    file_size_bytes: u64 = 512 * 1024 * 1024,
};

/// Allowlist propagated to the child; DYLD_* and RUBYOPT/RUBYLIB are dropped.
pub const ScrubbedEnv = struct {
    home: []const u8,
    path: []const u8,
    malt_prefix: []const u8,
    tmpdir: []const u8,
};

/// Minimal PATH — keeps a hostile formula off user-owned bin prefixes.
pub const sandbox_path: []const u8 = "/usr/bin:/bin:/usr/sbin:/sbin";

/// Where the sandboxed child's stdout/stderr land. Production passes the
/// process's real fd 1/2; tests redirect to `/dev/null` so subprocess
/// chatter doesn't leak past `output.beginStderrCapture` into the build
/// runner's `result_error_msgs` (which would print a misleading
/// `failed command:` against a passing test).
pub const Stdio = struct {
    out: c_int = std.posix.STDOUT_FILENO,
    err: c_int = std.posix.STDERR_FILENO,
};

/// Reject any byte that could break out of a `(subpath "...")` token.
pub fn validatePathForProfile(p: []const u8) SandboxError!void {
    if (p.len == 0 or p[0] != '/') return SandboxError.UnsafePath;
    for (p) |c| switch (c) {
        0, '"', '\\', '(', ')', '\n', '\r' => return SandboxError.UnsafePath,
        else => {},
    };
}

/// Per-spawn profile knobs. `allow_ipc` is opt-in for the database
/// initialisers only — every other fenced child stays IPC-free.
pub const ProfileOpts = struct {
    allow_ipc: bool = false,
};

/// Render the deny-by-default SCL profile; writes limited to `cellar_path`
/// and a fixed set of `malt_prefix` subtrees. Caller owns the slice.
pub fn renderRubyProfile(
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    opts: ProfileOpts,
) SandboxError![]const u8 {
    try validatePathForProfile(cellar_path);
    try validatePathForProfile(malt_prefix);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    const header =
        \\(version 1)
        \\(deny default)
        \\(allow process-fork)
        \\(allow process-exec*)
        \\(allow signal (target self))
        \\(allow sysctl-read)
        \\(allow mach-lookup)
        \\(allow iokit-open)
        \\(allow file-read*)
        \\(deny network*)
        \\(allow file-write-data
        \\  (regex #"^/dev/(null|dtracehelper|tty|stdout|stderr)$")
        \\  (regex #"^/private/tmp/")
        \\  (regex #"^/private/var/folders/")
        \\  (regex #"^/tmp/"))
        \\
    ;
    buf.appendSlice(allocator, header) catch return SandboxError.ProfileBuildFailed;

    // Database initialisers (postgres bootstrap) allocate SysV/POSIX shared
    // memory + SysV semaphores; without these grants initdb dies in
    // shmget/semctl. Scoped to `init_data_dir` so no other fenced child
    // (DSL system, cache-regen tools, Ruby fallback) gets IPC access.
    if (opts.allow_ipc) {
        buf.appendSlice(allocator,
            \\(allow ipc-sysv-shm)
            \\(allow ipc-sysv-sem)
            \\(allow ipc-posix-shm)
            \\
        ) catch return SandboxError.ProfileBuildFailed;
    }

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    const w = &aw.writer;
    w.writeAll("(allow file-write*") catch return SandboxError.ProfileBuildFailed;

    // The kernel matches subpath filters against resolved vnode paths;
    // a symlinked root (macOS /tmp → /private/tmp) needs its resolved
    // form granted too or writes under it are silently denied.
    var cellar_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    var prefix_real_buf: [std.fs.max_path_bytes]u8 = undefined;

    writeCellarRule(w, cellar_path) catch return SandboxError.ProfileBuildFailed;
    if (resolvedForProfile(cellar_path, &cellar_real_buf)) |real|
        writeCellarRule(w, real) catch return SandboxError.ProfileBuildFailed;
    writePrefixRules(w, malt_prefix) catch return SandboxError.ProfileBuildFailed;
    if (resolvedForProfile(malt_prefix, &prefix_real_buf)) |real|
        writePrefixRules(w, real) catch return SandboxError.ProfileBuildFailed;
    w.writeAll(")\n") catch return SandboxError.ProfileBuildFailed;

    return aw.toOwnedSlice() catch SandboxError.ProfileBuildFailed;
}

fn writeCellarRule(w: *std.Io.Writer, root: []const u8) !void {
    try w.print("\n  (subpath \"{s}\")", .{root});
}

fn writePrefixRules(w: *std.Io.Writer, prefix: []const u8) !void {
    // `<prefix>/lib` is the cross-formula symlink farm — granting all of it
    // would let one formula's post-install overwrite another's dylib. The
    // cache-regen steps only touch two subtrees, so grant just those.
    for ([_][]const u8{ "etc", "var", "share", "opt", "lib/gdk-pixbuf-2.0", "lib/gio" }) |sub|
        try w.print("\n  (subpath \"{s}/{s}\")", .{ prefix, sub });
}

// Zig 0.16 ships no io-free realpath wrapper and this module is
// deliberately posix-level (fork/exec, no std.Io) — bind libc directly.
extern "c" fn realpath(noalias file_name: [*:0]const u8, noalias resolved_name: [*:0]u8) ?[*:0]u8;

/// Resolved form of `p` for the kernel's vnode-path matching, or null
/// when it resolves to itself, is not on disk yet, or the resolved form
/// fails profile validation — the caller keeps the literal rule either
/// way, so a failed resolve degrades to today's behaviour.
fn resolvedForProfile(p: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var z: [std.fs.max_path_bytes]u8 = undefined;
    if (p.len >= z.len) return null;
    @memcpy(z[0..p.len], p);
    z[p.len] = 0;
    const res = realpath(z[0..p.len :0].ptr, @ptrCast(buf)) orelse return null;
    const resolved = std.mem.sliceTo(res, 0);
    if (std.mem.eql(u8, resolved, p)) return null;
    validatePathForProfile(resolved) catch return null;
    return resolved;
}

/// Clamp a setrlimit request to the kernel's current hard cap so a
/// requested ceiling above the system limit doesn't trip `LimitTooBig`.
/// `max` higher than `current.max` requires CAP_SYS_RESOURCE and
/// otherwise fails fork→exec with exit 127.
fn setrlimitClamped(resource: std.posix.rlimit_resource, requested: std.posix.rlim_t) SandboxError!void {
    const current = std.posix.getrlimit(resource) catch return SandboxError.RlimitFailed;
    const cap = @min(requested, current.max);
    std.posix.setrlimit(resource, .{ .cur = cap, .max = cap }) catch
        return SandboxError.RlimitFailed;
}

fn applyRlimits(limits: Limits) SandboxError!void {
    const fs_max: std.posix.rlim_t = @intCast(limits.file_size_bytes);
    const cpu_max: std.posix.rlim_t = @intCast(limits.cpu_seconds);

    try setrlimitClamped(.CPU, cpu_max);
    try setrlimitClamped(.FSIZE, fs_max);

    // Skip RLIMIT_AS on Darwin: XNU rejects values below ~512 GB with EINVAL
    // and no longer enforces RSS; sandbox-exec is the real boundary here.
    _ = limits.address_space_bytes;
}

/// Build a null-terminated envp from the allowlist; everything else dropped.
pub fn buildEnvp(
    allocator: std.mem.Allocator,
    env: ScrubbedEnv,
) SandboxError![:null]?[*:0]u8 {
    var list: std.ArrayList(?[*:0]u8) = .empty;
    errdefer {
        for (list.items) |maybe| if (maybe) |s| allocator.free(std.mem.span(s));
        list.deinit(allocator);
    }
    const entries = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "HOME", .v = env.home },
        .{ .k = "PATH", .v = env.path },
        .{ .k = "MALT_PREFIX", .v = env.malt_prefix },
        .{ .k = "TMPDIR", .v = env.tmpdir },
    };
    for (entries) |e| {
        const s = std.fmt.allocPrintSentinel(allocator, "{s}={s}", .{ e.k, e.v }, 0) catch
            return SandboxError.EnvBuildFailed;
        list.append(allocator, s) catch {
            allocator.free(s);
            return SandboxError.EnvBuildFailed;
        };
    }
    return list.toOwnedSliceSentinel(allocator, null) catch SandboxError.EnvBuildFailed;
}

pub fn freeEnvp(allocator: std.mem.Allocator, envp: [:null]?[*:0]u8) void {
    var i: usize = 0;
    while (envp[i]) |s| : (i += 1) allocator.free(std.mem.span(s));
    allocator.free(envp[0 .. i + 1]);
}

/// Build a null-terminated argv; free with `freeArgv`. Caller owns.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) SandboxError![:null]?[*:0]u8 {
    var list: std.ArrayList(?[*:0]u8) = .empty;
    errdefer {
        for (list.items) |maybe| if (maybe) |s| allocator.free(std.mem.span(s));
        list.deinit(allocator);
    }
    for (argv) |a| {
        const s = allocator.dupeZ(u8, a) catch return SandboxError.EnvBuildFailed;
        list.append(allocator, s) catch {
            allocator.free(s);
            return SandboxError.EnvBuildFailed;
        };
    }
    return list.toOwnedSliceSentinel(allocator, null) catch SandboxError.EnvBuildFailed;
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]u8) void {
    var i: usize = 0;
    while (argv[i]) |s| : (i += 1) allocator.free(std.mem.span(s));
    allocator.free(argv[0 .. i + 1]);
}

/// Spawn `ruby tmp_script` under `sandbox-exec` with scrubbed env and limits.
/// Child stdout/stderr are run through `term_sanitize` to strip OSC/DCS/cursor
/// escapes before forwarding to `stdio.out`/`stdio.err`;
/// `MALT_ALLOW_RAW_POST_INSTALL=1` bypasses the sanitizer but still honours
/// the configured fds.
pub fn runRubySandboxed(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    ruby_path: []const u8,
    script_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    env: ScrubbedEnv,
    limits: Limits,
    stdio: Stdio,
) SandboxError!u8 {
    if (builtin.os.tag != .macos) return SandboxError.SandboxUnsupported;

    const profile = try renderRubyProfile(allocator, cellar_path, malt_prefix, .{});
    defer allocator.free(profile);

    const argv = [_][]const u8{
        "/usr/bin/sandbox-exec", "-p", profile, ruby_path, script_path,
    };
    const argv_z = try buildArgv(allocator, argv[0..]);
    defer freeArgv(allocator, argv_z);

    const envp = try buildEnvp(allocator, env);
    defer freeEnvp(allocator, envp);

    if (rawPassthroughEnabled(environ)) {
        return spawnInherit(argv_z, envp, limits, stdio);
    }
    return spawnFiltered(argv_z, envp, limits, stdio);
}

pub fn rawPassthroughEnabled(environ: std.process.Environ) bool {
    const v = std.process.Environ.getPosix(environ, "MALT_ALLOW_RAW_POST_INSTALL") orelse return false;
    return std.mem.eql(u8, v, "1");
}

fn spawnInherit(
    argv_z: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    limits: Limits,
    stdio: Stdio,
) SandboxError!u8 {
    const pid = std.c.fork();
    if (pid < 0) return SandboxError.ForkFailed;
    if (pid == 0) {
        // dup2 is a no-op when source equals destination, so unconditional
        // redirection keeps the production path identical to the old
        // inherited-stdio behaviour while letting tests sink to /dev/null.
        _ = std.c.dup2(stdio.out, std.posix.STDOUT_FILENO);
        _ = std.c.dup2(stdio.err, std.posix.STDERR_FILENO);
        applyRlimits(limits) catch std.c._exit(127);
        _ = std.c.execve(argv_z[0].?, argv_z.ptr, envp.ptr);
        std.c._exit(127);
    }
    var status: c_int = 0;
    const w = std.c.waitpid(pid, &status, 0);
    if (w < 0) return SandboxError.WaitFailed;
    if (wifsignaled(status)) return SandboxError.ChildSignaled;
    if (!wifexited(status)) return SandboxError.ChildCrashed;
    return @intCast(wexitstatus(status));
}

/// Idempotent fd wrapper — `closeOnce` zeroes the value so `errdefer`
/// can't double-close an fd another path already dropped.
const Fd = struct {
    value: c_int = -1,

    fn closeOnce(self: *Fd) void {
        if (self.value != -1) {
            _ = std.c.close(self.value);
            self.value = -1;
        }
    }
};

fn openPipe(reader: *Fd, writer: *Fd) SandboxError!void {
    var buf: [2]c_int = undefined;
    if (std.c.pipe(&buf) != 0) return SandboxError.ForkFailed;
    reader.value = buf[0];
    writer.value = buf[1];
}

/// Test-only hooks; zero-value in production.
pub const SpawnHooks = struct {
    /// Force the Nth thread spawn to return `error.SystemResources`.
    fail_thread_spawn_on: ?u32 = null,
    /// Invoked after the parent waitpid's the child on an error path.
    on_child_reaped: ?*const fn (pid: std.c.pid_t, ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

fn spawnFiltered(
    argv_z: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    limits: Limits,
    stdio: Stdio,
) SandboxError!u8 {
    return spawnFilteredWithHooks(argv_z, envp, limits, stdio, .{});
}

fn maybeSpawnFilter(
    hooks: SpawnHooks,
    call_idx: u32,
    pipe_fd: c_int,
    out_fd: c_int,
) std.Thread.SpawnError!std.Thread {
    if (hooks.fail_thread_spawn_on) |n| if (call_idx == n) return error.SystemResources;
    return std.Thread.spawn(.{}, filterLoop, .{ pipe_fd, out_fd });
}

/// Kill and reap; safe on already-dead pids (ESRCH/zombie are tolerated).
fn reapChild(pid: std.c.pid_t, hooks: SpawnHooks) void {
    std.posix.kill(pid, std.posix.SIG.KILL) catch {}; // ESRCH means already dead
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    if (hooks.on_child_reaped) |cb| cb(pid, hooks.ctx);
}

pub fn spawnFilteredWithHooks(
    argv_z: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    limits: Limits,
    stdio: Stdio,
    hooks: SpawnHooks,
) SandboxError!u8 {
    var out_r: Fd = .{};
    var out_w: Fd = .{};
    var err_r: Fd = .{};
    var err_w: Fd = .{};
    // Pre-fork guards: every live fd gets closed exactly once if pipe
    // setup or fork fails before another owner (a reader thread or an
    // explicit close) takes over.
    errdefer out_r.closeOnce();
    errdefer out_w.closeOnce();
    errdefer err_r.closeOnce();
    errdefer err_w.closeOnce();

    try openPipe(&out_r, &out_w);
    try openPipe(&err_r, &err_w);

    const pid = std.c.fork();
    if (pid < 0) return SandboxError.ForkFailed;
    if (pid == 0) {
        // Child: wire pipes to fd 1/2, drop the read ends, exec.
        _ = std.c.close(out_r.value);
        _ = std.c.close(err_r.value);
        _ = std.c.dup2(out_w.value, 1);
        _ = std.c.dup2(err_w.value, 2);
        _ = std.c.close(out_w.value);
        _ = std.c.close(err_w.value);
        applyRlimits(limits) catch std.c._exit(127);
        _ = std.c.execve(argv_z[0].?, argv_z.ptr, envp.ptr);
        std.c._exit(127);
    }

    // Parent: drop write ends immediately. The child still owns its dup'd copies.
    out_w.closeOnce();
    err_w.closeOnce();

    var out_thread: ?std.Thread = null;
    var err_thread: ?std.Thread = null;
    // Registered after a successful fork: on any later error, kill and
    // reap the child first so reader threads' `read` calls return EOF,
    // then join any reader threads that did start.
    errdefer {
        reapChild(pid, hooks);
        if (out_thread) |t| t.join();
        if (err_thread) |t| t.join();
    }

    out_thread = maybeSpawnFilter(hooks, 0, out_r.value, stdio.out) catch
        return SandboxError.ForkFailed;
    // Thread owns the read end now; its own `defer close` releases it.
    out_r.value = -1;

    err_thread = maybeSpawnFilter(hooks, 1, err_r.value, stdio.err) catch
        return SandboxError.ForkFailed;
    err_r.value = -1;

    var status: c_int = 0;
    const w = std.c.waitpid(pid, &status, 0);

    // Happy path: threads exit on EOF once the child is gone; join and
    // clear the optionals so a late error cannot re-join.
    out_thread.?.join();
    err_thread.?.join();
    out_thread = null;
    err_thread = null;

    if (w < 0) return SandboxError.WaitFailed;
    if (wifsignaled(status)) return SandboxError.ChildSignaled;
    if (!wifexited(status)) return SandboxError.ChildCrashed;
    return @intCast(wexitstatus(status));
}

const FdSinkCtx = struct { fd: c_int };

fn fdSinkWrite(ctx: *anyopaque, bytes: []const u8) term_sanitize.SinkError!void {
    const self: *FdSinkCtx = @ptrCast(@alignCast(ctx));
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(self.fd, bytes.ptr + off, bytes.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Reader thread: pull from the pipe, run through the sanitizer,
/// push the surviving bytes to the parent's real fd. Exits on EOF
/// or write error. Owns `pipe_fd` and closes it.
fn filterLoop(pipe_fd: c_int, out_fd: c_int) void {
    defer _ = std.c.close(pipe_fd);
    filterInto(pipe_fd, out_fd);
}

/// Same pump, but the caller retains ownership of `pipe_fd`. The DSL's
/// `system`/`safe_popen_read` spawn through `std.process.spawn`, whose own
/// `wait` closes the pipes it handed out — closing here as well would free an
/// fd number a later `open` could already have reused.
pub fn filterInto(pipe_fd: c_int, out_fd: c_int) void {
    var sanitizer = term_sanitize.Sanitizer.init();
    var ctx = FdSinkCtx{ .fd = out_fd };
    const sink = term_sanitize.Sink{ .ctx = &ctx, .write_fn = fdSinkWrite };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fd, &buf, buf.len);
        if (n <= 0) break;
        sanitizer.feed(buf[0..@intCast(n)], sink) catch break;
    }
    // Flush after EOF; parent fd may already be gone on shutdown races.
    sanitizer.flush(sink) catch {};
}

// macOS <sys/wait.h> status macros, open-coded.
fn wifexited(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn wifsignaled(status: c_int) bool {
    const term = status & 0x7f;
    return term != 0 and term != 0x7f;
}
fn wexitstatus(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

// ---------------------------------------------------------------------------
// tests

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

test "validatePathForProfile accepts normal absolute paths" {
    try validatePathForProfile("/opt/malt");
    try validatePathForProfile("/opt/malt/Cellar/foo/1.2.3");
}

test "validatePathForProfile rejects SCL metacharacters" {
    try std.testing.expectError(SandboxError.UnsafePath, validatePathForProfile("/tmp/\"hack"));
    try std.testing.expectError(SandboxError.UnsafePath, validatePathForProfile("/tmp/ha(ck"));
    try std.testing.expectError(SandboxError.UnsafePath, validatePathForProfile("/tmp/ha\\ck"));
    try std.testing.expectError(SandboxError.UnsafePath, validatePathForProfile("relative/path"));
    try std.testing.expectError(SandboxError.UnsafePath, validatePathForProfile(""));
}

test "renderRubyProfile emits deny-default + cellar + prefix subpaths" {
    const profile = try renderRubyProfile(
        std.testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
        .{},
    );
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/Cellar/foo/1.0\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/etc\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/var\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/opt\")") != null);
    // Cache-regen steps write only two lib subtrees; the whole `lib` farm
    // must NOT be granted (cross-formula dylib overwrite surface).
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib/gdk-pixbuf-2.0\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib/gio\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/lib\")\n") == null);
    // IPC is opt-in: the default profile must NOT grant it.
    try std.testing.expect(std.mem.indexOf(u8, profile, "ipc-sysv-shm") == null);
}

test "renderRubyProfile grants IPC only when allow_ipc is set" {
    const profile = try renderRubyProfile(
        std.testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
        .{ .allow_ipc = true },
    );
    defer std.testing.allocator.free(profile);
    // The database initialisers need SysV/POSIX shm + SysV sem.
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-sysv-shm)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-posix-shm)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(allow ipc-sysv-sem)") != null);
}

// The kernel matches subpath filters against resolved vnode paths, so a
// symlinked root (macOS /tmp → /private/tmp) must also grant its
// resolved form or every write under it is silently denied.
test "renderRubyProfile also grants writes under the resolved roots for symlinked paths" {
    var s = try Scratch.init("sbx_profile_test");
    defer s.deinit();
    _ = std.c.mkdir(s.base.ptr, 0o755); // EEXIST is fine

    const a = s.arena.allocator();
    // Does not exist on disk — must fall back to the literal alone.
    const keg = s.p("/Cellar/foo/1.0");

    const profile = try renderRubyProfile(
        std.testing.allocator,
        keg,
        s.base,
        .{},
    );
    defer std.testing.allocator.free(profile);

    // Literal rules stay (fail-open to today's behaviour)...
    const lit_etc = try std.fmt.allocPrint(a, "(subpath \"{s}/etc\")", .{s.base});
    const lit_keg = try std.fmt.allocPrint(a, "(subpath \"{s}\")", .{keg});
    try std.testing.expect(std.mem.indexOf(u8, profile, lit_etc) != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, lit_keg) != null);
    // ...and the resolved prefix is granted too.
    const res_etc = try std.fmt.allocPrint(a, "(subpath \"/private{s}/etc\")", .{s.base});
    const res_var = try std.fmt.allocPrint(a, "(subpath \"/private{s}/var\")", .{s.base});
    try std.testing.expect(std.mem.indexOf(u8, profile, res_etc) != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, res_var) != null);
}

test "renderRubyProfile does not duplicate rules for already-resolved roots" {
    const profile = try renderRubyProfile(
        std.testing.allocator,
        "/opt/malt/Cellar/foo/1.0",
        "/opt/malt",
        .{},
    );
    defer std.testing.allocator.free(profile);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, profile, "(subpath \"/opt/malt/etc\")"),
    );
}

test "renderRubyProfile rejects unsafe cellar path" {
    try std.testing.expectError(
        SandboxError.UnsafePath,
        renderRubyProfile(std.testing.allocator, "/opt/malt\"/evil", "/opt/malt", .{}),
    );
}
