//! DB record schema + filesystem-prep helpers for the install flow.
//! Owns the `InstallError` set so every submodule returns the same
//! narrow set and the dispatch loop can classify errors exhaustively.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const formula_mod = @import("../../core/formula.zig");
const sqlite = @import("../../db/sqlite.zig");
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
    /// The formula's archive builds from source: after extraction the
    /// promote walk found no binary and bin/ is empty, so nothing
    /// runnable would be linked. malt (a bottle/binary client) does not
    /// run build blocks, so it unwinds the half-extracted keg and records
    /// nothing — the user is pointed at `brew install` instead.
    BuildFromSourceUnsupported,
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
    /// GitHub-API rate limit hit while resolving a tap's HEAD commit.
    /// Distinct from `FormulaNotFound` so the user-facing summary
    /// names the real cause instead of "formula does not exist."
    RateLimited,
    /// Network-layer failure (no HTTP status) while resolving a tap.
    /// Distinct tag so retry policies can differentiate from 4xx/5xx.
    NetworkError,
};

/// True for any `InstallError`. The install/upgrade commands always print
/// a user-facing line before returning one of these, so the top-level
/// dispatch in `main` exits non-zero *quietly* on them — the same
/// treatment as `error.Aborted` — instead of dumping the error enum name
/// (and, in debug, a return trace) on top of the message the command
/// already showed. Comptime-derived so a new tag is covered automatically.
pub fn isReportedInstallError(e: anyerror) bool {
    inline for (@typeInfo(InstallError).error_set.?) |variant| {
        if (e == @field(InstallError, variant.name)) return true;
    }
    return false;
}

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
        InstallError.RateLimited,
        InstallError.NetworkError,
        // Raise site prints the actionable "builds from source" line, so
        // the generic dispatch summary stays suppressed.
        InstallError.BuildFromSourceUnsupported,
        => true,

        InstallError.NoPackages,
        InstallError.DatabaseError,
        InstallError.LockError,
        InstallError.CaskNotFound,
        InstallError.NoBottle,
        InstallError.StoreFailed,
        InstallError.LinkFailed,
        // Some RecordFailed paths emit a classified err first, others
        // (db.beginTransaction failure) do not — leave the generic
        // dispatch summary on so the silent path still surfaces.
        InstallError.RecordFailed,
        InstallError.PartialFailure,
        InstallError.PrefixAbsurd,
        InstallError.PostInstallUnsupported,
        InstallError.AmbiguousSystemRubyScope,
        => false,
    };
}

/// Options for `recordKeg`. Defaults keep the install path's pre-T-007
/// observable behaviour: a user pin survives a force-reinstall (via
/// COALESCE-MAX), and `recordKeg` opens its own SQLite transaction.
pub const RecordOpts = struct {
    /// `true` → new row inherits any existing pin on this name via
    /// COALESCE-MAX. `false` → new row's `pinned` is hard-coded to 0,
    /// even if a prior row was pinned.
    inherit_pin: bool = true,
    /// `true` → caller already opened a transaction. `recordKeg`
    /// performs no BEGIN/COMMIT/ROLLBACK so atomicity is the caller's
    /// responsibility (used by `upgradeDbAtomic` to wrap
    /// unlink → record → link → delete in a single txn).
    in_transaction: bool = false,
};

/// Record a keg in the database. Returns the keg_id.
/// Errors propagate as `sqlite.SqliteError` so callers can route the
/// underlying cause through `db.errMsg()` instead of seeing a flat
/// `RecordFailed` — particularly load-bearing for the upgrade path
/// where a UNIQUE collision must surface to the user.
///
/// `bin_isolated` is the user's per-keg "don't link bin/sbin into
/// prefix/bin" intent; it round-trips so a later upgrade reads back
/// the same policy without the user re-passing a flag.
pub fn recordKeg(
    db: *sqlite.Database,
    formula: *const formula_mod.Formula,
    store_sha256: []const u8,
    cellar_path: []const u8,
    install_reason: []const u8,
    bin_isolated: bool,
    opts: RecordOpts,
) sqlite.SqliteError!i64 {
    if (!opts.in_transaction) {
        try db.beginTransaction();
    }
    errdefer if (!opts.in_transaction) db.rollback();

    // Pin column: inherit any existing pin on this name via COALESCE-MAX
    // (default), or hard-code 0 when the caller opts out. INSERT OR
    // REPLACE handles same-(name, version) re-records (install --force,
    // revision bumps); upgrade (different version) just INSERTs alongside.
    const sql = if (opts.inherit_pin)
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason, bin_isolated, pinned)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, COALESCE((SELECT MAX(pinned) FROM kegs WHERE name = ?1), 0));"
    else
        "INSERT OR REPLACE INTO kegs (name, full_name, version, revision, tap, store_sha256, cellar_path, install_reason, bin_isolated, pinned)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0);";

    var stmt = try db.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, formula.name);
    try stmt.bindText(2, formula.full_name);
    try stmt.bindText(3, formula.version);
    try stmt.bindInt(4, formula.revision);
    try stmt.bindText(5, formula.tap);
    try stmt.bindText(6, store_sha256);
    try stmt.bindText(7, cellar_path);
    try stmt.bindText(8, install_reason);
    try stmt.bindInt(9, if (bin_isolated) 1 else 0);

    _ = try stmt.step();

    const keg_id = try getLastInsertId(db);

    if (!opts.in_transaction) {
        try db.commit();
    }

    return keg_id;
}

/// Delete a keg record (rollback / replaced-old-row helper). Wipes
/// `dependencies` and `links` rows before the kegs row so the upgrade
/// path can call this on a fully-populated old keg; the install
/// rollback path arrives before those rows exist, where the extra
/// deletes are harmless no-ops. Best-effort: a failed delete leaves a
/// stale row that `doctor` cleans.
pub fn deleteKeg(db: *sqlite.Database, keg_id: i64) void {
    {
        var dep_stmt = db.prepare("DELETE FROM dependencies WHERE keg_id = ?1;") catch return;
        defer dep_stmt.finalize();
        dep_stmt.bindInt(1, keg_id) catch return;
        _ = dep_stmt.step() catch {};
    }
    {
        var link_stmt = db.prepare("DELETE FROM links WHERE keg_id = ?1;") catch return;
        defer link_stmt.finalize();
        link_stmt.bindInt(1, keg_id) catch return;
        _ = link_stmt.step() catch {};
    }
    var stmt = db.prepare("DELETE FROM kegs WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// Record dependencies for a keg. Each row is independent; on per-row
/// failure we skip and continue so a partial dep table is preferred to
/// the install being rolled back wholesale.
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
/// one-row read. Errors propagate as `sqlite.SqliteError` so the
/// upgrade path can surface `db.errMsg()` to the user.
pub fn getLastInsertId(db: *sqlite.Database) sqlite.SqliteError!i64 {
    var stmt = try db.prepare("SELECT last_insert_rowid();");
    defer stmt.finalize();
    const has_row = try stmt.step();
    if (!has_row) return sqlite.SqliteError.StepFailed;
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
pub fn ensureDirs(ctx: *const AppCtx, prefix: []const u8) !void {
    // Create the prefix directory itself first (e.g. /opt/malt)
    std.Io.Dir.createDirAbsolute(ctx.io, prefix, .default_dir) catch |e| switch (e) {
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
        std.Io.Dir.createDirAbsolute(ctx.io, dir_path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => continue,
        };
    }
}
