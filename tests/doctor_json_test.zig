//! malt — `mt doctor --json` structured `checks[]` integration tests.
//!
//! Drives `doctor.collectFindings` with the production check table
//! against a scratch prefix seeded with a known condition, then asserts
//! the captured finding (and its serialized JSON) carries the right
//! `severity` / `fixable` / `fix_class`. The walker prints the same
//! human rows it always did; these tests pin the machine view that the
//! dashboard and `jq`/script consumers read.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const doctor = malt.doctor;
const sqlite = malt.sqlite;
const schema = malt.schema;
const store_mod = malt.store;
const output = malt.output;

const Scratch = struct {
    path: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrint(allocator, "/tmp/malt_doctor_json_{s}_{d}", .{ tag, ts });
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const subs = [_][]const u8{ "store", "Cellar", "Caskroom", "opt", "bin", "lib", "tmp", "cache", "db" };
        for (subs) |sd| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, sd });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }

    fn initSchema(self: *Scratch) !void {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{self.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }
};

fn findById(findings: []const doctor.Finding, id: []const u8) ?doctor.Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.id, id)) return f;
    }
    return null;
}

fn walk(allocator: std.mem.Allocator, prefix: []const u8) doctor.WalkResult {
    // Quiet suppresses the stderr rows; findings are still collected.
    const prior = output.isQuiet();
    output.setQuiet(true);
    defer output.setQuiet(prior);
    return doctor.collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = prefix,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks, true);
}

test "collectFindings captures one finding per row, including a stable always-ok entry" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "ok_entry");
    defer s.deinit(allocator);
    try s.initSchema();

    var result = walk(allocator, s.path);
    defer result.deinit();

    // At least the static rows are present.
    try testing.expect(result.findings().len >= 5);

    // MALT_PREFIX is unconditionally healthy — the anchor for the
    // "ok finding ⇒ none/false" shape every consumer relies on.
    const prefix_finding = findById(result.findings(), "malt_prefix") orelse
        return error.MissingPrefixFinding;
    try testing.expectEqual(doctor.CheckStatus.ok, prefix_finding.severity);
    try testing.expect(!prefix_finding.fixable);
    try testing.expect(prefix_finding.fix_class == null);
    try testing.expect(prefix_finding.detail.len > 0);
}

test "a broken symlink serializes a fixable broken_symlinks finding" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "broken_symlink");
    defer s.deinit(allocator);

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-json", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(
        std.Options.debug_io,
        "/tmp/malt_doctor_json_broken_target_dne",
        link_path,
        .{},
    );

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "broken_symlinks") orelse
        return error.MissingBrokenSymlinkFinding;
    try testing.expectEqual(doctor.CheckStatus.warn_status, f.severity);
    try testing.expect(f.fixable);
    try testing.expectEqual(doctor.FixKind.broken_symlinks, f.fix_class.?);
    try testing.expectEqualStrings("Broken symlinks", f.title);

    // The same finding serializes with fixable:true and its class.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try doctor.writeChecksJson(&aw.writer, result.findings());
    const json = aw.written();
    try testing.expect(std.mem.startsWith(u8, json, "{\"checks\":["));
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"id\":\"broken_symlinks\",\"severity\":\"warn\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"fixable\":true,\"fix_class\":\"broken_symlinks\"",
    ) != null);
}

test "an orphaned store entry serializes a fixable orphaned_store finding" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "orphan_store");
    defer s.deinit(allocator);
    try s.initSchema();

    // A store/<sha> dir whose store_refs refcount has dropped to 0 is a
    // true orphan — the entry `purge --store-orphans` removes.
    const sha = "0000000000000000000000000000000000000000000000000000000000000000";
    const orphan = try std.fmt.allocPrint(allocator, "{s}/store/{s}", .{ s.path, sha });
    defer allocator.free(orphan);
    try test_io.cwd().createDirPath(std.Options.debug_io, orphan);

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var store = store_mod.Store.init(std.Options.debug_io, allocator, &db, s.path);
        try store.incrementRef(sha);
        try store.decrementRef(sha);
    }

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "orphaned_store_entries") orelse
        return error.MissingOrphanFinding;
    try testing.expectEqual(doctor.CheckStatus.warn_status, f.severity);
    try testing.expect(f.fixable);
    try testing.expectEqual(doctor.FixKind.orphaned_store, f.fix_class.?);
}

