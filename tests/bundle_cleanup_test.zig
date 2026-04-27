//! malt — bundle cleanup CLI integration tests
//!
//! Pure unit tests for `core/bundle/cleanup.zig` live inline next to the
//! module. This file pins the cross-module CLI wiring: `cli/bundle.zig`
//! parsing, MALT_PREFIX-driven DB lookup, brewfile parsing, and the
//! dry-run skip-uninstall contract.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;

test "cli bundle cleanup --dry-run plans removal without dispatching" {
    // We can't inject a fake dispatcher through `cli_bundle.execute`, so
    // dry-run is the proof — any uninstall would mutate the database, and
    // we assert it stays intact.
    const dir_z: [:0]const u8 = "/tmp/malt_bundle_cleanup_cli_dry_run";
    malt.fs_compat.deleteTreeAbsolute(dir_z) catch {};
    try malt.fs_compat.cwd().makePath(dir_z);
    defer malt.fs_compat.deleteTreeAbsolute(dir_z) catch {};

    _ = c.setenv("MALT_PREFIX", dir_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{dir_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);
    {
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        var ins_keg = try db.prepare(
            \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path, install_reason)
            \\VALUES (?, ?, '1.0', '', '', 'direct');
        );
        defer ins_keg.finalize();
        for ([_][]const u8{ "wget", "ripgrep", "jq" }) |n| {
            try ins_keg.reset();
            try ins_keg.bindText(1, n);
            try ins_keg.bindText(2, n);
            _ = try ins_keg.step();
        }
        var ins_cask = try db.prepare(
            \\INSERT INTO casks(token, name, version, url) VALUES (?, ?, '1.0', '');
        );
        defer ins_cask.finalize();
        for ([_][]const u8{ "ghostty", "iterm2" }) |n| {
            try ins_cask.reset();
            try ins_cask.bindText(1, n);
            try ins_cask.bindText(2, n);
            _ = try ins_cask.step();
        }
    }

    // Brewfile keeps wget + ghostty; cleanup must propose ripgrep, jq, iterm2.
    const bf_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{dir_z});
    defer testing.allocator.free(bf_path);
    {
        const f = try malt.fs_compat.cwd().createFile(bf_path, .{});
        defer f.close();
        try f.writeAll("brew \"wget\"\ncask \"ghostty\"\n");
    }

    try malt.cli_bundle.execute(testing.allocator, &.{ "cleanup", "--dry-run", bf_path });

    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM kegs;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 3), stmt.columnInt(0));

    var stmt2 = try db.prepare("SELECT COUNT(*) FROM casks;");
    defer stmt2.finalize();
    _ = try stmt2.step();
    try testing.expectEqual(@as(i64, 2), stmt2.columnInt(0));
}

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};
