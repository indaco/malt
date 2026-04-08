const std = @import("std");

/// Initializes the database schema (creates tables if they do not exist).
pub fn initSchema(db: anytype) !void {
    _ = db;
    return error.NotImplemented;
}

/// Runs any pending schema migrations.
pub fn migrate(db: anytype) !void {
    _ = db;
    return error.NotImplemented;
}

/// Returns the current schema version number.
pub fn currentVersion(db: anytype) !u32 {
    _ = db;
    return error.NotImplemented;
}
