//! malt — backup command tests
//! The execute() function touches the SQLite database and writes to the
//! filesystem, so these tests cover the pure helpers (writeEntry, parseLine,
//! parseBackup, defaultBackupPath) that do the actual work.

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const backup = malt.backup;

// ── writeEntry / writeHeader ─────────────────────────────────────────────

test "writeEntry writes a bare formula line without a version" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeEntry(&aw.writer, .formula, "git", "2.44.0", false);
    try testing.expectEqualStrings("formula git\n", aw.written());
}

test "writeEntry writes a bare cask line without a version" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeEntry(&aw.writer, .cask, "firefox", "124.0", false);
    try testing.expectEqualStrings("cask firefox\n", aw.written());
}

test "writeEntry writes the version as a separate field when include_versions is true" {
    // A `@` suffix is ambiguous with versioned names like `postgresql@16`
    // and reached install as a literal package name.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeEntry(&aw.writer, .formula, "wget", "1.24.5", true);
    try backup.writeEntry(&aw.writer, .formula, "postgresql@16", "16.4", true);
    try testing.expectEqualStrings("formula wget 1.24.5\nformula postgresql@16 16.4\n", aw.written());
}

test "writeEntry omits the version even with include_versions when version is empty" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeEntry(&aw.writer, .cask, "slack", "", true);
    try testing.expectEqualStrings("cask slack\n", aw.written());
}

test "writeHeader emits comment lines and a trailing blank line" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeHeader(&aw.writer);

    // Every non-blank line in the header must start with `#` so that
    // `parseBackup` ignores them when the file is restored.
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
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

test "parseLine reads the version from the second field" {
    const f = backup.parseLine("formula wget 1.24.5").?;
    try testing.expectEqual(backup.Kind.formula, f.kind);
    try testing.expectEqualStrings("wget", f.name);
    try testing.expectEqualStrings("1.24.5", f.version);

    const c = backup.parseLine("cask slack \t 4.36.140\r").?;
    try testing.expectEqual(backup.Kind.cask, c.kind);
    try testing.expectEqualStrings("slack", c.name);
    try testing.expectEqualStrings("4.36.140", c.version);
}

test "parseLine keeps `@` inside the name, versioned or not" {
    // `postgresql@16` is a package name; splitting it would install `postgresql`.
    const bare = backup.parseLine("formula postgresql@16").?;
    try testing.expectEqualStrings("postgresql@16", bare.name);
    try testing.expectEqualStrings("", bare.version);

    const pinned = backup.parseLine("formula postgresql@16 16.4").?;
    try testing.expectEqualStrings("postgresql@16", pinned.name);
    try testing.expectEqualStrings("16.4", pinned.version);

    // A legacy `name@version` line stays one token: no heuristic can tell it
    // from a versioned name.
    const legacy = backup.parseLine("formula wget@1.24.5").?;
    try testing.expectEqualStrings("wget@1.24.5", legacy.name);
    try testing.expectEqualStrings("", legacy.version);
}

test "parseLine takes the rest of the line as the version" {
    // A tap may declare `version "1.0 beta"`; splitting it would drop the line.
    const e = backup.parseLine("formula acme/tools/foo 1.0 beta\r").?;
    try testing.expectEqualStrings("acme/tools/foo", e.name);
    try testing.expectEqualStrings("1.0 beta", e.version);
    // Services carry no version, so anything after the name is malformed.
    try testing.expect(backup.parseLine("service redis extra") == null);
}

// ── parseLocalNote ───────────────────────────────────────────────────────

test "parseLocalNote reads the keg name and the rest of the line as its recipe path" {
    const n = backup.parseLocalNote("# local lx /src/my dir/lx.rb\r").?;
    try testing.expectEqualStrings("lx", n.name);
    try testing.expectEqualStrings("/src/my dir/lx.rb", n.path);
}

test "parseLocalNote ignores every other comment and malformed note" {
    try testing.expect(backup.parseLocalNote("# malt backup") == null);
    try testing.expect(backup.parseLocalNote("#local lx /src/lx.rb") == null);
    try testing.expect(backup.parseLocalNote("# local") == null);
    try testing.expect(backup.parseLocalNote("# local lx") == null);
    try testing.expect(backup.parseLocalNote("# local lx   ") == null);
    try testing.expect(backup.parseLocalNote("formula lx") == null);
    // Older readers see a comment, so the note never becomes an install.
    try testing.expect(backup.parseLine("# local lx /src/lx.rb") == null);
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
    try testing.expect(backup.parseLine("service ") == null);
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
        "formula wget 1.24.5\n" ++
        "# mid-file comment\n" ++
        "cask firefox\n" ++
        "cask slack 4.36.140\n";

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
        expected_version: []const u8,
    }{
        .{ .kind = .formula, .name = "git", .version = "2.44.0", .expected_version = "2.44.0" },
        .{ .kind = .formula, .name = "wget", .version = "1.24.5", .expected_version = "1.24.5" },
        .{ .kind = .formula, .name = "postgresql@16", .version = "16.4", .expected_version = "16.4" },
        .{ .kind = .formula, .name = "acme/tools/foo", .version = "1.0 beta", .expected_version = "1.0 beta" },
        .{ .kind = .cask, .name = "firefox", .version = "124.0", .expected_version = "124.0" },
        .{ .kind = .cask, .name = "slack", .version = "4.36.140", .expected_version = "4.36.140" },
        // Services round-trip with the full `name@channel` intact and no
        // version surfaced — the schema doesn't carry one.
        .{ .kind = .service, .name = "postgresql@16", .version = "", .expected_version = "" },
        .{ .kind = .service, .name = "redis", .version = "", .expected_version = "" },
    };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try backup.writeHeader(w);
    for (fixtures) |f| {
        try backup.writeEntry(w, f.kind, f.name, f.version, true);
    }

    const entries = try backup.parseBackup(testing.allocator, aw.written());
    defer testing.allocator.free(entries);

    try testing.expectEqual(fixtures.len, entries.len);
    inline for (fixtures, 0..) |f, i| {
        try testing.expectEqual(f.kind, entries[i].kind);
        try testing.expectEqualStrings(f.name, entries[i].name);
        try testing.expectEqualStrings(f.expected_version, entries[i].version);
    }
}

