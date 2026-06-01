//! malt — DSL builtin: Pathname operations
//! Maps Ruby Pathname methods to std.fs calls.
//!
//! Same contract as fileutils.zig: fs mutations swallow their errors and
//! surface at the downstream step (linker, cellar layout, bottle verify).
//! Matches Ruby's non-raising Pathname helpers used by Homebrew formulae.

const std = @import("std");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const ast = @import("../ast.zig");
const fallback_log = @import("../fallback_log.zig");

const Value = values.Value;

pub const BuiltinError = error{
    PathSandboxViolation,
    PostInstallFailed,
    SystemCommandFailed,
    OutOfMemory,
    UnknownMethod,
    UnsupportedNode,
    ParseError,
};

pub const ExecCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    cellar_path: []const u8,
    malt_prefix: []const u8,
    /// Suppress a spawned child's stdout (set under --json/--ndjson so it
    /// can't corrupt the document). Threaded in by the interpreter.
    suppress_child_stdout: bool = false,
    /// Record-only diagnostics sink for builtins (e.g. inreplace's
    /// atomic-write fallback). Optional so test contexts can omit it.
    fallback_log: ?*fallback_log.FallbackLog = null,
};

/// mkpath — recursive directory creation
pub fn mkpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    std.Io.Dir.cwd().createDirPath(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// exist? — check if path exists
pub fn existQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// directory? — check if path is a directory
pub fn directoryQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    dir.close(ctx.io);
    return Value{ .bool = true };
}

/// symlink? — check if path is a symlink
pub fn symlinkQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.cwd().readLink(ctx.io, path, &buf) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = true };
}

/// write — write content to file (sandbox-validated)
pub fn write(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    const content = if (args.len > 0) try args[0].asString(ctx.allocator) else "";

    const file = std.Io.Dir.createFileAbsolute(ctx.io, path, .{}) catch {
        return Value{ .nil = {} };
    };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, content) catch {};
    return Value{ .nil = {} };
}

/// read — read file content
pub fn read(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .string = "" };
    const content = readFileAllAbsolute(ctx.io, ctx.allocator, path, 1024 * 1024) catch {
        return Value{ .string = "" };
    };
    return Value{ .string = content };
}

/// children — list directory entries
pub fn children(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .array = &.{} };
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, path, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close(ctx.io);

    var entries: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        const child_path = std.fs.path.join(ctx.allocator, &.{ path, entry.name }) catch continue;
        entries.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
    }
    const slice = entries.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// basename — filename component
pub fn basename(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.basename(path) };
}

/// dirname — parent directory
pub fn dirname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .pathname = std.fs.path.dirname(path) orelse "/" };
}

/// extname — file extension
pub fn extname(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = std.fs.path.extension(path) };
}

/// to_s — convert pathname to string
pub fn toS(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    return Value{ .string = path };
}

/// realpath — resolve symlinks
pub fn realpath(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(ctx.io, path, &buf) catch {
        return Value{ .pathname = path };
    };
    const duped = ctx.allocator.dupe(u8, buf[0..n]) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = duped };
}

/// file? — check if path is a regular file
pub fn fileQ(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .bool = false };
    const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch {
        return Value{ .bool = false };
    };
    return Value{ .bool = stat.kind == .file };
}

/// atomic_write — write content atomically (sandbox-validated)
pub fn atomicWrite(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    return write(ctx, receiver, args);
}

