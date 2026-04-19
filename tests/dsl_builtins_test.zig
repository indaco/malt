//! malt — DSL builtin coverage tests
//! Drives pathname/fileutils/process builtin functions directly against a
//! real temp-directory sandbox to cover the happy paths that the
//! interpreter-level tests don't already touch.

const std = @import("std");
const malt = @import("malt");
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

fn uniqueSandbox(suffix: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_dsl_builtins_{d}_{s}",
        .{ malt.fs_compat.nanoTimestamp(), suffix },
    );
    malt.fs_compat.cwd().makePath(p) catch {};
    return p;
}

fn mkCtx(root: []const u8) ExecCtx {
    return .{
        .allocator = testing.allocator,
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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const nested = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c", .{root});
    defer testing.allocator.free(nested);

    _ = try pathname.mkpath(ctx, Value{ .pathname = nested }, &.{});
    var d = try malt.fs_compat.openDirAbsolute(nested, .{});
    d.close();
}

test "Pathname.exist?, .directory?, .file?, .symlink? classify entries correctly" {
    const root = try uniqueSandbox("classify");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
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

    const f = try malt.fs_compat.createFileAbsolute(file_path, .{});
    f.close();
    try malt.fs_compat.makeDirAbsolute(dir_path);
    try malt.fs_compat.symLinkAbsolute(file_path, link_path, .{});

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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const out = try pathname.read(ctx, Value{ .pathname = "/tmp/malt_dsl_read_missing_xyz" }, &.{});
    try testing.expectEqualStrings("", out.string);
}

test "Pathname.children returns array of children; empty for missing dir" {
    const root = try uniqueSandbox("children");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const a = try std.fmt.allocPrint(testing.allocator, "{s}/a", .{root});
    defer testing.allocator.free(a);
    const b = try std.fmt.allocPrint(testing.allocator, "{s}/b", .{root});
    defer testing.allocator.free(b);
    (try malt.fs_compat.createFileAbsolute(a, .{})).close();
    (try malt.fs_compat.createFileAbsolute(b, .{})).close();

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

test "Pathname.opt_bin/.opt_lib/.opt_include/.pkgetc append the right subdir" {
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

    const etc = try pathname.pkgetc(ctx, v, &.{});
    defer testing.allocator.free(etc.pathname);
    try testing.expectEqualStrings("/opt/malt/opt/foo/etc", etc.pathname);
}

test "Pathname.unlink deletes a file in the sandbox" {
    const root = try uniqueSandbox("unlink");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const path = try std.fmt.allocPrint(testing.allocator, "{s}/goodbye.txt", .{root});
    defer testing.allocator.free(path);
    (try malt.fs_compat.createFileAbsolute(path, .{})).close();

    _ = try pathname.unlink(ctx, Value{ .pathname = path }, &.{});
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(path, .{}));
}

test "Pathname.install_symlink creates and replaces a symlink in the sandbox" {
    const root = try uniqueSandbox("install_symlink");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/source.txt", .{root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/sub/link", .{root});
    defer testing.allocator.free(dst);
    (try malt.fs_compat.createFileAbsolute(src, .{})).close();

    const args = [_]Value{.{ .string = dst }};
    _ = try pathname.installSymlink(ctx, Value{ .pathname = src }, &args);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try malt.fs_compat.readLinkAbsolute(dst, &buf);
    try testing.expectEqualStrings(src, target);
}

test "Pathname.glob with receiver returns matching entries" {
    const root = try uniqueSandbox("glob");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const lib_dir = try std.fmt.allocPrint(testing.allocator, "{s}/lib", .{root});
    defer testing.allocator.free(lib_dir);
    try malt.fs_compat.makeDirAbsolute(lib_dir);
    for ([_][]const u8{ "libfoo.dylib", "libbar.dylib", "readme.txt" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ lib_dir, name });
        defer testing.allocator.free(p);
        (try malt.fs_compat.createFileAbsolute(p, .{})).close();
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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const a_path = try std.fmt.allocPrint(testing.allocator, "{s}/a.zig", .{root});
    defer testing.allocator.free(a_path);
    (try malt.fs_compat.createFileAbsolute(a_path, .{})).close();

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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    for ([_][]const u8{ "a.c", "a.h", "a.o" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ root, name });
        defer testing.allocator.free(p);
        (try malt.fs_compat.createFileAbsolute(p, .{})).close();
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
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const nested = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c", .{root});
    defer testing.allocator.free(nested);
    _ = try fileutils.mkdirP(ctx, null, &.{.{ .string = nested }});
    var d = try malt.fs_compat.openDirAbsolute(nested, .{});
    d.close();

    const file = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/c/hello", .{root});
    defer testing.allocator.free(file);
    _ = try fileutils.touch(ctx, null, &.{.{ .string = file }});
    (try malt.fs_compat.openFileAbsolute(file, .{})).close();

    _ = try fileutils.rm(ctx, null, &.{.{ .string = file }});
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(file, .{}));
}

