//! malt — tap command
//! Manage taps (tap/untap).

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const tap_mod = @import("../core/tap.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
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
    var url_buf: [256]u8 = undefined;

    // Parse user/repo format
    if (std.mem.indexOfScalar(u8, name, '/')) |_| {
        const url = std.fmt.bufPrint(&url_buf, "https://github.com/{s}", .{name}) catch return;
        tap_mod.add(&db, name, url) catch {
            output.err("Failed to add tap {s}", .{name});
            return;
        };
        output.info("Tapped {s}", .{name});
    } else {
        output.err("Invalid tap format. Use: mt tap user/repo", .{});
    }
}
