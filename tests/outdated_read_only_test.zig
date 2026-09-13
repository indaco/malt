//! malt — `mt outdated` is read-only against the tap pin
//!
//! `taps.commit_sha` is what `mt upgrade` reads as "installed at", so a
//! read-only check that advances it wedges the next upgrade. The resolver
//! has no network-free seam; this grep is the offline guard, the round trip
//! lives in `scripts/regressions/read-only-outdated-advances-tap-pin-*.sh`.

const std = @import("std");
const testing = std.testing;
const test_io = @import("test_io");

// Bare `updateHead(` is unique enough to survive an import alias; `add(` is not.
const pin_writers = [_][]const u8{ "updateHead(", "tap_mod.add(" };

fn stripLineComment(line: []const u8) []const u8 {
    const idx = std.mem.indexOf(u8, line, "//") orelse return line;
    return line[0..idx];
}

test "no tap pin writer under src/cli/outdated/" {
    const alloc = testing.allocator;
    var dir = try test_io.cwd().openDir(std.Options.debug_io, "src/cli/outdated", .{ .iterate = true });
    defer dir.close(std.Options.debug_io);
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var found = false;
    while (try walker.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const f = try entry.dir.openFile(std.Options.debug_io, entry.basename, .{});
        defer f.close(std.Options.debug_io);
        const src = try test_io.readFileToEndAlloc(f, alloc, 4 * 1024 * 1024);
        defer alloc.free(src);

        var it = std.mem.splitScalar(u8, src, '\n');
        var lineno: usize = 0;
        while (it.next()) |line| {
            lineno += 1;
            const stripped = stripLineComment(line);
            for (pin_writers) |w| {
                if (std.mem.indexOf(u8, stripped, w) == null) continue;
                std.debug.print("read-only outdated writes the tap pin: src/cli/outdated/{s}:{d}: {s}\n", .{ entry.path, lineno, line });
                found = true;
            }
        }
    }
    if (found) return error.TestUnexpectedResult;
}