test "a missing keg serializes a non-fixable err finding (manual class)" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "missing_keg");
    defer s.deinit(allocator);
    try s.initSchema();

    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        var stmt = try db.prepare(
            \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path)
            \\VALUES ('phantom', 'phantom', '9.9', 0, '', '/tmp/malt_doctor_json_phantom_dne');
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "missing_kegs") orelse
        return error.MissingKegFinding;
    try testing.expectEqual(doctor.CheckStatus.err_status, f.severity);
    // Manual-class: --fix never auto-resolves a missing keg.
    try testing.expect(!f.fixable);
    try testing.expect(f.fix_class == null);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try doctor.writeChecksJson(&aw.writer, result.findings());
    try testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "\"id\":\"missing_kegs\",\"severity\":\"err\"",
    ) != null);
}

test "collect=false leaves the sink empty (human path pays nothing)" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "no_collect");
    defer s.deinit(allocator);
    try s.initSchema();

    const prior = output.isQuiet();
    output.setQuiet(true);
    defer output.setQuiet(prior);

    var result = doctor.collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks, false);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.findings().len);
}

test "a lock held by a live PID warns but stays non-fixable" {
    // The same Stale lock row is fixable for a dead PID and not for a
    // live one. A live holder must report warn + fixable:false so a
    // consumer never offers `--fix` against a legitimately held lock.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "live_lock");
    defer s.deinit(allocator);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/db/malt.lock", .{s.path});
    defer allocator.free(lock_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, lock_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        var buf: [16]u8 = undefined;
        // Our own PID is, by definition, alive for the duration of the test.
        const line = try std.fmt.bufPrint(&buf, "{d}\n", .{std.c.getpid()});
        try f.writeStreamingAll(std.Options.debug_io, line);
    }

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "stale_lock") orelse return error.MissingLockFinding;
    try testing.expectEqual(doctor.CheckStatus.warn_status, f.severity);
    try testing.expect(!f.fixable);
    try testing.expect(f.fix_class == null);
}

test "a lock from a dead PID is a fixable stale_lock finding" {
    // The fixable arm of the same row: a holder PID that cannot exist
    // means the lock is abandoned, so --fix can safely remove it.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "dead_lock");
    defer s.deinit(allocator);

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/db/malt.lock", .{s.path});
    defer allocator.free(lock_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, lock_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        // Well above macOS's max PID, so kill(pid, 0) is always ESRCH.
        try f.writeStreamingAll(std.Options.debug_io, "4000000\n");
    }

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "stale_lock") orelse return error.MissingLockFinding;
    try testing.expectEqual(doctor.CheckStatus.warn_status, f.severity);
    try testing.expect(f.fixable);
    try testing.expectEqual(doctor.FixKind.stale_lock, f.fix_class.?);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try doctor.writeChecksJson(&aw.writer, result.findings());
    try testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "\"id\":\"stale_lock\",\"severity\":\"warn\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "\"fixable\":true,\"fix_class\":\"stale_lock\"",
    ) != null);
}

test "every finding keeps the fixable/fix_class invariant" {
    // Cross-cutting contract the dashboard relies on: fixable ⇔ a class
    // is set, and an ok row is never fixable. One walk with a planted
    // fixable warn exercises both arms.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "invariant");
    defer s.deinit(allocator);
    try s.initSchema();

    const link_path = try std.fmt.allocPrint(allocator, "{s}/bin/ghost-inv", .{s.path});
    defer allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, "/tmp/malt_doctor_json_inv_dne", link_path, .{});

    var result = walk(allocator, s.path);
    defer result.deinit();

    var saw_fixable = false;
    for (result.findings()) |f| {
        try testing.expectEqual(f.fix_class != null, f.fixable);
        if (f.severity == .ok) {
            try testing.expect(!f.fixable);
            try testing.expect(f.fix_class == null);
        }
        if (f.fixable) saw_fixable = true;
        try testing.expect(f.id.len > 0);
        try testing.expect(f.title.len > 0);
    }
    // The planted broken symlink guarantees at least one fixable arm ran.
    try testing.expect(saw_fixable);
}

