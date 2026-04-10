//! malt — backup command tests
//! The execute() function touches the SQLite database and writes to the
//! filesystem, so these tests cover the pure helpers (writeEntry, parseLine,
//! parseBackup, defaultBackupPath) that do the actual work.

const std = @import("std");
const testing = std.testing;
const backup = @import("malt").backup;

// ── writeEntry / writeHeader ─────────────────────────────────────────────

test "writeEntry writes a bare formula line without a version" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try backup.writeEntry(buf.writer(testing.allocator), .formula, "git", "2.44.0", false);
    try testing.expectEqualStrings("formula git\n", buf.items);
}

test "writeEntry writes a bare cask line without a version" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try backup.writeEntry(buf.writer(testing.allocator), .cask, "firefox", "124.0", false);
    try testing.expectEqualStrings("cask firefox\n", buf.items);
}

test "writeEntry includes @version when include_versions is true" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try backup.writeEntry(buf.writer(testing.allocator), .formula, "wget", "1.24.5", true);
    try testing.expectEqualStrings("formula wget@1.24.5\n", buf.items);
}

test "writeEntry omits @version even with include_versions when version is empty" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try backup.writeEntry(buf.writer(testing.allocator), .cask, "slack", "", true);
    try testing.expectEqualStrings("cask slack\n", buf.items);
}

test "writeHeader emits comment lines and a trailing blank line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try backup.writeHeader(buf.writer(testing.allocator));

    // Every non-blank line in the header must start with `#` so that
    // `parseBackup` ignores them when the file is restored.
    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try testing.expectEqual(@as(u8, '#'), line[0]);
    }
}

// ── parseLine ────────────────────────────────────────────────────────────

test "parseLine returns null for blank lines and comments" {
    try testing.expect(backup.parseLine("") == null);
    try testing.expect(backup.parseLine("   ") == null);
    try testing.expect(backup.parseLine("\t") == null);
    try testing.expect(backup.parseLine("# malt backup") == null);
    try testing.expect(backup.parseLine("   # indented comment") == null);
}

test "parseLine parses a bare formula line" {
    const e = backup.parseLine("formula git").?;
    try testing.expectEqual(backup.Kind.formula, e.kind);
    try testing.expectEqualStrings("git", e.name);
    try testing.expectEqualStrings("", e.version);
}

test "parseLine parses a bare cask line" {
    const e = backup.parseLine("cask firefox").?;
    try testing.expectEqual(backup.Kind.cask, e.kind);
    try testing.expectEqualStrings("firefox", e.name);
    try testing.expectEqualStrings("", e.version);
}

test "parseLine parses the @version suffix" {
    const f = backup.parseLine("formula wget@1.24.5").?;
    try testing.expectEqual(backup.Kind.formula, f.kind);
    try testing.expectEqualStrings("wget", f.name);
    try testing.expectEqualStrings("1.24.5", f.version);

    const c = backup.parseLine("cask slack@4.36.140").?;
    try testing.expectEqual(backup.Kind.cask, c.kind);
    try testing.expectEqualStrings("slack", c.name);
    try testing.expectEqualStrings("4.36.140", c.version);
}

test "parseLine tolerates trailing carriage returns and surrounding whitespace" {
    const a = backup.parseLine("  formula git  \r").?;
    try testing.expectEqualStrings("git", a.name);

    const b = backup.parseLine("cask firefox\r").?;
    try testing.expectEqualStrings("firefox", b.name);
}

test "parseLine returns null for unknown kinds and malformed lines" {
    // Unknown kind prefix.
    try testing.expect(backup.parseLine("bottle git") == null);
    // Kind prefix without a name.
    try testing.expect(backup.parseLine("formula ") == null);
    try testing.expect(backup.parseLine("cask   ") == null);
    // No space between kind and name (missed prefix).
    try testing.expect(backup.parseLine("formulagit") == null);
}

// ── parseBackup + round-trip ─────────────────────────────────────────────

