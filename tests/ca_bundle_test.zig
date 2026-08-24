//! Integration cover for the native CA bundle builder: the real macOS
//! keychains, real `security` children. The inline tests next to the builder
//! drive classification with fixed fixtures; these check it against the
//! machine it will actually run on.

const std = @import("std");
const malt = @import("malt");

const ca_bundle = malt.ca_bundle;
const testing = std.testing;

/// Seconds since the epoch, from the injected clock rather than a constant so
/// the expiry filter is exercised against today.
fn nowSec(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

fn countBlocks(pem: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, pem, i, "-----BEGIN CERTIFICATE-----")) |at| {
        n += 1;
        i = at + 1;
    }
    return n;
}

test "building against the live keychains yields a well-formed bundle" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const bundle = ca_bundle.build(io, testing.allocator, "", nowSec(io), null) catch |e| switch (e) {
        // A sandboxed runner with no readable keychain has nothing to check.
        error.KeychainUnreadable => return error.SkipZigTest,
        else => return e,
    };
    defer testing.allocator.free(bundle);

    // A macOS system trust store is never nearly empty; a handful of
    // certificates would mean the filters became far too strict.
    try testing.expect(countBlocks(bundle) > 100);
    // Every emitted block is closed and separated, so the file parses.
    try testing.expectEqual(countBlocks(bundle), std.mem.count(u8, bundle, "-----END CERTIFICATE-----"));
    try testing.expect(std.mem.endsWith(u8, bundle, "-----END CERTIFICATE-----\n\n"));
}

test "the shipped Mozilla source is merged on top of the keychains" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const keychains_only = ca_bundle.build(io, testing.allocator, "", nowSec(io), null) catch |e| switch (e) {
        error.KeychainUnreadable => return error.SkipZigTest,
        else => return e,
    };
    defer testing.allocator.free(keychains_only);

    // Feed one certificate the keychains cannot already hold.
    const extra = @embedFile("fixtures/ca_bundle_extra.pem");
    const merged = try ca_bundle.build(io, testing.allocator, extra, nowSec(io), null);
    defer testing.allocator.free(merged);

    try testing.expectEqual(countBlocks(keychains_only) + 1, countBlocks(merged));
    try testing.expect(std.mem.indexOf(u8, merged, std.mem.trimEnd(u8, extra, "\n")) != null);
}

test "a file that is not the known script is never substituted for" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try std.Io.Dir.realPath(tmp.dir, io, &buf)];

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/decoy", .{dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "#!/bin/sh\nexit 0\n" });

    try testing.expect(!ca_bundle.isKnownScript(io, path));
    // A missing file is not the known script either, and must not error.
    try testing.expect(!ca_bundle.isKnownScript(io, "/nonexistent/post-install"));
}

test "the recognition digest is a full lowercase sha256" {
    try testing.expectEqual(@as(usize, 64), ca_bundle.known_script_sha256.len);
    for (ca_bundle.known_script_sha256) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

/// openssl's own verdict for one certificate, via the LibreSSL that upstream's
/// script calls. Null when openssl could not read it at all.
fn opensslSaysCa(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    pem: []const u8,
    n: usize,
) !?bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{d}.pem", .{ dir, n });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = pem });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var report = try malt.child.run(io, gpa, &.{
        "/usr/bin/openssl", "x509", "-in", path, "-purpose", "-noout",
    });
    defer report.deinit(gpa);
    if (report.code != 0) return null;
    return std.mem.indexOf(u8, report.stdout, "SSL server CA : Yes") != null;
}

// The builder's CA test is a hand-written DER walk standing in for openssl's
// `check_ca`. Every certificate it misjudges is a root wrongly added to or
// missing from a trust store, so hold the two against the whole machine.
// Needs no network: the keychains and /usr/bin/openssl are always present.
test "the CA classifier agrees with openssl on every certificate on this machine" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &dir_buf)];

    var checked: usize = 0;
    var disagreements: usize = 0;
    for ([_][]const u8{ ca_bundle.system_keychain, ca_bundle.root_keychain }) |keychain| {
        const pem = ca_bundle.dumpKeychain(io, testing.allocator, keychain) catch |e| switch (e) {
            error.KeychainUnreadable => return error.SkipZigTest,
            else => return e,
        };
        defer testing.allocator.free(pem);

        var it = ca_bundle.eachCertificate(pem);
        while (it.next()) |block| {
            checked += 1;
            const theirs = (try opensslSaysCa(io, testing.allocator, dir, block, checked)) orelse continue;
            const ours = try ca_bundle.wouldTrustAsCa(block);
            if (ours != theirs) {
                disagreements += 1;
                std.debug.print(
                    "certificate {d} in {s}: malt says ca={}, openssl says ca={}\n",
                    .{ checked, keychain, ours, theirs },
                );
            }
        }
    }
    try testing.expect(checked > 100);
    try testing.expectEqual(@as(usize, 0), disagreements);
}

// Hand-built certificates covering the extension shapes a real keychain may
// not happen to contain: extendedKeyUsage that names no server usage, the
// Netscape type bits, non-critical basicConstraints, a keyUsage without
// keyCertSign. openssl stays the oracle - the expected value is never
// hardcoded, so this cannot drift into asserting malt's own opinion.
test "the CA classifier agrees with openssl on adversarial extension shapes" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try std.Io.Dir.realPath(tmp.dir, io, &dir_buf)];

    var fixtures = try std.Io.Dir.cwd().openDir(io, "tests/fixtures/ca_classify", .{ .iterate = true });
    defer fixtures.close(io);

    var checked: usize = 0;
    var disagreements: usize = 0;
    var it = fixtures.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pem")) continue;
        const pem = try readWholeFile(io, a, fixtures, entry.name);

        checked += 1;
        const theirs = (try opensslSaysCa(io, testing.allocator, dir, pem, checked)) orelse continue;
        const ours = try ca_bundle.wouldTrustAsCa(pem);
        if (ours != theirs) {
            disagreements += 1;
            std.debug.print("{s}: malt says ca={}, openssl says ca={}\n", .{ entry.name, ours, theirs });
        }
    }
    // A silently empty fixture directory would make this pass for free.
    try testing.expect(checked >= 10);
    try testing.expectEqual(@as(usize, 0), disagreements);
}

fn readWholeFile(io: std.Io, a: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    const f = try dir.openFile(io, name, .{});
    defer f.close(io);
    var list: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    var r = f.reader(io, &.{});
    while (true) {
        const n = try r.interface.readSliceShort(&buf);
        if (n == 0) break;
        try list.appendSlice(a, buf[0..n]);
    }
    return list.items;
}
