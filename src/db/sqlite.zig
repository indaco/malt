const std = @import("std");

pub const Statement = struct {
    _handle: ?*anyopaque = null,

    /// Advances the statement to the next row. Returns true if a row is available.
    pub fn step(self: *Statement) !bool {
        _ = self;
        return error.NotImplemented;
    }

    /// Finalizes the prepared statement, releasing resources.
    pub fn finalize(self: *Statement) void {
        _ = self;
    }

    /// Binds a text value to the parameter at the given index.
    pub fn bindText(self: *Statement, idx: u32, text: []const u8) !void {
        _ = .{ self, idx, text };
        return error.NotImplemented;
    }

    /// Returns the text value of the column at the given index.
    pub fn columnText(self: *Statement, idx: u32) []const u8 {
        _ = .{ self, idx };
        return "";
    }
};

pub const Database = struct {
    _handle: ?*anyopaque = null,

    /// Opens a database at the given file path.
    pub fn open(path: []const u8) !Database {
        _ = path;
        return error.NotImplemented;
    }

    /// Closes the database connection.
    pub fn close(self: *Database) void {
        self._handle = null;
    }

    /// Executes a SQL statement that returns no rows.
    pub fn exec(self: *Database, sql: []const u8) !void {
        _ = .{ self, sql };
        return error.NotImplemented;
    }

    /// Prepares a SQL statement for execution.
    pub fn prepare(self: *Database, sql: []const u8) !Statement {
        _ = .{ self, sql };
        return error.NotImplemented;
    }
};
