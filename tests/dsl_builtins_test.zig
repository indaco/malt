//! malt — DSL builtin coverage tests
//! Drives pathname/fileutils/process builtin functions directly against a
//! real temp-directory sandbox to cover the happy paths that the
//! interpreter-level tests don't already touch.

const std = @import("std");
const builtin = @import("builtin");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const dsl = @import("malt").dsl;
const pathname = dsl.builtins.pathname;
const fileutils = dsl.builtins.fileutils;
const process = dsl.builtins.process;
const string = dsl.builtins.string;
const Value = dsl.Value;
const ExecCtx = pathname.ExecCtx;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn uniqueSandbox(suffix: []const u8) ![]const u8 {
    const p = try test_io.uniqueTempPath(testing.allocator, "dsl_builtins", suffix);
    test_io.cwd().createDirPath(std.Options.debug_io, p) catch {};
    return p;
}

/// Live-environ Threaded so DSL builtins that spawn or read child pipes
/// (system, safePopenRead, macosVersion) reach a real PATH. Lifetime
/// scoped via `defer LiveIo.deinit`.
const LiveIo = struct {
    threaded: std.Io.Threaded,
    pub fn init() LiveIo {
        return .{ .threaded = .init(testing.allocator, .{ .environ = malt.app_ctx.processEnviron() }) };
    }
    pub fn deinit(self: *LiveIo) void {
        self.threaded.deinit();
    }
    pub fn io(self: *LiveIo) std.Io {
        return self.threaded.io();
    }
};

fn mkCtx(root: []const u8) ExecCtx {
    return .{
        .allocator = testing.allocator,
        .io = std.Options.debug_io,
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = root,
        .malt_prefix = root,
    };
}

fn mkCtxLive(lio: *LiveIo, root: []const u8) ExecCtx {
    return .{
        .allocator = testing.allocator,
        .io = lio.io(),
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = root,
        .malt_prefix = root,
    };
}

// ---------------------------------------------------------------------------
// Pathname builtins
// ---------------------------------------------------------------------------

test "Pathname.mkpath creates a directory tree under the receiver" {
    const root = try uniqueSandbox("mkpath");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const nested = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c", .{root});
    defer testing.allocator.free(nested);

    _ = try pathname.mkpath(ctx, Value{ .pathname = nested }, &.{});
    var d = try test_io.openDirAbsolute(std.Options.debug_io, nested, .{});
    d.close(std.Options.debug_io);
}

test "Pathname.mkpath refuses a directory outside the sandbox" {
    const root = try uniqueSandbox("mkpath_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("mkpath_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const escaped = try std.fmt.allocPrint(testing.allocator, "{s}/created", .{outside});
    defer testing.allocator.free(escaped);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.mkpath(mkCtx(root), Value{ .pathname = escaped }, &.{}),
    );
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, escaped, .{}));
}

test "Pathname.exist?, .directory?, .file?, .symlink? classify entries correctly" {
    const root = try uniqueSandbox("classify");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    // Create a regular file, a directory, and a symlink.
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{root});
    defer testing.allocator.free(file_path);
    const dir_path = try std.fmt.allocPrint(testing.allocator, "{s}/d", .{root});
    defer testing.allocator.free(dir_path);
    const link_path = try std.fmt.allocPrint(testing.allocator, "{s}/link", .{root});
    defer testing.allocator.free(link_path);
    const missing_path = try std.fmt.allocPrint(testing.allocator, "{s}/missing", .{root});
    defer testing.allocator.free(missing_path);

    const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{});
    f.close(std.Options.debug_io);
    try test_io.makeDirAbsolute(std.Options.debug_io, dir_path);
    try test_io.symLinkAbsolute(std.Options.debug_io, file_path, link_path, .{});

    try testing.expect((try pathname.existQ(ctx, Value{ .pathname = file_path }, &.{})).bool);
    try testing.expect(!(try pathname.existQ(ctx, Value{ .pathname = missing_path }, &.{})).bool);

    try testing.expect((try pathname.directoryQ(ctx, Value{ .pathname = dir_path }, &.{})).bool);
    try testing.expect(!(try pathname.directoryQ(ctx, Value{ .pathname = file_path }, &.{})).bool);

    try testing.expect((try pathname.fileQ(ctx, Value{ .pathname = file_path }, &.{})).bool);
    try testing.expect(!(try pathname.fileQ(ctx, Value{ .pathname = dir_path }, &.{})).bool);

    try testing.expect((try pathname.symlinkQ(ctx, Value{ .pathname = link_path }, &.{})).bool);
    try testing.expect(!(try pathname.symlinkQ(ctx, Value{ .pathname = file_path }, &.{})).bool);

    // Empty-string path returns false on every Q-predicate.
    try testing.expect(!(try pathname.existQ(ctx, Value{ .pathname = "" }, &.{})).bool);
    try testing.expect(!(try pathname.directoryQ(ctx, Value{ .pathname = "" }, &.{})).bool);
    try testing.expect(!(try pathname.fileQ(ctx, Value{ .pathname = "" }, &.{})).bool);
    try testing.expect(!(try pathname.symlinkQ(ctx, Value{ .pathname = "" }, &.{})).bool);
}

test "Pathname.write + Pathname.read round-trip content through the sandbox" {
    const root = try uniqueSandbox("rw");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/payload.txt", .{root});
    defer testing.allocator.free(path);
    const args = [_]Value{.{ .string = "hello world" }};
    _ = try pathname.write(ctx, Value{ .pathname = path }, &args);

    const out = try pathname.read(ctx, Value{ .pathname = path }, &.{});
    try testing.expectEqualStrings("hello world", out.string);
    testing.allocator.free(out.string);
}

test "Pathname.write returns PathSandboxViolation for paths outside the sandbox" {
    const root = try uniqueSandbox("violate");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const args = [_]Value{.{ .string = "oops" }};
    try testing.expectError(
        error.PathSandboxViolation,
        pathname.write(ctx, Value{ .pathname = "/etc/malt_bad_write" }, &args),
    );
}

test "Pathname.read returns empty string for a missing file" {
    const root = try uniqueSandbox("read_missing");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/missing", .{root});
    defer testing.allocator.free(missing);
    const out = try pathname.read(ctx, Value{ .pathname = missing }, &.{});
    try testing.expectEqualStrings("", out.string);
}

