//! Integration tests for the link pre-check in `linkAndRecord`: a formula
//! may take over slots its predecessor left linked, but only the ones it
//! lists, and a failed link must give the predecessor its slots back.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const install = malt.install;
const install_record = malt.install_record;
const linker_mod = malt.linker;
const deps_mod = malt.deps;

const io = std.Options.debug_io;

const Env = struct {
    prefix: []const u8,
    db: sqlite.Database,
    linker: linker_mod.Linker,

    fn init(tag: []const u8) !*Env {
        const self = try testing.allocator.create(Env);
        self.prefix = try test_io.uniqueTempPath(testing.allocator, "link_takeover", tag);
        self.db = try sqlite.Database.open(":memory:");
        try schema.initSchema(&self.db);
        self.linker = linker_mod.Linker.init(io, testing.allocator, &self.db, self.prefix);
        return self;
    }

    fn deinit(self: *Env) void {
        self.db.close();
        test_io.deleteTreeAbsolute(io, self.prefix) catch {};
        testing.allocator.free(self.prefix);
        testing.allocator.destroy(self);
    }

    fn path(self: *Env, comptime fmt: []const u8, args: anytype) ![]u8 {
        return testing.allocator.print("{s}/" ++ fmt, .{self.prefix} ++ args);
    }

    fn makeKeg(self: *Env, name: []const u8, files: []const []const u8) ![]u8 {
        const keg = try self.path("Cellar/{s}/1.0", .{name});
        for (files) |rel| {
            const full = try testing.allocator.print("{s}/{s}", .{ keg, rel });
            defer testing.allocator.free(full);
            try test_io.cwd().createDirPath(io, std.Io.Dir.path.dirname(full).?);
            const f = try test_io.createFileAbsolute(io, full, .{});
            f.close(io);
        }
        return keg;
    }

    /// Keg recorded and linked the way a pre-keg-only install left it.
    fn installLinked(self: *Env, name: []const u8, files: []const []const u8) ![]u8 {
        const keg = try self.makeKeg(name, files);
        const id = try install_record.recordKegFields(&self.db, .{
            .name = name,
            .full_name = name,
            .version = "1.0",
            .revision = 0,
            .tap = "",
            .store_sha256 = "",
            .cellar_path = keg,
            .install_reason = "direct",
            .bin_isolated = false,
            .dependencies = &.{},
        }, .{});
        try self.linker.link(keg, name, id, false);
        return keg;
    }

    fn target(self: *Env, rel: []const u8, buf: []u8) []const u8 {
        var p: [512]u8 = undefined;
        const full = std.mem.print(&p, "{s}/{s}", .{ self.prefix, rel }) catch return "";
        return test_io.readLinkAbsolute(io, full, buf) catch "";
    }

    fn owner(self: *Env, rel: []const u8, buf: []u8) []const u8 {
        var stmt = self.db.prepare(
            "SELECT k.name FROM links l JOIN kegs k ON k.id = l.keg_id WHERE l.link_path = ?1;",
        ) catch return "";
        defer stmt.finalize();
        var p: [512]u8 = undefined;
        const full = std.mem.print(&p, "{s}/{s}", .{ self.prefix, rel }) catch return "";
        stmt.bindText(1, full) catch return "";
        if (!(stmt.step() catch false)) return "";
        const name = std.mem.sliceTo(stmt.columnText(0) orelse return "", 0);
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }

    /// Run the link phase for `new` with the given `link_overwrite` JSON list.
    fn linkNew(self: *Env, keg: []const u8, overwrite_json: []const u8) !void {
        return self.linkNewWith(keg, overwrite_json, .{});
    }

    fn linkNewWith(self: *Env, keg: []const u8, overwrite_json: []const u8, flags: malt.install_args.InstallFlags) !void {
        const json = try testing.allocator.print(
            "{{\"name\":\"new\",\"versions\":{{\"stable\":\"1.0\"}},\"link_overwrite\":{s}}}",
            .{overwrite_json},
        );
        defer testing.allocator.free(json);
        var job: malt.install_download.DownloadJob = .{
            .name = "new",
            .version_str = "1.0",
            .sha256 = "",
            .bottle_url = "",
            .is_dep = false,
            .keg_only = false,
            .wants_post_install = false,
            .formula_json = json,
            .cellar_type = "",
            .label_width = 0,
            .line_index = 0,
            .multi = null,
            .bar = null,
            .store_sha256 = "",
            .succeeded = true,
        };
        var cache = deps_mod.FormulaCache.init(testing.allocator);
        defer cache.deinit();
        try install.linkAndRecord(io, std.process.Environ.empty, testing.allocator, &job, keg, &self.db, &self.linker, self.prefix, &cache, flags, malt.install_sink.silent);
    }
};

