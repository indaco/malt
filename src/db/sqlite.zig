const std = @import("std");
const c = @import("c_sqlite");

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

/// SQLite's transient-destructor sentinel (-1 as a pointer): tells `bind` to
/// copy the bound bytes now, so the caller's buffer need only stay valid for the
/// bind call itself — no lifetime obligation past `bindText`.
const SQLITE_TRANSIENT_BITS: usize = @bitCast(@as(isize, -1));

comptime {
    // The sentinel must be all-ones for SQLite to recognize it as -1.
    std.debug.assert(SQLITE_TRANSIENT_BITS == std.math.maxInt(usize));
}

/// The sentinel isn't pointer-aligned, so Zig can't hold it as a typed
/// fn-pointer constant; reinterpret the bits at the call. SQLite only compares
/// this value against -1, never calls through it.
inline fn sqliteTransient() c.sqlite3_destructor_type {
    return (extern union { bits: usize, dtor: c.sqlite3_destructor_type }{
        .bits = SQLITE_TRANSIENT_BITS,
    }).dtor;
}

pub const Statement = struct {
    /// Raw sqlite handle; touch only via the methods below.
    _stmt: *c.sqlite3_stmt,

    /// Advance the statement. Returns true when a data row is available (SQLITE_ROW),
    /// false when execution is complete (SQLITE_DONE).
    pub fn step(self: *Statement) SqliteError!bool {
        const rc = c.sqlite3_step(self._stmt);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return mapError(rc, SqliteError.StepFailed);
    }

    /// Finalize (destroy) the prepared statement, releasing all resources.
    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self._stmt);
    }

    /// Reset the statement so it can be re-executed with new bindings.
    pub fn reset(self: *Statement) SqliteError!void {
        const rc = c.sqlite3_reset(self._stmt);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.StepFailed);
    }

    /// Bind a text value to the 1-indexed parameter at `idx`. SQLite copies the
    /// bytes at bind time, so `text` may be freed as soon as this returns.
    pub fn bindText(self: *Statement, idx: u32, text: []const u8) SqliteError!void {
        const rc = c.sqlite3_bind_text(
            self._stmt,
            @intCast(idx),
            @ptrCast(text.ptr),
            @intCast(text.len),
            sqliteTransient(),
        );
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Bind a 64-bit integer value to the 1-indexed parameter at `idx`.
    pub fn bindInt(self: *Statement, idx: u32, val: i64) SqliteError!void {
        const rc = c.sqlite3_bind_int64(self._stmt, @intCast(idx), val);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Bind NULL to the 1-indexed parameter at `idx`.
    pub fn bindNull(self: *Statement, idx: u32) SqliteError!void {
        const rc = c.sqlite3_bind_null(self._stmt, @intCast(idx));
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.BindFailed);
    }

    /// Return the text value of column `idx` (0-indexed), or null if the column is SQL NULL.
    pub fn columnText(self: *Statement, idx: u32) ?[*:0]const u8 {
        const ptr = c.sqlite3_column_text(self._stmt, @intCast(idx));
        if (ptr == null) return null;
        return ptr;
    }

    /// Return the 64-bit integer value of column `idx` (0-indexed).
    pub fn columnInt(self: *Statement, idx: u32) i64 {
        return c.sqlite3_column_int64(self._stmt, @intCast(idx));
    }

    /// Return the boolean interpretation of column `idx` (0-indexed): true when non-zero.
    pub fn columnBool(self: *Statement, idx: u32) bool {
        return c.sqlite3_column_int64(self._stmt, @intCast(idx)) != 0;
    }
};

