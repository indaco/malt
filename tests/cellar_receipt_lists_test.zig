//! malt — relocation driven by a bottle's receipt lists.
//!
//! A bottle built by recent brew records which files carry the build prefix.
//! These tests drive such a receipt through the public materialize entry
//! point and pin that only the listed files are rewritten, that the receipt
//! is read before malt's own replaces it, and that the store → Cellar clone
//! keeps the lists in reach.

const std = @import("std");
const test_io = @import("test_io");
const testing = std.testing;
const cellar_mod = @import("malt").cellar;

const c = test_io.c;

const sha_receipt_lists = "a1" ** 32;

fn setMaltPrefix(prefix: [:0]const u8) [:0]const u8 {
    const old = test_io.getenv("MALT_PREFIX") orelse "";
    _ = c.setenv("MALT_PREFIX", prefix.ptr, 1);
    return old;
}

fn restoreMaltPrefix(old: [:0]const u8) void {
    if (old.len == 0) {
        _ = c.unsetenv("MALT_PREFIX");
    } else {
        _ = c.setenv("MALT_PREFIX", old.ptr, 1);
    }
}

fn createTestDir(allocator: std.mem.Allocator) ![:0]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/malt_cellar_receipt_test_{x}", .{test_io.randomInt(std.Options.debug_io, u64)});
    defer allocator.free(path);
    const z = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(z, path);
    try test_io.makeDirAbsolute(std.Options.debug_io, z);
    return z;
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{});
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, contents);
}

/// Store entry with two placeholdered text files and the given receipt.
fn createListedBottleFixture(allocator: std.mem.Allocator, prefix: []const u8, receipt_json: []const u8) !void {
    const keg = try std.fmt.allocPrint(allocator, "{s}/store/{s}/listed/1.0", .{ prefix, sha_receipt_lists });
    defer allocator.free(keg);
    for ([_][]const u8{ "bin", "lib" }) |sub| {
        const d = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ keg, sub });
        defer allocator.free(d);
        try test_io.cwd().createDirPath(std.Options.debug_io, d);
    }
    const hello = try std.fmt.allocPrint(allocator, "{s}/bin/hello", .{keg});
    defer allocator.free(hello);
    try writeFile(hello, "#!/bin/sh\nprefix=@@HOMEBREW_PREFIX@@\necho $prefix\n");
    const pc = try std.fmt.allocPrint(allocator, "{s}/lib/test.pc", .{keg});
    defer allocator.free(pc);
    try writeFile(pc, "prefix=@@HOMEBREW_PREFIX@@\nlibdir=${prefix}/lib\n");
    const receipt = try std.fmt.allocPrint(allocator, "{s}/INSTALL_RECEIPT.json", .{keg});
    defer allocator.free(receipt);
    try writeFile(receipt, receipt_json);
    for ([_][]const u8{ "Cellar", "opt", "bin", "lib" }) |sub| {
        const d = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sub });
        defer allocator.free(d);
        test_io.cwd().createDirPath(std.Options.debug_io, d) catch {};
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return test_io.cwd().readFileAlloc(std.Options.debug_io, path, allocator, .limited(1 << 20));
}

fn materialize(allocator: std.mem.Allocator, prefix: []const u8) !cellar_mod.Keg {
    return cellar_mod.materializeWithCellar(
        std.Options.debug_io,
        allocator,
        prefix,
        sha_receipt_lists,
        "listed",
        "1.0",
        ":any",
        null,
        true,
    );
}

fn carriesPlaceholder(allocator: std.mem.Allocator, keg_path: []const u8, rel: []const u8) !bool {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ keg_path, rel });
    defer allocator.free(path);
    const text = try readFile(allocator, path);
    defer allocator.free(text);
    return std.mem.indexOf(u8, text, "@@HOMEBREW_PREFIX@@") != null;
}

test "materializeWithCellar relocates only the files the bottle receipt lists" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    try createListedBottleFixture(testing.allocator, prefix,
        \\{"changed_files": ["bin/hello"], "linkage_files": [], "binary_relocation_files": []}
    );

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try materialize(testing.allocator, prefix);
    defer testing.allocator.free(keg.path);

    try testing.expect(!try carriesPlaceholder(testing.allocator, keg.path, "bin/hello"));
    try testing.expect(try carriesPlaceholder(testing.allocator, keg.path, "lib/test.pc"));

    // malt's own receipt replaces the bottle's once relocation is done.
    const receipt_path = try std.fmt.allocPrint(testing.allocator, "{s}/INSTALL_RECEIPT.json", .{keg.path});
    defer testing.allocator.free(receipt_path);
    const receipt = try readFile(testing.allocator, receipt_path);
    defer testing.allocator.free(receipt);
    try testing.expect(std.mem.indexOf(u8, receipt, "bin/hello") == null);
    try testing.expect(std.mem.indexOf(u8, receipt, sha_receipt_lists) != null);
}

test "materializeWithCellar walks the keg when the bottle receipt carries no lists" {
    const prefix = try createTestDir(testing.allocator);
    defer {
        test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
        testing.allocator.free(prefix);
    }
    // An older bottle: every placeholder must still be substituted.
    try createListedBottleFixture(testing.allocator, prefix,
        \\{"source": {"tap": "homebrew/core"}}
    );

    const old_env = setMaltPrefix(prefix);
    defer restoreMaltPrefix(old_env);

    const keg = try materialize(testing.allocator, prefix);
    defer testing.allocator.free(keg.path);

    try testing.expect(!try carriesPlaceholder(testing.allocator, keg.path, "bin/hello"));
    try testing.expect(!try carriesPlaceholder(testing.allocator, keg.path, "lib/test.pc"));
}