fn exists(path: []const u8) bool {
    test_io.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "a listed slot moves to the new keg and the old keg stays installed" {
    const env = try Env.init("listed");
    defer env.deinit();
    const old = try env.installLinked("old", &.{ "lib/libfoo.dylib", "lib/libfoo.1.dylib" });
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{ "lib/libfoo.dylib", "lib/libfoo.1.dylib" });
    defer testing.allocator.free(new);

    try env.linkNew(new, "[\"lib/libfoo*\"]");

    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.find(u8, env.target("lib/libfoo.dylib", &buf), "Cellar/new/") != null);
    var obuf: [64]u8 = undefined;
    try testing.expectEqualStrings("new", env.owner("lib/libfoo.dylib", &obuf));
    try testing.expectEqualStrings("new", env.owner("lib/libfoo.1.dylib", &obuf));
    try testing.expect(exists(old));
}

test "an unlisted slot still refuses the install and leaves every link alone" {
    const env = try Env.init("unlisted");
    defer env.deinit();
    const old = try env.installLinked("old", &.{ "lib/libfoo.dylib", "bin/foo" });
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{ "lib/libfoo.dylib", "bin/foo" });
    defer testing.allocator.free(new);

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/libfoo*\"]"));

    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.find(u8, env.target("lib/libfoo.dylib", &buf), "Cellar/old/") != null);
    try testing.expect(std.mem.find(u8, env.target("bin/foo", &buf), "Cellar/old/") != null);
    try testing.expect(!exists(new));
}

test "no link_overwrite keeps the old refusal" {
    const env = try Env.init("none");
    defer env.deinit();
    const old = try env.installLinked("old", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(new);

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[]"));
}

test "a symlink that points outside the Cellar is never taken over" {
    const env = try Env.init("foreign");
    defer env.deinit();
    const new = try env.makeKeg("new", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(new);
    const lib = try env.path("lib", .{});
    defer testing.allocator.free(lib);
    try test_io.cwd().createDirPath(io, lib);
    const slot = try env.path("lib/libfoo.dylib", .{});
    defer testing.allocator.free(slot);
    try test_io.symLinkAbsolute(io, "/usr/local/lib/libfoo.dylib", slot, .{});

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/libfoo*\"]"));

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/usr/local/lib/libfoo.dylib", env.target("lib/libfoo.dylib", &buf));
}

test "a directory symlink into another keg is never written through" {
    const env = try Env.init("structural");
    defer env.deinit();
    const old = try env.installLinked("old", &.{"lib/sub/libold.dylib"});
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{"lib/sub/libnew.dylib"});
    defer testing.allocator.free(new);
    // Old layout: the whole directory was one symlink into the old keg.
    const sub = try env.path("lib/sub", .{});
    defer testing.allocator.free(sub);
    try test_io.deleteTreeAbsolute(io, sub);
    const old_sub = try testing.allocator.print("{s}/lib/sub", .{old});
    defer testing.allocator.free(old_sub);
    try test_io.symLinkAbsolute(io, old_sub, sub, .{ .is_directory = true });

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/sub*\"]"));

    const stray = try testing.allocator.print("{s}/lib/sub/libnew.dylib", .{old});
    defer testing.allocator.free(stray);
    try testing.expect(!exists(stray));
}

test "a link that fails after a takeover gives the old keg its slots back" {
    const env = try Env.init("rollback");
    defer env.deinit();
    const files = [_][]const u8{ "lib/libfoo.dylib", "lib/libbar.dylib" };
    const old = try env.installLinked("old", &files);
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &files);
    defer testing.allocator.free(new);
    // Fail the new keg's second row, so one slot has already moved.
    try env.db.exec(
        \\CREATE TRIGGER fail_second AFTER INSERT ON links
        \\WHEN NEW.keg_id = (SELECT id FROM kegs WHERE name = 'new')
        \\  AND (SELECT COUNT(*) FROM links WHERE keg_id = NEW.keg_id) >= 2
        \\BEGIN SELECT RAISE(ABORT, 'disk full'); END;
    );

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/lib*\"]"));

    var buf: [512]u8 = undefined;
    var obuf: [64]u8 = undefined;
    for (files) |rel| {
        try testing.expect(std.mem.find(u8, env.target(rel, &buf), "Cellar/old/") != null);
        try testing.expectEqualStrings("old", env.owner(rel, &obuf));
    }
    try testing.expect(!exists(new));
}

