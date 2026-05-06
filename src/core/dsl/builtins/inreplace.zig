//! malt — DSL builtin: inreplace
//! Literal form: inreplace(path, from, to) — read file, replace all, write back.
//! Block form is deferred to a future phase (requires interpreter cooperation).

const std = @import("std");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

/// Categorises the step that failed during a temp-file + rename atomic write.
/// The original underlying error is surfaced separately so triage gets both
/// "which step" and "why" rather than a collapsed AccessDenied.
const AtomicWriteError = error{
    TempCreateFailed,
    WriteFailed,
    RenameFailed,
    NameTooLong,
};

/// inreplace(path, from_string, to_string)
/// Reads the file at `path`, replaces all occurrences of `from_string` with
/// `to_string`, and writes the result back atomically.
pub fn inreplace(ctx: ExecCtx, _: ?Value, args: []const Value) BuiltinError!Value {
    if (args.len < 3) return Value{ .nil = {} };

    const path = try args[0].asString(ctx.allocator);
    const from = try args[1].asString(ctx.allocator);
    const to = try args[2].asString(ctx.allocator);

    // Sandbox validation — inreplace is a mutating operation
    sandbox.validatePath(path, ctx.cellar_path, ctx.malt_prefix) catch
        return BuiltinError.PathSandboxViolation;

    // Read file contents
    const content = readFileAllAbsolute(ctx.io, ctx.allocator, path, 4 * 1024 * 1024) catch {
        return Value{ .nil = {} };
    };

    // Replace all occurrences
    if (from.len == 0) return Value{ .nil = {} };
    const new_content = replaceAll(ctx.allocator, content, from, to) catch {
        return Value{ .nil = {} };
    };

    // Write back atomically via temp file + rename. If the atomic write
    // fails (e.g. ENOSPC in the target directory), fall back to a direct
    // overwrite and log the fallback so the user is aware that the write
    // did *not* use the atomic path.
    var underlying_name: ?[]const u8 = null;
    writeAtomic(ctx.io, path, new_content, &underlying_name) catch |e| {
        const stderr: std.Io.File = .{ .handle = std.posix.STDERR_FILENO, .flags = .{ .nonblocking = false } };
        var buf: [512]u8 = undefined;
        const underlying = underlying_name orelse @errorName(e);
        const msg = formatAtomicWriteFailureMessage(&buf, e, underlying) catch return Value{ .nil = {} };
        // Warning is advisory; fallback write is the load-bearing step.
        stderr.writeStreamingAll(ctx.io, msg) catch {};
        writeDirectly(ctx.io, path, new_content);
    };

    return Value{ .nil = {} };
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    // Count occurrences
    var count: usize = 0;
    var pos: usize = 0;
    while (pos <= haystack.len -| needle.len) {
        if (std.mem.startsWith(u8, haystack[pos..], needle)) {
            count += 1;
            pos += needle.len;
        } else {
            pos += 1;
        }
    }

    if (count == 0) return try allocator.dupe(u8, haystack);

    const new_len = haystack.len - (count * needle.len) + (count * replacement.len);
    const buf = try allocator.alloc(u8, new_len);

    var src: usize = 0;
    var dst: usize = 0;
    while (src <= haystack.len -| needle.len) {
        if (std.mem.startsWith(u8, haystack[src..], needle)) {
            @memcpy(buf[dst..][0..replacement.len], replacement);
            dst += replacement.len;
            src += needle.len;
        } else {
            buf[dst] = haystack[src];
            dst += 1;
            src += 1;
        }
    }
    // Copy remaining tail
    if (src < haystack.len) {
        @memcpy(buf[dst..][0 .. haystack.len - src], haystack[src..]);
    }

    return buf;
}

/// Write content atomically: write to temp file then rename over original.
/// Returns one of `AtomicWriteError` to identify the failing step; the
/// underlying error name is written to `underlying_name_out` so the caller
/// can surface the real cause (e.g. NoSpaceLeft) instead of a generic label.
fn writeAtomic(io: std.Io, path: []const u8, content: []const u8, underlying_name_out: *?[]const u8) AtomicWriteError!void {
    const dir_path = std.fs.path.dirname(path) orelse "/";

    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch |e| {
        underlying_name_out.* = @errorName(e);
        return error.TempCreateFailed;
    };
    defer dir.close(io);

    // Create a temp file in the same directory
    const basename = std.fs.path.basename(path);
    var tmp_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".{s}.malt.tmp", .{basename}) catch return error.NameTooLong;

    // Write temp file
    const tmp_file = dir.createFile(io, tmp_name, .{}) catch |e| {
        underlying_name_out.* = @errorName(e);
        return error.TempCreateFailed;
    };
    tmp_file.writeStreamingAll(io, content) catch |e| {
        tmp_file.close(io);
        // Cleanup of the partial tmp file; the write error is what we return.
        dir.deleteFile(io, tmp_name) catch {};
        underlying_name_out.* = @errorName(e);
        return error.WriteFailed;
    };
    tmp_file.close(io);

    // Rename over original
    dir.rename(tmp_name, dir, basename, io) catch |e| {
        // Cleanup of the orphaned tmp file; the rename error is what we return.
        dir.deleteFile(io, tmp_name) catch {};
        underlying_name_out.* = @errorName(e);
        return error.RenameFailed;
    };
}

/// Render the user-visible warning that precedes the direct-overwrite fallback.
/// Surfaces both the failing step (e.g. WriteFailed) and the underlying cause
/// (e.g. NoSpaceLeft) so operators can triage without reading the source.
fn formatAtomicWriteFailureMessage(buf: []u8, kind: AtomicWriteError, underlying: []const u8) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "malt: inreplace atomic write failed ({s}: {s}); falling back to direct overwrite\n",
        .{ @errorName(kind), underlying },
    );
}

/// Fallback: direct overwrite (no atomicity guarantee).
fn writeDirectly(io: std.Io, path: []const u8, content: []const u8) void {
    const out = std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true }) catch return;
    defer out.close(io);
    // Fallback path already logged a warning; no error channel left to surface.
    out.writeStreamingAll(io, content) catch {};
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

test "atomic-write failure message preserves the underlying error name" {
    var buf: [256]u8 = undefined;
    const msg = try formatAtomicWriteFailureMessage(&buf, error.WriteFailed, "NoSpaceLeft");
    try std.testing.expect(std.mem.indexOf(u8, msg, "WriteFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "NoSpaceLeft") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "AccessDenied") == null);
}

test "atomic-write failure message names the failing step" {
    var buf: [256]u8 = undefined;
    const create_msg = try formatAtomicWriteFailureMessage(&buf, error.TempCreateFailed, "ReadOnlyFileSystem");
    try std.testing.expect(std.mem.indexOf(u8, create_msg, "TempCreateFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_msg, "ReadOnlyFileSystem") != null);

    const rename_msg = try formatAtomicWriteFailureMessage(&buf, error.RenameFailed, "CrossDeviceLink");
    try std.testing.expect(std.mem.indexOf(u8, rename_msg, "RenameFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, rename_msg, "CrossDeviceLink") != null);
}
