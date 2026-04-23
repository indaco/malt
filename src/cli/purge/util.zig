//! malt — purge shared helpers (allocator-free formatting, stat walking,
//! db open, confirmation prompts) used by both `wipe` and `scopes`.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const sqlite = @import("../../db/sqlite.zig");
const output = @import("../../ui/output.zig");
const io_mod = @import("../../ui/io.zig");
const args_mod = @import("args.zig");

pub const Error = args_mod.Error;

pub const TierResult = struct {
    removed: u32 = 0,
    bytes: u64 = 0,
};

pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

pub fn pathSize(allocator: std.mem.Allocator, path: []const u8) u64 {
    if (fs_compat.cwd().statFile(path)) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| {}

    var dir = fs_compat.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next() catch null) |entry| {
        if (entry.kind == .file) {
            const s = std.Io.Dir.statFile(entry.dir, io_mod.ctx(), entry.basename, .{}) catch continue;
            total += s.size;
        }
    }
    return total;
}

pub fn openDb(prefix: []const u8) ?sqlite.Database {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return null;
    return sqlite.Database.open(db_path) catch null;
}

pub fn confirmScope(yes: bool, expected: []const u8, scope_label: []const u8) Error!void {
    if (yes) return;
    var prompt_buf: [128]u8 = undefined;
    const prompt = std.fmt.bufPrint(
        &prompt_buf,
        "Type `{s}` to confirm {s} (anything else aborts): ",
        .{ expected, scope_label },
    ) catch "Type the scope name to confirm: ";
    if (!output.confirmTyped(expected, prompt)) {
        output.info("aborted", .{});
        return Error.UserAborted;
    }
}

pub fn writeStderr(s: []const u8) void {
    io_mod.stderrWriteAll(s);
}
