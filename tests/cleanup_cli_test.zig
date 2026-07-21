//! malt — `mt cleanup` shim tests.
//!
//! `mt cleanup` is a one-line alias for `mt purge --housekeeping`. The
//! contract is byte-identical output: every line the alias produces on
//! stderr (the human surface) must match what the canonical invocation
//! produces against the same scratch prefix.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const purge = malt.purge;
const output = malt.output;
const sqlite = malt.sqlite;
const schema = malt.schema;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const ScratchPrefix = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !ScratchPrefix {
        const base = try test_io.uniqueTempPath(allocator, "cleanup_cli", tag);
        defer allocator.free(base);
        const path = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{path});
        defer allocator.free(cache_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);

        // Schema must exist — every housekeeping scope opens the DB.
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);

        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *ScratchPrefix, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

const OutputState = struct {
    prior_mode: output.OutputMode,
    prior_ndjson: bool,
    prior_dry: bool,
    prior_quiet: bool,

    fn save() OutputState {
        return .{
            .prior_mode = if (output.isJson()) .json else .human,
            .prior_ndjson = output.isNdjson(),
            .prior_dry = output.isDryRun(),
            .prior_quiet = output.isQuiet(),
        };
    }

    fn restore(self: OutputState) void {
        output.setMode(self.prior_mode);
        output.setNdjson(self.prior_ndjson);
        output.setDryRun(self.prior_dry);
        output.setQuiet(self.prior_quiet);
    }
};

// `mt cleanup` and `mt purge --housekeeping` must produce identical
// stderr against an empty seeded prefix. Running both back-to-back in
// dry-run keeps the prefix unchanged between calls.
test "cleanup with no extra args matches purge --housekeeping byte-for-byte" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "noargs");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(false);
    output.setQuiet(false);

    const ctx = malt.app_ctx.debug_ctx;

    var ref_buf: std.ArrayList(u8) = .empty;
    defer ref_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &ref_buf);
    try purge.execute(&ctx, allocator, &.{"--housekeeping"});
    output.endStderrCapture();

    var shim_buf: std.ArrayList(u8) = .empty;
    defer shim_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &shim_buf);
    try purge.executeCleanup(&ctx, allocator, &.{});
    output.endStderrCapture();

    try testing.expectEqualStrings(ref_buf.items, shim_buf.items);
}

// `mt cleanup --help` must show cleanup's own help, not purge's. The
// shim intercepts before forwarding so the verb the user typed is the
// verb the help text names. Captures via a real fd so the byte stream
// from `ctx.stdout.writeStreamingAll` lands somewhere readable.
test "cleanup --help shows cleanup's help, not purge's" {
    const allocator = testing.allocator;

    const base = try test_io.uniqueTempPath(allocator, "cleanup_help", "out");
    defer allocator.free(base);
    const path = try allocator.dupeZ(u8, base);
    defer allocator.free(path);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = .{ .handle = fd, .flags = .{ .nonblocking = false } },
        .stderr = test_io.testSink(),
    };

    try purge.executeCleanup(&ctx, allocator, &.{"--help"});

    // Read back from the start of the file.
    _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
    var buf: [4096]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    try testing.expect(n > 0);
    const stdout = buf[0..@intCast(n)];

    try testing.expect(std.mem.indexOf(u8, stdout, "malt cleanup") != null);
    // Negative guard: purge's usage banner must not leak through.
    try testing.expect(std.mem.indexOf(u8, stdout, "Usage: malt purge") == null);
}

// Defence against the alias quietly widening scope: `mt cleanup --wipe`
// must be rejected the same way `mt purge --housekeeping --wipe` is, so
// users can't accidentally promote the daily-driver verb to the nuclear
// one by appending a flag.
test "cleanup rejects --wipe (mutually exclusive scopes)" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_combo");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setQuiet(true);

    const ctx = malt.app_ctx.debug_ctx;
    try testing.expectError(
        purge.Error.InvalidArgs,
        purge.executeCleanup(&ctx, allocator, &.{"--wipe"}),
    );
}

// A second `--housekeeping` on the alias must be idempotent — the args
// parser tolerates duplicate scope flags and the resulting plan is the
// same as a single `--housekeeping`. Pinned so a future "reject
// duplicates" refactor doesn't break the alias.
test "cleanup tolerates a redundant --housekeeping forwarded by users" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "double_house");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setQuiet(false);

    const ctx = malt.app_ctx.debug_ctx;

    var ref_buf: std.ArrayList(u8) = .empty;
    defer ref_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &ref_buf);
    try purge.executeCleanup(&ctx, allocator, &.{});
    output.endStderrCapture();

    var dup_buf: std.ArrayList(u8) = .empty;
    defer dup_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &dup_buf);
    try purge.executeCleanup(&ctx, allocator, &.{"--housekeeping"});
    output.endStderrCapture();

    try testing.expectEqualStrings(ref_buf.items, dup_buf.items);
}

// Passthrough check: trailing per-command flags after `cleanup` must
// reach purge in the same order as if they followed `--housekeeping`
// directly. `--cache=7` is a real per-command override (the global
// `--dry-run` would be stripped upstream by `main`, so it can't ride
// in via cmd_args).
test "cleanup forwards --cache=N identically to purge --housekeeping --cache=N" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "cache_pass");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(false);
    output.setQuiet(false);

    const ctx = malt.app_ctx.debug_ctx;

    var ref_buf: std.ArrayList(u8) = .empty;
    defer ref_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &ref_buf);
    try purge.execute(&ctx, allocator, &.{ "--housekeeping", "--cache=7" });
    output.endStderrCapture();

    var shim_buf: std.ArrayList(u8) = .empty;
    defer shim_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &shim_buf);
    try purge.executeCleanup(&ctx, allocator, &.{"--cache=7"});
    output.endStderrCapture();

    try testing.expectEqualStrings(ref_buf.items, shim_buf.items);
}