test "Pathname.read refuses a source outside the sandbox" {
    const root = try uniqueSandbox("read_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("read_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/private", .{outside});
    defer testing.allocator.free(victim);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, victim, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "PRIVATE");
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = mkCtx(root);
    ctx.allocator = arena.allocator();
    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.read(ctx, Value{ .pathname = victim }, &.{}),
    );
}

test "Pathname.read refuses a final symlink outside the sandbox" {
    const root = try uniqueSandbox("read_symlink_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("read_symlink_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/private", .{outside});
    defer testing.allocator.free(victim);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/config", .{root});
    defer testing.allocator.free(link);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, victim, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "PRIVATE");
    }
    try test_io.symLinkAbsolute(std.Options.debug_io, victim, link, .{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = mkCtx(root);
    ctx.allocator = arena.allocator();
    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.read(ctx, Value{ .pathname = link }, &.{}),
    );
}

test "Pathname.children returns array of children; empty for missing dir" {
    const root = try uniqueSandbox("children");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const a = try std.fmt.allocPrint(testing.allocator, "{s}/a", .{root});
    defer testing.allocator.free(a);
    const b = try std.fmt.allocPrint(testing.allocator, "{s}/b", .{root});
    defer testing.allocator.free(b);
    (try test_io.createFileAbsolute(std.Options.debug_io, a, .{})).close(std.Options.debug_io);
    (try test_io.createFileAbsolute(std.Options.debug_io, b, .{})).close(std.Options.debug_io);

    const result = try pathname.children(ctx, Value{ .pathname = root }, &.{});
    defer {
        for (result.array) |entry| testing.allocator.free(entry.pathname);
        testing.allocator.free(result.array);
    }
    try testing.expectEqual(@as(usize, 2), result.array.len);

    const empty = try pathname.children(ctx, Value{ .pathname = "/tmp/malt_children_nonexistent_xyz" }, &.{});
    try testing.expectEqual(@as(usize, 0), empty.array.len);
}

test "Pathname.basename/.dirname/.extname/.toS expose path components" {
    const ctx = mkCtx("/tmp/malt");
    try testing.expectEqualStrings("hello.tar.gz", (try pathname.basename(ctx, Value{ .pathname = "/a/b/hello.tar.gz" }, &.{})).string);
    try testing.expectEqualStrings("/a/b", (try pathname.dirname(ctx, Value{ .pathname = "/a/b/hello.tar.gz" }, &.{})).pathname);
    try testing.expectEqualStrings(".gz", (try pathname.extname(ctx, Value{ .pathname = "/a/b/hello.tar.gz" }, &.{})).string);
    try testing.expectEqualStrings("/x/y", (try pathname.toS(ctx, Value{ .pathname = "/x/y" }, &.{})).string);
}

test "Pathname.opt_bin/.opt_lib/.opt_include append the right subdir" {
    const ctx = mkCtx("/tmp/malt");
    const v = Value{ .pathname = "/opt/malt/opt/foo" };

    const bin = try pathname.optBin(ctx, v, &.{});
    defer testing.allocator.free(bin.pathname);
    try testing.expectEqualStrings("/opt/malt/opt/foo/bin", bin.pathname);

    const lib = try pathname.optLib(ctx, v, &.{});
    defer testing.allocator.free(lib.pathname);
    try testing.expectEqualStrings("/opt/malt/opt/foo/lib", lib.pathname);

    const inc = try pathname.optInclude(ctx, v, &.{});
    defer testing.allocator.free(inc.pathname);
    try testing.expectEqualStrings("/opt/malt/opt/foo/include", inc.pathname);
}

test "Pathname.unlink deletes a file in the sandbox" {
    const root = try uniqueSandbox("unlink");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/goodbye.txt", .{root});
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);

    _ = try pathname.unlink(ctx, Value{ .pathname = path }, &.{});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, path, .{}));
}

test "Pathname.unlink refuses an intermediate symlink outside the sandbox" {
    const root = try uniqueSandbox("unlink_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("unlink_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};

    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{outside});
    defer testing.allocator.free(victim);
    (try test_io.createFileAbsolute(std.Options.debug_io, victim, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const through = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{doorway});
    defer testing.allocator.free(through);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.unlink(mkCtx(root), Value{ .pathname = through }, &.{}),
    );
    try test_io.accessAbsolute(std.Options.debug_io, victim, .{});
}

test "Pathname.install_symlink (positional) links <dir>/<basename(source)> -> source" {
    // Homebrew semantics: receiver is the target directory, arg[0] is the
    // source. The link lands at <dir>/<basename(source)>.
    const root = try uniqueSandbox("install_symlink_pos");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/source.txt", .{root});
    defer testing.allocator.free(src);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/sub", .{root});
    defer testing.allocator.free(dir);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);

    const args = [_]Value{.{ .string = src }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args);

    const link = try std.fmt.allocPrint(testing.allocator, "{s}/source.txt", .{dir});
    defer testing.allocator.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(src, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "Pathname.install_symlink (hash) links <dir>/<link_name> -> source" {
    // The `source => link_name` form: ca-certificates uses
    // `openssl_pkgetc.install_symlink pkgshare/"cacert.pem" => "cert.pem"`.
    const root = try uniqueSandbox("install_symlink_hash");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/cacert.pem", .{root});
    defer testing.allocator.free(src);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{root});
    defer testing.allocator.free(dir);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);

    const pairs = [_]Value.HashPair{.{ .key = .{ .pathname = src }, .value = .{ .string = "cert.pem" } }};
    const args = [_]Value{.{ .hash = &pairs }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args);

    const link = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
    defer testing.allocator.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(src, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "Pathname.install_symlink (array) links each source by basename" {
    const root = try uniqueSandbox("install_symlink_arr");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const a = try std.fmt.allocPrint(testing.allocator, "{s}/a.conf", .{root});
    defer testing.allocator.free(a);
    const b = try std.fmt.allocPrint(testing.allocator, "{s}/b.conf", .{root});
    defer testing.allocator.free(b);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{root});
    defer testing.allocator.free(dir);
    for ([_][]const u8{ a, b }) |p| (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);

    const items = [_]Value{ .{ .pathname = a }, .{ .pathname = b } };
    const args = [_]Value{.{ .array = &items }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "a.conf", "b.conf" }) |name| {
        const link = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
        defer testing.allocator.free(link);
        _ = try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf);
    }
}

