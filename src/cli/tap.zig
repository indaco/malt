//! malt — tap command
//! Manage taps (tap/untap).

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
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

/// Primitive entry point for core/bundle's dispatcher: add a single tap by
/// name. Argv parsing stays in `execute`; this is the non-argv seam.
pub fn tapAdd(allocator: std.mem.Allocator, name: []const u8) !void {
    const argv = [_][]const u8{name};
    return run(allocator, &argv, .add);
}

pub fn executeUntap(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return run(allocator, args, .remove);
}

const Action = enum { add, remove };

fn run(allocator: std.mem.Allocator, args: []const []const u8, action: Action) !void {
    if (help.showIfRequested(args, if (action == .add) "tap" else "untap")) return;

    // --refresh <name>: update the stored commit pin to current HEAD.
    var refresh_target: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--refresh")) {
            // `--refresh` without a name refreshes the positional,
            // resolved below. We just flag the mode here.
            refresh_target = "";
        } else if (std.mem.startsWith(u8, arg, "--refresh=")) {
            refresh_target = arg["--refresh=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional == null) positional = arg;
        }
    }
    if (refresh_target) |rt| {
        if (rt.len == 0) refresh_target = positional;
    }

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = no taps registered.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    if (refresh_target) |target| {
        if (action != .add) {
            output.err("--refresh is only valid with `mt tap`", .{});
            return error.Aborted;
        }
        try refreshTap(allocator, &db, target);
        return;
    }

    if (positional == null) {
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
            const f = fs_compat.stdoutFile();
            f.writeAll(t.name) catch {};
            if (t.commit_sha) |sha| {
                f.writeAll(" @ ") catch {};
                // Print just the 7-char short SHA to keep the listing compact.
                const short_len = @min(sha.len, 7);
                f.writeAll(sha[0..short_len]) catch {};
            } else {
                f.writeAll(" (unpinned — run `mt tap --refresh ") catch {};
                f.writeAll(t.name) catch {};
                f.writeAll("`)") catch {};
            }
            f.writeAll("\n") catch {};
            allocator.free(t.name);
            allocator.free(t.url);
            if (t.commit_sha) |sha| allocator.free(sha);
        }
        return;
    }

    const name = positional.?;
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return error.Aborted;
    };

    switch (action) {
        .add => {
            const slash = std.mem.findScalar(u8, name, '/').?;
            const user = name[0..slash];
            const repo = name[slash + 1 ..];
            // Resolve HEAD so the tap is pinned from day one. Failing
            // here beats silently registering an unpinned tap.
            const sha = tap_mod.resolveHeadCommit(allocator, user, repo) catch {
                output.err("Could not resolve {s}'s HEAD commit. Network down?", .{name});
                return error.Aborted;
            };
            defer allocator.free(sha);
            var url_buf: [256]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://github.com/{s}", .{name}) catch return;
            tap_mod.add(&db, name, url, sha) catch {
                output.err("Failed to add tap {s}", .{name});
                return error.Aborted;
            };
            output.info("Tapped {s} @ {s}", .{ name, sha[0..@min(sha.len, 7)] });
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

fn refreshTap(allocator: std.mem.Allocator, db: *sqlite.Database, name: []const u8) !void {
    validateTapName(name) catch {
        output.err("Invalid tap '{s}'. Expected: user/repo with [A-Za-z0-9._-]", .{name});
        return error.Aborted;
    };
    const slash = std.mem.findScalar(u8, name, '/').?;
    const user = name[0..slash];
    const repo = name[slash + 1 ..];
    const sha = tap_mod.resolveHeadCommit(allocator, user, repo) catch {
        output.err("Could not resolve {s}'s HEAD commit. Network down?", .{name});
        return error.Aborted;
    };
    defer allocator.free(sha);
    tap_mod.updateCommit(db, name, sha) catch {
        output.err("Failed to update commit pin for {s}", .{name});
        return error.Aborted;
    };
    output.info("Refreshed {s} to {s}", .{ name, sha[0..@min(sha.len, 7)] });
}
