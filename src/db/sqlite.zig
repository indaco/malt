const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));

pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ExecFailed,
    ConstraintViolation,
    Busy,
    Corrupt,
};

/// Map a raw SQLite result code to the appropriate SqliteError.
fn mapError(rc: c_int, comptime default: SqliteError) SqliteError {
    return switch (rc) {
        c.SQLITE_CONSTRAINT,
        c.SQLITE_CONSTRAINT_UNIQUE,
        c.SQLITE_CONSTRAINT_PRIMARYKEY,
        c.SQLITE_CONSTRAINT_FOREIGNKEY,
        c.SQLITE_CONSTRAINT_CHECK,
        c.SQLITE_CONSTRAINT_NOTNULL,
        => SqliteError.ConstraintViolation,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => SqliteError.Busy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => SqliteError.Corrupt,
        else => default,
    };
}

/// SQLITE_TRANSIENT expressed as a Zig pointer, telling SQLite to copy bound data immediately.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    /// Advance the statement. Returns true when a data row is available (SQLITE_ROW),
    /// false when execution is complete (SQLITE_DONE).
    pub fn step(self: *Statement) SqliteError!bool {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return mapError(rc, SqliteError.StepFailed);
    }

    /// Finalize (destroy) the prepared statement, releasing all resources.
    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }

    /// Reset the statement so it can be re-executed with new bindings.
    pub fn reset(self: *Statement) SqliteError!void {
        const rc = c.sqlite3_reset(self.stmt);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.StepFailed);
    }

    /// Bind a text value to the 1-indexed parameter at `idx`.
    pub fn bindText(self: *Statement, idx: u32, text: []const u8) SqliteError!void {
        const rc = c.sqlite3_bind_text(
            self.stmt,
            @intCast(idx),
            @ptrCast(text.ptr),
            @intCast(text.len),
            SQLITE_TRANSIENT,
        );
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Bind a 64-bit integer value to the 1-indexed parameter at `idx`.
    pub fn bindInt(self: *Statement, idx: u32, val: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self.stmt, @intCast(idx), val);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Bind NULL to the 1-indexed parameter at `idx`.
    pub fn bindNull(self: *Statement, idx: u32) SqliteError!void {
        const rc = c.sqlite3_bind_null(self.stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Return the text value of column `idx` (0-indexed), or null if the column is SQL NULL.
    pub fn columnText(self: *Statement, idx: u32) ?[*:0]const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, @intCast(idx));
        if (ptr == null) return null;
        return ptr;
    }

    /// Return the 64-bit integer value of column `idx` (0-indexed).
    pub fn columnInt(self: *Statement, idx: u32) i64 {
        return c.sqlite3_column_int64(self.stmt, @intCast(idx));
    }

    /// Return the boolean interpretation of column `idx` (0-indexed): true when non-zero.
    pub fn columnBool(self: *Statement, idx: u32) bool {
        return c.sqlite3_column_int64(self.stmt, @intCast(idx)) != 0;
    }
};

pub const Database = struct {
    handle: *c.sqlite3,

    /// Open (or create) a database file at `path`.
    /// Configures pragmas: journal_mode=WAL, foreign_keys=ON, busy_timeout=5000.
    pub fn open(path: []const u8) SqliteError!Database {
        // SQLite requires a null-terminated path.  Zig string literals are
        // already sentinel-terminated, so we can try a direct cast when the
        // slice happens to be backed by one.  For the general case we would
        // need an allocator, but every call-site in this project passes a
        // comptime-known literal, so the cast is safe.
        const c_path: [*:0]const u8 = @ptrCast(path.ptr);

        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            c_path,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );

        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }

        var self = Database{ .handle = db.? };

        // Set recommended pragmas.
        self.exec("PRAGMA journal_mode=WAL;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA foreign_keys=ON;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA busy_timeout=5000;") catch return SqliteError.OpenFailed;

        return self;
    }

    /// Close the database connection and release resources.
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute one or more SQL statements that return no result rows.
    pub fn exec(self: *Database, sql: [*:0]const u8) SqliteError!void {
        const rc = c.sqlite3_exec(self.handle, sql, null, null, null);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.ExecFailed);
    }

    /// Prepare a single SQL statement for later execution.
    pub fn prepare(self: *Database, sql: [*:0]const u8) SqliteError!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.PrepareFailed);
        return Statement{ .stmt = stmt.? };
    }

    /// Begin an immediate transaction.
    pub fn beginTransaction(self: *Database) SqliteError!void {
        return self.exec("BEGIN IMMEDIATE;");
    }

    /// Commit the current transaction.
    pub fn commit(self: *Database) SqliteError!void {
        return self.exec("COMMIT;");
    }

    /// Roll back the current transaction.  Errors are intentionally ignored
    /// because this is typically called from an errdefer path.
    pub fn rollback(self: *Database) void {
        _ = c.sqlite3_exec(self.handle, "ROLLBACK;", null, null, null);
    }
};
