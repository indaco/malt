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
        // A control byte would split the sidecar and link-manifest lines.
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x"],"target":"code\nx"}]}
        ,
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["a\tb"]}]}
        ,
    }) |json| {
        try testing.expectError(error.ParseFailed, cask.parseCask(testing.allocator, json));
    }
    // A bare name and the `<prefix>/bin/` form both name the same link.
    try expectSingleTarget("x",
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x-arm64"],"target":"$HOMEBREW_PREFIX/bin/x"}]}
    );
}

fn expectSingleTarget(want: []const u8, json: []const u8) !void {
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();
    const entries = (try cask.collectBinaryArtifacts(testing.allocator, c.parsed.value.object)).?;
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings(want, entries[0].target.?);
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
    try expectSingleTarget("x",
        \\{"token":"x","version":"1","url":"https://e/x.zip","artifacts":[{"binary":["x-arm64",{"target":"$HOMEBREW_PREFIX/bin/x"}]}]}
    );
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
    // The link is left dangling into the wiped Caskroom: still this cask's
    // own, so the rollback may take it over.
    try db.exec("UPDATE casks SET version = '0.8.0' WHERE token = 'rabbit';");
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

// The editor shape: the binaries live inside the bundle, under `$APPDIR`.
const editor_json =
    \\{"token":"editor","name":["Editor"],"version":"1.0","url":"https://example.invalid/editor.zip","sha256":"no_check",
    \\ "artifacts":[{"app":["Editor.app"]},
    \\  {"binary":["$APPDIR/Editor.app/Contents/MacOS/editor"],"target":"$HOMEBREW_PREFIX/bin/editor"},
    \\  {"binary":["$APPDIR/Editor.app/Contents/MacOS/editor-tunnel"],"target":"$HOMEBREW_PREFIX/bin/editor-tunnel"}]}
;

fn expectLinkInto(io: std.Io, link: []const u8, file: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const want = real_buf[0..try std.Io.Dir.cwd().realPathFile(io, file, &real_buf)];
    try testing.expectEqualStrings(want, try linkTarget(io, link, &buf));
}

test "links an APPDIR binary into the placed bundle" {
    var fx = try Fixture.init("appdir_link");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // Every stanza is linked, in order, from the bundle just placed.
    try installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app"));
    try expectLinkInto(io, fx.p("bin/editor"), fx.p("Applications/Editor.app/Contents/MacOS/editor"));
    try expectLinkInto(io, fx.p("bin/editor-tunnel"), fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"));
    const st = try std.Io.Dir.cwd().statFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), .{});
    try testing.expect(@intFromEnum(st.permissions) & 0o111 != 0);

    // The links are recorded under the Caskroom so uninstall can remove them.
    const manifest = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Caskroom/editor/1.0/" ++ cask.LINKS_MANIFEST_NAME), 4096);
    defer testing.allocator.free(manifest);
    const want = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n", .{ fx.p("bin/editor"), fx.p("bin/editor-tunnel") });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, manifest);
}

test "an APPDIR binary naming a bundle other than the placed one is refused" {
    var fx = try Fixture.init("appdir_other");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"editor","name":["Editor"],"version":"1.0","url":"https://example.invalid/editor.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Editor.app"]},{"binary":["$APPDIR/Other.app/Contents/MacOS/x"],"target":"$HOMEBREW_PREFIX/bin/x"}]}
    );
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Other.app/Contents/MacOS/x"), "x");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // Only the bundle this install placed is a legitimate link source; a
    // stanza reaching into a neighbour is an error, not a skip.
    try testing.expectError(error.InstallFailed, installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app")));
    try testing.expect(!exists(io, fx.p("bin/x")));
}

test "uninstall removes every placed link" {
    var fx = try Fixture.init("appdir_uninstall");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    var installer = cask.CaskInstaller.init(io, malt.app_ctx.processEnviron(), testing.allocator, &db, fx.base, fx.p("cache"));
    try installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app"));
    try cask.recordInstall(&db, &c, fx.p("Applications/Editor.app"), null);
    // A manifest line that is not an absolute path is skipped, never asserted on.
    {
        const manifest_path = fx.p("Caskroom/editor/1.0/" ++ cask.LINKS_MANIFEST_NAME);
        const before = try test_io.readFileAbsoluteAlloc(io, testing.allocator, manifest_path, 4096);
        defer testing.allocator.free(before);
        const after = try std.fmt.allocPrint(testing.allocator, "{s}relative\n", .{before});
        defer testing.allocator.free(after);
        try putFile(io, manifest_path, after);
    }

    try installer.uninstall("editor");

    // `app_path` still names the bundle; the links went with the manifest.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor"), &buf));
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor-tunnel"), &buf));
    try testing.expect(!exists(io, fx.p("Applications/Editor.app")));
    try testing.expect(!exists(io, fx.p("Caskroom/editor")));
    try testing.expect(!cask.isInstalled(&db, "editor"));
}

