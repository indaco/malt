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

fn exists(io: std.Io, path: []const u8) bool {
    return if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| true else |_| false;
}

fn runTool(argv: []const []const u8) !void {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = argv, .stdout = .ignore, .stderr = .ignore });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.ToolFailed,
        else => return error.ToolFailed,
    }
}

// A synthetic cask the way reinstallFromHistory builds it: no `artifacts`,
// so the dispatch sees neither an `app` nor a `binary`.
const synthetic_json =
    \\{"token":"tool","name":["Tool"],"version":"1.0","url":"https://example.invalid/tool.zip","sha256":"no_check"}
;

test "placeExtracted honors binary_entries_override on an artifact-less cask" {
    var fx = try Fixture.init("override");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, synthetic_json);
    defer c.deinit();

    const extract = fx.p("extract");
    try putFile(io, fx.p("extract/tool-arm64"), "#!/bin/sh\necho 1.0\n");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // The override carries what the synthetic JSON lost, the rollback
    // re-source path: the link name comes from the recorded target.
    const entries = [_]cask.BinaryEntry{.{ .source = "tool-arm64", .target = "tool" }};
    installer.binary_entries_override = &entries;

    const placed = try installer.placeExtracted(extract, fx.p("Applications"), &c);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings(fx.p("bin/tool"), placed);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = real_buf[0..try std.Io.Dir.cwd().realPathFile(io, fx.p("Caskroom/tool/1.0/tool-arm64"), &real_buf)];
    try testing.expectEqualStrings(want, try linkTarget(io, placed, &buf));
}

test "binary_entries_override is re-checked: a tampered sidecar source cannot leave the Caskroom" {
    var fx = try Fixture.init("tamper");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, synthetic_json);
    defer c.deinit();

    try putFile(io, fx.p("extract/tool"), "bin");
    try putFile(io, fx.p("secret"), "SECRET");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // The sidecar sits on disk and could be edited; a `..` hop must still be
    // refused at link time, not trusted because it was recorded.
    for ([_]cask.BinaryEntry{
        .{ .source = "../../secret", .target = "tool" },
        .{ .source = "tool", .target = "../../escaped" },
    }) |entry| {
        const entries = [_]cask.BinaryEntry{entry};
        installer.binary_entries_override = &entries;
        try testing.expectError(error.InstallFailed, installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c));
    }
    try testing.expect(!exists(io, fx.p("bin/tool")));
    try testing.expect(!exists(io, fx.p("escaped")));
}

test "a fresh binary-only install persists a per-version sidecar that round-trips the stanzas" {
    var fx = try Fixture.init("sidecar");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, rabbit_json);
    defer c.deinit();

    try putFile(io, fx.p("stage/rabbit"), "#!/bin/sh\necho rabbit\n");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const zip = fx.p("cache/Cask/rabbit-0.7.8.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try testing.expectEqualStrings(fx.p("bin/rabbit"), app_path);

    // Next to the cached artefact, the way the font sidecar is, so a later
    // rollback finds it offline without the cask JSON.
    var spec = (try installer.readBinarySpec("rabbit", "0.7.8")).?;
    defer spec.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), spec.entries.len);
    try testing.expectEqualStrings("rabbit", spec.entries[0].source);
    try testing.expectEqualStrings("rabbit", spec.entries[0].target.?);
}

test "a binary-only cask rolls back to a version that still links its executable" {
    var fx = try Fixture.init("rollback");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try putFile(io, fx.p("stage/rabbit"), "#!/bin/sh\necho 0.7.8\n");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const zip = fx.p("cache/Cask/rabbit-0.7.8.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    // The history row must pin the real digest: only a digest-pinned
    // artefact is reused from the cache, and offline there is no fetch.
    const zip_bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(zip_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip_bytes, &digest, .{});
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"token":"rabbit","name":["Rabbit"],"version":"0.7.8","url":"https://example.invalid/rabbit-darwin-arm64.zip","sha256":"{x}",
        \\ "artifacts":[{{"binary":["rabbit"],"target":"$HOMEBREW_PREFIX/bin/rabbit"}}]}}
    , .{digest});
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try cask.recordInstall(&db, &c, app_path, null);

    // The casks row moved on and the link went with it, as a failed upgrade
    // leaves things; only the history row and the cached zip remain.
    try db.exec("UPDATE casks SET version = '0.8.0' WHERE token = 'rabbit';");
    try std.Io.Dir.cwd().deleteFile(io, fx.p("bin/rabbit"));
    try test_io.deleteTreeAbsolute(io, fx.p("Caskroom/rabbit"));

    installer.prefetched_artifact = null;
    try installer.reinstallFromHistory("rabbit", "0.7.8");

    const info = cask.lookupInstalled(&db, "rabbit") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("0.7.8", info.version());
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = real_buf[0..try std.Io.Dir.cwd().realPathFile(io, fx.p("Caskroom/rabbit/0.7.8/rabbit"), &real_buf)];
    try testing.expectEqualStrings(want, try linkTarget(io, fx.p("bin/rabbit"), &buf));
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("bin/rabbit"), 64);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("#!/bin/sh\necho 0.7.8\n", body);
}