test "Pathname.install_symlink refuses scalar, array, and hash targets outside the sandbox" {
    const root = try uniqueSandbox("install_symlink_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("install_symlink_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/private", .{outside});
    defer testing.allocator.free(target);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/bin", .{root});
    defer testing.allocator.free(dir);
    const ctx = mkCtx(root);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.installSymlink(ctx, Value{ .pathname = dir }, &.{Value{ .string = target }}),
    );
    const items = [_]Value{Value{ .string = target }};
    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.installSymlink(ctx, Value{ .pathname = dir }, &.{Value{ .array = &items }}),
    );
    const pairs = [_]Value.HashPair{.{ .key = Value{ .string = target }, .value = Value{ .string = "alias" } }};
    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.installSymlink(ctx, Value{ .pathname = dir }, &.{Value{ .hash = &pairs }}),
    );
}

test "Pathname.install_symlink refuses a destination symlink outside the sandbox" {
    const root = try uniqueSandbox("install_symlink_dest_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("install_symlink_dest_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{root});
    defer testing.allocator.free(target);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const escaped = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{outside});
    defer testing.allocator.free(escaped);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        pathname.installSymlink(mkCtx(root), Value{ .pathname = doorway }, &.{Value{ .string = target }}),
    );
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, escaped, .{}));
}

test "Pathname.install_symlink replaces an existing link at the target name" {
    const root = try uniqueSandbox("install_symlink_replace");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const old_src = try std.fmt.allocPrint(testing.allocator, "{s}/old.pem", .{root});
    defer testing.allocator.free(old_src);
    const new_src = try std.fmt.allocPrint(testing.allocator, "{s}/new.pem", .{root});
    defer testing.allocator.free(new_src);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{root});
    defer testing.allocator.free(dir);
    for ([_][]const u8{ old_src, new_src }) |p| (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);

    const args_old = [_]Value{.{ .hash = &[_]Value.HashPair{.{ .key = .{ .pathname = old_src }, .value = .{ .string = "cert.pem" } }} }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args_old);
    const args_new = [_]Value{.{ .hash = &[_]Value.HashPair{.{ .key = .{ .pathname = new_src }, .value = .{ .string = "cert.pem" } }} }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args_new);

    const link = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
    defer testing.allocator.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(new_src, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "Pathname.install_symlink rejects a target directory outside the sandbox" {
    const root = try uniqueSandbox("install_symlink_violate");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const args = [_]Value{.{ .string = "/some/source" }};
    try testing.expectError(
        error.PathSandboxViolation,
        pathname.installSymlink(ctx, Value{ .pathname = "/etc/malt_bad_symlink_dir" }, &args),
    );
}

test "Pathname.install_symlink with no args is a no-op returning nil" {
    const root = try uniqueSandbox("install_symlink_noargs");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const v = try pathname.installSymlink(ctx, Value{ .pathname = root }, &.{});
    try testing.expect(v == .nil);
}

test "Pathname.install_symlink accepts a plain string source (not only pathname)" {
    const root = try uniqueSandbox("install_symlink_strsrc");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/s.txt", .{root});
    defer testing.allocator.free(src);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);

    const args = [_]Value{.{ .string = src }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = root }, &args);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/s.txt", .{root});
    defer testing.allocator.free(link);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(src, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "Pathname.install_symlink hash with multiple pairs links each" {
    const root = try uniqueSandbox("install_symlink_multi");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const s1 = try std.fmt.allocPrint(testing.allocator, "{s}/one", .{root});
    defer testing.allocator.free(s1);
    const s2 = try std.fmt.allocPrint(testing.allocator, "{s}/two", .{root});
    defer testing.allocator.free(s2);
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc", .{root});
    defer testing.allocator.free(dir);
    for ([_][]const u8{ s1, s2 }) |p| (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);

    const pairs = [_]Value.HashPair{
        .{ .key = .{ .pathname = s1 }, .value = .{ .string = "a.pem" } },
        .{ .key = .{ .pathname = s2 }, .value = .{ .string = "b.pem" } },
    };
    const args = [_]Value{.{ .hash = &pairs }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = dir }, &args);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "a.pem", .src = s1 },
        .{ .name = "b.pem", .src = s2 },
    }) |entry| {
        const link = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, entry.name });
        defer testing.allocator.free(link);
        try testing.expectEqualStrings(entry.src, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
    }
}

test "Pathname.install_symlink skips a hash entry with an empty link name" {
    const root = try uniqueSandbox("install_symlink_emptyname");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{root});
    defer testing.allocator.free(src);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);

    // Empty link name must not create `<root>/` or crash — just skip.
    const pairs = [_]Value.HashPair{.{ .key = .{ .pathname = src }, .value = .{ .string = "" } }};
    const args = [_]Value{.{ .hash = &pairs }};
    const v = try pathname.installSymlink(ctx, Value{ .pathname = root }, &args);
    try testing.expect(v == .nil);
}

test "rm_f removes an array of paths and skips out-of-sandbox entries" {
    const root = try uniqueSandbox("rm_f_array");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const rm_f = @import("malt").dsl.builtins.bare_builtins.get("rm_f").?;
    const good = try std.fmt.allocPrint(testing.allocator, "{s}/g.txt", .{root});
    defer testing.allocator.free(good);
    (try test_io.createFileAbsolute(std.Options.debug_io, good, .{})).close(std.Options.debug_io);

    const items = [_]Value{ .{ .string = "/etc/passwd" }, .{ .string = good } };
    _ = try rm_f(ctx, null, &.{.{ .array = &items }});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, good, .{}));
}

test "rm_f rejects a single path outside the sandbox (force does not bypass the boundary)" {
    const root = try uniqueSandbox("rm_f_violate");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const rm_f = @import("malt").dsl.builtins.bare_builtins.get("rm_f").?;
    try testing.expectError(error.PathSandboxViolation, rm_f(ctx, null, &.{.{ .string = "/etc/passwd" }}));
}

test "rm_f is registered as an alias of rm in the bare-builtin table" {
    const dispatch = @import("malt").dsl.builtins.bare_builtins;
    try testing.expect(dispatch.get("rm_f") != null);
    try testing.expect(dispatch.get("rm") != null);
}

test "rm_f silently no-ops on a missing target inside the sandbox" {
    const root = try uniqueSandbox("rm_f_missing");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const rm_f = @import("malt").dsl.builtins.bare_builtins.get("rm_f").?;
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/etc/cert.pem", .{root});
    defer testing.allocator.free(missing);
    const v = try rm_f(ctx, null, &.{.{ .string = missing }});
    try testing.expect(v == .nil);
}