test "FileUtils.cp copies a single file into the sandbox" {
    const root = try uniqueSandbox("fileutils_cp");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src.txt", .{root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/dst.txt", .{root});
    defer testing.allocator.free(dst);
    {
        const f = try malt.fs_compat.createFileAbsolute(src, .{});
        try f.writeAll("payload");
        f.close();
    }
    _ = try fileutils.cp(ctx, null, &.{
        .{ .string = src },
        .{ .string = dst },
    });

    const f = try malt.fs_compat.openFileAbsolute(dst, .{});
    defer f.close();
    var buf: [32]u8 = undefined;
    const n = try f.readAll(&buf);
    try testing.expectEqualStrings("payload", buf[0..n]);
}

test "FileUtils.cp with an array copies each file into the destination directory" {
    const root = try uniqueSandbox("fileutils_cp_array");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = ExecCtx{ .allocator = arena.allocator(), .cellar_path = root, .malt_prefix = root };

    const dst_dir = try std.fmt.allocPrint(testing.allocator, "{s}/dst", .{root});
    defer testing.allocator.free(dst_dir);

    const src_a = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{root});
    defer testing.allocator.free(src_a);
    const src_b = try std.fmt.allocPrint(testing.allocator, "{s}/b.txt", .{root});
    defer testing.allocator.free(src_b);
    for ([_][]const u8{ src_a, src_b }) |p| {
        const f = try malt.fs_compat.createFileAbsolute(p, .{});
        try f.writeAll("x");
        f.close();
    }

    const items = [_]Value{ .{ .string = src_a }, .{ .string = src_b } };
    _ = try fileutils.cp(ctx, null, &.{ .{ .array = &items }, .{ .string = dst_dir } });

    for ([_][]const u8{ "a.txt", "b.txt" }) |name| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dst_dir, name });
        defer testing.allocator.free(p);
        (try malt.fs_compat.openFileAbsolute(p, .{})).close();
    }
}

test "FileUtils.rm_r (and rm_rf alias) delete a directory tree" {
    const root = try uniqueSandbox("fileutils_rmr");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);

    const tree = try std.fmt.allocPrint(testing.allocator, "{s}/tree/a/b", .{root});
    defer testing.allocator.free(tree);
    try malt.fs_compat.cwd().makePath(tree);

    const root_tree = try std.fmt.allocPrint(testing.allocator, "{s}/tree", .{root});
    defer testing.allocator.free(root_tree);
    _ = try fileutils.rmR(ctx, null, &.{.{ .string = root_tree }});
    try testing.expectError(error.FileNotFound, malt.fs_compat.openDirAbsolute(root_tree, .{}));

    try malt.fs_compat.cwd().makePath(tree);
    _ = try fileutils.rmRf(ctx, null, &.{.{ .string = root_tree }});
    try testing.expectError(error.FileNotFound, malt.fs_compat.openDirAbsolute(root_tree, .{}));
}

test "FileUtils.rm with an array silently skips out-of-sandbox paths but removes the others" {
    const root = try uniqueSandbox("fileutils_rm_array");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const good = try std.fmt.allocPrint(testing.allocator, "{s}/good.txt", .{root});
    defer testing.allocator.free(good);
    (try malt.fs_compat.createFileAbsolute(good, .{})).close();

    const items = [_]Value{ .{ .string = "/etc/passwd" }, .{ .string = good } };
    _ = try fileutils.rm(ctx, null, &.{.{ .array = &items }});
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(good, .{}));
}

test "FileUtils.chmod with an array of paths chmods each one" {
    const root = try uniqueSandbox("fileutils_chmod_array");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const a = try std.fmt.allocPrint(testing.allocator, "{s}/a", .{root});
    defer testing.allocator.free(a);
    const b = try std.fmt.allocPrint(testing.allocator, "{s}/b", .{root});
    defer testing.allocator.free(b);
    for ([_][]const u8{ a, b }) |p| (try malt.fs_compat.createFileAbsolute(p, .{})).close();

    const items = [_]Value{ .{ .string = a }, .{ .string = b } };
    _ = try fileutils.chmod(ctx, null, &.{ .{ .int = 0o644 }, .{ .array = &items } });
}

test "FileUtils.ln_sf with an array symlinks each target into the dest dir" {
    const root = try uniqueSandbox("fileutils_lnsf_array");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = ExecCtx{ .allocator = arena.allocator(), .cellar_path = root, .malt_prefix = root };
    const t1 = try std.fmt.allocPrint(testing.allocator, "{s}/t1", .{root});
    defer testing.allocator.free(t1);
    const t2 = try std.fmt.allocPrint(testing.allocator, "{s}/t2", .{root});
    defer testing.allocator.free(t2);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/links", .{root});
    defer testing.allocator.free(dst);
    for ([_][]const u8{ t1, t2 }) |p| (try malt.fs_compat.createFileAbsolute(p, .{})).close();

    const items = [_]Value{ .{ .string = t1 }, .{ .string = t2 } };
    _ = try fileutils.lnSf(ctx, null, &.{ .{ .array = &items }, .{ .string = dst } });

    for ([_][]const u8{ "t1", "t2" }) |name| {
        const link = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dst, name });
        defer testing.allocator.free(link);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try malt.fs_compat.readLinkAbsolute(link, &buf);
    }
}