test "an app cask installs and rolls back with its APPDIR binaries linked" {
    var fx = try Fixture.init("appdir_rollback");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor"), "#!/bin/sh\necho 1.0\n");
    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const zip = fx.p("cache/Cask/editor-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    // A digest-pinned history row is what lets the rollback reuse the
    // cached zip offline.
    const zip_bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(zip_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip_bytes, &digest, .{});
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"token":"editor","name":["Editor"],"version":"1.0","url":"https://example.invalid/editor.zip","sha256":"{x}",
        \\ "artifacts":[{{"app":["Editor.app"]}},
        \\  {{"binary":["$APPDIR/Editor.app/Contents/MacOS/editor"],"target":"$HOMEBREW_PREFIX/bin/editor"}},
        \\  {{"binary":["$APPDIR/Editor.app/Contents/MacOS/editor-tunnel"],"target":"$HOMEBREW_PREFIX/bin/editor-tunnel"}}]}}
    , .{digest});
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try testing.expectEqualStrings(fx.p("Applications/Editor.app"), app_path);
    try expectLinkInto(io, fx.p("bin/editor"), fx.p("Applications/Editor.app/Contents/MacOS/editor"));
    try expectLinkInto(io, fx.p("bin/editor-tunnel"), fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"));
    try cask.recordInstall(&db, &c, app_path, null);

    // A newer version replaced everything, then went missing: only the
    // history row and the cached zip are left to restore from.
    try db.exec("UPDATE casks SET version = '2.0' WHERE token = 'editor';");
    try test_io.deleteTreeAbsolute(io, fx.p("Applications/Editor.app"));
    try test_io.deleteTreeAbsolute(io, fx.p("Caskroom/editor"));

    // The outgoing 2.0 linked a helper 1.0 does not ship; the swap must
    // remove it rather than leave it pointing into the older bundle.
    const stale_manifest = try std.fmt.allocPrint(testing.allocator, "{s}\n", .{fx.p("bin/editor-new")});
    defer testing.allocator.free(stale_manifest);
    try putFile(io, fx.p("Caskroom/editor/2.0/" ++ cask.LINKS_MANIFEST_NAME), stale_manifest);
    // Real links store the resolved path; the fixture must too.
    var apps_real: [std.fs.max_path_bytes]u8 = undefined;
    const apps = apps_real[0..try std.Io.Dir.cwd().realPathFile(io, fx.p("Applications"), &apps_real)];
    const stale_target = try std.fmt.allocPrint(testing.allocator, "{s}/Editor.app/Contents/MacOS/editor-new", .{apps});
    defer testing.allocator.free(stale_target);
    try std.Io.Dir.symLinkAbsolute(io, stale_target, fx.p("bin/editor-new"), .{});

    installer.prefetched_artifact = null;
    try installer.reinstallFromHistory("editor", "1.0");

    const info = cask.lookupInstalled(&db, "editor") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.0", info.version());
    try expectLinkInto(io, fx.p("bin/editor"), fx.p("Applications/Editor.app/Contents/MacOS/editor"));
    try expectLinkInto(io, fx.p("bin/editor-tunnel"), fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"));
    var stale: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor-new"), &stale));
}

test "an app cask whose declared binary is missing installs nothing" {
    var fx = try Fixture.init("appdir_partial");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // The bundle ships `editor` but not `editor-tunnel`.
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor"), "bin");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const zip = fx.p("cache/Cask/editor-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;

    // A half-linked install is worse than none: no bundle left in the app
    // dir, no dangling first link, nothing to roll back to.
    try testing.expectError(error.InstallFailed, installer.install(&c));
    try testing.expect(!exists(io, fx.p("Applications/Editor.app")));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor"), &buf));
    try testing.expect(!exists(io, fx.p("Caskroom/editor/1.0/" ++ cask.LINKS_MANIFEST_NAME)));
    try testing.expect((try installer.readBinarySpec("editor", "1.0")) == null);
}

test "an app cask with a staged-path binary still rolls back to its bundle" {
    var fx = try Fixture.init("staged_rollback");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    try putFile(io, fx.p("stage/Pad.app/Contents/MacOS/pad"), "bin");
    try putFile(io, fx.p("stage/pad-cli"), "cli");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const zip = fx.p("cache/Cask/pad-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    const zip_bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(zip_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip_bytes, &digest, .{});
    // The live shape of a few editors: the bundle plus a helper that sits
    // beside it in the archive rather than inside it.
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"token":"pad","name":["Pad"],"version":"1.0","url":"https://example.invalid/pad.zip","sha256":"{x}",
        \\ "artifacts":[{{"app":["Pad.app"]}},{{"binary":["pad-cli"],"target":"$HOMEBREW_PREFIX/bin/pad"}}]}}
    , .{digest});
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try testing.expectEqualStrings(fx.p("Applications/Pad.app"), app_path);
    try cask.recordInstall(&db, &c, app_path, null);
    // Nothing was linked, so nothing is recorded: the sidecar only ever
    // describes what the install placed.
    try testing.expect((try installer.readBinarySpec("pad", "1.0")) == null);

    try db.exec("UPDATE casks SET version = '2.0' WHERE token = 'pad';");
    try test_io.deleteTreeAbsolute(io, fx.p("Applications/Pad.app"));

    // The rollback must take the bundle path the install took, not the
    // binary-only one: the record cannot turn an app cask into a CLI cask.
    installer.prefetched_artifact = null;
    try installer.reinstallFromHistory("pad", "1.0");
    const info = cask.lookupInstalled(&db, "pad") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(fx.p("Applications/Pad.app"), info.appPath().?);
    try testing.expect(exists(io, fx.p("Applications/Pad.app/Contents/MacOS/pad")));
}

