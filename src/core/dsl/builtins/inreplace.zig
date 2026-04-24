//! malt — DSL builtin: inreplace
//! Literal form: inreplace(path, from, to) — read file, replace all, write back.
//! Block form is deferred to a future phase (requires interpreter cooperation).

const std = @import("std");
const fs_compat = @import("../../../fs/compat.zig");
const values = @import("../values.zig");
const sandbox = @import("../sandbox.zig");
const pathname = @import("pathname.zig");

const Value = values.Value;
const BuiltinError = pathname.BuiltinError;
const ExecCtx = pathname.ExecCtx;

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
    const file = fs_compat.openFileAbsolute(path, .{}) catch {
        return Value{ .nil = {} };
    };
    defer file.close();
    const content = file.readToEndAlloc(ctx.allocator, 4 * 1024 * 1024) catch {
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
    writeAtomic(path, new_content) catch |e| {
        const stderr = fs_compat.stderrFile();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "malt: inreplace atomic write failed ({s}); falling back to direct overwrite\n", .{@errorName(e)}) catch return Value{ .nil = {} };
        // Warning is advisory; fallback write is the load-bearing step.
        stderr.writeAll(msg) catch {};
        writeDirectly(path, new_content);
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
fn writeAtomic(path: []const u8, content: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse "/";

    var dir = try fs_compat.openDirAbsolute(dir_path, .{});
    defer dir.close();

    // Create a temp file in the same directory
    const basename = std.fs.path.basename(path);
    var tmp_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, ".{s}.malt.tmp", .{basename}) catch return error.NameTooLong;

    // Write temp file
    const tmp_file = dir.createFile(tmp_name, .{}) catch return error.AccessDenied;
    tmp_file.writeAll(content) catch {
        tmp_file.close();
        // Cleanup of the partial tmp file; the write error is what we return.
        dir.deleteFile(tmp_name) catch {};
        return error.AccessDenied;
    };
    tmp_file.close();

    // Rename over original
    dir.rename(tmp_name, basename) catch {
        // Cleanup of the orphaned tmp file; the rename error is what we return.
        dir.deleteFile(tmp_name) catch {};
        return error.AccessDenied;
    };
}

/// Fallback: direct overwrite (no atomicity guarantee).
fn writeDirectly(path: []const u8, content: []const u8) void {
    const out = fs_compat.createFileAbsolute(path, .{ .truncate = true }) catch return;
    defer out.close();
    // Fallback path already logged a warning; no error channel left to surface.
    out.writeAll(content) catch {};
}
