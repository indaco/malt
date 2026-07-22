//! malt — parsed-revision consumer guard
//!
//! A cask has no revision: the Cask DSL has no such stanza and the `casks`
//! table has no such column. But `parseRubyFormula` serves both the formula
//! and cask legs and greps `revision` layout-blind, so a hand-written tap
//! `.rb` can hand one to either caller. Qualifying a cask version with it
//! mints a string no installed cask can ever equal — the row is listed
//! forever and the upgrade is skipped forever.
//!
//! Keeping that correct means keeping every consumer of the parsed revision
//! accounted for. A cask-side consumer that qualifies is a bug; the failure
//! is silent, needs hand-written tap content to trigger, and lives in a
//! different file from the code it contradicts. So the count is pinned here:
//! a new consumer fails this test and has to declare which leg it serves.
//!
//! The guard keys on `rb_info.revision`, the binding both call sites use for
//! `parseRubyFormula`'s result. Renaming that binding means updating this
//! list.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

const TOKEN = "rb_info.revision";

/// Every accounted-for consumer, with the leg it serves. Paths are relative
/// to `src/cli`, the walked root.
const allowed = [_]struct {
    path: []const u8,
    why: []const u8,
}{
    .{
        .path = "outdated/refresh.zig",
        .why = "shared fetch leg — forces 0 on the cask subtree before qualifying",
    },
    .{
        .path = "upgrade.zig",
        .why = "tap formula leg — formulas do carry revisions, so it qualifies",
    },
};

fn allowedFor(path: []const u8) ?usize {
    for (allowed, 0..) |entry, i| {
        if (std.mem.eql(u8, path, entry.path)) return i;
    }
    return null;
}

test "every consumer of a parsed .rb revision is accounted for" {
    const allocator = testing.allocator;

    var dir = try test_io.cwd().openDir(std.Options.debug_io, "src/cli", .{ .iterate = true });
    defer dir.close(std.Options.debug_io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var seen = [_]usize{0} ** allowed.len;

    while (try walker.next(std.Options.debug_io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.basename, ".zig")) continue;

        const f = try ent.dir.openFile(std.Options.debug_io, ent.basename, .{});
        defer f.close(std.Options.debug_io);
        const src = try test_io.readFileToEndAlloc(f, allocator, 4 * 1024 * 1024);
        defer allocator.free(src);

        var hits: usize = 0;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            if (std.mem.indexOf(u8, line, TOKEN) != null) hits += 1;
        }
        if (hits == 0) continue;

        const idx = allowedFor(ent.path) orelse {
            std.debug.print(
                "\nsrc/cli/{s} consumes the parsed .rb revision and is not accounted for.\n" ++
                    "If it serves casks it must force 0 — see the outdated policy note\n" ++
                    "in src/cli/outdated/refresh.zig. If it serves formulas, add it here.\n",
                .{ent.path},
            );
            return error.UnaccountedRevisionConsumer;
        };
        seen[idx] += hits;
    }

    // One use each: the guarded ternary and the formula-leg qualification. A
    // second use in the same file is the shape the cask dry-run sink had.
    for (allowed, seen) |entry, count| {
        if (count == 1) continue;
        std.debug.print(
            "\n{s} uses the parsed .rb revision {d} time(s), expected 1 ({s}).\n",
            .{ entry.path, count, entry.why },
        );
        return error.RevisionConsumerCountChanged;
    }
}
