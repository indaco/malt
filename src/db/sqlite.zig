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
    /// The return is the last `step` error, already surfaced there; the
    /// statement is destroyed regardless, so `defer` sites stay sound.
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

// Worst case every path byte is percent-encoded, plus the scheme and query.
const snapshot_uri_len = std.fs.max_path_bytes * 3 + 64;

/// Existence via SQLite's VFS. A wrong answer is safe for both uses: a
/// missed -wal yields an older but consistent copy, a missed db/ a refusal.
fn vfsExists(path: [*:0]const u8) bool {
    const vfs = c.sqlite3_vfs_find(null) orelse return true;
    var res: c_int = 0;
    if (vfs.*.xAccess.?(vfs, path, c.SQLITE_ACCESS_EXISTS, &res) != c.SQLITE_OK) return true;
    return res != 0;
}

/// Read-only URI for `path`; `?`, `#` and `%` would otherwise end the path.
fn snapshotUri(buf: []u8, path: []const u8, immutable: bool) error{WriteFailed}![:0]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("file://");
    for (path) |ch| switch (ch) {
        '?', '#', '%' => try w.print("%{X:0>2}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeAll(if (immutable) "?mode=ro&immutable=1" else "?mode=ro");
    try w.writeByte(0);
    return buf[0 .. w.end - 1 :0];
}

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
            if (db) |d| _ = c.sqlite3_close_v2(d);
            return SqliteError.OpenFailed;
        }

        var self = Database{ ._handle = db.? };
        errdefer self.close();

        // busy_timeout first: the WAL switch needs a lock, and without the
        // timeout a writer holding one fails the open instead of waiting.
        self.exec("PRAGMA busy_timeout=5000;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA journal_mode=WAL;") catch return SqliteError.OpenFailed;
        self.exec("PRAGMA foreign_keys=ON;") catch return SqliteError.OpenFailed;

        return self;
    }

    /// Preview handle: a private copy, so a dry run can migrate and read
    /// without touching the prefix.
    pub fn openSnapshot(path: [:0]const u8) SqliteError!Database {
        var mem: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(":memory:", &mem, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) {
            if (mem) |d| _ = c.sqlite3_close_v2(d);
            return SqliteError.OpenFailed;
        }
        var self = Database{ ._handle = mem.? };
        errdefer self.close();
        self.exec("PRAGMA foreign_keys=ON;") catch return SqliteError.OpenFailed;

        // No -wal means no uncheckpointed frames, so `immutable` loses nothing
        // and keeps SQLite from creating sidecars next to the file.
        var buf: [snapshot_uri_len]u8 = undefined;
        const wal = std.fmt.bufPrintSentinel(&buf, "{s}-wal", .{path}, 0) catch return SqliteError.OpenFailed;
        const immutable = !vfsExists(wal);
        const uri = snapshotUri(&buf, path, immutable) catch return SqliteError.OpenFailed;

        var src: ?*c.sqlite3 = null;
        defer if (src) |s| {
            _ = c.sqlite3_close_v2(s);
        };
        if (c.sqlite3_open_v2(uri.ptr, &src, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI, null) != c.SQLITE_OK) {
            // Mirror `open`: only a missing file starts empty; a missing
            // directory or a file it cannot read fails.
            const absent = src != null and c.sqlite3_system_errno(src) == @intFromEnum(std.posix.E.NOENT);
            const dir = std.fs.path.dirname(path) orelse return if (absent) self else SqliteError.OpenFailed;
            const dir_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir}, 0) catch return SqliteError.OpenFailed;
            return if (absent and vfsExists(dir_z)) self else SqliteError.OpenFailed;
        }
        _ = c.sqlite3_busy_timeout(src.?, 5000);

        const backup = c.sqlite3_backup_init(self._handle, "main", src.?, "main") orelse return SqliteError.OpenFailed;
        const step_rc = c.sqlite3_backup_step(backup, -1);
        if (c.sqlite3_backup_finish(backup) != c.SQLITE_OK or step_rc != c.SQLITE_DONE) return SqliteError.OpenFailed;
        return self;
    }

    /// Close the database connection and release resources. A statement that
    /// outlives this call keeps the connection alive until its own `finalize`,
    /// so a straggler cannot leak the connection.
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close_v2(self._handle);
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