test "the capturing walk renders no rows to stderr (--json stays stdout-only)" {
    // `--json` is a machine-output mode: the JSON document goes to stdout
    // and stderr must stay silent. The capturing walk (collect=true) is the
    // JSON path, so it must record findings without drawing the human rows —
    // here, with quiet OFF, so the only thing keeping stderr clean is the
    // capture gate, not `--quiet`.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "json_quiet_stderr");
    defer s.deinit(allocator);
    try s.initSchema();

    const prior_quiet = output.isQuiet();
    output.setQuiet(false);
    defer output.setQuiet(prior_quiet);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    var result = doctor.collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks, true);
    defer result.deinit();

    // Findings still captured for the JSON document …
    try testing.expect(result.findings().len >= 5);
    // … but not one byte of the human report reached stderr.
    try testing.expectEqualStrings("", stderr_buf.items);
}

test "the human walk still renders rows to stderr (capture gate is JSON-only)" {
    // The fix must not silence the human path: with collect=false and quiet
    // off, the check rows still render — proving the gate keys on capture
    // mode, not a blanket mute.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "human_rows");
    defer s.deinit(allocator);
    try s.initSchema();

    const prior_quiet = output.isQuiet();
    output.setQuiet(false);
    defer output.setQuiet(prior_quiet);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    var result = doctor.collectFindings(allocator, .{
        .allocator = allocator,
        .prefix = s.path,
        .io = std.Options.debug_io,
        .environ = .empty,
    }, &doctor.checks, false);
    defer result.deinit();

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "MALT_PREFIX") != null);
}

// ── SSL CA bundle: gated on ca-certificates being installed ───────────
// The human/severity behaviour is pinned in doctor_ssl_test.zig; these
// lock the `--json` `checks[]` contract for each state.

fn linkCaCerts(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const opt = try std.fmt.allocPrint(allocator, "{s}/opt/ca-certificates", .{prefix});
    defer allocator.free(opt);
    try test_io.cwd().createDirPath(std.Options.debug_io, opt);
}

test "ca-certificates not installed: no ssl_ca_bundle finding in checks[]" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "ssl_absent");
    defer s.deinit(allocator);
    try s.initSchema();

    var result = walk(allocator, s.path);
    defer result.deinit();

    // The precondition is absent, so the check emits nothing — consumers
    // see no entry rather than a misleading ok/warn.
    try testing.expect(findById(result.findings(), "ssl_ca_bundle") == null);
}

test "ca-certificates installed but unlinked: a warn ssl_ca_bundle finding" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "ssl_unlinked");
    defer s.deinit(allocator);
    try s.initSchema();
    try linkCaCerts(allocator, s.path);

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "ssl_ca_bundle") orelse
        return error.MissingSslFinding;
    try testing.expectEqual(doctor.CheckStatus.warn_status, f.severity);
    // Informational warn — doctor surfaces it but --fix can't act on it.
    try testing.expect(!f.fixable);
    try testing.expect(f.fix_class == null);
}

test "ca-certificates installed and linked: an ok ssl_ca_bundle finding" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "ssl_linked");
    defer s.deinit(allocator);
    try s.initSchema();
    try linkCaCerts(allocator, s.path);

    const dir = try std.fmt.allocPrint(allocator, "{s}/etc/openssl@3", .{s.path});
    defer allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    const cert = try std.fmt.allocPrint(allocator, "{s}/cert.pem", .{dir});
    defer allocator.free(cert);
    (try test_io.createFileAbsolute(std.Options.debug_io, cert, .{})).close(std.Options.debug_io);

    var result = walk(allocator, s.path);
    defer result.deinit();

    const f = findById(result.findings(), "ssl_ca_bundle") orelse
        return error.MissingSslFinding;
    try testing.expectEqual(doctor.CheckStatus.ok, f.severity);
}