const two_tools_json =
    \\{"token":"tools","name":["Tools"],"version":"1.0","url":"https://example.invalid/tools.zip","sha256":"no_check",
    \\ "artifacts":[{"binary":["a"]},{"binary":["b"]}]}
;

test "a binary-only cask with two stanzas records both links so uninstall removes both" {
    var fx = try Fixture.init("two_tools");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, two_tools_json);
    defer c.deinit();

    try putFile(io, fx.p("extract/a"), "a");
    try putFile(io, fx.p("extract/b"), "b");
    var installer = cask.CaskInstaller.init(io, malt.app_ctx.processEnviron(), testing.allocator, &db, fx.base, fx.p("cache"));
    const placed = try installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c);
    defer testing.allocator.free(placed);
    try testing.expectEqualStrings(fx.p("bin/a"), placed);
    try expectLinkInto(io, fx.p("bin/b"), fx.p("Caskroom/tools/1.0/b"));
    try cask.recordInstall(&db, &c, placed, null);

    // `app_path` names one link; the second must go through the manifest.
    try installer.uninstall("tools");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/a"), &buf));
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/b"), &buf));
}

test "a binary-only cask missing its second stanza installs nothing" {
    var fx = try Fixture.init("two_tools_partial");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, two_tools_json);
    defer c.deinit();

    try putFile(io, fx.p("extract/a"), "a");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // No row will be written, so the first link and the Caskroom copy must
    // not outlive the failure.
    try testing.expectError(error.InstallFailed, installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/a"), &buf));
    try testing.expect(!exists(io, fx.p("Caskroom/tools")));
}

test "uninstall refuses a version too long to name the links manifest" {
    var fx = try Fixture.init("long_version");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    const long = "9" ** 300;
    try db.exec("INSERT INTO casks(token,name,version,url,sha256,app_path) VALUES('x','x','" ++ long ++ "','https://e/x.zip','aa','/nowhere/X.app');");

    // A truncated version would silently miss the manifest and leave the
    // links dangling; refusing is the same choice `lookupInstalled` makes.
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    try testing.expectError(error.UninstallFailed, installer.uninstall("x"));
}