test "Pathname.glob with receiver returns matching entries" {
    const root = try uniqueSandbox("glob");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const lib_dir = try std.fmt.allocPrint(testing.allocator, "{s}/lib", .{root});
    defer testing.allocator.free(lib_dir);
    try test_io.makeDirAbsolute(std.Options.debug_io, lib_dir);
    for ([_][]const u8{ "libfoo.dylib", "libbar.dylib", "readme.txt" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ lib_dir, name });
        defer testing.allocator.free(p);
        (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);
    }

    const args = [_]Value{.{ .string = "*.dylib" }};
    const result = try pathname.glob(ctx, Value{ .pathname = lib_dir }, &args);
    defer {
        for (result.array) |entry| testing.allocator.free(entry.pathname);
        testing.allocator.free(result.array);
    }
    try testing.expectEqual(@as(usize, 2), result.array.len);
}

test "Pathname.glob bare form (no receiver) splits dirname/basename of the pattern" {
    const root = try uniqueSandbox("glob_bare");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const a_path = try std.fmt.allocPrint(testing.allocator, "{s}/a.zig", .{root});
    defer testing.allocator.free(a_path);
    (try test_io.createFileAbsolute(std.Options.debug_io, a_path, .{})).close(std.Options.debug_io);

    const pattern = try std.fmt.allocPrint(testing.allocator, "{s}/*.zig", .{root});
    defer testing.allocator.free(pattern);
    const args = [_]Value{.{ .string = pattern }};
    const result = try pathname.glob(ctx, null, &args);
    defer {
        for (result.array) |entry| testing.allocator.free(entry.pathname);
        testing.allocator.free(result.array);
    }
    try testing.expectEqual(@as(usize, 1), result.array.len);
}

test "Pathname.glob honours {a,b,c} brace expansion" {
    const root = try uniqueSandbox("glob_brace");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    for ([_][]const u8{ "a.c", "a.h", "a.o" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ root, name });
        defer testing.allocator.free(p);
        (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);
    }
    const args = [_]Value{.{ .string = "*.{c,h}" }};
    const result = try pathname.glob(ctx, Value{ .pathname = root }, &args);
    defer {
        for (result.array) |entry| testing.allocator.free(entry.pathname);
        testing.allocator.free(result.array);
    }
    try testing.expectEqual(@as(usize, 2), result.array.len);
}

// ---------------------------------------------------------------------------
// FileUtils builtins
// ---------------------------------------------------------------------------

test "FileUtils.mkdir_p + touch + rm round-trip through the sandbox" {
    const root = try uniqueSandbox("fileutils_basic");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const nested = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c", .{root});
    defer testing.allocator.free(nested);
    _ = try fileutils.mkdirP(ctx, null, &.{.{ .string = nested }});
    var d = try test_io.openDirAbsolute(std.Options.debug_io, nested, .{});
    d.close(std.Options.debug_io);

    const file = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c/hello", .{root});
    defer testing.allocator.free(file);
    _ = try fileutils.touch(ctx, null, &.{.{ .string = file }});
    (try test_io.openFileAbsolute(std.Options.debug_io, file, .{})).close(std.Options.debug_io);

    _ = try fileutils.rm(ctx, null, &.{.{ .string = file }});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, file, .{}));
}

test "FileUtils.cp copies a single file into the sandbox" {
    const root = try uniqueSandbox("fileutils_cp");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src.txt", .{root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/dst.txt", .{root});
    defer testing.allocator.free(dst);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, src, .{});
        try f.writeStreamingAll(std.Options.debug_io, "payload");
        f.close(std.Options.debug_io);
    }
    _ = try fileutils.cp(ctx, null, &.{
        .{ .string = src },
        .{ .string = dst },
    });

    const f = try test_io.openFileAbsolute(std.Options.debug_io, dst, .{});
    defer f.close(std.Options.debug_io);
    var buf: [32]u8 = undefined;
    const n = try f.readPositionalAll(std.Options.debug_io, &buf, 0);
    try testing.expectEqualStrings("payload", buf[0..n]);
}

test "FileUtils.cp with an array copies each file into the destination directory" {
    const root = try uniqueSandbox("fileutils_cp_array");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = ExecCtx{ .allocator = arena.allocator(), .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron(), .cellar_path = root, .malt_prefix = root };

    const dst_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{root});
    defer testing.allocator.free(dst_dir);

    const src_a = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{root});
    defer testing.allocator.free(src_a);
    const src_b = try std.fmt.allocPrint(testing.allocator, "{s}/b.txt", .{root});
    defer testing.allocator.free(src_b);
    for ([_][]const u8{ src_a, src_b }) |p| {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, p, .{});
        try f.writeStreamingAll(std.Options.debug_io, "x");
        f.close(std.Options.debug_io);
    }

    const items = [_]Value{ .{ .string = src_a }, .{ .string = src_b } };
    _ = try fileutils.cp(ctx, null, &.{ .{ .array = &items }, .{ .string = dst_dir } });

    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dst_dir, name });
        defer testing.allocator.free(p);
        (try test_io.openFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);
    }
}

test "FileUtils.rm_r (and rm_rf alias) delete a directory tree" {
    const root = try uniqueSandbox("fileutils_rmr");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);

    const tree = try std.fmt.allocPrint(testing.allocator, "{s}/tree/a/b", .{root});
    defer testing.allocator.free(tree);
    try test_io.cwd().createDirPath(std.Options.debug_io, tree);

    const root_tree = try std.fmt.allocPrint(testing.allocator, "{s}/tree", .{root});
    defer testing.allocator.free(root_tree);
    _ = try fileutils.rmR(ctx, null, &.{.{ .string = root_tree }});
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(std.Options.debug_io, root_tree, .{}));

    try test_io.cwd().createDirPath(std.Options.debug_io, tree);
    _ = try fileutils.rmRf(ctx, null, &.{.{ .string = root_tree }});
    try testing.expectError(error.FileNotFound, test_io.openDirAbsolute(std.Options.debug_io, root_tree, .{}));
}