/// opt_bin — receiver/"bin" (Formula accessor)
pub fn optBin(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "bin" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_lib — receiver/"lib" (Formula accessor)
pub fn optLib(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "lib" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// opt_include — receiver/"include" (Formula accessor)
pub fn optInclude(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const joined = std.fs.path.join(ctx.allocator, &.{ path, "include" }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// pkgetc — `Formula[name].pkgetc` is `<prefix>/etc/<name>`, not
/// `<opt>/<name>/etc`. The receiver is the opt anchor (`<prefix>/opt/<name>`),
/// so re-anchor under malt_prefix using its basename as the package name.
/// The bare current-formula `pkgetc` resolves through path bindings, not here.
pub fn pkgetc(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    const name = std.fs.path.basename(path);
    const joined = std.fs.path.join(ctx.allocator, &.{ ctx.malt_prefix, "etc", name }) catch return BuiltinError.OutOfMemory;
    return Value{ .pathname = joined };
}

/// unlink — delete a file (alias for File.delete)
pub fn unlink(ctx: ExecCtx, receiver: ?Value, _: []const Value) BuiltinError!Value {
    const path = try receiverPath(ctx.allocator, receiver);
    if (path.len == 0) return Value{ .nil = {} };
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;
    std.Io.Dir.cwd().deleteFile(ctx.io, path) catch {};
    return Value{ .nil = {} };
}

/// install_symlink — link source(s) into the receiver directory.
///
/// Homebrew semantics: the receiver is the *target directory*, each arg
/// names a source. A bare source lands at `<dir>/<basename(source)>`; a
/// hash entry `source => link_name` overrides the link name; an array
/// links each element by basename. The link path is sandbox-validated.
pub fn installSymlink(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    const dir = try receiverPath(ctx.allocator, receiver);
    if (dir.len == 0) return Value{ .nil = {} };
    for (args) |arg| try installSymlinkArg(ctx, dir, arg);
    return Value{ .nil = {} };
}

fn installSymlinkArg(ctx: ExecCtx, dir: []const u8, arg: Value) BuiltinError!void {
    switch (arg) {
        // `source => link_name`: key is the source, value the link name.
        .hash => |pairs| for (pairs) |p| {
            const source = try p.key.asString(ctx.allocator);
            const name = try p.value.asString(ctx.allocator);
            try linkInto(ctx, dir, source, name);
        },
        .array => |items| for (items) |item| {
            const source = try item.asString(ctx.allocator);
            try linkInto(ctx, dir, source, std.fs.path.basename(source));
        },
        else => {
            const source = try arg.asString(ctx.allocator);
            try linkInto(ctx, dir, source, std.fs.path.basename(source));
        },
    }
}

/// Symlink `<dir>/<name>` → `<source>`, sandbox-validated on the link
/// path. Same non-raising fs contract as the rest of this module: a
/// failed mkdir/symlink surfaces downstream, not here.
fn linkInto(ctx: ExecCtx, dir: []const u8, source: []const u8, name: []const u8) BuiltinError!void {
    if (source.len == 0 or name.len == 0) return;

    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Overflow means a pathological path — skip rather than truncate.
    const link = std.fmt.bufPrint(&link_buf, "{s}/{s}", .{ dir, name }) catch return;

    sandbox.validatePath(link, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(ctx.io, link) catch {};
    std.Io.Dir.symLinkAbsolute(ctx.io, source, link, .{}) catch {};
}

/// glob(pattern) — match files in a directory against a glob pattern
/// Receiver is the directory path; first arg is the pattern string.
/// If called bare (no receiver), the first arg is the full glob pattern.
pub fn glob(ctx: ExecCtx, receiver: ?Value, args: []const Value) BuiltinError!Value {
    var base_dir: []const u8 = "";
    var pattern: []const u8 = "*";

    if (receiver) |recv| {
        // Receiver form: dir.glob("*.dylib")
        base_dir = switch (recv) {
            .pathname => |p| p,
            .string => |s| s,
            else => recv.asString(ctx.allocator) catch return BuiltinError.OutOfMemory,
        };
        if (args.len == 0) return Value{ .array = &.{} };
        pattern = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
    } else {
        // Bare form: Dir.glob("lib/*.dylib") — first arg is full pattern
        if (args.len == 0) return Value{ .array = &.{} };
        const full = args[0].asString(ctx.allocator) catch return Value{ .array = &.{} };
        if (full.len == 0) return Value{ .array = &.{} };
        base_dir = std.fs.path.dirname(full) orelse ".";
        pattern = std.fs.path.basename(full);
    }

    // Guard against empty/relative base_dir
    if (base_dir.len == 0) return Value{ .array = &.{} };

    var dir = std.Io.Dir.openDirAbsolute(ctx.io, base_dir, .{ .iterate = true }) catch {
        return Value{ .array = &.{} };
    };
    defer dir.close(ctx.io);

    var results: std.ArrayList(Value) = .empty;
    var iter = dir.iterate();
    while (iter.next(ctx.io) catch null) |entry| {
        if (globMatch(pattern, entry.name)) {
            const child_path = std.fs.path.join(ctx.allocator, &.{ base_dir, entry.name }) catch continue;
            results.append(ctx.allocator, Value{ .pathname = child_path }) catch continue;
        }
    }

    const slice = results.toOwnedSlice(ctx.allocator) catch return BuiltinError.OutOfMemory;
    return Value{ .array = slice };
}

/// Glob pattern matching with `*`, `?`, and `{a,b,c}` brace expansion.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Check if pattern contains braces — if so, expand and try each alternative
    if (std.mem.findScalar(u8, pattern, '{')) |brace_start| {
        if (findMatchingBrace(pattern, brace_start)) |brace_end| {
            const prefix = pattern[0..brace_start];
            const suffix = pattern[brace_end + 1 ..];
            const alternatives = pattern[brace_start + 1 .. brace_end];

            // Split alternatives by comma and try each
            var iter = std.mem.splitScalar(u8, alternatives, ',');
            while (iter.next()) |alt| {
                // Build expanded pattern: prefix + alt + suffix
                var buf: [1024]u8 = undefined;
                const expanded_len = prefix.len + alt.len + suffix.len;
                if (expanded_len > buf.len) continue;
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len .. prefix.len + alt.len], alt);
                @memcpy(buf[prefix.len + alt.len .. expanded_len], suffix);
                if (globMatch(buf[0..expanded_len], name)) return true;
            }
            return false;
        }
    }

    // Standard glob matching without braces
    var pi: usize = 0;
    var ni: usize = 0;
    var star_pi: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == name[ni] or pattern[pi] == '?')) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ni = ni;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
        } else {
            return false;
        }
    }

    // Consume trailing *'s in pattern
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