test "a font cask that also declares an APPDIR binary still installs its fonts" {
    var fx = try Fixture.init("font_appdir");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"font-x","name":["FontX"],"version":"1.0","url":"https://example.invalid/x.zip","sha256":"no_check",
        \\ "artifacts":[{"font":["A.ttf"]},{"binary":["$APPDIR/X.app/Contents/MacOS/x"],"target":"x"}]}
    );
    defer c.deinit();

    try putFile(io, fx.p("stage/A.ttf"), "AAA");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const zip = fx.p("cache/Cask/font-x-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    // There is no bundle to link from, so the stanza is ignored the way it
    // was before, not turned into a failure that strands the placed fonts.
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    const app_path = try installer.install(&c);
    defer testing.allocator.free(app_path);
    try testing.expect(exists(io, fx.p("Fonts/A.ttf")));
}

test "a bin entry this cask does not own is refused, not replaced" {
    var fx = try Fixture.init("conflict");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    try putFile(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), "formula");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    // A formula's link and a plain file are both foreign; brew refuses the
    // same. The first stanza linked fine and must be unwound.
    try test_io.cwd().createDirPath(io, fx.p("bin"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), fx.p("bin/editor-tunnel"), .{});
    try testing.expectError(error.LinkConflict, installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app")));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(fx.p("Cellar/tool/1.0/bin/editor-tunnel"), try linkTarget(io, fx.p("bin/editor-tunnel"), &buf));
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor"), &buf));

    try std.Io.Dir.cwd().deleteFile(io, fx.p("bin/editor-tunnel"));
    try putFile(io, fx.p("bin/editor-tunnel"), "user's own");
    try testing.expectError(error.LinkConflict, installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app")));
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("bin/editor-tunnel"), 64);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("user's own", body);
}

// --- review findings on the links manifest ---

test "a symlinked links manifest inside the archive cannot redirect the manifest write" {
    var fx = try Fixture.init("manifest_symlink");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, rabbit_json);
    defer c.deinit();

    // The archive plants `.malt-links` as a symlink to a user file; the
    // ditto copy into the Caskroom preserves it.
    try putFile(io, fx.p("victim"), "keep me\n");
    try putFile(io, fx.p("extract/rabbit"), "bin");
    try std.Io.Dir.symLinkAbsolute(io, fx.p("victim"), fx.p("extract/" ++ cask.LINKS_MANIFEST_NAME), .{});
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));

    const placed = try installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c);
    defer testing.allocator.free(placed);
    const victim = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("victim"), 64);
    defer testing.allocator.free(victim);
    try testing.expectEqualStrings("keep me\n", victim);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.NotLink, std.Io.Dir.readLinkAbsolute(io, fx.p("Caskroom/rabbit/0.7.8/" ++ cask.LINKS_MANIFEST_NAME), &buf));
}

test "uninstall removes only bin links that still resolve into this cask" {
    var fx = try Fixture.init("manifest_planted");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = malt.app_ctx.processEnviron() });
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    try putFile(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), "formula");
    try putFile(io, fx.p("secret"), "SECRET");
    var installer = cask.CaskInstaller.init(io, malt.app_ctx.processEnviron(), testing.allocator, &db, fx.base, fx.p("cache"));
    try installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app"));
    try cask.recordInstall(&db, &c, fx.p("Applications/Editor.app"), null);

    // Since the install, a formula took over `editor-tunnel`, and the
    // manifest (which an archive can plant) names a file outside bin.
    try std.Io.Dir.cwd().deleteFile(io, fx.p("bin/editor-tunnel"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), fx.p("bin/editor-tunnel"), .{});
    const manifest = try std.fmt.allocPrint(testing.allocator, "{s}\n{s}\n{s}\n", .{ fx.p("bin/editor"), fx.p("bin/editor-tunnel"), fx.p("secret") });
    defer testing.allocator.free(manifest);
    try putFile(io, fx.p("Caskroom/editor/1.0/" ++ cask.LINKS_MANIFEST_NAME), manifest);

    try installer.uninstall("editor");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/editor"), &buf));
    try testing.expectEqualStrings(fx.p("Cellar/tool/1.0/bin/editor-tunnel"), try linkTarget(io, fx.p("bin/editor-tunnel"), &buf));
    try testing.expect(exists(io, fx.p("secret")));
}