test "FileUtils.rm with an array silently skips out-of-sandbox paths but removes the others" {
    const root = try uniqueSandbox("fileutils_rm_array");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const good = try std.fmt.allocPrint(testing.allocator, "{s}/good.txt", .{root});
    defer testing.allocator.free(good);
    (try test_io.createFileAbsolute(std.Options.debug_io, good, .{})).close(std.Options.debug_io);

    const items = [_]Value{ .{ .string = "/etc/passwd" }, .{ .string = good } };
    _ = try fileutils.rm(ctx, null, &.{.{ .array = &items }});
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, good, .{}));
}

test "FileUtils.chmod with an array of paths chmods each one" {
    const root = try uniqueSandbox("fileutils_chmod_array");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const a = try std.fmt.allocPrint(testing.allocator, "{s}/a", .{root});
    defer testing.allocator.free(a);
    const b = try std.fmt.allocPrint(testing.allocator, "{s}/b", .{root});
    defer testing.allocator.free(b);
    for ([_][]const u8{ a, b }) |p| (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);

    const items = [_]Value{ .{ .string = a }, .{ .string = b } };
    _ = try fileutils.chmod(ctx, null, &.{ .{ .int = 0o644 }, .{ .array = &items } });
}

test "FileUtils.ln_sf with an array symlinks each target into the dest dir" {
    const root = try uniqueSandbox("fileutils_lnsf_array");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = ExecCtx{ .allocator = arena.allocator(), .io = std.Options.debug_io, .environ = malt.app_ctx.processEnviron(), .cellar_path = root, .malt_prefix = root };
    const t1 = try std.fmt.allocPrint(testing.allocator, "{s}/t1", .{root});
    defer testing.allocator.free(t1);
    const t2 = try std.fmt.allocPrint(testing.allocator, "{s}/t2", .{root});
    defer testing.allocator.free(t2);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/links", .{root});
    defer testing.allocator.free(dst);
    for ([_][]const u8{ t1, t2 }) |p| (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);

    const items = [_]Value{ .{ .string = t1 }, .{ .string = t2 } };
    _ = try fileutils.lnSf(ctx, null, &.{ .{ .array = &items }, .{ .string = dst } });

    for ([_][]const u8{ "t1", "t2" }) |name| {
        const link = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dst, name });
        defer testing.allocator.free(link);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf);
    }
}

test "FileUtils.mv renames within the sandbox" {
    const root = try uniqueSandbox("fileutils_mv");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/x.txt", .{root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/y.txt", .{root});
    defer testing.allocator.free(dst);
    (try test_io.createFileAbsolute(std.Options.debug_io, src, .{})).close(std.Options.debug_io);
    _ = try fileutils.mv(ctx, null, &.{ .{ .string = src }, .{ .string = dst } });
    try testing.expectError(error.FileNotFound, test_io.openFileAbsolute(std.Options.debug_io, src, .{}));
    (try test_io.openFileAbsolute(std.Options.debug_io, dst, .{})).close(std.Options.debug_io);
}

test "FileUtils.ln_s/ln_sf create (and force-replace) symlinks" {
    const root = try uniqueSandbox("fileutils_ln");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{root});
    defer testing.allocator.free(target);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/sub/link", .{root});
    defer testing.allocator.free(link);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);

    _ = try fileutils.lnS(ctx, null, &.{ .{ .string = target }, .{ .string = link } });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(target, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));

    // ln_sf should overwrite the existing symlink silently.
    _ = try fileutils.lnSf(ctx, null, &.{ .{ .string = target }, .{ .string = link } });
    try testing.expectEqualStrings(target, try test_io.readLinkAbsolute(std.Options.debug_io, link, &buf));
}

test "FileUtils.ln_sf scalar refuses an intermediate symlink outside the sandbox" {
    const root = try uniqueSandbox("lnsf_scalar_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("lnsf_scalar_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{root});
    defer testing.allocator.free(target);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const through = try std.fmt.allocPrint(testing.allocator, "{s}/escaped", .{doorway});
    defer testing.allocator.free(through);
    const escaped = try std.fmt.allocPrint(testing.allocator, "{s}/escaped", .{outside});
    defer testing.allocator.free(escaped);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        fileutils.lnSf(mkCtx(root), null, &.{ Value{ .string = target }, Value{ .string = through } }),
    );
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, escaped, .{}));
}

test "FileUtils.ln_sf array refuses a destination symlink outside the sandbox" {
    const root = try uniqueSandbox("lnsf_array_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("lnsf_array_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};

    const target = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{root});
    defer testing.allocator.free(target);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const items = [_]Value{Value{ .string = target }};
    const escaped = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{outside});
    defer testing.allocator.free(escaped);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        fileutils.lnSf(mkCtx(root), null, &.{ Value{ .array = &items }, Value{ .string = doorway } }),
    );
    try testing.expectError(error.FileNotFound, test_io.accessAbsolute(std.Options.debug_io, escaped, .{}));
}

test "FileUtils.rm rejects paths outside the sandbox" {
    const root = try uniqueSandbox("fileutils_violate");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    try testing.expectError(
        error.PathSandboxViolation,
        fileutils.rm(ctx, null, &.{.{ .string = "/etc/passwd" }}),
    );
}

test "FileUtils.rm scalar refuses an intermediate symlink outside the sandbox" {
    const root = try uniqueSandbox("rm_scalar_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("rm_scalar_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{outside});
    defer testing.allocator.free(victim);
    (try test_io.createFileAbsolute(std.Options.debug_io, victim, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const through = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{doorway});
    defer testing.allocator.free(through);

    try testing.expectError(
        pathname.BuiltinError.PathSandboxViolation,
        fileutils.rm(mkCtx(root), null, &.{Value{ .string = through }}),
    );
    try test_io.accessAbsolute(std.Options.debug_io, victim, .{});
}

test "FileUtils.rm array skips an intermediate symlink outside the sandbox" {
    const root = try uniqueSandbox("rm_array_escape_root");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const outside = try uniqueSandbox("rm_array_escape_outside");
    defer testing.allocator.free(outside);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, outside) catch {};
    const victim = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{outside});
    defer testing.allocator.free(victim);
    (try test_io.createFileAbsolute(std.Options.debug_io, victim, .{})).close(std.Options.debug_io);
    const doorway = try std.fmt.allocPrint(testing.allocator, "{s}/door", .{root});
    defer testing.allocator.free(doorway);
    try test_io.symLinkAbsolute(std.Options.debug_io, outside, doorway, .{});
    const through = try std.fmt.allocPrint(testing.allocator, "{s}/victim", .{doorway});
    defer testing.allocator.free(through);
    const items = [_]Value{Value{ .string = through }};

    _ = try fileutils.rm(mkCtx(root), null, &.{Value{ .array = &items }});
    try test_io.accessAbsolute(std.Options.debug_io, victim, .{});
}

