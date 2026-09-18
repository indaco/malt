//! malt - binary-only zip cask integration
//! A zip cask that ships a bare executable and no `.app` links it into
//! `<prefix>/bin` from a persisted Caskroom copy, the way a tarball already
//! does. Feeds a pre-populated extract dir so no ditto or network is needed.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const cask = malt.cask;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (test_io.path.dirname(path)) |dir| try test_io.cwd().createDirPath(io, dir);
    const f = try test_io.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "binzip", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}/{s}", .{ self.base, sub }, 0) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

fn linkTarget(io: std.Io, link: []const u8, buf: []u8) ![]const u8 {
    const n = try std.Io.Dir.readLinkAbsolute(io, link, buf);
    return buf[0..n];
}

// The live shape: `target` is a sibling of `binary`, spelled as a full
// `$HOMEBREW_PREFIX/bin/<name>` path.
const rabbit_json =
    \\{"token":"rabbit","name":["Rabbit"],"version":"0.7.8","url":"https://example.invalid/rabbit-darwin-arm64.zip","sha256":"no_check",
    \\ "artifacts":[{"binary":["rabbit"],"target":"$HOMEBREW_PREFIX/bin/rabbit"},{"zap":[{"trash":"~/.rabbit"}]}]}
;

test "a binary-only zip cask links its executable from a persisted Caskroom copy" {
    var fx = try Fixture.init("link");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, rabbit_json);
    defer c.deinit();

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/rabbit"), "#!/bin/sh\necho rabbit\n");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    const placed = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings(fx.p("bin/rabbit"), placed);

    // The extract dir is gone after a real install, so the link must point
    // into the Caskroom, not back at the stage. The link content is the
    // resolved path, so compare against the real one.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = real_buf[0..try std.Io.Dir.cwd().realPathFile(io, fx.p("Caskroom/rabbit/0.7.8/rabbit"), &real_buf)];
    try testing.expectEqualStrings(want, try linkTarget(io, placed, &buf));
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, placed, 64);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("#!/bin/sh\necho rabbit\n", body);
    const st = try std.Io.Dir.cwd().statFile(io, fx.p("Caskroom/rabbit/0.7.8/rabbit"), .{});
    try testing.expect(@intFromEnum(st.permissions) & 0o111 != 0);
}

test "a binary target outside the prefix bin dir is refused at parse time" {
    for ([_][]const u8{
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x"],"target":"$HOMEBREW_PREFIX/etc/x"}]}
        ,
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x"],"target":"/usr/local/bin/x"}]}
        ,
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x"],"target":"$HOMEBREW_PREFIX/bin/../x"}]}
        ,
    }) |json| {
        try testing.expectError(error.ParseFailed, cask.parseCask(testing.allocator, json));
    }
    // A bare name and the `<prefix>/bin/` form both name the same link.
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x-arm64"],"target":"$HOMEBREW_PREFIX/bin/x"}]}
    );
    defer c.deinit();
    try testing.expectEqualStrings("x", cask.parseBinaryTarget(c.parsed.value.object).?);
}

test "a zip cask declaring both an app and a binary still places the app" {
    var fx = try Fixture.init("app_and_binary");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // The editor shape: the binary lives inside the bundle, under `$APPDIR`.
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"editor","name":["Editor"],"version":"1.0","url":"https://example.invalid/editor.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Editor.app"]},{"binary":["$APPDIR/Editor.app/Contents/MacOS/editor"],"target":"$HOMEBREW_PREFIX/bin/editor"}]}
    );
    defer c.deinit();

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/Editor.app/Contents/MacOS/editor"), "bin");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    const placed = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings(fx.p("Applications/Editor.app"), placed);
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Applications/Editor.app/Contents/MacOS/editor"), 64);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("bin", body);
}

test "a full-path target inside the binary array names the same link as the sibling form" {
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x-arm64",{"target":"$HOMEBREW_PREFIX/bin/x"}]}]}
    );
    defer c.deinit();
    try testing.expectEqualStrings("x", cask.parseBinaryTarget(c.parsed.value.object).?);
}