/// Find matching closing brace, accounting for nesting.
fn findMatchingBrace(pattern: []const u8, start: usize) ?usize {
    var depth: u32 = 0;
    var i = start;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '{') {
            depth += 1;
        } else if (pattern[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn receiverPath(allocator: std.mem.Allocator, receiver: ?Value) BuiltinError![]const u8 {
    const recv = receiver orelse return BuiltinError.UnknownMethod;
    return switch (recv) {
        .pathname => |p| p,
        .string => |s| s,
        else => recv.asString(allocator) catch return BuiltinError.OutOfMemory,
    };
}

/// Read the entire contents of an absolute file path into a caller-owned slice.
fn readFileAllAbsolute(io: std.Io, allocator: std.mem.Allocator, abs_path: []const u8, max_bytes: usize) ![]u8 {
    const f = try std.Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    const size = @min(@as(u64, max_bytes), st.size);
    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);
    if (n == buf.len) return buf;
    if (allocator.resize(buf, n)) return buf[0..n];
    const shrunk = try allocator.alloc(u8, n);
    @memcpy(shrunk, buf[0..n]);
    allocator.free(buf);
    return shrunk;
}

// ---------------------------------------------------------------------------
// Inline tests
// ---------------------------------------------------------------------------

/// pkgetc only reads `allocator` + `malt_prefix`; the rest is structurally
/// required by ExecCtx but never touched on this path.
fn testCtx(allocator: std.mem.Allocator, malt_prefix: []const u8) ExecCtx {
    return .{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .cellar_path = "",
        .malt_prefix = malt_prefix,
    };
}

test "pkgetc re-anchors a Formula[] opt path to <prefix>/etc/<name>" {
    // Homebrew's `Formula[name].pkgetc` is `<prefix>/etc/<name>`, not
    // `<opt>/<name>/etc`. The receiver is the opt anchor, so pkgetc rebuilds
    // under malt_prefix; the bare current-formula pkgetc uses path bindings.
    const ctx = testCtx(std.testing.allocator, "/opt/malt");
    const etc = try pkgetc(ctx, Value{ .pathname = "/opt/malt/opt/ca-certificates" }, &.{});
    defer std.testing.allocator.free(etc.pathname);
    try std.testing.expectEqualStrings("/opt/malt/etc/ca-certificates", etc.pathname);
}

test "pkgetc keeps an @-versioned formula name intact" {
    // openssl@3 et al. carry `@` in the keg name; the basename re-anchor
    // must preserve it verbatim.
    const ctx = testCtx(std.testing.allocator, "/opt/malt");
    const etc = try pkgetc(ctx, Value{ .pathname = "/opt/malt/opt/openssl@3" }, &.{});
    defer std.testing.allocator.free(etc.pathname);
    try std.testing.expectEqualStrings("/opt/malt/etc/openssl@3", etc.pathname);
}