test "FileUtils.chmod returns nil for a non-int mode and is a no-op" {
    const root = try uniqueSandbox("fileutils_chmod_nil");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/f", .{root});
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
    const v = try fileutils.chmod(ctx, null, &.{ .{ .string = "0755" }, .{ .string = path } });
    try testing.expect(v == .nil);
}

// A formula carries its mode as an i64; chmod must mask to the permission bits
// rather than narrow through i32/u16, where any of three windows aborts the
// process: out of i32 range, negative, or in-i32 but past mode_t (u16).
test "FileUtils.chmod masks an out-of-i32-range mode instead of aborting" {
    const root = try uniqueSandbox("fileutils_chmod_overflow");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/f", .{root});
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
    const v = try fileutils.chmod(ctx, null, &.{ .{ .int = 9999999999 }, .{ .string = path } });
    try testing.expect(v == .nil);
}

test "FileUtils.chmod masks a negative mode instead of aborting" {
    const root = try uniqueSandbox("fileutils_chmod_negative");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/f", .{root});
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
    const v = try fileutils.chmod(ctx, null, &.{ .{ .int = -1 }, .{ .string = path } });
    try testing.expect(v == .nil);
}

test "FileUtils.chmod masks high non-permission bits down to 0o7777" {
    const root = try uniqueSandbox("fileutils_chmod_mask");
    defer testing.allocator.free(root);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, root) catch {};
    const ctx = mkCtx(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/f", .{root});
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
    // 70000 fits i32 but exceeds mode_t; 70000 & 0o7777 == 0o560.
    _ = try fileutils.chmod(ctx, null, &.{ .{ .int = 70000 }, .{ .string = path } });
    const got = (try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{})).permissions.toMode();
    try testing.expectEqual(@as(std.posix.mode_t, 0o560), got & 0o7777);
}

// ---------------------------------------------------------------------------
// Process builtins
//
// These builtins allocate short-lived argv slices with the caller's allocator
// and deliberately don't free them (in production the interpreter hands them
// an arena that's reset per-formula). We mirror that contract by wrapping an
// ArenaAllocator for the duration of each test.
// ---------------------------------------------------------------------------

fn arenaCtx(arena: *std.heap.ArenaAllocator, root: []const u8) ExecCtx {
    return .{
        .allocator = arena.allocator(),
        .io = std.Options.debug_io,
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = root,
        .malt_prefix = root,
    };
}

fn arenaCtxLive(arena: *std.heap.ArenaAllocator, lio: *LiveIo, root: []const u8) ExecCtx {
    return .{
        .allocator = arena.allocator(),
        .io = lio.io(),
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = root,
        .malt_prefix = root,
    };
}

test "system runs /bin/true and returns true" {
    try test_io.skipIfNoSubprocess();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lio = LiveIo.init();
    defer lio.deinit();
    const v = try process.system(arenaCtxLive(&arena, &lio, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/true" }});
    try testing.expect(v.bool);
}

test "system runs /bin/false and returns false" {
    try test_io.skipIfNoSubprocess();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lio = LiveIo.init();
    defer lio.deinit();
    const v = try process.system(arenaCtxLive(&arena, &lio, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/false" }});
    try testing.expect(!v.bool);
}

test "system with no args returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.system(arenaCtx(&arena, "/tmp/malt"), null, &.{});
    try testing.expect(v == .nil);
}

test "quietSystem always returns nil regardless of exit code" {
    try test_io.skipIfNoSubprocess();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lio = LiveIo.init();
    defer lio.deinit();
    const v = try process.quietSystem(arenaCtxLive(&arena, &lio, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/false" }});
    try testing.expect(v == .nil);
}

// ---------------------------------------------------------------------------
// Native post_install containment. `system` spawns must run under the same
// real sandbox-exec fence the --use-system-ruby path gets: the DSL argv lint
// (validateArgv) accepts any bare/system-dir argv0, so only the OS fence can
// stop a destructive write the formula's *arguments* aim outside the keg.
// ---------------------------------------------------------------------------

var fence_seq: std.atomic.Value(u32) = .init(0);

/// Scratch root for the fence tests. Stands in for `std.testing.tmpDir`,
/// which roots under `.zig-cache` — a tree the build system rewrites
/// underneath a running test — but deliberately *not* under `/tmp`: the
/// profile grants blanket writes to /tmp, /private/tmp and
/// /private/var/folders, so a base there would pass the denied write
/// through and the assertion would prove nothing. `$HOME/.cache` is
/// writable by the test process and carries no such grant. A relocated
/// HOME surfaces as a skip, not a false pass.
const FenceScratch = struct {
    path: []const u8,

    fn init(tag: []const u8) !FenceScratch {
        const io = std.Options.debug_io;
        const home = test_io.getenv("HOME") orelse return error.SkipZigTest;
        const raw = try std.fmt.allocPrint(testing.allocator, "{s}/.cache/malt_fence_{s}_{d}_{d}", .{
            home, tag, std.c.getpid(), fence_seq.fetchAdd(1, .monotonic),
        });
        defer testing.allocator.free(raw);
        test_io.deleteTreeAbsolute(io, raw) catch {};
        try test_io.cwd().createDirPath(io, raw);
        errdefer test_io.deleteTreeAbsolute(io, raw) catch {};

        var dir = try test_io.openDirAbsolute(io, raw, .{});
        defer dir.close(io);
        var buf: [test_io.max_path_bytes]u8 = undefined;
        const base = buf[0..try std.Io.Dir.realPath(dir, io, &buf)];
        if (std.mem.startsWith(u8, base, "/tmp/") or
            std.mem.startsWith(u8, base, "/private/tmp/") or
            std.mem.startsWith(u8, base, "/private/var/folders/"))
            return error.SkipZigTest;
        return .{ .path = try testing.allocator.dupe(u8, base) };
    }

    fn deinit(self: *FenceScratch) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        testing.allocator.free(self.path);
    }
};

test "system: a write outside the keg/prefix is blocked by the fence, not the argv lint" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    var scratch = try FenceScratch.init("fence_outside");
    defer scratch.deinit();
    const base = scratch.path;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "{s}/opt/malt", .{base});
    const cellar = try std.fmt.allocPrint(a, "{s}/Cellar/foo/1.0", .{prefix});
    // Sibling of the prefix: outside both the keg and every blessed subtree.
    const outside = try std.fmt.allocPrint(a, "{s}/pwned", .{base});

    var lio = LiveIo.init();
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = a,
        .io = lio.io(),
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = cellar,
        .malt_prefix = prefix,
    };

    // argv0 (/usr/bin/touch) is a system-dir path the lint accepts; only the OS
    // fence can stop the out-of-root write the argument targets. The denied
    // write makes touch print "Operation not permitted" to the inherited
    // stderr; mute fd 2 around the spawn (the argv-only invariant rules out a
    // shell redirect) so it can't leak into the build runner's error capture
    // and read as a spurious failure. Restored before the assertions.
    const v = blk: {
        const devnull = try std.Io.Dir.cwd().openFile(std.Options.debug_io, "/dev/null", .{ .mode = .write_only });
        defer devnull.close(std.Options.debug_io);
        const saved_err = std.c.dup(std.posix.STDERR_FILENO);
        defer {
            _ = std.c.dup2(saved_err, std.posix.STDERR_FILENO);
            _ = std.c.close(saved_err);
        }
        _ = std.c.dup2(devnull.handle, std.posix.STDERR_FILENO);
        break :blk try process.system(ctx, null, &.{
            .{ .string = "/usr/bin/touch" },
            .{ .string = outside },
        });
    };

    try testing.expect(!v.bool); // denied write → touch exits nonzero
    if (std.Io.Dir.cwd().access(std.Options.debug_io, outside, .{})) |_|
        return error.SandboxFenceLeaked
    else |_| {}
}

test "system: a write into the keg still succeeds under the fence (no over-confinement)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try test_io.skipIfNoSubprocess();

    var scratch = try FenceScratch.init("fence_inside");
    defer scratch.deinit();
    const base = scratch.path;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "{s}/opt/malt", .{base});
    const cellar = try std.fmt.allocPrint(a, "{s}/Cellar/foo/1.0", .{prefix});
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, cellar);
    const inside = try std.fmt.allocPrint(a, "{s}/marker", .{cellar});

    var lio = LiveIo.init();
    defer lio.deinit();
    const ctx = ExecCtx{
        .allocator = a,
        .io = lio.io(),
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = cellar,
        .malt_prefix = prefix,
    };

    // A keg-local write is exactly what a real post_install does; the fence
    // must allow it or it would reject the whole regression corpus.
    const v = try process.system(ctx, null, &.{
        .{ .string = "/usr/bin/touch" },
        .{ .string = inside },
    });

    try testing.expect(v.bool); // allowed write → touch exits 0
    try std.Io.Dir.cwd().access(std.Options.debug_io, inside, .{});
}

