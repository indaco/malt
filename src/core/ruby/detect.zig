//! malt — Ruby interpreter + homebrew-core tap discovery.
//!
//! Pure path probing: no DSL parser, no HTTP client. Splitting this off
//! the subprocess driver is what stops DSL-only and net-only tests from
//! cross-linking through `ruby_subprocess.zig`.

const std = @import("std");
const builtin = @import("builtin");

// Order matters: the package-manager Ruby is preferred, the system one is last.
const candidates = [_][]const u8{
    "/opt/homebrew/opt/ruby/bin/ruby",
    "/usr/local/opt/ruby/bin/ruby",
    "/usr/bin/ruby",
};

/// Detect a Ruby interpreter the sandbox fence can start. Returns a
/// caller-owned absolute path or null. Caller must free the returned slice
/// with `allocator.free`.
///
/// Only package-manager and system Rubies are probed: the fence denies
/// reads under `$HOME` and scrubs `$PATH`, so version-manager shims and
/// arbitrary PATH interpreters cannot run inside it. Keep `candidates` in
/// step with the interpreter prefix the fence re-grants.
///
/// Previously the hardcoded candidates returned static slices while other
/// branches `allocator.dupe`d — the only call site never freed, so the heap
/// branches leaked. Unifying on "always heap-owned" lets the caller pair
/// every successful return with one `defer allocator.free(...)`.
///
/// Public for testability; not part of the stable surface.
pub fn detectRuby(io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
    for (candidates) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return allocator.dupe(u8, path) catch return null;
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

test "detectRuby returns a heap-owned path and always finds one on macOS" {
    // Heap-owned so the call site can pair it with one `defer allocator.free`.
    // /usr/bin/ruby is part of the macOS base system, so null there means the
    // probe itself is broken, not the box.
    const path = detectRuby(testIo(), testing.allocator) orelse {
        try testing.expect(builtin.os.tag != .macos);
        return;
    };
    defer testing.allocator.free(path);
    try testing.expect(std.mem.startsWith(u8, path, "/"));
}

test "detectRuby only offers interpreters the sandbox fence can start" {
    // The fence only re-grants reads for a `/opt/ruby/bin/ruby` prefix and
    // never denies the system tree; any other shape is detected only to die
    // inside the fence. Checked over the whole list, not the runtime pick,
    // so a bad candidate fails on every box.
    for (candidates) |path| {
        try testing.expect(std.mem.endsWith(u8, path, "/opt/ruby/bin/ruby") or
            std.mem.eql(u8, path, "/usr/bin/ruby"));
    }
}
