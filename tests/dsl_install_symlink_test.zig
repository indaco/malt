//! malt — DSL install_symlink integration test
//! Drives a synthetic ca-certificates-shaped post_install body through the
//! full pipeline (parser trailing-hash → interpreter dispatch → rm_f +
//! Homebrew-shaped install_symlink) and asserts the symlink lands.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const dsl = malt.dsl;
const formula_mod = malt.formula;

fn minimalJson(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "name": "testpkg",
        \\  "full_name": "testpkg",
        \\  "tap": "homebrew/core",
        \\  "desc": "test",
        \\  "homepage": "https://example.com",
        \\  "license": "MIT",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": true,
        \\  "versions": {{ "stable": "1.0", "head": null }},
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {{ "stable": {{ "root_url": "https://example.com", "files": {{}} }} }}
        \\}}
    , .{});
}

/// Build `<prefix>/Cellar/testpkg/1.0`, `<prefix>/etc`, and the keg's
/// `share/` (where the symlink source lives). Returns the owned prefix.
fn makePrefix() ![]const u8 {
    const tmp = std.testing.tmpDir(.{});
    var buf: [test_io.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.realPath(tmp.dir, std.Options.debug_io, &buf);
    const prefix = try testing.allocator.dupe(u8, buf[0..n]);

    const cellar_share = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/testpkg/1.0/share", .{prefix});
    defer testing.allocator.free(cellar_share);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_share);

    const etc = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{prefix});
    defer testing.allocator.free(etc);
    try test_io.cwd().createDirPath(std.Options.debug_io, etc);

    // The source the post_install body symlinks to.
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src.pem", .{cellar_share});
    defer testing.allocator.free(src);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);

    return prefix;
}

test "install_symlink: ca-certificates-shaped post_install lands the cert symlink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix = try makePrefix();
    defer testing.allocator.free(prefix);

    const json = try minimalJson(alloc);
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();

    var flog = dsl.FallbackLog.init(alloc);
    defer flog.deinit();

    const environ = malt.app_ctx.processEnviron();
    var threaded: std.Io.Threaded = .init(alloc, .{ .environ = environ });
    defer threaded.deinit();

    // Exact shape of ca-certificates' post_install: rm_f a (missing) cert,
    // then install_symlink the keg's bundle into etc under a fixed name.
    const ruby_src =
        \\rm_f etc/"cert.pem"
        \\etc.install_symlink share/"src.pem" => "cert.pem"
    ;

    try dsl.executePostInstall(threaded.io(), environ, alloc, .{
        .name = f.name,
        .version = f.version,
        .pkg_version = f.pkg_version,
    }, ruby_src, prefix, &flog);

    // rm_f on a missing target is a silent no-op — neither it nor
    // install_symlink may be logged as unknown_method.
    for (flog.entries.items) |entry| {
        if (entry.reason == .unknown_method) {
            std.debug.print("unexpected unknown_method: {s}\n", .{entry.detail});
            return error.UnexpectedUnknownMethod;
        }
    }

    // <prefix>/etc/cert.pem is a symlink to the keg's share/src.pem.
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/etc/cert.pem", .{prefix});
    defer testing.allocator.free(link);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/testpkg/1.0/share/src.pem", .{prefix});
    defer testing.allocator.free(expected);

    var buf: [test_io.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(expected, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "install_symlink: positional form lands the link by basename end-to-end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix = try makePrefix();
    defer testing.allocator.free(prefix);

    const json = try minimalJson(alloc);
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();
    var flog = dsl.FallbackLog.init(alloc);
    defer flog.deinit();
    const environ = malt.app_ctx.processEnviron();
    var threaded: std.Io.Threaded = .init(alloc, .{ .environ = environ });
    defer threaded.deinit();

    // No `=>`: the link name is the basename of the source.
    const ruby_src = "etc.install_symlink share/\"src.pem\"";
    try dsl.executePostInstall(threaded.io(), environ, alloc, .{
        .name = f.name,
        .version = f.version,
        .pkg_version = f.pkg_version,
    }, ruby_src, prefix, &flog);

    const link = try std.fmt.allocPrint(testing.allocator, "{s}/etc/src.pem", .{prefix});
    defer testing.allocator.free(link);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/testpkg/1.0/share/src.pem", .{prefix});
    defer testing.allocator.free(expected);
    var buf: [test_io.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(expected, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "install_symlink: rm_f clears a pre-existing regular file before relinking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const prefix = try makePrefix();
    defer testing.allocator.free(prefix);

    // Pre-seed etc/cert.pem as a *regular file* — the stale state
    // ca-certificates' `rm_f` is there to clear.
    const stale = try std.fmt.allocPrint(testing.allocator, "{s}/etc/cert.pem", .{prefix});
    defer testing.allocator.free(stale);
    (try test_io.createFileAbsolute(std.Options.debug_io, stale, .{})).close(std.Options.debug_io);

    const json = try minimalJson(alloc);
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();
    var flog = dsl.FallbackLog.init(alloc);
    defer flog.deinit();
    const environ = malt.app_ctx.processEnviron();
    var threaded: std.Io.Threaded = .init(alloc, .{ .environ = environ });
    defer threaded.deinit();

    const ruby_src =
        \\rm_f etc/"cert.pem"
        \\etc.install_symlink share/"src.pem" => "cert.pem"
    ;
    try dsl.executePostInstall(threaded.io(), environ, alloc, .{
        .name = f.name,
        .version = f.version,
        .pkg_version = f.pkg_version,
    }, ruby_src, prefix, &flog);

    // The regular file is gone; cert.pem is now the symlink.
    var buf: [test_io.max_path_bytes]u8 = undefined;
    const got = try test_io.readLinkAbsolute(std.Options.debug_io, stale, &buf);
    try testing.expect(std.mem.endsWith(u8, got, "/share/src.pem"));
}
