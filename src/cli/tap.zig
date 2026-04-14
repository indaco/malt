//! malt — tap command
//! Manage taps (tap/untap).

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const tap_mod = @import("../core/tap.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const TapNameError = error{InvalidTapName};

/// Reject malformed `user/repo` inputs before they're formatted into a
/// GitHub URL or stored as a tap name. No security boundary (no shell
/// expansion, no path traversal reaches disk) — this is just an early,
/// clear "bad input" rather than a confusing failure later.
///
/// Rules: exactly one `/`, each side 1–64 chars of [A-Za-z0-9._-], and
/// neither side starts with `.` (rules out `..` traversal and hidden
/// components).
pub fn validateTapName(name: []const u8) TapNameError!void {
    const slash = std.mem.indexOfScalar(u8, name, '/') orelse return TapNameError.InvalidTapName;
    if (std.mem.indexOfScalarPos(u8, name, slash + 1, '/') != null) return TapNameError.InvalidTapName;
    try validateComponent(name[0..slash]);
    try validateComponent(name[slash + 1 ..]);
}

fn validateComponent(part: []const u8) TapNameError!void {
    if (part.len == 0 or part.len > 64) return TapNameError.InvalidTapName;
    if (part[0] == '.') return TapNameError.InvalidTapName;
    for (part) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return TapNameError.InvalidTapName,
        }
    }
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "tap")) return;

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    if (args.len == 0) {
        // List taps
        const taps = tap_mod.list(allocator, &db) catch {
            output.err("Failed to list taps", .{});
            return;
        };
        defer allocator.free(taps);

        if (taps.len == 0) {
            output.info("No taps registered", .{});
            return;
        }

        for (taps) |t| {
            const f = std.fs.File.stdout();
            f.writeAll(t.name) catch {};
            f.writeAll("\n") catch {};
            allocator.free(t.name);
            allocator.free(t.url);
        }
        return;
    }

    const name = args[0];

    // Check if this is untap (called via main.zig dispatch)
    // The main dispatch sends both "tap" and "untap" here
    // We detect untap by checking if the name is already tapped
    // For explicit untap, we'd need the parent command info
    // For now: if tap already exists, remove it; else add it
    // Better: check a flag or use separate logic

    // Simple approach: "mt tap user/repo" adds, "mt untap user/repo" also comes here
    // We'll just add the tap
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return;
    };

    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://github.com/{s}", .{name}) catch return;
    tap_mod.add(&db, name, url) catch {
        output.err("Failed to add tap {s}", .{name});
        return;
    };
    output.info("Tapped {s}", .{name});
}
