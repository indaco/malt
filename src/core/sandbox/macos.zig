//! malt — macOS sandbox-exec profile + spawn wrapper for the Ruby
//! post_install subprocess.
//!
//! This module is the OS-level containment layer for the explicit
//! `--use-system-ruby` path. Ruby code from a hostile formula running
//! under the user's UID is the threat; the containment goal is:
//!
//!   - confine writes to the formula's own cellar and a small set of
//!     shared directories under MALT_PREFIX (etc, var, share, opt),
//!   - block network entirely,
//!   - strip environment vars that alter dynamic-loader or Ruby
//!     behaviour (DYLD_*, RUBYOPT, etc.),
//!   - clamp CPU / memory / file-size budgets so a runaway script
//!     fails fast instead of exhausting the user's machine.
//!
//! The sandbox profile is rendered per formula at spawn time. Paths are
//! validated against a conservative charset before interpolation to
//! keep the profile string free of SCL metacharacters.

const std = @import("std");
const builtin = @import("builtin");
const fs_compat = @import("../../fs/compat.zig");
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

/// Resource caps applied to the sandboxed child before `execve`.
/// Conservative defaults — a well-behaved post_install hook never hits
/// any of these. Operators can widen via formula-level config later if
/// a real regression shows up.
pub const Limits = struct {
    /// Wall-clock CPU seconds. macOS counts user+system.
    cpu_seconds: u64 = 300,
    /// Virtual address space ceiling (RLIMIT_AS). 2 GiB is generous
    /// for any post_install that isn't mining.
    address_space_bytes: u64 = 2 * 1024 * 1024 * 1024,
    /// Largest single file the child may create (RLIMIT_FSIZE).
    file_size_bytes: u64 = 512 * 1024 * 1024,
};

/// Environment slots propagated to the sandboxed child. Everything not
/// in this list is dropped at `execve` time — in particular the
/// dynamic-loader knobs and Ruby's global preload hooks.
pub const ScrubbedEnv = struct {
    home: []const u8,
    path: []const u8,
    malt_prefix: []const u8,
    tmpdir: []const u8,
};

/// Minimal PATH passed through to the sandboxed child. Anything more
/// ambitious lets a hostile formula exploit whatever random binary
/// happens to live in the user's homebrew/cargo/npm prefixes.
pub const SANDBOX_PATH: []const u8 = "/usr/bin:/bin:/usr/sbin:/sbin";

/// Validate that a path is safe to splice into a sandbox-exec profile
/// string. Rejects quote, backslash, parenthesis, newline, and NUL —
/// any of which could break out of the `(subpath "...")` token.
///
/// malt's cellar paths are built from [a-z0-9@._+-/] formula names and
/// version strings concatenated with a known prefix, so well-formed
/// input passes; this guards against a malformed MALT_PREFIX or an
/// unusual formula version slipping through.
pub fn validatePathForProfile(p: []const u8) SandboxError!void {
    if (p.len == 0 or p[0] != '/') return SandboxError.UnsafePath;
    for (p) |c| switch (c) {
        0, '"', '\\', '(', ')', '\n', '\r' => return SandboxError.UnsafePath,
        else => {},
    };
}

/// Render a sandbox-exec profile SCL string for a Ruby post_install
/// run. Deny-by-default; file-read broadly; file-write only under
/// `cellar_path` and the four shared subtrees of `malt_prefix`.
///
/// Caller owns the returned slice.
pub fn renderRubyProfile(
    allocator: std.mem.Allocator,
    cellar_path: []const u8,
    malt_prefix: []const u8,
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

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &buf);
    aw.writer.print(
        \\(allow file-write*
        \\  (subpath "{s}")
        \\  (subpath "{s}/etc")
        \\  (subpath "{s}/var")
        \\  (subpath "{s}/share")
        \\  (subpath "{s}/opt"))
        \\
    , .{ cellar_path, malt_prefix, malt_prefix, malt_prefix, malt_prefix }) catch
        return SandboxError.ProfileBuildFailed;
    return aw.toOwnedSlice() catch SandboxError.ProfileBuildFailed;
}

/// RLIMIT constants. Zig's `std.posix.rlimit_resource` is an enum on
/// macOS whose integer values match the platform headers; we name
/// them here so the call sites below stay readable.
const RLIMIT = struct {
    const CPU: std.posix.rlimit_resource = @enumFromInt(0);
    const FSIZE: std.posix.rlimit_resource = @enumFromInt(1);
    const AS: std.posix.rlimit_resource = @enumFromInt(5);
};

fn applyRlimits(limits: Limits) SandboxError!void {
    const as_max: std.posix.rlim_t = @intCast(limits.address_space_bytes);
    const fs_max: std.posix.rlim_t = @intCast(limits.file_size_bytes);
    const cpu_max: std.posix.rlim_t = @intCast(limits.cpu_seconds);

    std.posix.setrlimit(RLIMIT.CPU, .{ .cur = cpu_max, .max = cpu_max }) catch
        return SandboxError.RlimitFailed;
    std.posix.setrlimit(RLIMIT.FSIZE, .{ .cur = fs_max, .max = fs_max }) catch
        return SandboxError.RlimitFailed;
    std.posix.setrlimit(RLIMIT.AS, .{ .cur = as_max, .max = as_max }) catch
        return SandboxError.RlimitFailed;
}

