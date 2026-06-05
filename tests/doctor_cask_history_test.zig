//! malt — doctor cask history report integration tests.
//!
//! Drives `doctor.emitCaskHistoryReport` against a real seeded prefix
//! and asserts the bytes that land on stderr (human) or stdout (JSON).
//! The pure rendering functions are exercised in
//! `src/cli/doctor/cask_history.zig`'s inline tests; this file pins
//! the wiring through `output.*`.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const doctor = malt.doctor;
const cask_history = malt.doctor_cask_history;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_doctor_cask_history_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const subs = [_][]const u8{ "db", "cache/Cask", "Caskroom" };
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

    /// Plant a current cask + two retained history rows + matching
    /// disk artefacts so the walker reports a deterministic byte total.
    fn seedTwoRetainedAlphaVersions(self: *Scratch, allocator: std.mem.Allocator) !void {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{self.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try db.exec(
            \\INSERT INTO casks (token, name, version, url)
            \\VALUES ('alpha', 'Alpha', '2.0', 'https://x.invalid/a.dmg');
        );
        try db.exec(
            \\INSERT INTO cask_versions (token, version, url, artifact_type)
            \\VALUES ('alpha', '1.0', 'https://x.invalid/a-1.0.dmg', 'dmg'),
            \\       ('alpha', '1.5', 'https://x.invalid/a-1.5.dmg', 'dmg'),
            \\       ('alpha', '2.0', 'https://x.invalid/a-2.0.dmg', 'dmg');
        );

        const app_1_0 = try std.fmt.allocPrint(allocator, "{s}/Caskroom/alpha/1.0/Alpha.app", .{self.path});
        defer allocator.free(app_1_0);
        try test_io.cwd().createDirPath(std.Options.debug_io, std.fs.path.dirname(app_1_0).?);
        const f1 = try test_io.createFileAbsolute(std.Options.debug_io, app_1_0, .{ .truncate = true });
        defer f1.close(std.Options.debug_io);
        try f1.writeStreamingAll(std.Options.debug_io, "x" ** 64);

        const cache_1_5 = try std.fmt.allocPrint(allocator, "{s}/cache/Cask/alpha-1.5.dmg", .{self.path});
        defer allocator.free(cache_1_5);
        const f2 = try test_io.createFileAbsolute(std.Options.debug_io, cache_1_5, .{ .truncate = true });
        defer f2.close(std.Options.debug_io);
        try f2.writeStreamingAll(std.Options.debug_io, "y" ** 128);
    }
};

fn resetOutputFlags() void {
    output.setQuiet(false);
    output.setVerbose(false);
    output.setMode(.human);
}

test "emitCaskHistoryReport: default mode prints a one-line summary on stderr" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "default");
    defer s.deinit(allocator);
    try s.seedTwoRetainedAlphaVersions(allocator);

    resetOutputFlags();
    defer resetOutputFlags();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitCaskHistoryReport(allocator, std.Options.debug_io, s.path);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Retained cask versions: 2") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "mt purge --old-versions") != null);
    // Default mode must not list per-entry rows — those belong to --verbose.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.0") == null);
}

test "emitCaskHistoryReport: empty case stays silent on stderr in human mode" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "empty");
    defer s.deinit(allocator);

    resetOutputFlags();
    defer resetOutputFlags();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitCaskHistoryReport(allocator, std.Options.debug_io, s.path);

    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "emitCaskHistoryReport: --verbose lists every retained (token version) under the summary" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "verbose");
    defer s.deinit(allocator);
    try s.seedTwoRetainedAlphaVersions(allocator);

    resetOutputFlags();
    defer resetOutputFlags();
    output.setVerbose(true);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitCaskHistoryReport(allocator, std.Options.debug_io, s.path);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Retained cask versions: 2") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.0") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        alpha 1.5") != null);
}

test "emitDoctorJson: the merged --json carries the cask_history payload on stdout" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "json");
    defer s.deinit(allocator);
    try s.seedTwoRetainedAlphaVersions(allocator);

    resetOutputFlags();
    defer resetOutputFlags();
    output.setMode(.json);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    // The cask_history data is now one member of the single merged document.
    doctor.emitDoctorJson(allocator, std.Options.debug_io, s.path, &.{});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"cask_history\":") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"retained_versions\":2") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"bytes\":") != null);
    // JSON routes the report away from stderr — no human summary line.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "Retained cask versions") == null);
}

test "emitCaskHistoryReport: read-only — cask_versions rows survive the walk" {
    // Doctor reports without `--fix` must never mutate. Pin the row
    // count before and after so a future regression that wires a
    // delete into this code path trips here.
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "ro");
    defer s.deinit(allocator);
    try s.seedTwoRetainedAlphaVersions(allocator);

    const before = try countCaskVersionRows(allocator, s.path);

    resetOutputFlags();
    defer resetOutputFlags();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitCaskHistoryReport(allocator, std.Options.debug_io, s.path);

    const after = try countCaskVersionRows(allocator, s.path);
    try testing.expectEqual(before, after);
    try testing.expectEqual(@as(i64, 3), after);
}

fn countCaskVersionRows(allocator: std.mem.Allocator, prefix: []const u8) !i64 {
    _ = allocator;
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM cask_versions;");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "writeJson exposed via lib alias matches the inline test bytes" {
    // Smoke check that the public symbol path in `malt.doctor_cask_history`
    // resolves to the same writer the unit tests exercise.
    var entries = [_]cask_history.Entry{
        .{ .token = "alpha", .version = "1.0", .bytes = 64 },
    };
    const census: cask_history.Census = .{ .entries = entries[0..], .total_bytes = 64 };

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try cask_history.writeJson(&w, census);
    try testing.expectEqualStrings(
        "{\"cask_history\":{\"retained_versions\":1,\"bytes\":64}}\n",
        w.buffered(),
    );
}
