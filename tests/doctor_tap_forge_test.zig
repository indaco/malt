//! malt — doctor registered-taps forge/host report integration tests.
//!
//! Drives `doctor.emitTapForgeReport` against a real seeded prefix and
//! asserts the bytes that land on stderr (human) or stdout (JSON). The
//! pure formatters are byte-pinned in `tests/doctor_render_test.zig`;
//! this file pins the DB walk + `output.*` wiring.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const doctor = malt.doctor;
const tap_mod = malt.tap;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_doctor_tap_forge_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        // An initialized (empty) DB mirrors production: doctor's SQLite
        // check creates the schema before the tap report runs.
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }

    /// Register a github tap and a gitlab tap so the report has one of
    /// each forge to surface.
    fn seedTwoForges(self: *Scratch) !void {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{self.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        try tap_mod.add(&db, "user/repo", "user", "repo", null);
        try tap_mod.addWithHost(&db, "grp/tap", "grp", "tap", "gitlab.com", null);
    }
};

fn resetOutputFlags() void {
    output.setQuiet(false);
    output.setVerbose(false);
    output.setMode(.human);
}

test "emitTapForgeReport: human mode lists each tap with its host on stderr" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "human");
    defer s.deinit(allocator);
    try s.seedTwoForges();

    resetOutputFlags();
    defer resetOutputFlags();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitTapForgeReport(allocator, s.path);

    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "  > Registered taps:") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        user/repo [github.com]") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "        grp/tap [gitlab.com]") != null);
}

test "emitTapForgeReport: human mode stays silent when no taps are registered" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "empty");
    defer s.deinit(allocator);

    resetOutputFlags();
    defer resetOutputFlags();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    doctor.emitTapForgeReport(allocator, s.path);

    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "emitDoctorJson: the merged --json carries the taps payload on stdout" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "json");
    defer s.deinit(allocator);
    try s.seedTwoForges();

    resetOutputFlags();
    defer resetOutputFlags();
    output.setMode(.json);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    // The taps data is now one member of the single merged document.
    doctor.emitDoctorJson(allocator, std.Options.debug_io, s.path, &.{});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        stdout_buf.items,
        "\"taps\":[{\"name\":\"user/repo\",\"host\":\"github.com\"}," ++
            "{\"name\":\"grp/tap\",\"host\":\"gitlab.com\"}]",
    ) != null);
}

test "emitDoctorJson: the merged --json keeps an empty taps array when no taps exist" {
    const allocator = testing.allocator;
    var s = try Scratch.init(allocator, "json_empty");
    defer s.deinit(allocator);

    resetOutputFlags();
    defer resetOutputFlags();
    output.setMode(.json);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    doctor.emitDoctorJson(allocator, std.Options.debug_io, s.path, &.{});

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"taps\":[]") != null);
}