test "a rollback leaves a slot a third keg holds with that keg" {
    const env = try Env.init("third");
    defer env.deinit();
    const old = try env.installLinked("old", &.{ "lib/libfoo.dylib", "lib/libbar.dylib", "lib/libbaz.dylib" });
    defer testing.allocator.free(old);
    // `third` took libbaz from `old` earlier, and `new` does not ship it.
    const third = try env.installLinked("third", &.{"lib/libbaz.dylib"});
    defer testing.allocator.free(third);
    const new = try env.makeKeg("new", &.{ "lib/libfoo.dylib", "lib/libbar.dylib" });
    defer testing.allocator.free(new);
    try env.db.exec(
        \\CREATE TRIGGER fail_second AFTER INSERT ON links
        \\WHEN NEW.keg_id = (SELECT id FROM kegs WHERE name = 'new')
        \\  AND (SELECT COUNT(*) FROM links WHERE keg_id = NEW.keg_id) >= 2
        \\BEGIN SELECT RAISE(ABORT, 'disk full'); END;
    );

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/lib*\"]"));

    var buf: [512]u8 = undefined;
    var obuf: [64]u8 = undefined;
    try testing.expectEqualStrings("old", env.owner("lib/libfoo.dylib", &obuf));
    try testing.expectEqualStrings("old", env.owner("lib/libbar.dylib", &obuf));
    try testing.expect(std.mem.find(u8, env.target("lib/libbaz.dylib", &buf), "Cellar/third/") != null);
    try testing.expectEqualStrings("third", env.owner("lib/libbaz.dylib", &obuf));
}

test "snapshotTaken frees what it holds when an allocation fails" {
    const env = try Env.init("snapshot_oom");
    defer env.deinit();
    const old = try env.installLinked("old", &.{ "lib/libfoo.dylib", "lib/libbar.dylib", "lib/libbaz.dylib" });
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{ "lib/libfoo.dylib", "lib/libbar.dylib", "lib/libbaz.dylib" });
    defer testing.allocator.free(new);
    const found = try env.linker.checkConflicts(new, false);
    defer {
        for (found) |c| {
            testing.allocator.free(c.link_path);
            testing.allocator.free(c.existing_keg);
        }
        testing.allocator.free(found);
    }

    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const taken = install.snapshotTaken(io, failing.allocator(), &env.db, found, env.prefix, "new", &.{"lib/lib*"}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try testing.expectEqual(@as(usize, 3), taken.len);
        install.freeTaken(failing.allocator(), taken);
    }
}

test "a link into a Cellar outside the prefix is never taken over" {
    const env = try Env.init("other_cellar");
    defer env.deinit();
    const new = try env.makeKeg("new", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(new);
    const lib = try env.path("lib", .{});
    defer testing.allocator.free(lib);
    try test_io.cwd().createDirPath(io, lib);
    const slot = try env.path("lib/libfoo.dylib", .{});
    defer testing.allocator.free(slot);
    try test_io.symLinkAbsolute(io, "/elsewhere/Cellar/x/1/lib/libfoo.dylib", slot, .{});

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/libfoo*\"]"));

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/elsewhere/Cellar/x/1/lib/libfoo.dylib", env.target("lib/libfoo.dylib", &buf));
}

test "a snapshot that cannot be taken stops the install and removes the new keg" {
    const env = try Env.init("snapshot_fail");
    defer env.deinit();
    const old = try env.installLinked("old", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(new);
    // The owner lookup reads `links`; losing it makes the snapshot fail.
    try env.db.exec("ALTER TABLE links RENAME TO links_gone;");

    try testing.expectError(error.LinkFailed, env.linkNew(new, "[\"lib/libfoo*\"]"));

    var buf: [512]u8 = undefined;
    try testing.expect(std.mem.find(u8, env.target("lib/libfoo.dylib", &buf), "/Cellar/old/") != null);
    try testing.expect(!exists(new));
}

test "a snapshot failure under --force keeps the keg the surviving row points at" {
    const env = try Env.init("snapshot_fail_force");
    defer env.deinit();
    const old = try env.installLinked("old", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(old);
    const new = try env.makeKeg("new", &.{"lib/libfoo.dylib"});
    defer testing.allocator.free(new);
    // A same-version reinstall: the prior row already owns this directory.
    _ = try install_record.recordKegFields(&env.db, .{
        .name = "new",
        .full_name = "new",
        .version = "1.0",
        .revision = 0,
        .tap = "",
        .store_sha256 = "",
        .cellar_path = new,
        .install_reason = "direct",
        .bin_isolated = false,
        .dependencies = &.{},
    }, .{});
    try env.db.exec("ALTER TABLE links RENAME TO links_gone;");

    try testing.expectError(error.LinkFailed, env.linkNewWith(new, "[\"lib/libfoo*\"]", .{ .force = true }));

    try testing.expect(exists(new));
}