test "writeRows output parses back into restore entries with the tap kept on the cask" {
    // The row writer and `parseBackup` are the two ends of the restore
    // contract: a tap-qualified cask must come back as one name that
    // `install --cask` can route to the owning tap.
    var db = try malt.sqlite.Database.open(":memory:");
    defer db.close();
    try malt.schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path)
        \\  VALUES ('git', 'git', '2.0', 'a', '/c/git');
        \\INSERT INTO casks(token, name, version, url, tap)
        \\  VALUES ('foo', 'Foo', '1.0', 'https://x/foo.dmg', 'acme/tools');
        \\INSERT INTO services(name, keg_name, plist_path, auto_start)
        \\  VALUES ('svc', 'svc', '/svc.plist', 1);
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeHeader(&aw.writer);
    _ = try backup.writeRows(&aw.writer, &db, true, true);

    const entries = try backup.parseBackup(testing.allocator, aw.written());
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(backup.Kind.formula, entries[0].kind);
    try testing.expectEqualStrings("git", entries[0].name);
    try testing.expectEqual(backup.Kind.cask, entries[1].kind);
    try testing.expectEqualStrings("acme/tools/foo", entries[1].name);
    try testing.expectEqualStrings("1.0", entries[1].version);
    try testing.expectEqual(backup.Kind.service, entries[2].kind);
    try testing.expectEqualStrings("svc", entries[2].name);
}

test "writeRows keeps a clean local note but drops one a carriage return would split" {
    // The file is meant to be hand-edited, and editors break a line on a bare
    // CR; a clean path must still leave its rebuild hint behind.
    var db = try malt.sqlite.Database.open(":memory:");
    defer db.close();
    try malt.schema.initSchema(&db);
    try db.exec(
        \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path, tap) VALUES
        \\  ('la', '/w/la.rb', '1.0', 'a', '/c/la', 'local'),
        \\  ('lb', '/w/b' || char(13) || 'formula evil/lb.rb', '1.0', 'b', '/c/lb', 'local');
    );

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const count = try backup.writeRows(&aw.writer, &db, true, false);

    try testing.expectEqual(@as(usize, 0), count);
    try testing.expectEqualStrings("# local la /w/la.rb\n", aw.written());
}

// ── defaultBackupPath ────────────────────────────────────────────────────

test "writeBackupJson: empty inputs emit `{formulas:[],casks:[]}\\n`" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeBackupJson(&aw.writer, &.{}, &.{}, &.{}, null);
    try testing.expectEqualStrings("{\"formulas\":[],\"casks\":[]}\n", aw.written());
}

test "writeBackupJson: emits `name`/`version`/`tap` for formulas and casks" {
    // Formulas carry `tap` like casks so a consumer can restore a tap keg
    // from its owning tap instead of homebrew/core.
    const formulas = [_]backup.JsonFormula{
        .{ .name = "wget", .version = "1.21", .tap = "" },
        .{ .name = "jq", .version = "1.7", .tap = "acme/tools" },
    };
    const casks = [_]backup.JsonCask{
        .{ .name = "firefox", .version = "120.0", .tap = "" },
        .{ .name = "flux-markdown", .version = "0.1.0", .tap = "xykong/tap" },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeBackupJson(&aw.writer, &formulas, &casks, &.{}, null);
    try testing.expectEqualStrings(
        "{\"formulas\":[" ++
            "{\"name\":\"wget\",\"version\":\"1.21\",\"tap\":\"\"}," ++
            "{\"name\":\"jq\",\"version\":\"1.7\",\"tap\":\"acme/tools\"}" ++
            "],\"casks\":[" ++
            "{\"name\":\"firefox\",\"version\":\"120.0\",\"tap\":\"\"}," ++
            "{\"name\":\"flux-markdown\",\"version\":\"0.1.0\",\"tap\":\"xykong/tap\"}" ++
            "]}\n",
        aw.written(),
    );
}

test "writeBackupJson: appends services array only when caller opts in" {
    const services = [_]backup.JsonService{
        .{ .name = "postgresql@16", .auto_start = true },
    };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try backup.writeBackupJson(&aw.writer, &.{}, &.{}, &.{}, &services);
    try testing.expectEqualStrings(
        "{\"formulas\":[],\"casks\":[]," ++
            "\"services\":[{\"name\":\"postgresql@16\",\"auto_start\":true}]}\n",
        aw.written(),
    );
}

test "defaultBackupPath has the expected shape" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };

    const path = try backup.defaultBackupPath(&ctx, testing.allocator);
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