test "fileExist checks a real path" {
    const ctx = mkCtx("/tmp/malt");
    try testing.expect((try process.fileExist(ctx, null, &.{.{ .string = "/bin/sh" }})).bool);
    try testing.expect(!(try process.fileExist(ctx, null, &.{.{ .string = "/nonexistent/xyz_malt_test" }})).bool);
    try testing.expect(!(try process.fileExist(ctx, null, &.{})).bool);
}

test "devToolsLocate returns a pathname for sh (on PATH)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.devToolsLocate(arenaCtx(&arena, "/tmp/malt"), null, &.{.{ .string = "sh" }});
    try testing.expect(v == .pathname);
    try testing.expect(v.pathname.len > 0);
}

test "devToolsLocate returns nil for empty args" {
    const ctx = mkCtx("/tmp/malt");
    const v = try process.devToolsLocate(ctx, null, &.{});
    try testing.expect(v == .nil);
}

test "devToolsLocate returns a heap-owned pathname (caller can free)" {
    // Regression for the per-iteration alloc cleanup: the result on both
    // the PATH-hit and fallback branches is now allocator.dupe-d, so the
    // caller can rely on `Value.pathname` being heap-owned.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.devToolsLocate(arenaCtx(&arena, "/tmp/malt"), null, &.{.{ .string = "sh" }});
    try testing.expect(v == .pathname);
    try testing.expect(std.mem.endsWith(u8, v.pathname, "/sh"));
    // arena.deinit() will free it without panicking — that's the contract
    // we want to lock in.
}

test "osMac is true, osLinux is false, cpuArch is arm64 or x86_64" {
    const ctx = mkCtx("/tmp/malt");
    try testing.expect((try process.osMac(ctx, null, &.{})).bool);
    try testing.expect(!(try process.osLinux(ctx, null, &.{})).bool);
    const arch = (try process.cpuArch(ctx, null, &.{})).string;
    try testing.expect(std.mem.eql(u8, arch, "arm64") or std.mem.eql(u8, arch, "x86_64"));
}

test "macosVersion returns a non-empty string" {
    try test_io.skipIfNoSubprocess();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lio = LiveIo.init();
    defer lio.deinit();
    const v = try process.macosVersion(arenaCtxLive(&arena, &lio, "/tmp/malt"), null, &.{});
    try testing.expect(v.string.len > 0);
}

test "pathnameNew wraps a string into a Pathname value" {
    const ctx = mkCtx("/tmp/malt");
    const v = try process.pathnameNew(ctx, null, &.{.{ .string = "/some/path" }});
    try testing.expectEqualStrings("/some/path", v.pathname);

    const empty = try process.pathnameNew(ctx, null, &.{});
    try testing.expectEqualStrings("", empty.pathname);
}

test "envGet returns nil for absent keys, string for present keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = [_:null]?[*:0]const u8{"LANG=malt-test-locale"};
    var ctx = arenaCtx(&arena, "/tmp/malt");
    ctx.environ = .{ .block = .{ .slice = &entries } };
    const got = try process.envGet(ctx, null, &.{.{ .string = "LANG" }});
    try testing.expectEqualStrings("malt-test-locale", got.string);

    const missing = try process.envGet(ctx, null, &.{.{ .string = "MALT_DSL_DOES_NOT_EXIST_XYZ" }});
    try testing.expect(missing == .nil);

    const noargs = try process.envGet(ctx, null, &.{});
    try testing.expect(noargs == .nil);
}

