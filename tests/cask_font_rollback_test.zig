//! malt — font-cask rollback re-source
//! reinstallFromHistory re-drives install() with a synthetic, artifact-less
//! cask, so the JSON font stanzas are gone. T-004 re-sources them from a
//! per-version sidecar written at install time and fed back via an installer
//! override. These tests cover the two offline-testable seams: the override
//! drives the font branch, and the sidecar round-trips the stanza list.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const cask = malt.cask;
const cask_font = malt.cask_font;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn testEnviron() std.process.Environ {
    return malt.app_ctx.processEnviron();
}

fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (test_io.path.dirname(path)) |dir| try test_io.cwd().createDirPath(io, dir);
    const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn expectFileBody(io: std.Io, path: []const u8, body: []const u8) !void {
    const got = try test_io.readFileAbsoluteAlloc(io, testing.allocator, path, 4096);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
}

// A synthetic cask the way reinstallFromHistory builds it: valid metadata but
// no `artifacts` array, so collectFontArtifacts finds nothing.
const synthetic_json =
    \\{"token":"font-x","name":["FontX"],"version":"1.0","desc":"","homepage":"",
    \\ "url":"https://example.com/x.zip","sha256":"no_check","auto_updates":false}
;

fn newInstaller(threaded: *std.Io.Threaded, db: *sqlite.Database, prefix: [:0]const u8) cask.CaskInstaller {
    return cask.CaskInstaller.init(threaded.io(), testEnviron(), testing.allocator, db, prefix);
}

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "font_rollback", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "placeExtracted honors font_entries_override on an artifact-less cask" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("override");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/ttf/A.ttf"), "AAA");

    var c = try cask.parseCask(testing.allocator, synthetic_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    // The override carries the stanzas the synthetic JSON lost — rollback's
    // re-source path. With it set, the font branch must fire despite the empty
    // artifacts.
    const entries = [_]cask_font.FontEntry{.{ .source = "ttf/A.ttf", .target = null }};
    installer.font_entries_override = &entries;

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    try testing.expectEqualStrings(fx.p("Caskroom/font-x/1.0/" ++ cask_font.MANIFEST_NAME), app_path);
    try expectFileBody(io, fx.p("Fonts/A.ttf"), "AAA");
}

const font_cask_json =
    \\{"token":"font-x","name":["FontX"],"version":"1.0","desc":"","homepage":"",
    \\ "url":"https://example.com/x.zip","sha256":"no_check","auto_updates":false,
    \\ "artifacts":[
    \\   {"font":["ttf/A.ttf"],"target":"/$HOME/Library/Fonts/Renamed.ttf"},
    \\   {"font":["B.ttf"]}
    \\ ]}
;

test "font_entries_override is re-sanitized: a tampered sidecar entry cannot traverse" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("tamper");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/Good.ttf"), "GOOD");
    try putFile(io, fx.p("secret"), "SECRET");

    var c = try cask.parseCask(testing.allocator, synthetic_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    // The override comes from an on-disk sidecar that could be tampered; the
    // leaf must re-sanitize at placement so a `..` hop is still rejected.
    const entries = [_]cask_font.FontEntry{
        .{ .source = "../secret", .target = null },
        .{ .source = "Good.ttf", .target = null },
    };
    installer.font_entries_override = &entries;

    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    try expectFileBody(io, fx.p("Fonts/Good.ttf"), "GOOD");
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(io, fx.p("Fonts/secret"), .{}));
}

test "a fresh font install persists a per-version sidecar that round-trips the stanzas" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("sidecar");
    defer fx.deinit();
    const prefix = fx.base;

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/ttf/A.ttf"), "AAA");
    try putFile(io, fx.p("extract/B.ttf"), "BBB");

    var c = try cask.parseCask(testing.allocator, font_cask_json);
    defer c.deinit();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    // Installing (the font branch) must persist the stanzas next to the cached
    // artifact so a later rollback can restore them offline, JSON-free.
    const app_path = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(app_path);

    var spec = (try installer.readFontSpec("font-x", "1.0")).?;
    defer spec.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), spec.entries.len);
    try testing.expectEqualStrings("ttf/A.ttf", spec.entries[0].source);
    try testing.expectEqualStrings("/$HOME/Library/Fonts/Renamed.ttf", spec.entries[0].target.?);
    try testing.expectEqualStrings("B.ttf", spec.entries[1].source);
    try testing.expect(spec.entries[1].target == null);
}

fn readSpecUnderOom(alloc: std.mem.Allocator, db: *sqlite.Database, prefix: [:0]const u8) !void {
    var installer = cask.CaskInstaller.init(std.Options.debug_io, testEnviron(), alloc, db, prefix);
    if (try installer.readFontSpec("font-x", "1.0")) |spec| {
        var s = spec;
        s.deinit(alloc);
    }
}

test "readFontSpec frees its buffers on allocation failure" {
    const io = std.Options.debug_io;
    var fx = try Fixture.init("oom");
    defer fx.deinit();
    try putFile(io, fx.p("cache/Cask/font-x-1.0.fonts"), "ttf/A.ttf\t/x/Renamed.ttf\nB.ttf\n");

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try testing.checkAllAllocationFailures(testing.allocator, readSpecUnderOom, .{ &db, fx.base });
}

test "readFontSpec returns null when no sidecar was written" {
    var fx = try Fixture.init("nospec");
    defer fx.deinit();
    const prefix = fx.base;

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = testEnviron() });
    defer threaded.deinit();
    var installer = newInstaller(&threaded, &db, prefix);

    try testing.expect((try installer.readFontSpec("absent", "9.9")) == null);
}