test "FileUtils.mv renames within the sandbox" {
    const root = try uniqueSandbox("fileutils_mv");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/x.txt", .{root});
    defer testing.allocator.free(src);
    const dst = try std.fmt.allocPrint(testing.allocator, "{s}/y.txt", .{root});
    defer testing.allocator.free(dst);
    (try malt.fs_compat.createFileAbsolute(src, .{})).close();
    _ = try fileutils.mv(ctx, null, &.{ .{ .string = src }, .{ .string = dst } });
    try testing.expectError(error.FileNotFound, malt.fs_compat.openFileAbsolute(src, .{}));
    (try malt.fs_compat.openFileAbsolute(dst, .{})).close();
}

test "FileUtils.ln_s/ln_sf create (and force-replace) symlinks" {
    const root = try uniqueSandbox("fileutils_ln");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/target", .{root});
    defer testing.allocator.free(target);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/sub/link", .{root});
    defer testing.allocator.free(link);
    (try malt.fs_compat.createFileAbsolute(target, .{})).close();

    _ = try fileutils.lnS(ctx, null, &.{ .{ .string = target }, .{ .string = link } });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(target, try malt.fs_compat.readLinkAbsolute(link, &buf));

    // ln_sf should overwrite the existing symlink silently.
    _ = try fileutils.lnSf(ctx, null, &.{ .{ .string = target }, .{ .string = link } });
    try testing.expectEqualStrings(target, try malt.fs_compat.readLinkAbsolute(link, &buf));
}

test "FileUtils.rm rejects paths outside the sandbox" {
    const root = try uniqueSandbox("fileutils_violate");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    try testing.expectError(
        error.PathSandboxViolation,
        fileutils.rm(ctx, null, &.{.{ .string = "/etc/passwd" }}),
    );
}

test "FileUtils.chmod returns nil for a non-int mode and is a no-op" {
    const root = try uniqueSandbox("fileutils_chmod_nil");
    defer testing.allocator.free(root);
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    const ctx = mkCtx(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/f", .{root});
    defer testing.allocator.free(path);
    (try malt.fs_compat.createFileAbsolute(path, .{})).close();
    const v = try fileutils.chmod(ctx, null, &.{ .{ .string = "0755" }, .{ .string = path } });
    try testing.expect(v == .nil);
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
        .cellar_path = root,
        .malt_prefix = root,
    };
}

test "system runs /bin/true and returns true" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.system(arenaCtx(&arena, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/true" }});
    try testing.expect(v.bool);
}

test "system runs /bin/false and returns false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.system(arenaCtx(&arena, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/false" }});
    try testing.expect(!v.bool);
}

test "system with no args returns nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.system(arenaCtx(&arena, "/tmp/malt"), null, &.{});
    try testing.expect(v == .nil);
}

test "quietSystem always returns nil regardless of exit code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.quietSystem(arenaCtx(&arena, "/tmp/malt"), null, &.{.{ .string = "/usr/bin/false" }});
    try testing.expect(v == .nil);
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.macosVersion(arenaCtx(&arena, "/tmp/malt"), null, &.{});
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
    const ctx = arenaCtx(&arena, "/tmp/malt");
    _ = c.setenv("MALT_DSL_ENV_TEST", "yes", 1);
    defer _ = c.unsetenv("MALT_DSL_ENV_TEST");
    const got = try process.envGet(ctx, null, &.{.{ .string = "MALT_DSL_ENV_TEST" }});
    try testing.expectEqualStrings("yes", got.string);

    const missing = try process.envGet(ctx, null, &.{.{ .string = "MALT_DSL_DOES_NOT_EXIST_XYZ" }});
    try testing.expect(missing == .nil);

    const noargs = try process.envGet(ctx, null, &.{});
    try testing.expect(noargs == .nil);
}

test "envSet does not touch the real environment but returns the written value" {
    const ctx = mkCtx("/tmp/malt");
    const v = try process.envSet(ctx, null, &.{ .{ .string = "MALT_DSL_UNSET_KEY" }, .{ .string = "val" } });
    try testing.expectEqualStrings("val", v.string);
    try testing.expect(malt.fs_compat.getenv("MALT_DSL_UNSET_KEY") == null);
}

test "formulaLookup returns MALT_PREFIX/opt/<name>" {
    const ctx = ExecCtx{
        .allocator = testing.allocator,
        .cellar_path = "/tmp/malt",
        .malt_prefix = "/tmp/malt",
    };
    const v = try process.formulaLookup(ctx, null, &.{.{ .string = "wget" }});
    defer testing.allocator.free(v.pathname);
    try testing.expectEqualStrings("/tmp/malt/opt/wget", v.pathname);
}

test "safePopenRead captures stdout and chomps trailing newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try process.safePopenRead(arenaCtx(&arena, "/tmp/malt"), null, &.{ .{ .string = "/bin/echo" }, .{ .string = "hello" } });
    try testing.expectEqualStrings("hello", v.string);
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