test "Database.open closes the handle when a PRAGMA fails after a successful open" {
    // sqlite3_open_v2 never reads the header, so a non-database file fails the
    // first PRAGMA - the only path that abandons a constructed Database.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-notadb-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, &[_]u8{0x5A} ** 4096);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    // Lowest-free-fd rule: a leaked connection pushes the probe fd up by one.
    const before = std.c.dup(0);
    _ = std.c.close(before);
    // A closed stdin would make both probes -1 and the check vacuous.
    try testing.expect(before >= 0);

    try testing.expectError(SqliteError.OpenFailed, Database.open(path));

    const after = std.c.dup(0);
    defer _ = std.c.close(after);
    try testing.expectEqual(before, after);
}

// SQLite removes the WAL sidecars only on a clean close; a red run must not litter /tmp.
fn deleteWithSidecars(io: std.Io, path: []const u8) void {
    for ([_][]const u8{ "", "-wal", "-shm" }) |suffix| {
        var buf: [80]u8 = undefined;
        const file = std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suffix }) catch unreachable;
        std.Io.Dir.cwd().deleteFile(io, file) catch {};
    }
}

test "Database.close releases the connection at once when no statement is alive" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-clean-close-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    defer deleteWithSidecars(io, path);

    const before = std.c.dup(0);
    _ = std.c.close(before);
    try testing.expect(before >= 0);

    var db = try Database.open(path);
    db.close();

    const after = std.c.dup(0);
    defer _ = std.c.close(after);
    try testing.expectEqual(before, after);
}

test "Database.close releases the connection once a straggling statement finalizes" {
    // File-backed on purpose: an in-memory connection owns no fd, so the
    // probe would pass vacuously against the legacy close.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-close-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    defer deleteWithSidecars(io, path);

    const before = std.c.dup(0);
    _ = std.c.close(before);
    try testing.expect(before >= 0);

    var db = try Database.open(path);
    try db.exec("CREATE TABLE t(x);");
    var stmt = try db.prepare("SELECT x FROM t;");
    db.close(); // straggler alive: the connection must outlive this call, not leak
    stmt.finalize(); // last finalize reaps the zombie connection and its fds

    const after = std.c.dup(0);
    defer _ = std.c.close(after);
    try testing.expectEqual(before, after);
}

fn commitAfter(holder: *Database, ms: i64) void {
    std.Io.sleep(std.Options.debug_io, .fromMilliseconds(ms), .awake) catch {};
    holder.exec("COMMIT;") catch {};
}

test "Database.open waits out a lock held by another connection instead of failing" {
    // A rollback-journal DB under a write lock makes the WAL pragma return
    // BUSY; that is a wait, not an unopenable database.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-busy-open-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    deleteWithSidecars(io, path);
    defer deleteWithSidecars(io, path);

    var holder = try Database.open(path);
    defer holder.close();
    try holder.exec("PRAGMA journal_mode=DELETE;");
    try holder.exec("BEGIN EXCLUSIVE; CREATE TABLE t(x);");

    const releaser = try std.Thread.spawn(.{}, commitAfter, .{ &holder, 300 });
    defer releaser.join();

    var db = try Database.open(path);
    db.close();
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn countRows(db: *Database) !i64 {
    var stmt = try db.prepare("SELECT count(*) FROM t;");
    defer stmt.finalize();
    _ = try stmt.step();
    return stmt.columnInt(0);
}

test "openSnapshot on an absent file hands back an empty database and creates nothing" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-snap-absent-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    deleteWithSidecars(io, path);
    defer deleteWithSidecars(io, path);

    var db = try Database.openSnapshot(path);
    try db.exec("CREATE TABLE t(x); INSERT INTO t VALUES (1);");
    try testing.expectEqual(@as(i64, 1), try countRows(&db));
    db.close();

    for ([_][]const u8{ "", "-wal", "-shm", "-journal" }) |suffix| {
        var buf: [80]u8 = undefined;
        try testing.expect(!fileExists(io, try std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suffix })));
    }
}