test "envGet refuses sensitive parent credentials" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const entries = [_:null]?[*:0]const u8{"MALT_GITHUB_TOKEN=private-token"};
    var ctx = arenaCtx(&arena, "/tmp/malt");
    ctx.environ = .{ .block = .{ .slice = &entries } };

    const got = try process.envGet(ctx, null, &.{.{ .string = "MALT_GITHUB_TOKEN" }});
    try testing.expect(got == .nil);
}

test "envSet does not touch the real environment but returns the written value" {
    const ctx = mkCtx("/tmp/malt");
    const v = try process.envSet(ctx, null, &.{ .{ .string = "MALT_DSL_UNSET_KEY" }, .{ .string = "val" } });
    try testing.expectEqualStrings("val", v.string);
    try testing.expect(test_io.getenv("MALT_DSL_UNSET_KEY") == null);
}

test "formulaLookup returns MALT_PREFIX/opt/<name>" {
    const ctx = ExecCtx{
        .allocator = testing.allocator,
        .io = std.Options.debug_io,
        .environ = malt.app_ctx.processEnviron(),
        .cellar_path = "/tmp/malt",
        .malt_prefix = "/tmp/malt",
    };
    const v = try process.formulaLookup(ctx, null, &.{.{ .string = "wget" }});
    defer testing.allocator.free(v.pathname);
    try testing.expectEqualStrings("/tmp/malt/opt/wget", v.pathname);
}

test "safePopenRead captures stdout and chomps trailing newline" {
    try test_io.skipIfNoSubprocess();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lio = LiveIo.init();
    defer lio.deinit();
    const v = try process.safePopenRead(arenaCtxLive(&arena, &lio, "/tmp/malt"), null, &.{ .{ .string = "/bin/echo" }, .{ .string = "hello" } });
    try testing.expectEqualStrings("hello", v.string);
}

test "safePopenRead does not pass parent credentials to the child" {
    try test_io.skipIfNoSubprocess();
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    _ = c.setenv("MALT_GITHUB_TOKEN", "private-child-token", 1);
    defer _ = c.unsetenv("MALT_GITHUB_TOKEN");
    var lio = LiveIo.init();
    defer lio.deinit();

    const got = try process.safePopenRead(
        arenaCtxLive(&arena, &lio, "/tmp/malt"),
        null,
        &.{.{ .string = "/usr/bin/env" }},
    );
    try testing.expect(std.mem.indexOf(u8, got.string, "private-child-token") == null);
}

// ---------------------------------------------------------------------------
// Version-style accessors on strings — `.major`, `.minor`, `.patch`, `.to_i`
//
// Homebrew formulas routinely chain `OS.kernel_version.major` /
// `Version.new(x).major`. Without these, llvm@21-style post_install bodies
// hit `unknown_method` on each accessor and bail out early.
// ---------------------------------------------------------------------------

test "string.major returns the leading numeric segment as an integer" {
    const v = try string.major(mkCtx("/tmp"), .{ .string = "25.4.0" }, &.{});
    try testing.expectEqual(@as(i64, 25), v.int);
}

test "string.major handles single-segment versions" {
    const v = try string.major(mkCtx("/tmp"), .{ .string = "15" }, &.{});
    try testing.expectEqual(@as(i64, 15), v.int);
}

test "string.major strips a leading 'v' prefix" {
    // Common in tag-style version strings (e.g. `v3.11.7`).
    const v = try string.major(mkCtx("/tmp"), .{ .string = "v3.11.7" }, &.{});
    try testing.expectEqual(@as(i64, 3), v.int);
}

test "string.major returns 0 on non-numeric / empty input" {
    // Conservative: degrade to 0 so downstream `.major == N` comparisons
    // don't crash on stray output. Matches Ruby `"".to_i == 0`.
    try testing.expectEqual(@as(i64, 0), (try string.major(mkCtx("/tmp"), .{ .string = "" }, &.{})).int);
    try testing.expectEqual(@as(i64, 0), (try string.major(mkCtx("/tmp"), .{ .string = "dev" }, &.{})).int);
}

test "string.minor returns the second numeric segment" {
    try testing.expectEqual(@as(i64, 4), (try string.minor(mkCtx("/tmp"), .{ .string = "25.4.0" }, &.{})).int);
    try testing.expectEqual(@as(i64, 11), (try string.minor(mkCtx("/tmp"), .{ .string = "3.11.7" }, &.{})).int);
    // Single-segment version has no minor — fall back to 0.
    try testing.expectEqual(@as(i64, 0), (try string.minor(mkCtx("/tmp"), .{ .string = "15" }, &.{})).int);
}

test "string.patch returns the third numeric segment" {
    try testing.expectEqual(@as(i64, 0), (try string.patch(mkCtx("/tmp"), .{ .string = "25.4.0" }, &.{})).int);
    try testing.expectEqual(@as(i64, 7), (try string.patch(mkCtx("/tmp"), .{ .string = "3.11.7" }, &.{})).int);
    try testing.expectEqual(@as(i64, 0), (try string.patch(mkCtx("/tmp"), .{ .string = "25.4" }, &.{})).int);
}

test "string.to_i parses the leading integer and stops at non-digits" {
    // Ruby-style: `"42abc".to_i == 42`, `"no_digits".to_i == 0`.
    try testing.expectEqual(@as(i64, 42), (try string.toI(mkCtx("/tmp"), .{ .string = "42" }, &.{})).int);
    try testing.expectEqual(@as(i64, 42), (try string.toI(mkCtx("/tmp"), .{ .string = "42abc" }, &.{})).int);
    try testing.expectEqual(@as(i64, 0), (try string.toI(mkCtx("/tmp"), .{ .string = "abc" }, &.{})).int);
    try testing.expectEqual(@as(i64, -5), (try string.toI(mkCtx("/tmp"), .{ .string = "-5" }, &.{})).int);
}

test "string.major routes through receiver_builtins dispatch" {
    // Regression: the interpreter looks up `.major` in receiver_builtins;
    // if this wiring ever drifts, `OS.kernel_version.major` silently
    // degrades back to unknown_method. Pin both the key and the function.
    const dispatch = @import("malt").dsl.builtins.receiver_builtins;
    try testing.expect(dispatch.get("major") != null);
    try testing.expect(dispatch.get("minor") != null);
    try testing.expect(dispatch.get("patch") != null);
    try testing.expect(dispatch.get("to_i") != null);
}
