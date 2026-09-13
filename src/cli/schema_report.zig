//! Shared messaging for `schema.initSchema` failures.
//!
//! `SchemaTooNew` is the gate an older binary hits against a DB a newer
//! malt already migrated. Callers used to collapse it into a generic
//! "failed to initialize" or swallow it, so the user never learned that
//! upgrading malt — not repairing the DB — is the fix.

const std = @import("std");
const output = @import("../ui/output.zig");
const schema = @import("../db/schema.zig");
const sqlite = @import("../db/sqlite.zig");

/// Build the message for an `initSchema` failure into `buf` and return the
/// written slice. `db_version` is the DB's own marker (0 when unreadable).
/// Split from emission so callers on an injected output sink (the install
/// pipeline) report the same text as the global `output`.
pub fn initFailureMessage(buf: []u8, e: schema.MigrateError, db_version: i64, prefix: []const u8) []const u8 {
    return switch (e) {
        error.SchemaTooNew => std.fmt.bufPrint(
            buf,
            "Database at {s}/db/malt.db is schema v{d}; this malt supports up to v{d}. It was written by a newer malt — run that malt, or upgrade (mt version update / brew upgrade --cask malt).",
            .{ prefix, db_version, schema.known_schema_version },
        ) catch "Database schema is newer than this malt supports — upgrade malt.",
        else => std.fmt.bufPrint(
            buf,
            "Failed to initialize database schema at {s}/db/malt.db ({s})",
            .{ prefix, @errorName(e) },
        ) catch "Failed to initialize database schema.",
    };
}

/// Emit the failure on the global `output` channel and hand back the error
/// the site aborts with. `SchemaTooNew` keeps its name so `main` can give it
/// a dedicated exit code the TUI turns into a banner reason; anything else
/// is the plain `Aborted` contract.
pub fn abortInitFailure(db: *sqlite.Database, e: schema.MigrateError, prefix: []const u8) error{ SchemaTooNew, Aborted } {
    var buf: [512]u8 = undefined;
    output.err("{s}", .{initFailureMessage(&buf, e, schema.currentVersion(db) catch 0, prefix)});
    return if (e == error.SchemaTooNew) error.SchemaTooNew else error.Aborted;
}

test "initFailureMessage names the DB version, the supported ceiling and the path on SchemaTooNew" {
    var buf: [512]u8 = undefined;
    const msg = initFailureMessage(&buf, error.SchemaTooNew, schema.known_schema_version + 1, "/opt/malt");

    var want_db: [16]u8 = undefined;
    const db_tag = try std.fmt.bufPrint(&want_db, "v{d}", .{schema.known_schema_version + 1});
    var want_max: [16]u8 = undefined;
    const max_tag = try std.fmt.bufPrint(&want_max, "v{d}", .{schema.known_schema_version});

    try std.testing.expect(std.mem.indexOf(u8, msg, db_tag) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, max_tag) != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/opt/malt/db/malt.db") != null);
    // Both ways out: the dev build that wrote it, or a release upgrade.
    try std.testing.expect(std.mem.indexOf(u8, msg, "run that malt") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "upgrade") != null);
}

test "initFailureMessage names the SQLite error and the path otherwise" {
    var buf: [512]u8 = undefined;
    const msg = initFailureMessage(&buf, error.ExecFailed, schema.known_schema_version, "/opt/malt");
    try std.testing.expect(std.mem.indexOf(u8, msg, "ExecFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "/opt/malt/db/malt.db") != null);
    // A real SQLite failure must never be dressed up as a version mismatch.
    try std.testing.expect(std.mem.indexOf(u8, msg, "upgrade") == null);
}

test "initFailureMessage degrades to a generic line when buf is too small" {
    var tiny: [8]u8 = undefined;
    const too_new = initFailureMessage(&tiny, error.SchemaTooNew, 99, "/opt/malt");
    try std.testing.expect(std.mem.indexOf(u8, too_new, "upgrade malt") != null);
    const broken = initFailureMessage(&tiny, error.StepFailed, 1, "/opt/malt");
    try std.testing.expect(std.mem.indexOf(u8, broken, "schema") != null);
}