/// Build a null-terminated envp array from an allowlist. Everything
/// outside the allowlist is dropped — in particular DYLD_*, RUBYOPT,
/// RUBYLIB, GEM_* and friends.
fn buildEnvp(
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

fn freeEnvp(allocator: std.mem.Allocator, envp: [:null]?[*:0]u8) void {
    var i: usize = 0;
    while (envp[i]) |s| : (i += 1) allocator.free(std.mem.span(s));
    allocator.free(envp[0 .. i + 1]);
}

/// Build a null-terminated argv array. Caller owns; free with
/// `freeArgv`.
fn buildArgv(
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

fn freeArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]u8) void {
    var i: usize = 0;
    while (argv[i]) |s| : (i += 1) allocator.free(std.mem.span(s));
    allocator.free(argv[0 .. i + 1]);
}

/// Spawn `ruby tmp_script` under `sandbox-exec -p <profile>`, a
/// scrubbed env, and the resource limits. Streams stdout/stderr from
/// the child directly to the current process's stdout/stderr.
///
/// Returns the child's exit code on normal exit, or a SandboxError
/// if the child was killed by a signal / the sandbox couldn't be
/// applied / the fork-exec itself failed.
///
/// The child's stdout/stderr are filtered through a terminal escape-
/// sequence sanitizer (`term_sanitize`) before being forwarded to the
/// parent's fds, so a hostile formula cannot emit OSC/DCS/cursor
/// commands that rewrite scrollback or exfiltrate via terminal
/// extensions. Set `MALT_ALLOW_RAW_POST_INSTALL=1` to bypass.
pub fn runRubySandboxed(
    allocator: std.mem.Allocator,
    ruby_path: []const u8,
    script_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    env: ScrubbedEnv,
    limits: Limits,
) SandboxError!u8 {
    if (builtin.os.tag != .macos) return SandboxError.SandboxUnsupported;

    const profile = try renderRubyProfile(allocator, cellar_path, malt_prefix);
    defer allocator.free(profile);

    const argv = [_][]const u8{
        "/usr/bin/sandbox-exec", "-p", profile, ruby_path, script_path,
    };
    const argv_z = try buildArgv(allocator, argv[0..]);
    defer freeArgv(allocator, argv_z);

    const envp = try buildEnvp(allocator, env);
    defer freeEnvp(allocator, envp);

    if (rawPassthroughEnabled()) {
        return spawnInherit(argv_z, envp, limits);
    }
    return spawnFiltered(argv_z, envp, limits);
}

fn rawPassthroughEnabled() bool {
    const v = fs_compat.getenv("MALT_ALLOW_RAW_POST_INSTALL") orelse return false;
    return std.mem.eql(u8, std.mem.sliceTo(v, 0), "1");
}

fn spawnInherit(
    argv_z: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    limits: Limits,
) SandboxError!u8 {
    const pid = std.c.fork();
    if (pid < 0) return SandboxError.ForkFailed;
    if (pid == 0) {
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

fn spawnFiltered(
    argv_z: [:null]?[*:0]u8,
    envp: [:null]?[*:0]u8,
    limits: Limits,
) SandboxError!u8 {
    var out_pipe: [2]c_int = undefined;
    var err_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return SandboxError.ForkFailed;
    errdefer {
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
    }
    if (std.c.pipe(&err_pipe) != 0) return SandboxError.ForkFailed;
    errdefer {
        _ = std.c.close(err_pipe[0]);
        _ = std.c.close(err_pipe[1]);
    }

    const pid = std.c.fork();
    if (pid < 0) return SandboxError.ForkFailed;
    if (pid == 0) {
        // Child: wire pipes to fd 1/2, drop the read ends, exec.
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(err_pipe[0]);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.dup2(err_pipe[1], 2);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.close(err_pipe[1]);
        applyRlimits(limits) catch std.c._exit(127);
        _ = std.c.execve(argv_z[0].?, argv_z.ptr, envp.ptr);
        std.c._exit(127);
    }

    // Parent: drop write ends, spawn reader threads that sanitize
    // into the parent's real stdout/stderr.
    _ = std.c.close(out_pipe[1]);
    _ = std.c.close(err_pipe[1]);

    const out_thread = std.Thread.spawn(.{}, filterLoop, .{ out_pipe[0], @as(c_int, 1) }) catch
        return SandboxError.ForkFailed;
    const err_thread = std.Thread.spawn(.{}, filterLoop, .{ err_pipe[0], @as(c_int, 2) }) catch
        return SandboxError.ForkFailed;

    var status: c_int = 0;
    const w = std.c.waitpid(pid, &status, 0);

    // Reader threads exit when their pipe returns EOF (child's fd
    // closed), so we can safely join after waitpid.
    out_thread.join();
    err_thread.join();

    if (w < 0) return SandboxError.WaitFailed;
    if (wifsignaled(status)) return SandboxError.ChildSignaled;
    if (!wifexited(status)) return SandboxError.ChildCrashed;
    return @intCast(wexitstatus(status));
}

const FdSinkCtx = struct { fd: c_int };

fn fdSinkWrite(ctx: *anyopaque, bytes: []const u8) anyerror!void {
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
/// or write error.
fn filterLoop(pipe_fd: c_int, out_fd: c_int) void {
    defer _ = std.c.close(pipe_fd);
    var sanitizer = term_sanitize.Sanitizer.init();
    var ctx = FdSinkCtx{ .fd = out_fd };
    const sink = term_sanitize.Sink{ .ctx = &ctx, .write_fn = fdSinkWrite };
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fd, &buf, buf.len);
        if (n <= 0) break;
        sanitizer.feed(buf[0..@intCast(n)], sink) catch break;
    }
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
    );
    defer std.testing.allocator.free(profile);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(deny network*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/Cellar/foo/1.0\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/etc\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/var\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile, "(subpath \"/opt/malt/opt\")") != null);
}

test "renderRubyProfile rejects unsafe cellar path" {
    try std.testing.expectError(
        SandboxError.UnsafePath,
        renderRubyProfile(std.testing.allocator, "/opt/malt\"/evil", "/opt/malt"),
    );
}