pub const Database = struct {
    /// Raw sqlite handle; touch only via the methods below.
    _handle: *c.sqlite3,

    /// Open (or create) a database file at `path`.
    /// Configures pragmas: journal_mode=WAL, foreign_keys=ON, busy_timeout=5000.
    pub fn open(path: [:0]const u8) SqliteError!Database {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(
            path.ptr,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            null,
        );

        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return SqliteError.OpenFailed;
        }

        var self = Database{ ._handle = db.? };

        // Set recommended pragmas.
        self.exec("PRAGMA journal_mode=WAL;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA foreign_keys=ON;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA busy_timeout=5000;") catch return SqliteError.OpenFailed;

        return self;
    }

    /// Close the database connection and release resources.
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self._handle);
    }

    /// Last error message from this connection. Returns the SQLite-owned
    /// UTF-8 buffer (`sqlite3_errmsg`); the slice is valid only until the
    /// next call on this handle, so use it inline (e.g. directly in an
    /// `output.err` format) and never store it past the next op.
    pub fn errMsg(self: *Database) []const u8 {
        const ptr = c.sqlite3_errmsg(self._handle);
        if (ptr == null) return "";
        return std.mem.sliceTo(ptr, 0);
    }

    /// Execute one or more SQL statements that return no result rows.
    /// String literals and `bufPrintZ` output coerce to `[:0]const u8`; dynamic
    /// SQL should be built with `bufPrintZ` or an ArrayList plus a trailing 0.
    pub fn exec(self: *Database, sql: [:0]const u8) SqliteError!void {
        const rc = c.sqlite3_exec(self._handle, sql.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.ExecFailed);
    }

    /// Prepare a single SQL statement for later execution. Takes a slice and
    /// passes the length directly to sqlite — no null terminator required,
    /// no copy needed.
    pub fn prepare(self: *Database, sql: []const u8) SqliteError!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self._handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return mapError(rc, SqliteError.PrepareFailed);
        return Statement{ ._stmt = stmt.? };
    }

    /// Whether an explicit transaction is already open. SQLite has no nested
    /// `BEGIN`, so a callee that batches writes must ask before opening one.
    pub fn inTransaction(self: *Database) bool {
        return c.sqlite3_get_autocommit(self._handle) == 0;
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
        _ = c.sqlite3_exec(self._handle, "ROLLBACK;", null, null, null);
    }
};

/// Reports the linked SQLite's compile-time threading mode:
///   0 = single-thread, 1 = serialized, 2 = multi-thread.
/// Callers that spawn workers across the same handle rely on 1.
pub fn threadsafeMode() c_int {
    return c.sqlite3_threadsafe();
}

const testing = std.testing;

test "inTransaction reports an explicit BEGIN, not autocommit" {
    var db = try Database.open(":memory:");
    defer db.close();

    // Callers batching writes ask this before opening one of their own, so it
    // has to clear on both exits, not just commit.
    try testing.expect(!db.inTransaction());
    try db.beginTransaction();
    try testing.expect(db.inTransaction());
    try db.commit();
    try testing.expect(!db.inTransaction());

    try db.beginTransaction();
    db.rollback();
    try testing.expect(!db.inTransaction());
}

test "threadsafeMode returns one of the three documented values" {
    const m = threadsafeMode();
    try testing.expect(m == 0 or m == 1 or m == 2);
}

test "errMsg returns the underlying SQLite error string after a failed exec" {
    var db = try Database.open(":memory:");
    defer db.close();

    // Forces a parse error, populating the connection's last-error slot.
    try testing.expectError(SqliteError.ExecFailed, db.exec("NOT VALID SQL;"));
    const msg = db.errMsg();
    try testing.expect(msg.len > 0);
    // SQLite's parse error includes the offending token; assert on a stable
    // substring rather than the full message.
    try testing.expect(std.mem.indexOf(u8, msg, "syntax error") != null or
        std.mem.indexOf(u8, msg, "near \"NOT\"") != null);
}

test "errMsg surfaces a UNIQUE constraint violation message" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t(name TEXT UNIQUE);");
    try db.exec("INSERT INTO t(name) VALUES('a');");

    var stmt = try db.prepare("INSERT INTO t(name) VALUES(?1);");
    defer stmt.finalize();
    try stmt.bindText(1, "a");
    try testing.expectError(SqliteError.ConstraintViolation, stmt.step());
    const msg = db.errMsg();
    try testing.expect(std.mem.indexOf(u8, msg, "UNIQUE") != null);
}

test "bindText copies bound bytes at bind time, so caller may free before step" {
    var db = try Database.open(":memory:");
    defer db.close();

    try db.exec("CREATE TABLE t(name TEXT);");

    var stmt = try db.prepare("INSERT INTO t(name) VALUES(?1);");
    defer stmt.finalize();

    const original = "malt-formula-name";
    const buf = try testing.allocator.dupe(u8, original);
    try stmt.bindText(1, buf);

    // Scribble then free the caller's buffer *before* stepping. Under a no-copy
    // (SQLITE_STATIC) bind this hands SQLite a dangling pointer to 0xAA bytes;
    // a copy-at-bind (SQLITE_TRANSIENT) already owns the bytes and is immune.
    @memset(buf, 0xAA);
    testing.allocator.free(buf);

    try testing.expect(!try stmt.step());

    var read = try db.prepare("SELECT name FROM t;");
    defer read.finalize();
    try testing.expect(try read.step());
    const got = std.mem.sliceTo(read.columnText(0).?, 0);
    try testing.expectEqualStrings(original, got);
}
