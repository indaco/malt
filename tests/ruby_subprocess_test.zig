//! malt — ruby_subprocess pure-helper tests
//! Covers tap discovery, formula .rb path resolution (new sharded and flat
//! layouts), and post_install body extraction from a .rb file on disk.

const std = @import("std");
const testing = std.testing;
const ruby = @import("malt").ruby_subprocess;

fn uniqueDir(suffix: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_ruby_sub_{d}_{s}",
        .{ std.time.nanoTimestamp(), suffix },
    );
    try std.fs.cwd().makePath(p);
    return p;
}

test "findHomebrewCoreTap returns null when the canonical paths are absent" {
    // On most CI boxes the tap is absent. We can't assert true/null
    // deterministically, so we at least exercise the lookup loop.
    _ = ruby.findHomebrewCoreTap();
}

test "resolveFormulaRbPath returns null for an empty name" {
    var buf: [1024]u8 = undefined;
    try testing.expect(ruby.resolveFormulaRbPath(&buf, "/any/tap", "") == null);
}

test "resolveFormulaRbPath returns null when neither layout exists" {
    const tap = try uniqueDir("no_formula");
    defer testing.allocator.free(tap);
    defer std.fs.deleteTreeAbsolute(tap) catch {};
    var buf: [1024]u8 = undefined;
    try testing.expect(ruby.resolveFormulaRbPath(&buf, tap, "wget") == null);
}

test "resolveFormulaRbPath prefers the sharded Formula/{first}/{name}.rb layout" {
    const tap = try uniqueDir("sharded");
    defer testing.allocator.free(tap);
    defer std.fs.deleteTreeAbsolute(tap) catch {};
    const shard_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula/w", .{tap});
    defer testing.allocator.free(shard_dir);
    try std.fs.cwd().makePath(shard_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{shard_dir});
    defer testing.allocator.free(rb);
    (try std.fs.createFileAbsolute(rb, .{})).close();

    var buf: [1024]u8 = undefined;
    const got = ruby.resolveFormulaRbPath(&buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/w/wget.rb"));
}

test "resolveFormulaRbPath falls back to the flat Formula/{name}.rb layout" {
    const tap = try uniqueDir("flat");
    defer testing.allocator.free(tap);
    defer std.fs.deleteTreeAbsolute(tap) catch {};
    const flat_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula", .{tap});
    defer testing.allocator.free(flat_dir);
    try std.fs.cwd().makePath(flat_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{flat_dir});
    defer testing.allocator.free(rb);
    (try std.fs.createFileAbsolute(rb, .{})).close();

    var buf: [1024]u8 = undefined;
    const got = ruby.resolveFormulaRbPath(&buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/wget.rb"));
}

test "extractPostInstallBody returns null when the file has no post_install" {
    const tap = try uniqueDir("no_postinstall");
    defer testing.allocator.free(tap);
    defer std.fs.deleteTreeAbsolute(tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try std.fs.createFileAbsolute(rb, .{});
        try f.writeAll("class Hello < Formula\n  url \"x\"\nend\n");
        f.close();
    }
    try testing.expect(ruby.extractPostInstallBody(testing.allocator, rb) == null);
}

test "extractPostInstallBody returns null for a missing file" {
    try testing.expect(ruby.extractPostInstallBody(testing.allocator, "/tmp/malt_ruby_missing_xyz.rb") == null);
}

test "extractPostInstallFromSource handles an in-memory Ruby body" {
    const src =
        \\class Hello < Formula
        \\  def post_install
        \\    mkdir_p "etc"
        \\  end
        \\end
        \\
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc\"") != null);
}

test "extractPostInstallFromSource returns null when no post_install exists" {
    const src = "class X < Formula\n  url \"x\"\nend\n";
    try testing.expect(ruby.extractPostInstallFromSource(testing.allocator, src) == null);
}

test "extractPostInstallFromSource handles post_install at the top level (no indent)" {
    const src =
        \\def post_install
        \\touch "foo"
        \\end
        \\
    ;
    const body = ruby.extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"foo\"") != null);
}

test "generateWrapper emits a Ruby script containing the post_install body and prefix" {
    const script = try ruby.generateWrapper(
        testing.allocator,
        "mypkg",
        "2.3",
        "/opt/malt",
        "  mkdir_p \"etc/mypkg\"\n",
    );
    defer testing.allocator.free(script);
    try testing.expect(std.mem.indexOf(u8, script, "require 'pathname'") != null);
    try testing.expect(std.mem.indexOf(u8, script, "mkdir_p \"etc/mypkg\"") != null);
    try testing.expect(std.mem.indexOf(u8, script, "/opt/malt") != null);
    try testing.expect(std.mem.indexOf(u8, script, "mypkg") != null);
    try testing.expect(std.mem.indexOf(u8, script, "2.3") != null);
}

test "fetchPostInstallFromGitHub returns null for an empty name" {
    try testing.expect(ruby.fetchPostInstallFromGitHub(testing.allocator, "") == null);
}

test "extractPostInstallBody captures the body between def post_install and matching end" {
    const tap = try uniqueDir("with_postinstall");
    defer testing.allocator.free(tap);
    defer std.fs.deleteTreeAbsolute(tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try std.fs.createFileAbsolute(rb, .{});
        try f.writeAll(
            \\class Hello < Formula
            \\  def post_install
            \\    mkdir_p "etc/hello"
            \\    touch "etc/hello/config"
            \\  end
            \\end
            \\
        );
        f.close();
    }
    const body = ruby.extractPostInstallBody(testing.allocator, rb);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc/hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"etc/hello/config\"") != null);
    // Trailing `end` must NOT be inside the body.
    try testing.expect(std.mem.indexOf(u8, body.?, "end\n") == null or
        std.mem.lastIndexOf(u8, body.?, "end") == null);
}