test "a bin conflict is refused before the bundle on disk is touched" {
    var fx = try Fixture.init("precheck");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor"), "new");
    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor-tunnel"), "new");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const zip = fx.p("cache/Cask/editor-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    // The bundle already on disk and a formula's link in the way: the
    // refusal must come while that bundle is still whole.
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "old");
    try putFile(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), "formula");
    try test_io.cwd().createDirPath(io, fx.p("bin"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Cellar/tool/1.0/bin/editor-tunnel"), fx.p("bin/editor-tunnel"), .{});

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    try testing.expectError(error.LinkConflict, installer.install(&c));
    try testing.expectEqualStrings(fx.p("bin/editor-tunnel"), installer.conflictPath().?);
    const body = try test_io.readFileAbsoluteAlloc(io, testing.allocator, fx.p("Applications/Editor.app/Contents/MacOS/editor"), 64);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("old", body);
}

test "a failed rollback leaves the current version's links in place" {
    var fx = try Fixture.init("rollback_fails");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator, editor_json);
    defer c.deinit();

    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor"), "bin");
    try putFile(io, fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"), "tunnel");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    try installer.linkAppDirBinaries(&c, fx.p("Applications/Editor.app"));
    try cask.recordInstall(&db, &c, fx.p("Applications/Editor.app"), null);

    // 0.9 is on record but its artefact is gone and we are offline.
    try db.exec("INSERT INTO cask_versions(token,version,url,sha256,artifact_type,cache_path) VALUES('editor','0.9','https://example.invalid/e.zip','aa','zip',NULL);");
    installer.offline = true;
    try testing.expect(if (installer.reinstallFromHistory("editor", "0.9")) |_| false else |_| true);
    try expectLinkInto(io, fx.p("bin/editor"), fx.p("Applications/Editor.app/Contents/MacOS/editor"));
    try expectLinkInto(io, fx.p("bin/editor-tunnel"), fx.p("Applications/Editor.app/Contents/MacOS/editor-tunnel"));
}

test "a caller-supplied override stands in when a version predates the sidecar" {
    var fx = try Fixture.init("no_sidecar");
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
    const zip_bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(zip_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip_bytes, &digest, .{});
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"token":"rabbit","name":["Rabbit"],"version":"0.7.8","url":"https://example.invalid/r.zip","sha256":"{x}",
        \\ "artifacts":[{{"binary":["rabbit"]}}]}}
    , .{digest});
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();

    // The row and artefact exist as an older malt left them: no sidecar.
    try cask.recordInstall(&db, &c, fx.p("bin/rabbit"), null);
    try cask.recordCaskVersion(&db, "rabbit", "0.7.8", c.url, c.sha256, "zip", zip);
    try db.exec("UPDATE casks SET version = '0.8.0' WHERE token = 'rabbit';");

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    const entries = (try cask.linkedBinaryStanzas(testing.allocator, c.parsed.value.object)).?;
    defer testing.allocator.free(entries);
    installer.binary_entries_override = &.{};
    try testing.expectError(error.InstallFailed, installer.reinstallFromHistory("rabbit", "0.7.8"));
    installer.binary_entries_override = entries;
    try installer.reinstallFromHistory("rabbit", "0.7.8");
    try expectLinkInto(io, fx.p("bin/rabbit"), fx.p("Caskroom/rabbit/0.7.8/rabbit"));
}

test "a sibling cask's link is not this cask's to replace" {
    var fx = try Fixture.init("sibling");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"foo","name":["Foo"],"version":"1","url":"https://example.invalid/foo.zip","sha256":"no_check","artifacts":[{"binary":["foo"]}]}
    );
    defer c.deinit();

    // `foo-cli` owns the name; a prefix compare would mistake its Caskroom
    // for `foo`'s.
    try putFile(io, fx.p("Caskroom/foo-cli/1.0/foo"), "sibling");
    try test_io.cwd().createDirPath(io, fx.p("bin"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Caskroom/foo-cli/1.0/foo"), fx.p("bin/foo"), .{});
    try putFile(io, fx.p("extract/foo"), "mine");
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    try testing.expectError(error.LinkConflict, installer.placeExtracted(fx.p("extract"), fx.p("Applications"), &c));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(fx.p("Caskroom/foo-cli/1.0/foo"), try linkTarget(io, fx.p("bin/foo"), &buf));
}

test "a binary-only zip cask with a stray APPDIR stanza leaves no Caskroom copy behind" {
    var fx = try Fixture.init("mixed_zip");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"mixed","name":["Mixed"],"version":"1","url":"https://example.invalid/m.zip","sha256":"no_check",
        \\ "artifacts":[{"binary":["cli"]},{"binary":["$APPDIR/X.app/Contents/MacOS/x"],"target":"x"}]}
    );
    defer c.deinit();

    try putFile(io, fx.p("stage/cli"), "cli");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    const zip = fx.p("cache/Cask/mixed-1.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    installer.prefetched_artifact = zip;
    try testing.expectError(error.InstallFailed, installer.install(&c));
    try testing.expect(!exists(io, fx.p("Caskroom/mixed")));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectError(error.FileNotFound, std.Io.Dir.readLinkAbsolute(io, fx.p("bin/cli"), &buf));
}

