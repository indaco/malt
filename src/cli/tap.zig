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
    const slash = std.mem.findScalar(u8, name, '/') orelse return TapNameError.InvalidTapName;
    if (std.mem.findScalarPos(u8, name, slash + 1, '/') != null) return TapNameError.InvalidTapName;
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
    return run(allocator, args, .add);
}

pub fn executeUntap(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return run(allocator, args, .remove);
}

const Action = enum { add, remove };

fn run(allocator: std.mem.Allocator, args: []const []const u8, action: Action) !void {
    if (help.showIfRequested(args, if (action == .add) "tap" else "untap")) return;

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = no taps registered.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    if (args.len == 0) {
        if (action == .remove) {
            output.err("Usage: mt untap user/repo", .{});
            return error.Aborted;
        }
        // List taps
        const taps = tap_mod.list(allocator, &db) catch {
            output.err("Failed to list taps", .{});
            return error.Aborted;
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
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return error.Aborted;
    };

    switch (action) {
        .add => {
            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://github.com/{s}", .{name}) catch return;
            tap_mod.add(&db, name, url) catch {
                output.err("Failed to add tap {s}", .{name});
                return error.Aborted;
            };
            output.info("Tapped {s}", .{name});
        },
        .remove => {
            tap_mod.remove(&db, name) catch {
                output.err("Failed to untap {s}", .{name});
                return error.Aborted;
            };
            output.info("Untapped {s}", .{name});
        },
    }
}
