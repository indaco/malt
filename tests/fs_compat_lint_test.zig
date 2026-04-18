//! malt — lint-as-test for fs_compat.readAll misuse
//!
//! `readAll` is a positional read from offset 0 — safe for single-shot
//! reads of a whole file, fatal inside a loop (every iteration reads
//! the first bytes again). The cask SHA bug was exactly this.
//!
//! This test walks src/ and fails if any file pairs a `while`/`for`
//! keyword with a `readAll(` call within a short window. Use
//! `readAllAt` or `streamFile` for streaming instead.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const fs = malt.fs_compat;

/// Lines of look-ahead after a `while (` / `for (` header before we
/// stop counting. Real streaming loops put the `readAll(` within a
/// handful of lines of the loop header; anything farther is almost
/// certainly unrelated.
const SCAN_WINDOW: usize = 10;

/// Inspect one source buffer for the readAll-in-loop antipattern.
/// Returns the 1-based line number of the first offending `readAll(`
/// call, or null when the file is clean.
///
/// The dangerous shape is re-reading the *same* handle inside a loop.
/// If an `openFile` appears between the loop header and the `readAll`,
/// each iteration works on a fresh handle (one-shot-per-iteration) —
/// that's safe and the scanner skips it. Pure — no I/O.
fn findReadAllInLoop(source: []const u8) ?usize {
    var loop_open_at: ?usize = null;
    var open_file_since_loop: bool = false;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");

        if (isLoopHeader(line)) {
            loop_open_at = line_no;
            open_file_since_loop = false;
            continue;
        }
        if (loop_open_at) |opened| {
            if (line_no - opened > SCAN_WINDOW) {
                loop_open_at = null;
                open_file_since_loop = false;
            }
        }

        // A fresh handle inside the loop body flips the pattern from
        // "re-read same file" (bug) to "one read per new file" (safe).
        if (loop_open_at != null and std.mem.indexOf(u8, line, "openFile") != null) {
            open_file_since_loop = true;
            continue;
        }

        // Flag only bare `readAll(` inside an active loop where the
        // handle was NOT just opened in the same iteration.
        if (loop_open_at != null and !open_file_since_loop and containsBareReadAll(line)) {
            return line_no;
        }
    }
    return null;
}

fn isLoopHeader(line: []const u8) bool {
    // Match the start of a while/for statement — the `(` qualifier
    // rules out `while` as a word inside a comment or string literal.
    return std.mem.startsWith(u8, line, "while (") or
        std.mem.startsWith(u8, line, "for (") or
        std.mem.indexOf(u8, line, " while (") != null or
        std.mem.indexOf(u8, line, " for (") != null;
}

fn containsBareReadAll(line: []const u8) bool {
    // Locate `readAll(`, then make sure the two chars before it are
    // `.` (method call) or `(` / space (free function) rather than
    // `t` (i.e. the `readAllAt` prefix we *do* allow).
    const needle = "readAll(";
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, line, idx, needle)) |pos| {
        // Reject `readAllAt(` by checking the 3 chars before `(`.
        if (pos >= 2 and std.mem.eql(u8, line[pos + "readAll".len - 2 .. pos + "readAll".len], "ll") and
            (pos + needle.len) <= line.len and line[pos + needle.len - 1] == '(')
        {
            // Also confirm this isn't inside `readAllAt` — At would
            // appear immediately after readAll, but splitScalar above
            // matched `readAll(` already, so At can't be there.
            return true;
        }
        idx = pos + needle.len;
    }
    return false;
}

// ─── unit tests on the detector itself ───────────────────────────────

test "findReadAllInLoop flags the classic positional-0 bug shape" {
    const bad =
        \\while (remaining > 0) {
        \\    const n = file.readAll(buf) catch break;
        \\    if (n == 0) break;
        \\}
    ;
    try testing.expect(findReadAllInLoop(bad) != null);
}

test "findReadAllInLoop flags for-loops too" {
    const bad =
        \\for (chunks) |_| {
        \\    const n = file.readAll(&magic) catch break;
        \\    _ = n;
        \\}
    ;
    try testing.expect(findReadAllInLoop(bad) != null);
}

test "findReadAllInLoop accepts readAllAt inside a loop" {
    const ok =
        \\while (true) {
        \\    const n = try file.readAllAt(buf, offset);
        \\    if (n == 0) break;
        \\}
    ;
    try testing.expect(findReadAllInLoop(ok) == null);
}

test "findReadAllInLoop accepts a single-shot readAll outside any loop" {
    const ok =
        \\const data = allocator.alloc(u8, stat.size) catch return;
        \\const n = file.readAll(data) catch return;
        \\_ = n;
    ;
    try testing.expect(findReadAllInLoop(ok) == null);
}

test "findReadAllInLoop allows readAll when openFile opens a fresh handle per iteration" {
    // This is the cellar-walk pattern: open a new file per directory
    // entry, read its magic, close. Each iteration is one-shot and
    // therefore safe regardless of being inside a while loop.
    const ok =
        \\while (walker.next() catch null) |entry| {
        \\    const file = fs_compat.openFileAbsolute(path, .{}) catch continue;
        \\    var magic: [4]u8 = undefined;
        \\    const n = file.readAll(&magic) catch continue;
        \\    _ = n;
        \\}
    ;
    try testing.expect(findReadAllInLoop(ok) == null);
}

test "findReadAllInLoop ignores loops far above an unrelated readAll call" {
    // A `while` many lines earlier should NOT trigger on a one-shot
    // read — the window expires. Otherwise the lint would false-
    // positive on any file that happens to contain unrelated loops.
    const ok =
        \\while (it.next()) |entry| {
        \\    process(entry);
        \\}
        \\
        \\// 20 lines later, a one-shot read:
        \\//
        \\//
        \\//
        \\//
        \\//
        \\//
        \\//
        \\//
        \\//
        \\//
        \\const data = allocator.alloc(u8, stat.size) catch return;
        \\const n = file.readAll(data) catch return;
    ;
    try testing.expect(findReadAllInLoop(ok) == null);
}

test "findReadAllInLoop reports the line number of the first offender" {
    const bad =
        \\// line 1
        \\// line 2
        \\while (x) {
        \\    const n = file.readAll(buf) catch break;
        \\}
    ;
    try testing.expectEqual(@as(usize, 4), findReadAllInLoop(bad).?);
}

// ─── the guard itself: scan src/ ─────────────────────────────────────
//
// Fails loud if a future contributor (or a careless revert of the
// cask fix) re-introduces the bug pattern anywhere under src/.

test "no readAll() inside a loop anywhere under src/" {
    var dir = try fs.cwd().openDir("src", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(testing.allocator, 1 << 22);
        defer testing.allocator.free(content);

        if (findReadAllInLoop(content)) |line| {
            const msg = try std.fmt.allocPrint(
                testing.allocator,
                "src/{s}:{d}: readAll() inside a loop — use readAllAt or fs_compat.streamFile",
                .{ entry.path, line },
            );
            try failures.append(testing.allocator, msg);
        }
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.ReadAllInLoop;
    }
}
