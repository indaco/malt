//! DB record schema + filesystem-prep helpers for the install flow.
//! Owns the `InstallError` set so every submodule returns the same
//! narrow set and the dispatch loop can classify errors exhaustively.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const sqlite = @import("../../db/sqlite.zig");
const formula_mod = @import("../../core/formula.zig");
const output = @import("../../ui/output.zig");

pub const InstallError = error{
    NoPackages,
    DatabaseError,
    LockError,
    FormulaNotFound,
    CaskNotFound,
    NoBottle,
    DownloadFailed,
    StoreFailed,
    CellarFailed,
    LinkFailed,
    RecordFailed,
    /// At least one package in a multi-package install failed to materialize
    /// or was skipped because an ancestor dep failed. Returned from `execute`
    /// so `main` exits non-zero.
    PartialFailure,
    /// MALT_PREFIX is absurdly long (exceeds the 256-byte sanity cap).
    /// Raised before any network activity so pathological values never
    /// reach the relocation subprocess.
    PrefixAbsurd,
    /// Formula defines a Ruby `post_install` hook that malt cannot execute.
    /// Raised before any dep resolution or job queueing so nothing is
    /// downloaded, materialised, or linked for the affected package.
    PostInstallUnsupported,
    /// `--use-system-ruby` used with multiple formulas and no explicit
    /// scope list. The flag widens the trust boundary (runs full Ruby
    /// with only OS-level sandboxing), so malt requires the user to
    /// name which formulas it should apply to when ambiguity exists.
    AmbiguousSystemRubyScope,
    /// `--local <path>` named a file that does not exist, is not a
    /// regular file, or cannot be opened. Raised before parse so the
    /// user sees the real filesystem error instead of a parser message.
    LocalFormulaNotReadable,
    /// The `.rb`'s archive URL is not `https://`. Refusing to fetch
    /// means a malicious or accidentally-committed `file://`,
    /// `ftp://`, or plaintext `http://` URL cannot be turned into an
    /// exploit just by `malt install --local`-ing the file.
    InsecureArchiveUrl,
};

/// True when the given error has already surfaced a specific,
/// user-facing `output.err` line from inside the install helpers, so
/// the dispatch-loop shouldn't add a generic "Failed to install X: E"
/// summary on top. Narrowed to `InstallError` so a new tag forces a
/// compile error on unhandled paths instead of silently falling through
/// the old `else =>` prong.
pub fn localErrorIsAnnounced(e: InstallError) bool {
    return switch (e) {
        InstallError.LocalFormulaNotReadable,
        InstallError.InsecureArchiveUrl,
        InstallError.FormulaNotFound,
        InstallError.DownloadFailed,
        InstallError.CellarFailed,
        => true,

        InstallError.NoPackages,
        InstallError.DatabaseError,
        InstallError.LockError,
        InstallError.CaskNotFound,
        InstallError.NoBottle,
        InstallError.StoreFailed,
        InstallError.LinkFailed,
        InstallError.RecordFailed,
        InstallError.PartialFailure,
        InstallError.PrefixAbsurd,
        InstallError.PostInstallUnsupported,
        InstallError.AmbiguousSystemRubyScope,
        => false,
    };
}

/// Record a keg in the database. Returns the keg_id.
pub fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
) !i64 {
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var stmt = db.prepare(
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);",
    ) catch return InstallError.RecordFailed;
    defer stmt.finalize();

    stmt.bindText(1, formula.name) catch return InstallError.RecordFailed;
    stmt.bindText(2, formula.full_name) catch return InstallError.RecordFailed;
    stmt.bindText(3, formula.version) catch return InstallError.RecordFailed;
    stmt.bindInt(4, formula.revision) catch return InstallError.RecordFailed;
    stmt.bindText(5, formula.tap) catch return InstallError.RecordFailed;
    stmt.bindText(6, store_sha256) catch return InstallError.RecordFailed;
    stmt.bindText(7, cellar_path) catch return InstallError.RecordFailed;
    stmt.bindText(8, install_reason) catch return InstallError.RecordFailed;

    _ = stmt.step() catch return InstallError.RecordFailed;

    // Get last inserted row id
    const keg_id = getLastInsertId(db) catch return InstallError.RecordFailed;

    db.commit() catch return InstallError.RecordFailed;

    return keg_id;
}

/// Delete a keg record from the database (rollback helper).
pub fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// Record dependencies for a keg.
pub fn recordDeps(db: *sqlite.Database, keg_id: i64, formula: *const formula_mod.Formula) void {
    for (formula.dependencies) |dep_name| {
        var stmt = db.prepare(
            "INSERT OR IGNORE INTO dependencies (keg_id, dep_name, dep_type) VALUES (?1, ?2, 'runtime');",
        ) catch continue;
        defer stmt.finalize();

        stmt.bindInt(1, keg_id) catch continue;
        stmt.bindText(2, dep_name) catch continue;
        _ = stmt.step() catch {};
    }
}

/// Get the last inserted row id from SQLite. Pub so the ruby-formula
/// path in `install/local.zig` can reuse it without re-implementing the
/// one-row read.
pub fn getLastInsertId(db: *sqlite.Database) !i64 {
    var stmt = db.prepare("SELECT last_insert_rowid();") catch return InstallError.RecordFailed;
    defer stmt.finalize();
    const has_row = stmt.step() catch return InstallError.RecordFailed;
    if (!has_row) return InstallError.RecordFailed;
    return stmt.columnInt(0);
}

/// Check if a formula is already installed.
pub fn isInstalled(db: *sqlite.Database, name: []const u8) bool {
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;
    return stmt.step() catch false;
}

/// Ensure all required directories under prefix exist.
pub fn ensureDirs(prefix: []const u8) !void {
    // Create the prefix directory itself first (e.g. /opt/malt)
    fs_compat.makeDirAbsolute(prefix) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => {
            output.err("Cannot create prefix directory {s} — you may need: sudo mkdir -p {s} && sudo chown $USER {s}", .{ prefix, prefix, prefix });
            return error.Aborted;
        },
    };

    const subdirs = [_][]const u8{
        "store",
        "Cellar",
        "Caskroom",
        "opt",
        "bin",
        "lib",
        "include",
        "share",
        "sbin",
        "etc",
        "tmp",
        "cache",
        "db",
    };

    for (subdirs) |subdir| {
        var buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, subdir }) catch continue;
        fs_compat.makeDirAbsolute(dir_path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => continue,
        };
    }
}

/// Constant-time equality for byte slices. Used on the SHA256
/// comparison so a network-positioned attacker cannot mount a byte-by-
/// byte timing oracle against the expected hash. Returns false
/// immediately on length mismatch (the length itself is not a secret).
pub fn constantTimeEql(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    var diff: T = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}