test "openSnapshot refuses a path whose directory is missing, as open does" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-snap-nodir-{d}/malt.db", .{std.c.getpid()});
    const io = std.Options.debug_io;

    try testing.expectError(SqliteError.OpenFailed, Database.open(path));
    try testing.expectError(SqliteError.OpenFailed, Database.openSnapshot(path));
    try testing.expect(!fileExists(io, std.fs.path.dirname(path).?));
}

test "openSnapshot reads a WAL database without changing a byte or leaving a sidecar" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-snap-wal-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    deleteWithSidecars(io, path);
    defer deleteWithSidecars(io, path);
    {
        var seed = try Database.open(path);
        defer seed.close();
        try seed.exec("CREATE TABLE t(x); INSERT INTO t VALUES (1), (2);");
    }
    const before = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(before);

    var db = try Database.openSnapshot(path);
    try testing.expectEqual(@as(i64, 2), try countRows(&db));
    // A write lands in the copy only.
    try db.exec("INSERT INTO t VALUES (3);");
    try testing.expectEqual(@as(i64, 3), try countRows(&db));
    db.close();

    const after = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, before, after);
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        var buf: [80]u8 = undefined;
        try testing.expect(!fileExists(io, try std.fmt.bufPrint(&buf, "{s}{s}", .{ path, suffix })));
    }
}

test "openSnapshot sees rows a live writer has committed but not yet checkpointed" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-snap-live-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    deleteWithSidecars(io, path);
    defer deleteWithSidecars(io, path);

    var writer = try Database.open(path);
    defer writer.close();
    try writer.exec("PRAGMA wal_autocheckpoint=0; CREATE TABLE t(x); INSERT INTO t VALUES (1), (2), (3);");
    var wal_buf: [80]u8 = undefined;
    try testing.expect(fileExists(io, try std.fmt.bufPrint(&wal_buf, "{s}-wal", .{path})));

    var db = try Database.openSnapshot(path);
    defer db.close();
    try testing.expectEqual(@as(i64, 3), try countRows(&db));
}

test "openSnapshot reports an unreadable database as a failure, never as empty" {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/malt-snap-walled-{d}.db", .{std.c.getpid()});
    const io = std.Options.debug_io;
    deleteWithSidecars(io, path);
    defer deleteWithSidecars(io, path);
    {
        var seed = try Database.open(path);
        defer seed.close();
        try seed.exec("CREATE TABLE t(x);");
    }
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    try f.setPermissions(io, std.Io.File.Permissions.fromMode(0));
    defer f.setPermissions(io, std.Io.File.Permissions.fromMode(0o644)) catch {};
    // root reads through mode 0, which would make the check vacuous.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    try testing.expectError(SqliteError.OpenFailed, Database.openSnapshot(path));
}

test "openSnapshot copies a database whose path carries URI metacharacters" {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt-snap-%?#-{d}", .{std.c.getpid()});
    const io = std.Options.debug_io;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/malt.db", .{dir});
    {
        var seed = try Database.open(path);
        defer seed.close();
        try seed.exec("CREATE TABLE t(x); INSERT INTO t VALUES (1);");
    }

    var db = try Database.openSnapshot(path);
    defer db.close();
    try testing.expectEqual(@as(i64, 1), try countRows(&db));
}

test "openSnapshot reports a directory it cannot look into as a failure, never as empty" {
    // The file may well be there; only a definite ENOENT starts empty.
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root bypasses the perm wall
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/malt-snap-walled-dir-{d}", .{std.c.getpid()});
    const io = std.Options.debug_io;
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/malt.db", .{dir});
    {
        var seed = try Database.open(path);
        seed.close();
    }
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    try d.setPermissions(io, std.Io.File.Permissions.fromMode(0));
    defer d.setPermissions(io, std.Io.File.Permissions.fromMode(0o755)) catch {};

    try testing.expectError(SqliteError.OpenFailed, Database.openSnapshot(path));
}