test "a restore keeps the bundle when a declared helper cannot be linked" {
    var fx = try Fixture.init("restore_incomplete");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);

    // The old bundle ships `editor` only; the stand-in guessed from a newer
    // version also names `editor-tunnel`.
    try putFile(io, fx.p("stage/Editor.app/Contents/MacOS/editor"), "old");
    try test_io.cwd().createDirPath(io, fx.p("cache/Cask"));
    try test_io.cwd().createDirPath(io, fx.p("tmp"));
    try test_io.cwd().createDirPath(io, fx.p("Applications"));
    const zip = fx.p("cache/Cask/editor-1.0.zip");
    try runTool(&.{ "/usr/bin/ditto", "-c", "-k", fx.p("stage"), zip });
    const zip_bytes = try test_io.readFileAbsoluteAlloc(io, testing.allocator, zip, 1 << 20);
    defer testing.allocator.free(zip_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip_bytes, &digest, .{});
    const json = try std.fmt.allocPrint(testing.allocator,
        \\{{"token":"editor","name":["Editor"],"version":"1.0","url":"https://example.invalid/e.zip","sha256":"{x}","artifacts":[{{"app":["Editor.app"]}}]}}
    , .{digest});
    defer testing.allocator.free(json);
    var c = try cask.parseCask(testing.allocator, json);
    defer c.deinit();
    try cask.recordInstall(&db, &c, fx.p("Applications/Editor.app"), null);
    try cask.recordCaskVersion(&db, "editor", "1.0", c.url, c.sha256, "zip", zip);
    try db.exec("UPDATE casks SET version = '2.0' WHERE token = 'editor';");

    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    installer.offline = true;
    const stand_in = [_]cask.BinaryEntry{
        .{ .source = "$APPDIR/Editor.app/Contents/MacOS/editor", .target = "editor" },
        .{ .source = "$APPDIR/Editor.app/Contents/MacOS/editor-tunnel", .target = "editor-tunnel" },
    };
    installer.binary_entries_override = &stand_in;

    // The user had this version; a link the guess got wrong must not cost
    // them the bundle, only be named.
    try testing.expectError(error.LinksIncomplete, installer.reinstallFromHistory("editor", "1.0"));
    try testing.expect(exists(io, fx.p("Applications/Editor.app/Contents/MacOS/editor")));
    const info = cask.lookupInstalled(&db, "editor") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("1.0", info.version());
    try testing.expect((try installer.readBinarySpec("editor", "1.0")) == null);
}

test "the conflict check screens only the links the install will create" {
    var fx = try Fixture.init("precheck_scope");
    defer fx.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try schema.initSchema(&db);
    // The staged-path shape: `pad-cli` is declared but never linked.
    var c = try cask.parseCask(testing.allocator,
        \\{"token":"pad","name":["Pad"],"version":"1.0","url":"https://example.invalid/pad.zip","sha256":"no_check",
        \\ "artifacts":[{"app":["Pad.app"]},{"binary":["pad-cli"],"target":"$HOMEBREW_PREFIX/bin/pad"}]}
    );
    defer c.deinit();

    try putFile(io, fx.p("Cellar/pad/1.0/bin/pad"), "formula");
    try test_io.cwd().createDirPath(io, fx.p("bin"));
    try std.Io.Dir.symLinkAbsolute(io, fx.p("Cellar/pad/1.0/bin/pad"), fx.p("bin/pad"), .{});
    var installer = cask.CaskInstaller.init(io, .empty, testing.allocator, &db, fx.base, fx.p("cache"));
    try installer.checkLinkConflicts(&c);

    // A pkg never links, whatever it declares.
    var pkg = try cask.parseCask(testing.allocator,
        \\{"token":"pad","name":["Pad"],"version":"1.0","url":"https://example.invalid/pad.pkg","sha256":"no_check",
        \\ "artifacts":[{"binary":["$APPDIR/Pad.app/Contents/MacOS/pad"],"target":"pad"}]}
    );
    defer pkg.deinit();
    try installer.checkLinkConflicts(&pkg);
}