test "parseBackup ignores comments and parses every data line in order" {
    const text =
        "# malt backup\n" ++
        "# some header comment\n" ++
        "\n" ++
        "formula git\n" ++
        "formula wget@1.24.5\n" ++
        "# mid-file comment\n" ++
        "cask firefox\n" ++
        "cask slack@4.36.140\n";

    const entries = try backup.parseBackup(testing.allocator, text);
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 4), entries.len);

    try testing.expectEqual(backup.Kind.formula, entries[0].kind);
    try testing.expectEqualStrings("git", entries[0].name);
    try testing.expectEqualStrings("", entries[0].version);

    try testing.expectEqual(backup.Kind.formula, entries[1].kind);
    try testing.expectEqualStrings("wget", entries[1].name);
    try testing.expectEqualStrings("1.24.5", entries[1].version);

    try testing.expectEqual(backup.Kind.cask, entries[2].kind);
    try testing.expectEqualStrings("firefox", entries[2].name);

    try testing.expectEqual(backup.Kind.cask, entries[3].kind);
    try testing.expectEqualStrings("slack", entries[3].name);
    try testing.expectEqualStrings("4.36.140", entries[3].version);
}

test "parseBackup handles an empty input" {
    const entries = try backup.parseBackup(testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseBackup handles a file with only comments and blank lines" {
    const text =
        "# header\n" ++
        "\n" ++
        "   \n" ++
        "# another\n";
    const entries = try backup.parseBackup(testing.allocator, text);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "parseBackup tolerates a file that does not end with a newline" {
    const text = "formula git\ncask firefox";
    const entries = try backup.parseBackup(testing.allocator, text);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("git", entries[0].name);
    try testing.expectEqualStrings("firefox", entries[1].name);
}

test "parseBackup skips junk lines instead of failing" {
    // Unknown kinds and broken lines should be silently dropped so one bad
    // edit does not invalidate the whole backup file.
    const text =
        "formula git\n" ++
        "gibberish line\n" ++
        "formula \n" ++ // empty name
        "cask firefox\n" ++
        "pkg nope\n";
    const entries = try backup.parseBackup(testing.allocator, text);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("git", entries[0].name);
    try testing.expectEqualStrings("firefox", entries[1].name);
}

test "writeEntry + parseBackup round-trip preserves every entry" {
    const fixtures = [_]struct {
        kind: backup.Kind,
        name: []const u8,
        version: []const u8,
    }{
        .{ .kind = .formula, .name = "git", .version = "2.44.0" },
        .{ .kind = .formula, .name = "wget", .version = "1.24.5" },
        .{ .kind = .cask, .name = "firefox", .version = "124.0" },
        .{ .kind = .cask, .name = "slack", .version = "4.36.140" },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const w = buf.writer(testing.allocator);
    try backup.writeHeader(w);
    for (fixtures) |f| {
        try backup.writeEntry(w, f.kind, f.name, f.version, true);
    }

    const entries = try backup.parseBackup(testing.allocator, buf.items);
    defer testing.allocator.free(entries);

    try testing.expectEqual(fixtures.len, entries.len);
    inline for (fixtures, 0..) |f, i| {
        try testing.expectEqual(f.kind, entries[i].kind);
        try testing.expectEqualStrings(f.name, entries[i].name);
        try testing.expectEqualStrings(f.version, entries[i].version);
    }
}

// ── defaultBackupPath ────────────────────────────────────────────────────

test "defaultBackupPath has the expected shape" {
    const path = try backup.defaultBackupPath(testing.allocator);
    defer testing.allocator.free(path);

    // Expected shape: "malt-backup-YYYY-MM-DDTHH-MM-SS.txt" (35 chars).
    try testing.expect(std.mem.startsWith(u8, path, "malt-backup-"));
    try testing.expect(std.mem.endsWith(u8, path, ".txt"));
    try testing.expectEqual(@as(usize, 35), path.len);

    // Every non-separator character must be a digit so the filename is
    // safe on every filesystem (no spaces, no colons).
    const body = path["malt-backup-".len .. path.len - ".txt".len];
    for (body) |ch| {
        const is_digit = ch >= '0' and ch <= '9';
        const is_sep = ch == '-' or ch == 'T';
        try testing.expect(is_digit or is_sep);
    }
}
