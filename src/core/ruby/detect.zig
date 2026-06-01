//! malt — Ruby interpreter + homebrew-core tap discovery.
//!
//! Pure path probing: no DSL parser, no HTTP client. Splitting this off
//! the subprocess driver is what stops DSL-only and net-only tests from
//! cross-linking through `ruby_subprocess.zig`.

const std = @import("std");

/// Detect a usable Ruby interpreter. Returns a caller-owned absolute path
/// or null. Caller must free the returned slice with `allocator.free`.
///
/// Previously this function returned static slices for the hardcoded
/// candidates and `allocator.dupe`d slices for the rbenv/asdf/PATH
/// branches — the only call site never freed, so the heap branches
/// leaked. Unifying the contract on "always heap-owned" lets the caller
/// pair every successful return with one `defer allocator.free(...)`.
///
/// Public for testability; not part of the stable surface.
pub fn detectRuby(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/ruby/bin/ruby",
        "/usr/local/opt/ruby/bin/ruby",
        "/usr/bin/ruby",
    };
    for (candidates) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return allocator.dupe(u8, path) catch return null;
    }

    // Reusable scratch for path joining — avoids per-iteration heap churn.
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // User-local version managers: rbenv, asdf
    if (std.process.Environ.getPosix(environ, "HOME")) |home| {
        const shim_suffixes = [_][]const u8{ "/.rbenv/shims/ruby", "/.asdf/shims/ruby" };
        for (shim_suffixes) |suffix| {
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ home, suffix }) catch continue;
            std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
            return allocator.dupe(u8, path) catch return null;
        }
    }

    // PATH search
    if (std.process.Environ.getPosix(environ, "PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fmt.bufPrint(&buf, "{s}/ruby", .{dir}) catch continue;
            std.Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
            return allocator.dupe(u8, candidate) catch return null;
        }
    }

    return null;
}

/// Locate the homebrew-core tap clone on disk. Returns the tap path or null.
pub fn findHomebrewCoreTap(io: std.Io) ?[]const u8 {
    const tap_paths = [_][]const u8{
        "/opt/homebrew/Library/Taps/homebrew/homebrew-core",
        "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core",
    };
    for (tap_paths) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Resolve the .rb source file path for a formula within the tap.
/// Tries new sharded layout first (Formula/f/foo.rb), falls back to flat
/// (Formula/foo.rb).
pub fn resolveFormulaRbPath(io: std.Io, buf: *[1024]u8, tap_path: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    // New layout: Formula/FIRST_LETTER/NAME.rb
    const new_path = std.fmt.bufPrint(buf, "{s}/Formula/{c}/{s}.rb", .{
        tap_path, name[0], name,
    }) catch return null;
    std.Io.Dir.accessAbsolute(io, new_path, .{}) catch {
        // Fall through to old layout
        const old_path = std.fmt.bufPrint(buf, "{s}/Formula/{s}.rb", .{
            tap_path, name,
        }) catch return null;
        std.Io.Dir.accessAbsolute(io, old_path, .{}) catch return null;
        return old_path;
    };
    return new_path;
}

// --- tests ---------------------------------------------------------------
// Inline because these are unit tests for pure detection logic. Filesystem
// fixtures use `std.Io` directly — the lib test root can't reach the
// test-only `test_io` shim.

const testing = std.testing;

fn testIo() std.Io {
    return std.Options.debug_io;
}

/// Random-suffixed scratch dir under /tmp so concurrent test runs can't
/// collide. Caller frees the path and removes the tree.
fn uniqueDir(io: std.Io, suffix: []const u8) ![]u8 {
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const p = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_ruby_detect_{s}_{s}",
        .{ hex[0..], suffix },
    );
    try std.Io.Dir.cwd().createDirPath(io, p);
    return p;
}

test "findHomebrewCoreTap returns null when the canonical paths are absent" {
    // On most CI boxes the tap is absent. We can't assert true/null
    // deterministically, so we at least exercise the lookup loop.
    _ = findHomebrewCoreTap(testIo());
}

test "resolveFormulaRbPath returns null for an empty name" {
    var buf: [1024]u8 = undefined;
    try testing.expect(resolveFormulaRbPath(testIo(), &buf, "/any/tap", "") == null);
}

test "resolveFormulaRbPath returns null when neither layout exists" {
    const io = testIo();
    const tap = try uniqueDir(io, "no_formula");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    var buf: [1024]u8 = undefined;
    try testing.expect(resolveFormulaRbPath(io, &buf, tap, "wget") == null);
}

test "resolveFormulaRbPath prefers the sharded Formula/{first}/{name}.rb layout" {
    const io = testIo();
    const tap = try uniqueDir(io, "sharded");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    const shard_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula/w", .{tap});
    defer testing.allocator.free(shard_dir);
    try std.Io.Dir.cwd().createDirPath(io, shard_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{shard_dir});
    defer testing.allocator.free(rb);
    (try std.Io.Dir.createFileAbsolute(io, rb, .{})).close(io);

    var buf: [1024]u8 = undefined;
    const got = resolveFormulaRbPath(io, &buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/w/wget.rb"));
}

test "resolveFormulaRbPath falls back to the flat Formula/{name}.rb layout" {
    const io = testIo();
    const tap = try uniqueDir(io, "flat");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    const flat_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Formula", .{tap});
    defer testing.allocator.free(flat_dir);
    try std.Io.Dir.cwd().createDirPath(io, flat_dir);
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{flat_dir});
    defer testing.allocator.free(rb);
    (try std.Io.Dir.createFileAbsolute(io, rb, .{})).close(io);

    var buf: [1024]u8 = undefined;
    const got = resolveFormulaRbPath(io, &buf, tap, "wget");
    try testing.expect(got != null);
    try testing.expect(std.mem.endsWith(u8, got.?, "/Formula/wget.rb"));
}

test "detectRuby returns a heap-owned slice that the caller can free" {
    // The contract requires the returned slice to be allocator-owned so
    // the call site can pair it with `defer allocator.free`. We can't
    // assert the path itself (machine-dependent), but we *can* verify that
    // freeing the result does not double-free or fault — which only holds
    // if every branch returns heap memory rather than a mix of static and
    // heap slices. An empty environ exercises the hardcoded-candidate
    // branch, which is exactly the one that used to return static slices.
    if (detectRuby(testIo(), .empty, testing.allocator)) |path| {
        defer testing.allocator.free(path);
        try testing.expect(path.len > 0);
        try testing.expect(std.mem.startsWith(u8, path, "/"));
    }
}
