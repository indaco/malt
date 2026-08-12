//! malt — cask module
//! Cask JSON parsing and installation (DMG, PKG, ZIP, tar.gz).

const std = @import("std");
const builtin = @import("builtin");
const system_tools = @import("../system_tools.zig");

const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");
const archive_mod = @import("../fs/archive.zig");
const path_component = @import("../fs/path_component.zig");
const confined_source = @import("../fs/confined_source.zig");
const hash_mod = @import("hash.zig");
const child_mod = @import("child.zig");
const cask_font = @import("cask_font.zig");

pub const CaskError = error{
    ParseFailed,
    DownloadFailed,
    InstallFailed,
    UninstallFailed,
    // Distinct from UninstallFailed so callers can say *why*: the app is live.
    AppRunning,
    Sha256Mismatch,
    // Distinct from Sha256Mismatch: the manifest declared no digest at all.
    // Callers retry a mismatch as transient corruption; this one never
    // succeeds on a retry, so it must not wear the same name.
    Sha256Missing,
    // Also never succeeds on a retry: the manifest asked for a cleartext
    // origin for an artifact it declined to pin.
    InsecureOrigin,
    // This machine ran out of threads or descriptors; the origin was never
    // reached, so reporting it as a download failure sends the user to the
    // wrong place.
    DownloadLocalResourceExhausted,
    OutOfMemory,
};

/// `uninstall` lets the `removeRecord` SQLite failure bubble through so
/// the CLI caller can log `db.errMsg()` instead of swallowing it.
pub const UninstallError = CaskError || sqlite.SqliteError;

/// Parsed Homebrew cask. Every `[]const u8` borrows from `parsed`; valid
/// only until `deinit()`. Callers holding strings past that point must dupe.
pub const Cask = struct {
    /// Borrowed from `parsed`.
    token: []const u8,
    /// Borrowed from `parsed`.
    name: []const u8,
    /// Borrowed from `parsed`.
    version: []const u8,
    /// Borrowed from `parsed`.
    desc: []const u8,
    /// Borrowed from `parsed`.
    homepage: []const u8,
    /// Borrowed from `parsed`.
    url: []const u8,
    /// Borrowed from `parsed` when present.
    sha256: ?[]const u8,
    auto_updates: bool,

    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Cask) void {
        self.parsed.deinit();
    }
};

/// Parse cask JSON from Homebrew API.
pub fn parseCask(allocator: std.mem.Allocator, json_bytes: []const u8) !Cask {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return CaskError.ParseFailed;
    errdefer parsed.deinit();

    // A non-object root is an inactive union field: reading a field off it
    // aborts the process instead of failing the command.
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return CaskError.ParseFailed,
    };

    const token = getStr(obj, "token") orelse return CaskError.ParseFailed;
    const version = getStr(obj, "version") orelse "unknown";
    // `token` and `version` are interpolated verbatim into Caskroom,
    // cache, and mount paths, so a value that escapes its own path
    // component must be rejected here — the one ingestion choke point —
    // before any sink sees it. A compromised tap is the threat.
    if (!path_component.isPathComponent(token) or !path_component.isPathComponent(version)) return CaskError.ParseFailed;
    // Artifact strings are the *other* half of the tap-controlled path surface:
    // `app` lands in `<app_dir>/<name>` ahead of a `deleteTree`, and `binary`
    // resolves under the keg and symlinks into `<prefix>/bin`. Screen them at
    // the same choke point rather than at each sink.
    try validateArtifactPaths(obj);

    return .{
        .token = token,
        .name = getFirstName(obj) orelse token,
        .version = version,
        .desc = getStr(obj, "desc") orelse "",
        .homepage = getStr(obj, "homepage") orelse "",
        .url = getStr(obj, "url") orelse return CaskError.ParseFailed,
        .sha256 = getStr(obj, "sha256"),
        .auto_updates = getBool(obj, "auto_updates") orelse false,
        .parsed = parsed,
    };
}

/// Record cask installation in database.
/// The COALESCE subquery on `pinned` carries any existing user pin
/// across INSERT OR REPLACE so a force-upgrade doesn't silently clear
/// the hold; first-time installs default to 0. `tap` is NULL for casks
/// installed from the core Homebrew API and the tap label
/// (`user/repo`) for those installed from a third-party tap — read at
/// upgrade time so `mt upgrade <token>` can pre-route to the owning
/// tap without probing the rest of the registered list.
pub fn recordInstall(
    db: *sqlite.Database,
    cask: *const Cask,
    app_path: ?[]const u8,
    tap: ?[]const u8,
) sqlite.SqliteError!void {
    var stmt = try db.prepare(
        "INSERT OR REPLACE INTO casks (token, name, version, url, sha256, app_path, auto_updates, pinned, tap)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE((SELECT pinned FROM casks WHERE token = ?1), 0), ?8);",
    );
    defer stmt.finalize();

    try stmt.bindText(1, cask.token);
    try stmt.bindText(2, cask.name);
    try stmt.bindText(3, cask.version);
    try stmt.bindText(4, cask.url);
    if (cask.sha256) |s| try stmt.bindText(5, s) else try stmt.bindNull(5);
    if (app_path) |p| try stmt.bindText(6, p) else try stmt.bindNull(6);
    try stmt.bindInt(7, if (cask.auto_updates) 1 else 0);
    if (tap) |t| try stmt.bindText(8, t) else try stmt.bindNull(8);
    _ = try stmt.step();
}

/// Remove cask record from database.
pub fn removeRecord(db: *sqlite.Database, token: []const u8) sqlite.SqliteError!void {
    var stmt = try db.prepare("DELETE FROM casks WHERE token = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    _ = try stmt.step();
}

/// Append a row to the per-version cask history. Called from `install`
/// (and any other code path that materialises a cask version on disk)
/// so `mt rollback <cask> --list / --to` can retrieve the URL, SHA256,
/// artifact type, and cache path needed to reinstall later. INSERT OR
/// IGNORE keeps reinstalls of the same version idempotent.
pub fn recordCaskVersion(
    db: *sqlite.Database,
    token: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: ?[]const u8,
    artifact_type: []const u8,
    cache_path: ?[]const u8,
) sqlite.SqliteError!void {
    var stmt = try db.prepare(
        \\INSERT OR IGNORE INTO cask_versions
        \\    (token, version, url, sha256, artifact_type, cache_path)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6);
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    try stmt.bindText(3, url);
    if (sha256) |s| try stmt.bindText(4, s) else try stmt.bindNull(4);
    try stmt.bindText(5, artifact_type);
    if (cache_path) |p| try stmt.bindText(6, p) else try stmt.bindNull(6);
    _ = try stmt.step();
}

/// Snapshot of a single `cask_versions` row, owned by the caller.
/// Returned by `lookupCaskVersion`. Free via `deinit`.
pub const CaskVersion = struct {
    token: []u8,
    version: []u8,
    url: []u8,
    sha256: ?[]u8,
    artifact_type: []u8,
    cache_path: ?[]u8,

    pub fn deinit(self: *CaskVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.version);
        allocator.free(self.url);
        if (self.sha256) |s| allocator.free(s);
        allocator.free(self.artifact_type);
        if (self.cache_path) |p| allocator.free(p);
    }
};

pub const LookupError = sqlite.SqliteError || std.mem.Allocator.Error;

/// Existing-cask metadata the rollback path must preserve across a
/// reinstall — `auto_updates` and the owning `tap`. Mirrors the keg
/// rollback's pin-preservation: a rolled-back cask must not silently
/// flip these fields back to "fresh install" defaults.
pub const ReinstallMeta = struct {
    auto_updates: bool,
    tap: ?[]u8,

    pub fn deinit(self: *ReinstallMeta, allocator: std.mem.Allocator) void {
        if (self.tap) |t| allocator.free(t);
    }
};

/// Read `auto_updates` and `tap` from the current `casks` row for
/// `token`. Returns defaults (`false`, `null`) when the row is absent
/// — the rollback caller refuses earlier if the cask isn't installed,
/// so the default branch only fires under truly anomalous DB state.
pub fn readReinstallMeta(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    token: []const u8,
) LookupError!ReinstallMeta {
    var stmt = try db.prepare("SELECT auto_updates, tap FROM casks WHERE token = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    if (!(try stmt.step())) return .{ .auto_updates = false, .tap = null };
    const au = stmt.columnBool(0);
    const tap_dup = try dupColumn(allocator, stmt.columnText(1));
    return .{ .auto_updates = au, .tap = tap_dup };
}

/// Look up the cask_versions row for `(token, version)`. Returns null
/// when no row matches — the caller decides whether that's a rollback
/// refusal or a re-download trigger.
pub fn lookupCaskVersion(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    token: []const u8,
    version: []const u8,
) LookupError!?CaskVersion {
    var stmt = try db.prepare(
        \\SELECT token, version, url, sha256, artifact_type, cache_path
        \\FROM cask_versions WHERE token = ?1 AND version = ?2 LIMIT 1;
    );
    defer stmt.finalize();
    try stmt.bindText(1, token);
    try stmt.bindText(2, version);
    if (!(try stmt.step())) return null;

    // Stage every dup in a slot tracked by `cleanup`; the cleanup runs
    // on every error path so a mid-row OOM doesn't leak the earlier dups.
    var slots: [6]?[]u8 = .{null} ** 6;
    errdefer for (slots) |s| if (s) |buf| allocator.free(buf);

    inline for (.{ 0, 1, 2, 3, 4, 5 }) |idx| {
        slots[idx] = try dupColumn(allocator, stmt.columnText(idx));
    }

    // Required columns: token, version, url, artifact_type. NULL here
    // means the row is malformed; refuse cleanly so the caller can fall
    // back to "no rollback target".
    if (slots[0] == null or slots[1] == null or slots[2] == null or slots[4] == null) return null;

    return .{
        .token = slots[0].?,
        .version = slots[1].?,
        .url = slots[2].?,
        .sha256 = slots[3],
        .artifact_type = slots[4].?,
        .cache_path = slots[5],
    };
}

/// Duplicate a SQLite text column into an allocator-owned slice. NULL
/// columns map to `null`; rows whose schema is shorter than the index
/// also return `null` to keep the caller's error space tight.
fn dupColumn(allocator: std.mem.Allocator, raw: ?[*:0]const u8) std.mem.Allocator.Error!?[]u8 {
    const ptr = raw orelse return null;
    return try allocator.dupe(u8, std.mem.sliceTo(ptr, 0));
}

/// Render an `ArtifactType` enum tag for storage in `cask_versions.artifact_type`.
/// Symmetric with `artifactTypeFromTag` so writes and reads agree byte-for-byte.
pub fn artifactTypeTag(t: ArtifactType) []const u8 {
    return switch (t) {
        .dmg => "dmg",
        .zip => "zip",
        .pkg => "pkg",
        .tar_gz => "tar_gz",
        .tar_xz => "tar_xz",
        .unknown => "unknown",
    };
}

/// Delete the per-version cache file for one `(token, version)` pair.
/// Writes to the `<prefix>/cache/Cask/<token>-<version>.<ext>` naming and
/// stays surgical so `purge --old-versions` can drop a stale version
/// without touching the current one. Iterates every known extension because
/// `cask_versions.artifact_type` is nullable on rows backfilled
/// before v7. Returns true when every file that existed was removed
/// (or none existed); false when an existing file could not be
/// deleted — the caller uses that signal to gate the DB row delete
/// so a read-only mount doesn't orphan history.
pub fn deletePerVersionCacheFile(io: std.Io, prefix: []const u8, token: []const u8, version: []const u8) bool {
    for (cache_extensions) |ext| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/cache/Cask/{s}-{s}{s}", .{ prefix, token, version, ext }) catch continue;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        std.Io.Dir.cwd().deleteFile(io, path) catch return false;
    }
    return true;
}

/// Delete the cached per-version artefacts this token owns, resolved from
/// its `cask_versions` history rather than a lexical `{token}-` prefix. A
/// bare prefix also matches sibling tokens (`git` is a prefix of `git-lfs`),
/// and versions legitimately contain dashes, so the recorded version list is
/// the only signal that separates a real version from a sibling's suffix.
/// Enumerates every history row so stale rollback artefacts are swept too.
/// Best-effort: a failed delete never gates uninstall. Call BEFORE the
/// history rows are deleted, or the version list is already empty.
pub fn sweepOwnedVersionCache(io: std.Io, db: *sqlite.Database, prefix: []const u8, token: []const u8) void {
    var stmt = db.prepare("SELECT version FROM cask_versions WHERE token = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return;

    while (stmt.step() catch false) {
        const ver_ptr = stmt.columnText(0) orelse continue;
        _ = deletePerVersionCacheFile(io, prefix, token, std.mem.sliceTo(ver_ptr, 0));
    }
}

pub fn artifactTypeFromTag(tag: []const u8) ArtifactType {
    if (std.mem.eql(u8, tag, "dmg")) return .dmg;
    if (std.mem.eql(u8, tag, "zip")) return .zip;
    if (std.mem.eql(u8, tag, "pkg")) return .pkg;
    if (std.mem.eql(u8, tag, "tar_gz")) return .tar_gz;
    if (std.mem.eql(u8, tag, "tar_xz")) return .tar_xz;
    return .unknown;
}

/// Determine the artifact type from the cask download URL.
/// `tar_gz` covers both `.tar.gz` and `.tgz`, `tar_xz` both `.tar.xz` and
/// `.txz` — each pair is one container format with one extractor.
pub const ArtifactType = enum { dmg, zip, pkg, tar_gz, tar_xz, unknown };

/// Every suffix a cached artefact can carry on disk. Sweeps iterate it
/// rather than the recorded type because `cask_versions.artifact_type` is
/// nullable on rows backfilled before v7. The `.tgz`/`.txz` aliases are
/// absent on purpose: `downloadToCache` always stages the canonical name.
pub const cache_extensions = [_][]const u8{ ".dmg", ".zip", ".pkg", ".tar.gz", ".tar.xz" };

/// Canonical suffix a downloaded artefact is staged under. Aliases collapse
/// here (`.tgz` stages as `.tar.gz`) so the sweep only has to know one name
/// per format. Every value must appear in `cache_extensions`.
pub fn artifactExtension(t: ArtifactType) []const u8 {
    return switch (t) {
        .dmg => ".dmg",
        .zip => ".zip",
        .pkg => ".pkg",
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .unknown => ".bin",
    };
}

/// Suffix → type, longest first so `.tar.gz` is not read as a bare `.gz`
/// sibling of `.tgz`. Query strings and fragments follow the same table.
const artifact_suffixes = [_]struct { suffix: []const u8, type: ArtifactType }{
    .{ .suffix = ".dmg", .type = .dmg },
    .{ .suffix = ".zip", .type = .zip },
    .{ .suffix = ".pkg", .type = .pkg },
    .{ .suffix = ".tar.gz", .type = .tar_gz },
    .{ .suffix = ".tgz", .type = .tar_gz },
    .{ .suffix = ".tar.xz", .type = .tar_xz },
    .{ .suffix = ".txz", .type = .tar_xz },
};

pub fn artifactTypeFromUrl(url: []const u8) ArtifactType {
    for (artifact_suffixes) |row| {
        if (std.mem.endsWith(u8, url, row.suffix)) return row.type;
    }
    // Some URLs carry a query string or fragment after the extension.
    for (artifact_suffixes) |row| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, url, pos, row.suffix)) |at| : (pos = at + 1) {
            const next = at + row.suffix.len;
            if (next < url.len and (url[next] == '?' or url[next] == '#')) return row.type;
        }
    }
    return .unknown;
}

/// Detect artifact type from a Content-Disposition header value.
/// Handles both `filename="X.dmg"` and `filename*=UTF-8''X.dmg`.
pub fn artifactTypeFromContentDisposition(header: []const u8) ArtifactType {
    const filename = extractFilename(header) orelse return .unknown;
    return artifactTypeFromUrl(filename);
}

/// Combined resolution: URL extension first, then Content-Disposition.
/// `content_disposition` is nullable — pass the header from a HEAD
/// response when the URL alone is ambiguous.
pub fn resolveArtifactType(
    _: std.mem.Allocator,
    url: []const u8,
    content_disposition: ?[]const u8,
) ArtifactType {
    const from_url = artifactTypeFromUrl(url);
    if (from_url != .unknown) return from_url;

    if (content_disposition) |cd| {
        const from_cd = artifactTypeFromContentDisposition(cd);
        if (from_cd != .unknown) return from_cd;
    }

    return .unknown;
}

fn extractFilename(header: []const u8) ?[]const u8 {
    // Try filename*= first (RFC 5987), then filename=
    for ([_][]const u8{ "filename*=", "filename=" }) |key| {
        var pos: usize = 0;
        while (pos < header.len) {
            if (std.mem.indexOfPos(u8, header, pos, key)) |start| {
                var val_start = start + key.len;
                // Skip whitespace after '='
                while (val_start < header.len and header[val_start] == ' ') val_start += 1;

                if (std.mem.eql(u8, key, "filename*=")) {
                    // Skip charset and language: e.g. UTF-8''
                    if (std.mem.indexOfPos(u8, header, val_start, "''")) |ticks| {
                        val_start = ticks + 2;
                    }
                }

                // Strip optional quotes
                if (val_start < header.len and header[val_start] == '"') {
                    val_start += 1;
                    if (std.mem.indexOfPos(u8, header, val_start, "\"")) |end| {
                        return header[val_start..end];
                    }
                }
                // Unquoted: run until semicolon, space, or end
                const end = blk: {
                    for (header[val_start..], val_start..) |ch, i| {
                        if (ch == ';' or ch == ' ') break :blk i;
                    }
                    break :blk header.len;
                };
                if (end > val_start) return header[val_start..end];
                pos = val_start;
            } else break;
        }
    }

    // Also handle `filename =` (space before equals)
    if (std.mem.indexOf(u8, header, "filename")) |fn_start| {
        var i = fn_start + "filename".len;
        while (i < header.len and (header[i] == ' ' or header[i] == '=')) i += 1;
        if (i < header.len and header[i] == '"') {
            i += 1;
            if (std.mem.indexOfPos(u8, header, i, "\"")) |end| {
                return header[i..end];
            }
        }
    }

    return null;
}

/// Extract the .app bundle name from cask JSON artifacts array.
/// Homebrew cask JSON: "artifacts": [{"app": ["Firefox.app"]}, ...]
pub fn parseAppName(obj: std.json.ObjectMap) ?[]const u8 {
    const arr = firstArtifactArray(obj, "app") orelse return null;
    if (arr.items.len == 0) return null;
    return switch (arr.items[0]) {
        .string => |s| s,
        else => null,
    };
}

/// Source name of the first `binary` artifact — the file to locate
/// inside the extracted archive. Homebrew JSON shape:
///   "artifacts": [{"binary": ["<source>"]}, ...]
///   "artifacts": [{"binary": ["<source>", {"target": "<alias>"}]}, ...]
pub fn parseBinaryName(obj: std.json.ObjectMap) ?[]const u8 {
    const arr = firstArtifactArray(obj, "binary") orelse return null;
    if (arr.items.len == 0) return null;
    return switch (arr.items[0]) {
        .string => |s| s,
        else => null,
    };
}

/// Rename hint for a `binary` artifact, e.g. the symlink should be
/// `codex` while the file on disk is `codex-aarch64-apple-darwin`.
/// Null when no target override is present.
pub fn parseBinaryTarget(obj: std.json.ObjectMap) ?[]const u8 {
    const arr = firstArtifactArray(obj, "binary") orelse return null;
    for (arr.items[1..]) |item| {
        switch (item) {
            .object => |o| {
                if (o.get("target")) |tv| {
                    return switch (tv) {
                        .string => |s| s,
                        else => null,
                    };
                }
            },
            else => {},
        }
    }
    return null;
}

/// Homebrew lets a `binary` source name the prefix explicitly; the remainder is
/// still a subpath and is screened as one.
const homebrew_prefix_var = "$HOMEBREW_PREFIX/";

/// Reject any `app` or `binary` artifact string that would escape the directory
/// it is resolved against. Only the artifact kinds malt actually turns into
/// paths are screened: `font` has its own sanitizer in `cask_font.zig`, and
/// `pkg` reaches the installer as the cached download path, not as a name.
fn validateArtifactPaths(obj: std.json.ObjectMap) CaskError!void {
    const artifacts = switch (obj.get("artifacts") orelse return) {
        .array => |a| a,
        else => return,
    };

    for (artifacts.items) |item| {
        const art = switch (item) {
            .object => |o| o,
            else => continue,
        };

        // `app` — every string entry becomes `<app_dir>/<name>`.
        if (art.get("app")) |val| if (val == .array) {
            for (val.array.items) |entry| switch (entry) {
                .string => |s| if (!path_component.isRelativeSubpath(s)) return CaskError.ParseFailed,
                else => {},
            };
        };

        // `binary` — items[0] is the source under the keg; any trailing object
        // may carry a `target` rename hint that becomes `<prefix>/bin/<target>`.
        if (art.get("binary")) |val| if (val == .array) {
            for (val.array.items, 0..) |entry, i| switch (entry) {
                .string => |s| {
                    const rel = if (std.mem.startsWith(u8, s, homebrew_prefix_var))
                        s[homebrew_prefix_var.len..]
                    else
                        s;
                    if (!path_component.isRelativeSubpath(rel)) return CaskError.ParseFailed;
                },
                .object => |o| {
                    // Only the first element is the source; later objects are
                    // option hashes, and `target` is the one malt honours.
                    if (i == 0) continue;
                    if (o.get("target")) |tv| switch (tv) {
                        // The link name is a single entry in `<prefix>/bin`.
                        .string => |t| if (!path_component.isPathComponent(t)) return CaskError.ParseFailed,
                        else => {},
                    };
                },
                else => {},
            };
        };
    }
}

fn firstArtifactArray(obj: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const artifacts_val = obj.get("artifacts") orelse return null;
    const artifacts = switch (artifacts_val) {
        .array => |a| a,
        else => return null,
    };
    for (artifacts.items) |item| {
        switch (item) {
            .object => |art_obj| {
                if (art_obj.get(key)) |val| {
                    switch (val) {
                        .array => |arr| return arr,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

/// CaskInstaller — handles DMG, ZIP, and PKG cask installations.
pub const CaskInstaller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    prefix: [:0]const u8,
    db: *sqlite.Database,
    progress: ?client_mod.ProgressCallback,
    /// Pre-resolved type for extensionless URLs (HEAD fallback).
    artifact_type_override: ?ArtifactType = null,
    /// Font stanzas to place instead of parsing them from the cask JSON.
    /// Set by `reinstallFromHistory` from the per-version sidecar so a
    /// rollback's synthetic, artifact-less cask still restores its fonts.
    font_entries_override: ?[]const cask_font.FontEntry = null,
    /// Mirrors `ctx.offline` from the cli/ caller. Threaded onto the
    /// internal HttpClient so a download miss surfaces `OfflineRequired`
    /// instead of stalling on connect.
    offline: bool = false,

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, db: *sqlite.Database, prefix: [:0]const u8) CaskInstaller {
        return .{ .allocator = allocator, .io = io, .environ = environ, .db = db, .prefix = prefix, .progress = null };
    }

    /// Fetch + sha-verify the cask artefact into `<prefix>/cache/Cask/` and
    /// return the on-disk path. No `/Applications` writes, no DB inserts —
    /// the seam `mt install --download-only --cask <token>` reuses to warm
    /// the cache before going offline. Caller owns the returned slice.
    pub fn downloadOnly(self: *CaskInstaller, cask: *const Cask) CaskError![]const u8 {
        const artifact_type = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        if (artifact_type == .unknown) return CaskError.InstallFailed;

        var cache_buf: [512]u8 = undefined;
        const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/cache/Cask", .{self.prefix}) catch
            return CaskError.OutOfMemory;
        std.Io.Dir.createDirAbsolute(self.io, cache_dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return CaskError.InstallFailed,
        };

        const cache_path = self.downloadToCache(cask, cache_dir, self.progress) catch |e| switch (e) {
            // A retry re-fetches the same manifest and refuses identically, so
            // this must not reach the user wearing a transient error's name.
            error.InsecureUrlScheme => return CaskError.InsecureOrigin,
            error.WatchdogSpawnFailed => return CaskError.DownloadLocalResourceExhausted,
            else => return CaskError.DownloadFailed,
        };
        errdefer {
            std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
            self.allocator.free(cache_path);
        }

        self.verifySha256(cache_path, cask.sha256) catch |e| switch (e) {
            // A retry re-downloads and fails identically, so it must not
            // reach the caller wearing the transient error's name.
            error.Sha256Missing => return CaskError.Sha256Missing,
            else => return CaskError.Sha256Mismatch,
        };

        return cache_path;
    }

    /// Install a cask. Downloads, verifies SHA256, and installs based on artifact type.
    /// Returns the installed app path on success.
    pub fn install(self: *CaskInstaller, cask: *const Cask) CaskError![]const u8 {
        const artifact_type = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        if (artifact_type == .unknown) return CaskError.InstallFailed;

        const cache_path = try self.downloadOnly(cask);
        errdefer {
            std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
            self.allocator.free(cache_path);
        }

        // Determine target: prefix-aware sandbox / /Applications / ~/Applications.
        var app_dir_buf: [512]u8 = undefined;
        const app_dir = applicationsDir(self.io, self.environ, self.prefix, &app_dir_buf);

        // Install based on type
        const app_path = switch (artifact_type) {
            .dmg => self.installDmg(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .zip => self.installZip(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .pkg => self.installPkg(cache_path) catch return CaskError.InstallFailed,
            .tar_gz, .tar_xz => self.installTarball(cache_path, app_dir, cask, artifact_type) catch return CaskError.InstallFailed,
            .unknown => return CaskError.InstallFailed,
        };

        // Caskroom dir is bookkeeping; app is already in place.
        self.recordCaskroom(cask) catch {};

        // History row for `mt rollback <cask> --list / --to`. Best-effort:
        // a failed history insert must not undo a successful install.
        recordCaskVersion(
            self.db,
            cask.token,
            cask.version,
            cask.url,
            cask.sha256,
            artifactTypeTag(artifact_type),
            cache_path,
        ) catch {};

        // Clean up cache file (keep for uninstall/upgrade reference if desired)
        // We keep the cache file so reinstalls are faster.

        self.allocator.free(cache_path);
        return app_path;
    }

    /// Uninstall a cask by token. Looks up app_path from DB, removes app, cleans up.
    /// `removeRecord` propagates its SQLite failure so the CLI caller can
    /// log `db.errMsg()` instead of marking a half-cleaned DB as success.
    pub fn uninstall(self: *CaskInstaller, token: []const u8) UninstallError!void {
        // Copy app_path out of SQLite-owned memory and finalize the SELECT
        // before any later DB op. Otherwise the SELECT's deferred finalize
        // runs *after* `removeRecord` fails and resets `db.errMsg()` to
        // "not an error", blanking the message the caller wants to log.
        var app_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var app_path_len: usize = 0;
        {
            var stmt = self.db.prepare(
                "SELECT app_path FROM casks WHERE token = ?1 LIMIT 1;",
            ) catch return CaskError.UninstallFailed;
            defer stmt.finalize();
            stmt.bindText(1, token) catch return CaskError.UninstallFailed;

            const found = stmt.step() catch return CaskError.UninstallFailed;
            if (!found) return CaskError.UninstallFailed;

            if (stmt.columnText(0)) |p| {
                // sqlite3_column_text returns a null-terminated UTF-8 string per
                // the SQLite C API contract. There is an inherent TOCTOU window
                // between this read and the `deleteTree` below — accepted
                // because cask uninstall is a single-user operation and the
                // bundle is protected by filesystem permissions.
                const slice = std.mem.sliceTo(p, 0);
                app_path_len = @min(slice.len, app_path_buf.len);
                @memcpy(app_path_buf[0..app_path_len], slice[0..app_path_len]);
            }
        }

        if (app_path_len > 0) {
            const app_path = app_path_buf[0..app_path_len];

            if (std.mem.eql(u8, std.fs.path.basename(app_path), cask_font.MANIFEST_NAME)) {
                // Font cask: app_path is the manifest, not a removable bundle.
                // Unlink each placed font; the Caskroom wipe below removes the
                // manifest itself.
                self.removeManifestedFonts(app_path);
            } else {
                // Refuse while the app is live: removing the old bundle would
                // yank a running app. Distinct error so the caller can say so.
                if (isAppRunning(self.io, app_path)) return CaskError.AppRunning;

                // app may already be gone (manual delete); continue to DB cleanup.
                std.Io.Dir.cwd().deleteTree(self.io, app_path) catch {};
            }
        }

        // Caskroom bookkeeping; continue so later removals still run.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}", .{ self.prefix, token }) catch "";
        if (caskroom_path.len > 0) std.Io.Dir.cwd().deleteTree(self.io, caskroom_path) catch {};

        // Clean up cached artefacts. Two name shapes coexist: the legacy
        // `<token>.<ext>` and the per-version `<token>-<version>.<ext>`
        // shape that retains rollback targets. Wipe both for `uninstall`,
        // since after uninstall there is no version left to roll back to.
        var cache_buf: [512]u8 = undefined;
        for (cache_extensions) |ext| {
            const cache_file = std.fmt.bufPrint(&cache_buf, "{s}/cache/Cask/{s}{s}", .{ self.prefix, token, ext }) catch continue;
            std.Io.Dir.cwd().deleteFile(self.io, cache_file) catch {};
        }
        // Must precede the history wipe below — the sweep reads the version
        // list from `cask_versions`, which the DELETE would otherwise empty.
        sweepOwnedVersionCache(self.io, self.db, self.prefix, token);

        // Drop every history row so a future install starts clean.
        if (self.db.prepare("DELETE FROM cask_versions WHERE token = ?1;")) |prepared| {
            var hist_stmt = prepared;
            defer hist_stmt.finalize();
            hist_stmt.bindText(1, token) catch {};
            _ = hist_stmt.step() catch false;
        } else |_| {}

        // DB row cleanup. User-visible work is done; surfacing the
        // failure lets the CLI caller log `db.errMsg()` instead of
        // silently leaving the row behind.
        try removeRecord(self.db, token);
    }

    /// Unlink every font recorded in the `.malt-fonts` manifest at
    /// `manifest_path`. Best-effort by contract: a missing manifest (manual
    /// Caskroom deletion) reads as empty and an already-removed font unlinks
    /// as a no-op, so uninstall always proceeds to DB cleanup. The manifest
    /// file itself is left for the caller's Caskroom wipe to remove.
    fn removeManifestedFonts(self: *CaskInstaller, manifest_path: []const u8) void {
        // A read error (e.g. permissions) leaves the fonts in place rather
        // than aborting uninstall — drift is recoverable, a stuck row is not.
        const bytes = cask_font.readManifest(self.io, self.allocator, manifest_path) catch return;
        defer self.allocator.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            // Stale entry (font already gone) is a no-op; never abort here.
            std.Io.Dir.deleteFileAbsolute(self.io, line) catch {};
        }
    }

    /// Reinstall a previously-installed cask version from history. Drives
    /// the same `install` pipeline used for fresh installs, but sources
    /// (url, sha256, artifact_type) come from the `cask_versions` row
    /// instead of an API parse. Uses the cached artefact when present;
    /// otherwise re-downloads from the recorded URL.
    pub fn reinstallFromHistory(
        self: *CaskInstaller,
        token: []const u8,
        target_version: []const u8,
    ) CaskError!void {
        const row_opt = lookupCaskVersion(self.allocator, self.db, token, target_version) catch
            return CaskError.InstallFailed;
        var row = row_opt orelse return CaskError.InstallFailed;
        defer row.deinit(self.allocator);

        // Refuse if the recorded artifact type isn't one this binary can
        // install — silently picking `.unknown` would land an empty
        // install and corrupt the rollback contract.
        const at = artifactTypeFromTag(row.artifact_type);
        if (at == .unknown) return CaskError.InstallFailed;
        self.artifact_type_override = at;
        defer self.artifact_type_override = null;

        // Preserve `auto_updates` + owning `tap` across the rollback so
        // a held cask doesn't silently regress to install defaults. The
        // keg path gets the same guarantee on `pinned` via the COALESCE
        // inside recordInstall; cask fields aren't COALESCE-able from
        // there because install/upgrade legitimately overwrite them.
        var meta = readReinstallMeta(self.allocator, self.db, token) catch
            return CaskError.InstallFailed;
        defer meta.deinit(self.allocator);

        // Parse "{}" so the synthetic Cask carries a valid (empty)
        // ObjectMap — `parseAppName` falls through to `findAppInDir`,
        // which is the same fallback shape used for any cask whose API
        // payload didn't ship an explicit `app:` artifact. The Parsed
        // value owns its own arena; one `deinit` releases everything.
        var parsed_empty = std.json.parseFromSlice(std.json.Value, self.allocator, "{}", .{}) catch
            return CaskError.OutOfMemory;
        defer parsed_empty.deinit();

        const synthetic: Cask = .{
            .token = row.token,
            .name = row.token,
            .version = row.version,
            .desc = "",
            .homepage = "",
            .url = row.url,
            .sha256 = if (row.sha256) |s| s else null,
            .auto_updates = meta.auto_updates,
            .parsed = parsed_empty,
        };

        // Re-source font stanzas for this version from the sidecar: the
        // synthetic cask carries no artifacts, so without this a font cask
        // would fall through to the .app path and fail. Non-font casks have no
        // sidecar — the override stays null and behaviour is unchanged. A read
        // error degrades to "no override" (a font cask then fails loud at the
        // .app path); it never aborts the rollback before the install attempt.
        var spec_opt = self.readFontSpec(row.token, row.version) catch null;
        defer if (spec_opt) |*s| s.deinit(self.allocator);
        if (spec_opt) |*s| self.font_entries_override = s.entries;
        defer self.font_entries_override = null;

        const app_path = try self.install(&synthetic);
        defer self.allocator.free(app_path);

        // Flip the `casks` row to the rolled-back version. `pinned`
        // survives via recordInstall's COALESCE; `auto_updates` and
        // `tap` survive via the preserved values above.
        recordInstall(self.db, &synthetic, app_path, meta.tap) catch return CaskError.InstallFailed;
    }

    /// Check installed version vs API version. Returns true if outdated.
    /// SQLite errors flow up as `SqliteError` so the caller can log
    /// `db.errMsg()` instead of silently treating a broken row as fresh.
    pub fn isOutdated(
        self: *CaskInstaller,
        token: []const u8,
        latest_version: []const u8,
    ) sqlite.SqliteError!bool {
        var stmt = try self.db.prepare(
            "SELECT version FROM casks WHERE token = ?1 LIMIT 1;",
        );
        defer stmt.finalize();
        try stmt.bindText(1, token);

        const found = try stmt.step();
        if (!found) return false;

        // SQLite NULL in `version` is structurally impossible (NOT NULL
        // column); treat the absent pointer as "no installed row" so the
        // caller's not-outdated default still kicks in for that one case.
        const ver_ptr = stmt.columnText(0) orelse return false;
        const installed = std.mem.sliceTo(ver_ptr, 0);
        return !std.mem.eql(u8, installed, latest_version);
    }

    // --- Private helpers ---

    fn downloadToCache(self: *CaskInstaller, cask: *const Cask, cache_dir: []const u8, progress: ?client_mod.ProgressCallback) ![]const u8 {
        const resolved = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        const ext_str = artifactExtension(resolved);
        // Per-version filename so older versions' artefacts survive a
        // newer install — `mt rollback <cask> --to <ver>` reaches for
        // the cached file at `<token>-<version>.<ext>` before falling
        // back to a fresh download.
        const dest = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{s}{s}", .{ cache_dir, cask.token, cask.version, ext_str });
        errdefer self.allocator.free(dest);

        // Download via HTTP client
        var http = client_mod.HttpClient.init(self.io, self.environ, self.allocator);
        defer http.deinit();
        http.offline = self.offline;

        var resp = try http.getWithHeaders(cask.url, &.{}, progress, artifactIntegrity(cask.sha256));
        defer resp.deinit();

        if (resp.status != 200) return error.DownloadFailed;

        // Write to file
        const file = try std.Io.Dir.createFileAbsolute(self.io, dest, .{});
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, resp.body);

        return dest;
    }

    fn verifySha256(self: *CaskInstaller, file_path: []const u8, expected: ?[]const u8) !void {
        return verifyFileSha256(self.io, file_path, expected);
    }

    /// A private directory under `<prefix>/tmp` that cannot have been planted:
    /// the name carries OS entropy and creation is exclusive, so an existing
    /// path is an error rather than something to adopt. `buf` owns the result.
    fn freshTempDir(self: *CaskInstaller, buf: []u8, kind: []const u8, token: []const u8) ![]const u8 {
        var nonce: [16]u8 = undefined;
        self.io.randomSecure(&nonce) catch return error.InstallFailed;
        const path = std.fmt.bufPrint(buf, "{s}/tmp/cask_{s}_{s}_{s}", .{
            self.prefix, kind, token, std.fmt.bytesToHex(nonce, .lower),
        }) catch return error.InstallFailed;
        std.Io.Dir.createDirAbsolute(self.io, path, std.Io.File.Permissions.fromMode(0o700)) catch
            return error.InstallFailed;
        return path;
    }

    fn installDmg(self: *CaskInstaller, dmg_path: []const u8, app_dir: []const u8, cask: *const Cask) ![]const u8 {
        // A token-derived path is guessable, so it can be planted and then
        // adopted - mounted over, and removed on teardown.
        var mount_buf: [512]u8 = undefined;
        const mount_point = try self.freshTempDir(&mount_buf, "mount", cask.token);

        // Mount DMG (hdiutil attach -nobrowse -readonly -mountpoint {path} {dmg})
        const mount_argv = [_][]const u8{
            system_tools.hdiutil, "attach",
            "-nobrowse",          "-readonly",
            "-mountpoint",        mount_point,
            dmg_path,
        };
        child_mod.runOrFail(self.io, self.allocator, &mount_argv) catch return error.InstallFailed;

        // Unmount on any exit; kernel reaps stuck mounts on reboot if both fail.
        defer {
            const detach_argv = [_][]const u8{ system_tools.hdiutil, "detach", mount_point, "-quiet" };
            child_mod.runOrFail(self.io, self.allocator, &detach_argv) catch {};
            std.Io.Dir.deleteDirAbsolute(self.io, mount_point) catch {};
        }

        // Find the .app bundle name (from JSON artifacts or by scanning mount point).
        // app_name_buf owns the fallback name past iterator teardown.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(self.io, mount_point, &app_name_buf) orelse
            return error.InstallFailed;

        // Source and destination paths
        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ mount_point, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present (fresh install).
        std.Io.Dir.cwd().deleteTree(self.io, dst_app) catch {};

        // Copy .app bundle using ditto (preserves resource forks, xattrs)
        const ditto_argv = [_][]const u8{ system_tools.ditto, src_app, dst_app };
        child_mod.runOrFail(self.io, self.allocator, &ditto_argv) catch return error.InstallFailed;

        return dst_app;
    }

    fn installZip(self: *CaskInstaller, zip_path: []const u8, app_dir: []const u8, cask: *const Cask) ![]const u8 {
        // A token-derived path is guessable, so it can be planted and then
        // extracted through.
        var tmp_buf: [512]u8 = undefined;
        const extract_dir = try self.freshTempDir(&tmp_buf, "extract", cask.token);
        // temp extract dir; leftover tolerated if teardown races.
        defer std.Io.Dir.cwd().deleteTree(self.io, extract_dir) catch {};

        // Hold the directory itself and make it the child's cwd. `fchdir`
        // anchors ditto to the created inode, closing the check/use gap that a
        // later pathname replacement would otherwise reopen.
        const extract_handle = std.Io.Dir.openDirAbsolute(self.io, extract_dir, .{
            .follow_symlinks = false,
        }) catch return error.InstallFailed;
        defer extract_handle.close(self.io);

        // Extract with ditto -xk (handles macOS-specific ZIP features).
        const ditto_argv = [_][]const u8{ system_tools.ditto, "-xk", zip_path, "." };
        child_mod.runOrFailInDir(self.io, self.allocator, &ditto_argv, extract_handle) catch
            return error.InstallFailed;

        return self.placeExtracted(extract_dir, app_dir, cask);
    }

    /// Dispatch a freshly-extracted zip to its placement strategy. Public so
    /// the dispatch is exercisable in tests without driving ditto extraction
    /// or the network. Returns the path recorded as `app_path`.
    pub fn placeExtracted(self: *CaskInstaller, extract_dir: []const u8, app_dir: []const u8, cask: *const Cask) ![]const u8 {
        // Rollback re-sources the stanzas via this override (the synthetic
        // cask's JSON is empty); a fresh install collects them from the JSON.
        if (self.font_entries_override) |entries| {
            return self.installFontArtifacts(extract_dir, cask, entries);
        }

        // Font casks carry one `font` stanza per file and no `.app`; route
        // them to the leaf before the .app demand below. Everything else
        // falls through to the unchanged bundle-promotion path.
        if (try cask_font.collectFontArtifacts(self.allocator, cask.parsed.value.object)) |entries| {
            defer self.allocator.free(entries);
            return self.installFontArtifacts(extract_dir, cask, entries);
        }

        // Find the .app. app_name_buf owns the fallback past iterator teardown.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(self.io, extract_dir, &app_name_buf) orelse
            return error.InstallFailed;

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ extract_dir, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present.
        std.Io.Dir.cwd().deleteTree(self.io, dst_app) catch {};

        // Move .app to /Applications
        const mv_argv = [_][]const u8{ system_tools.ditto, src_app, dst_app };
        child_mod.runOrFail(self.io, self.allocator, &mv_argv) catch return error.InstallFailed;

        return dst_app;
    }

    /// Font branch of the zip dispatch. Wires the installer's environ,
    /// prefix, and Caskroom layout to the leaf, which owns all font-
    /// specific policy (destination, sanitization, manifest format).
    /// Places every artifact, persists the placed-paths manifest under
    /// `Caskroom/<token>/<version>/`, and returns that manifest path —
    /// recorded as `app_path` so uninstall reads it back. Caller owns the
    /// returned slice.
    fn installFontArtifacts(
        self: *CaskInstaller,
        extract_dir: []const u8,
        cask: *const Cask,
        entries: []const cask_font.FontEntry,
    ) ![]const u8 {
        var fonts_buf: [512]u8 = undefined;
        const env_home = std.process.Environ.getPosix(self.environ, "HOME");
        const fonts_dir = cask_font.resolveFontsDir(self.prefix, env_home, &fonts_buf);

        const manifest = try cask_font.placeFonts(self.io, self.allocator, extract_dir, fonts_dir, entries);
        defer self.allocator.free(manifest);

        // Create Caskroom/<token>/<version>/ before the manifest write,
        // mirroring recordCaskroom's ordering.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return error.InstallFailed;

        const manifest_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ caskroom_ver, cask_font.MANIFEST_NAME });
        errdefer self.allocator.free(manifest_path);
        try cask_font.writeManifest(self.io, manifest_path, manifest);

        // Persist the stanzas next to the cached artifact so a later rollback
        // restores them offline. Best-effort: a failed sidecar only degrades a
        // future rollback, never this install (as with recordCaskVersion).
        self.writeFontSpec(cask.token, cask.version, entries) catch {};

        return manifest_path;
    }

    /// Per-version sidecar of the placed font stanzas, co-located with the
    /// cached artifact at `<prefix>/cache/Cask/<token>-<version>.fonts`. It
    /// lets `reinstallFromHistory` re-place fonts offline without the cask
    /// JSON, which the synthetic rollback cask lacks. Format: one
    /// `source\ttarget` line per stanza; a tab-less line has no rename target.
    /// Sanitization still runs in the leaf at placement, so the persisted
    /// strings are re-validated there rather than trusted here.
    pub const FontSpec = struct {
        bytes: []u8,
        entries: []cask_font.FontEntry,

        pub fn deinit(self: *FontSpec, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
            allocator.free(self.bytes);
        }
    };

    fn fontSpecPath(self: *CaskInstaller, token: []const u8, version: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/cache/Cask/{s}-{s}.fonts", .{ self.prefix, token, version });
    }

    fn writeFontSpec(self: *CaskInstaller, token: []const u8, version: []const u8, entries: []const cask_font.FontEntry) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.fontSpecPath(token, version, &path_buf);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        for (entries) |e| {
            try bytes.appendSlice(self.allocator, e.source);
            if (e.target) |t| {
                try bytes.append(self.allocator, '\t');
                try bytes.appendSlice(self.allocator, t);
            }
            try bytes.append(self.allocator, '\n');
        }

        if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(self.io, dir);
        const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{ .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, bytes.items);
    }

    /// Read the sidecar for `(token, version)`, or null when none was written
    /// (a non-font cask, or a pre-sidecar install). Entries borrow the
    /// returned `bytes`; free both via `FontSpec.deinit`.
    pub fn readFontSpec(self: *CaskInstaller, token: []const u8, version: []const u8) !?FontSpec {
        var path_buf: [512]u8 = undefined;
        const path = try self.fontSpecPath(token, version, &path_buf);

        const file = std.Io.Dir.openFileAbsolute(self.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        defer file.close(self.io);

        const stat = try file.stat(self.io);
        const bytes = try self.allocator.alloc(u8, stat.size);
        errdefer self.allocator.free(bytes);
        const n = try file.readPositionalAll(self.io, bytes, 0);
        const data = bytes[0..n];

        var count: usize = 0;
        var counter = std.mem.splitScalar(u8, data, '\n');
        while (counter.next()) |line| {
            if (line.len != 0) count += 1;
        }

        const entries = try self.allocator.alloc(cask_font.FontEntry, count);
        errdefer self.allocator.free(entries);

        var i: usize = 0;
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.indexOfScalar(u8, line, '\t')) |t| {
                entries[i] = .{ .source = line[0..t], .target = line[t + 1 ..] };
            } else {
                entries[i] = .{ .source = line, .target = null };
            }
            i += 1;
        }

        return .{ .bytes = bytes, .entries = entries };
    }

    /// Install a tarball cask. Two shapes are supported:
    ///   1. `binary` artifacts — extract into `Caskroom/<token>/<version>/`
    ///      and symlink the first `binary` entry into `<prefix>/bin/`.
    ///   2. `app` artifacts — extract and promote the `.app` to `app_dir`,
    ///      mirroring the zip path for the rare tarball-wrapped bundle.
    ///
    /// Only the decompressor differs between gzip and xz; everything after
    /// extraction is identical, so both share this path.
    ///
    /// Returns the bin symlink for binary casks, the `.app` path for app
    /// casks — whichever the uninstaller needs to remove later.
    fn installTarball(
        self: *CaskInstaller,
        archive_path: []const u8,
        app_dir: []const u8,
        cask: *const Cask,
        artifact_type: ArtifactType,
    ) ![]const u8 {
        // Caskroom/<token>/<version>/ doubles as the extraction root so
        // the extracted payload is already at its final home — binaries
        // then just need a stable symlink off `<prefix>/bin/`.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return error.InstallFailed;
        std.Io.Dir.cwd().createDirPath(self.io, caskroom_ver) catch return error.InstallFailed;

        (switch (artifact_type) {
            .tar_gz => archive_mod.extractTarGz(self.io, archive_path, caskroom_ver),
            .tar_xz => archive_mod.extractTarXzFile(self.io, archive_path, caskroom_ver),
            else => return error.InstallFailed,
        }) catch return error.InstallFailed;

        // Same precedence as the zip dispatch: fonts first (they carry no
        // `.app` and no `binary`), then binaries, then a wrapped bundle.
        if (self.font_entries_override) |entries| {
            return self.installFontArtifacts(caskroom_ver, cask, entries);
        }
        if (try cask_font.collectFontArtifacts(self.allocator, cask.parsed.value.object)) |entries| {
            defer self.allocator.free(entries);
            return self.installFontArtifacts(caskroom_ver, cask, entries);
        }

        if (parseBinaryName(cask.parsed.value.object)) |src_name| {
            const link_name = parseBinaryTarget(cask.parsed.value.object) orelse
                std.fs.path.basename(src_name);
            return try self.linkCaskBinary(caskroom_ver, src_name, link_name);
        }

        // Fallback: .app inside a tar.gz (uncommon but valid). Reuse the
        // zip path's "promote .app to app_dir" shape.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(self.io, caskroom_ver, &app_name_buf) orelse
            return error.InstallFailed;

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ caskroom_ver, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present.
        std.Io.Dir.cwd().deleteTree(self.io, dst_app) catch {};
        const mv_argv = [_][]const u8{ system_tools.ditto, src_app, dst_app };
        child_mod.runOrFail(self.io, self.allocator, &mv_argv) catch return error.InstallFailed;
        return dst_app;
    }

    /// Resolve the source path of a `binary` artifact. Three shapes
    /// appear in the wild:
    ///   - Bare name (`copilot`) — walk the extraction tree.
    ///   - Relative path (`darwin-arm64/btp`) — join to the extraction
    ///     root; matches the `Caskroom/<token>/<version>/` layout.
    ///   - Homebrew `$HOMEBREW_PREFIX/...` absolute path — rewrite the
    ///     prefix to malt's active one; the tail already points at the
    ///     extracted file since Caskroom lives under the prefix.
    /// Returned slice is owned by the caller.
    fn resolveCaskBinaryPath(self: *CaskInstaller, root: []const u8, src: []const u8) ![]u8 {
        const env_prefix = "$HOMEBREW_PREFIX/";
        if (std.mem.startsWith(u8, src, env_prefix)) {
            const rel = src[env_prefix.len..];
            // Second line of defence: `parseCask` already screened this, but the
            // resolved path is opened read-write and chmod 0755'd, so the sink
            // does not lean on an upstream guard.
            if (!path_component.isRelativeSubpath(rel)) return error.InstallFailed;
            return try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.prefix, rel },
            );
        }
        if (std.mem.indexOfScalar(u8, src, '/') != null) {
            if (!path_component.isRelativeSubpath(src)) return error.InstallFailed;
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, src });
        }
        return (findFileInTree(self.io, self.allocator, root, src) catch null) orelse
            error.InstallFailed;
    }

    /// Resolve `src_name` inside `caskroom_ver`, chmod +x, and symlink
    /// it at `<prefix>/bin/<link_name>`. `src_name` and `link_name`
    /// diverge when the cask uses the `binary [..., {target: ...}]`
    /// rename form. Returns the symlink path — stored as `app_path` so
    /// `uninstall` knows what to remove.
    fn linkCaskBinary(
        self: *CaskInstaller,
        caskroom_ver: []const u8,
        src_name: []const u8,
        link_name: []const u8,
    ) ![]const u8 {
        const candidate = try self.resolveCaskBinaryPath(caskroom_ver, src_name);
        defer self.allocator.free(candidate);

        var source = confined_source.openFile(
            self.io,
            self.allocator,
            caskroom_ver,
            candidate,
            .read_write,
        ) catch return error.InstallFailed;
        defer source.deinit(self.io);

        // Archives sometimes land without the x-bit when built on CI.
        // chmod may fail on FUSE/NFS mounts; symlink still works if bit was set.
        source.file.setPermissions(self.io, std.Io.File.Permissions.fromMode(0o755)) catch {};

        // The link name is one entry in `<prefix>/bin`; a `target` carrying a
        // separator would delete and re-create somewhere else entirely.
        if (!path_component.isPathComponent(link_name)) return error.InstallFailed;

        var bin_parent_buf: [512]u8 = undefined;
        const bin_parent = std.fmt.bufPrint(&bin_parent_buf, "{s}/bin", .{self.prefix}) catch
            return error.InstallFailed;
        std.Io.Dir.cwd().createDirPath(self.io, bin_parent) catch return error.InstallFailed;

        const link_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ bin_parent, link_name });
        errdefer self.allocator.free(link_path);

        // stale link may not exist (fresh install); symLink below is authoritative.
        std.Io.Dir.cwd().deleteFile(self.io, link_path) catch {};
        std.Io.Dir.symLinkAbsolute(self.io, source.path, link_path, .{}) catch return error.InstallFailed;
        return link_path;
    }

    fn installPkg(self: *CaskInstaller, pkg_path: []const u8) ![]const u8 {
        // The CLI gate already refused off a TTY and took the user's
        // confirmation, so sudo here has a terminal to prompt on. Inherit
        // stdio (not the captured `run`) so the password prompt and the
        // installer's progress reach the user live, not as a post-mortem dump.
        const argv = [_][]const u8{ system_tools.sudo, system_tools.installer, "-pkg", pkg_path, "-target", "/" };
        child_mod.runOrFailInherit(self.io, &argv) catch return error.InstallFailed;
        // PKG installs don't have a single app path — record the pkg location
        return std.fmt.allocPrint(self.allocator, "{s}", .{pkg_path}) catch return error.OutOfMemory;
    }

    /// Public wrapper for isAppRunning (used by uninstall.zig).
    pub fn isAppRunningPub(io: std.Io, app_path: []const u8) bool {
        return isAppRunning(io, app_path);
    }

    fn recordCaskroom(self: *CaskInstaller, cask: *const Cask) !void {
        // Create Caskroom/{token}/{version}/ to match Homebrew layout
        var buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return;
        // Caskroom dir is cosmetic bookkeeping; install already recorded in DB.
        std.Io.Dir.cwd().createDirPath(self.io, caskroom_ver) catch {};
    }
};

/// Walk `root` looking for a regular file whose basename equals `name`
/// and return its absolute path (owned by the caller). tar.gz archives
/// often nest the binary one or two levels deep, so the installer can't
/// assume it sits at the extraction root. Returns null on no match.
pub fn findFileInTree(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), name)) continue;
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
    }
    return null;
}

/// Scan `dir_path` for a `.app` bundle and copy its name into `out_buf`.
/// Returns a slice of `out_buf` (owned by the caller) — the iterator's
/// internal entry buffer dies with the iterator, so the name must be
/// copied out before `dir.close()` fires. Returns null if no `.app`
/// exists, the directory can't be opened, or the name does not fit.
pub fn findAppInDir(io: std.Io, dir_path: []const u8, out_buf: []u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".app")) {
            if (entry.name.len > out_buf.len) return null;
            @memcpy(out_buf[0..entry.name.len], entry.name);
            return out_buf[0..entry.name.len];
        }
    }
    return null;
}

/// Compute the SHA256 of `file_path` as lowercase hex. Delegates to
/// the shared streaming helper so the chunk loop and buffer size are
/// defined in exactly one place.
pub fn hashFileSha256(io: std.Io, file_path: []const u8) ![64]u8 {
    return hash_mod.hashFileSha256Hex(io, file_path);
}

/// Verify `file_path` hashes to `expected` (lowercase hex). The literal
/// `"no_check"` skips verification — Homebrew's escape hatch for casks that
/// cannot be pinned (auto-updating installers).
///
/// An *absent* hash is not that escape hatch. Homebrew always emits `sha256`
/// for a cask, so a null here means a malformed or hostile manifest; treating
/// it as "verified" would silently drop every cask to transport-only integrity,
/// and `installPkg` hands the result to `sudo installer -target /`.
pub fn verifyFileSha256(io: std.Io, file_path: []const u8, expected: ?[]const u8) !void {
    const expected_hash = expected orelse return error.Sha256Missing;
    if (std.mem.eql(u8, expected_hash, "no_check")) return;

    const got = try hashFileSha256(io, file_path);
    // Cask manifest SHAs are public: constant-time here is for uniformity
    // across malt's SHA paths, not to close a live oracle.
    if (!hash_mod.eqlHex256(got, expected_hash)) return error.Sha256Mismatch;
}

/// What backs a cask's artifact once it is off the wire — the mirror image of
/// `verifyFileSha256`, decided before the fetch instead of after it.
///
/// Only the casks that hash-verify nothing are left leaning on the transport,
/// and those are the only ones a cleartext origin actually endangers.
pub fn artifactIntegrity(sha256: ?[]const u8) client_mod.Integrity {
    const h = sha256 orelse return .transport_only;
    if (std.mem.eql(u8, h, "no_check")) return .transport_only;
    return .digest_pinned;
}

test "artifactIntegrity: only an opted-out or absent digest falls back to the transport" {
    // The split has to track `verifyFileSha256` exactly: a cask that will be
    // hash-checked gains nothing from refusing http, and one that will not is
    // the whole reason the rule exists.
    try std.testing.expectEqual(client_mod.Integrity.transport_only, artifactIntegrity(null));
    try std.testing.expectEqual(client_mod.Integrity.transport_only, artifactIntegrity("no_check"));
    try std.testing.expectEqual(
        client_mod.Integrity.digest_pinned,
        artifactIntegrity("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    );
}

/// ERE metacharacters, which a bundle name may legitimately contain.
const ere_meta = "\\.[]()*+?{}|^$";

/// Quote `app_path` into a `pgrep -f` pattern: it must match the app's own argv but
/// never the literal path, since every probe carries the pattern in its own command
/// line and would otherwise read a racing probe as the app running. Null if it does
/// not fit `buf`.
pub fn pgrepPattern(buf: []u8, app_path: []const u8) ?[]const u8 {
    if (app_path.len == 0) return null;
    var w: std.Io.Writer = .fixed(buf); // a short path only overruns on absurd input
    if (std.mem.indexOfAny(u8, app_path, ere_meta) != null) {
        for (app_path) |c| {
            if (std.mem.indexOfScalar(u8, ere_meta, c) != null) w.writeByte('\\') catch return null;
            w.writeByte(c) catch return null;
        }
    } else {
        // Nothing to quote, so the pattern still reads as itself: class the first byte.
        w.print("[{c}]{s}", .{ app_path[0], app_path[1..] }) catch return null;
    }
    return w.buffered();
}

/// Check if an application is currently running by its path.
fn isAppRunning(io: std.Io, app_path: []const u8) bool {
    // pgrep -f reads its pattern as a regex over every process's whole command line.
    var pat_buf: [std.Io.Dir.max_path_bytes * 2 + 2]u8 = undefined;
    const pattern = pgrepPattern(&pat_buf, app_path) orelse return false;
    const argv = [_][]const u8{ system_tools.pgrep, "-f", pattern };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .exited => |code| code == 0, // pgrep exits 0 if match found
        .signal, .stopped, .unknown => false,
    };
}

/// True iff `prefix` is one of the well-known default install roots.
/// These keep the legacy system `/Applications` behavior; anything else
/// is treated as a sandbox and routes casks under the prefix.
pub fn isDefaultPrefix(prefix: []const u8) bool {
    const trimmed = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else
        prefix;
    return std.mem.eql(u8, trimmed, "/opt/malt") or
        std.mem.eql(u8, trimmed, "/opt/homebrew");
}

/// Pure resolver for "where do cask `.app` bundles go?" — split from
/// the FS-touching wrapper so the policy is unit-testable. Priority:
///   1. `MALT_APPDIR` env override (caller passes the value).
///   2. Non-default prefix → `<prefix>/Applications` (sandboxed).
///   3. Default prefix + writable system `/Applications` → `/Applications`.
///   4. Default prefix + per-user `HOME` → `<HOME>/Applications`.
///   5. Last resort → `/Applications` so a misconfigured host fails loudly.
pub fn resolveAppDir(
    prefix: []const u8,
    env_appdir: ?[]const u8,
    env_home: ?[]const u8,
    system_writable: bool,
    out: []u8,
) []const u8 {
    if (env_appdir) |dir| {
        const slice = std.mem.sliceTo(dir, 0);
        if (slice.len > 0 and slice.len <= out.len) {
            @memcpy(out[0..slice.len], slice);
            return out[0..slice.len];
        }
    }
    if (!isDefaultPrefix(prefix)) {
        return std.fmt.bufPrint(out, "{s}/Applications", .{prefix}) catch "/Applications";
    }
    if (system_writable) return "/Applications";
    if (env_home) |home| {
        const home_slice = std.mem.sliceTo(home, 0);
        return std.fmt.bufPrint(out, "{s}/Applications", .{home_slice}) catch "/Applications";
    }
    return "/Applications";
}

/// Determine the applications directory honouring `MALT_PREFIX`. Wraps
/// `resolveAppDir` with the env probes and an mkdir on the chosen path
/// so `ditto`/`unzip` can write there immediately. The caller owns `out`;
/// the returned slice is either a compile-time literal or a slice of `out`.
fn applicationsDir(io: std.Io, environ: std.process.Environ, prefix: []const u8, out: []u8) []const u8 {
    const env_appdir = std.process.Environ.getPosix(environ, "MALT_APPDIR");
    const env_home = std.process.Environ.getPosix(environ, "HOME");

    const test_path = "/Applications/.malt_write_test";
    const probe = std.Io.Dir.createFileAbsolute(io, test_path, .{});
    const system_writable = if (probe) |f| blk: {
        f.close(io);
        // probe file cleanup; leaving it behind would still be benign.
        std.Io.Dir.cwd().deleteFile(io, test_path) catch {};
        break :blk true;
    } else |_| false;

    const chosen = resolveAppDir(prefix, env_appdir, env_home, system_writable, out);

    // mkdir the chosen path unless it's the system /Applications (which
    // is a literal, not a slice of `out`, and either pre-exists or we
    // already proved it unwritable above).
    if (chosen.ptr != "/Applications".ptr) {
        std.Io.Dir.createDirAbsolute(io, chosen, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return "/Applications",
        };
    }
    return chosen;
}

/// Installed cask info with owned copies of strings.
pub const InstalledCask = struct {
    version_buf: [128]u8 = undefined,
    version_len: usize = 0,
    app_path_buf: [512]u8 = undefined,
    app_path_len: usize = 0,
    has_app_path: bool = false,
    tap_buf: [128]u8 = undefined,
    tap_len: usize = 0,
    has_tap: bool = false,

    pub fn version(self: *const InstalledCask) []const u8 {
        return self.version_buf[0..self.version_len];
    }

    pub fn appPath(self: *const InstalledCask) ?[]const u8 {
        if (!self.has_app_path) return null;
        return self.app_path_buf[0..self.app_path_len];
    }

    /// Owning tap label (`user/repo`) or null when the cask was
    /// installed from the core Homebrew API. Drives `mt upgrade`'s
    /// pre-routing decision — non-null skips the multi-tap probe loop.
    pub fn tap(self: *const InstalledCask) ?[]const u8 {
        if (!self.has_tap) return null;
        return self.tap_buf[0..self.tap_len];
    }
};

/// Look up installed cask info from DB. Copies data to avoid dangling pointers.
pub fn lookupInstalled(db: *sqlite.Database, token: []const u8) ?InstalledCask {
    var stmt = db.prepare(
        "SELECT version, app_path, tap FROM casks WHERE token = ?1 LIMIT 1;",
    ) catch return null;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return null;

    const found = stmt.step() catch return null;
    if (!found) return null;

    var result: InstalledCask = .{};

    const ver_ptr = stmt.columnText(0) orelse return null;
    const ver_slice = std.mem.sliceTo(ver_ptr, 0);
    if (ver_slice.len > result.version_buf.len) return null;
    @memcpy(result.version_buf[0..ver_slice.len], ver_slice);
    result.version_len = ver_slice.len;

    if (stmt.columnText(1)) |path_ptr| {
        const path_slice = std.mem.sliceTo(path_ptr, 0);
        if (path_slice.len <= result.app_path_buf.len) {
            @memcpy(result.app_path_buf[0..path_slice.len], path_slice);
            result.app_path_len = path_slice.len;
            result.has_app_path = true;
        }
    }

    if (stmt.columnText(2)) |tap_ptr| {
        const tap_slice = std.mem.sliceTo(tap_ptr, 0);
        if (tap_slice.len <= result.tap_buf.len) {
            @memcpy(result.tap_buf[0..tap_slice.len], tap_slice);
            result.tap_len = tap_slice.len;
            result.has_tap = true;
        }
    }

    return result;
}

/// Check if a cask is installed (by token).
pub fn isInstalled(db: *sqlite.Database, token: []const u8) bool {
    return lookupInstalled(db, token) != null;
}

// --- JSON helpers ---

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn getFirstName(obj: std.json.ObjectMap) ?[]const u8 {
    const val = obj.get("name") orelse return null;
    switch (val) {
        .array => |arr| {
            if (arr.items.len > 0) {
                return switch (arr.items[0]) {
                    .string => |s| s,
                    else => null,
                };
            }
            return null;
        },
        .string => |s| return s,
        else => return null,
    }
}

test "pgrepPattern escapes the dot every .app bundle carries" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/x/Running\\.app",
        pgrepPattern(&buf, "/tmp/x/Running.app").?,
    );
}

test "pgrepPattern quotes the metacharacters a bundle name can hold" {
    // An unquoted `Notepad++.app` is an invalid regex: pgrep errors out and the
    // running app reads as stopped.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/A/Notepad\\+\\+\\.app",
        pgrepPattern(&buf, "/A/Notepad++.app").?,
    );
    try std.testing.expectEqualStrings(
        "/A/Foo \\(2\\)\\.app",
        pgrepPattern(&buf, "/A/Foo (2).app").?,
    );
}

test "pgrepPattern classes the first byte when a path has nothing to quote" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("[/]tmp/plain", pgrepPattern(&buf, "/tmp/plain").?);
    try std.testing.expectEqualStrings("[x]", pgrepPattern(&buf, "x").?); // shortest path
}

test "pgrepPattern never yields the raw path, so a concurrent probe cannot match it" {
    // Each probe carries the pattern in its own argv; matching it would report the
    // app running whenever two uninstalls race.
    var buf: [64]u8 = undefined;
    for ([_][]const u8{ "/tmp/x/Running.app", "/tmp/plain" }) |path| // the second has nothing to escape
        try std.testing.expect(std.mem.indexOf(u8, pgrepPattern(&buf, path).?, path) == null);
}

test "pgrepPattern rejects an empty path and a buffer it would overrun" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(pgrepPattern(&buf, "") == null);
    var tiny: [4]u8 = undefined;
    try std.testing.expect(pgrepPattern(&tiny, "/tmp/x/Running.app") == null);
}

test "isAppRunning ignores a PATH-resident pgrep shim" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, "/tmp/malt_pgrep_shim_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const shim = try std.fmt.allocPrint(a, "{s}/pgrep", .{root});
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.symLinkAbsolute(io, "/usr/bin/true", shim, .{});

    const path_entry = try std.fmt.allocPrintSentinel(a, "PATH={s}", .{root}, 0);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .environ = environ });
    defer threaded.deinit();

    try std.testing.expect(!isAppRunning(threaded.io(), "/nonexistent/Malt-test-never-running.app"));
}

test "parseCask rejects a JSON root that is not an object" {
    const a = std.testing.allocator;
    // A mirror or a corrupted cache file can hand us any root shape. One entry
    // per `std.json.Value` tag: each was its own abort before the guard landed.
    const roots = [_][]const u8{ "[]", "\"x\"", "42", "1.5", "null", "true", "[{\"token\":\"ok\"}]" };
    for (roots) |json| {
        try std.testing.expectError(error.ParseFailed, parseCask(a, json));
    }
}

test "parseCask rejects path-traversal in token or version" {
    const a = std.testing.allocator;
    // Each carries a `/`, `..`, lone `.`, or NUL in `token` or `version` —
    // all of which become raw path segments downstream. The `\u0000`
    // sequences are JSON escapes the parser turns into real NUL bytes.
    const bad = [_][]const u8{
        \\{"token":"ev/../x","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"a/b","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"..","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":".","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"ok","version":"","url":"https://e/x.dmg"}
        ,
        \\{"token":"ok","version":"1.0/../../../../tmp/x","url":"https://e/x.dmg"}
        ,
        \\{"token":"a..b","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"ok","version":"a..b","url":"https://e/x.dmg"}
        ,
        \\{"token":"ok\u0000x","version":"1.0","url":"https://e/x.dmg"}
        ,
        \\{"token":"ok","version":"1.0\u0000","url":"https://e/x.dmg"}
        ,
    };
    for (bad) |json| {
        try std.testing.expectError(error.ParseFailed, parseCask(a, json));
    }
}

test "parseCask rejects path-traversal in an app artifact" {
    const a = std.testing.allocator;
    // `app` names are interpolated into `<app_dir>/<name>` and handed to
    // `deleteTree` before the copy runs, so a climbing name is a destructive
    // primitive for a hostile tap — reject it at the same choke point that
    // already screens token/version.
    const bad = [_][]const u8{
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["../Evil.app"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["../../../../Users/x/Documents"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["/Applications/Evil.app"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["Sub/../../Evil.app"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":[""]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["Evil\u0000.app"]}]}
        ,
    };
    for (bad) |json| {
        try std.testing.expectError(error.ParseFailed, parseCask(a, json));
    }
}

test "parseCask rejects path-traversal in a binary artifact" {
    const a = std.testing.allocator;
    // The `binary` source resolves under the keg and the `target` rename hint
    // becomes `<prefix>/bin/<target>` for a deleteFile + symlink pair. Both
    // escape their root if a `..` survives ingestion.
    const bad = [_][]const u8{
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["../../../etc/evil"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["/etc/passwd"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["tool",{"target":"../../../../Users/x/.zshenv"}]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["tool",{"target":"sub/tool"}]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["$HOMEBREW_PREFIX/../../etc/evil"]}]}
        ,
    };
    for (bad) |json| {
        try std.testing.expectError(error.ParseFailed, parseCask(a, json));
    }
}

test "an app artifact's target hint is ignored, so it never becomes a path" {
    const a = std.testing.allocator;
    // `binary` targets are screened because malt turns them into
    // `<prefix>/bin/<target>`. `app` targets are not screened because nothing
    // reads them — `parseAppName` takes the first string and stops. Pin that,
    // so the asymmetry stays a decision rather than looking like an oversight.
    const json =
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["Real.app",{"target":"../../../Evil.app"}]}]}
    ;
    var cask = try parseCask(a, json);
    defer cask.deinit();
    try std.testing.expectEqualStrings("Real.app", parseAppName(cask.parsed.value.object).?);
}

test "parseCask accepts the artifact shapes real casks use" {
    const a = std.testing.allocator;
    // The guard must not narrow what already installs: nested app bundles,
    // a binary nested under the extracted tree, the `$HOMEBREW_PREFIX/` form,
    // and a plain rename target all stay valid.
    const ok = [_][]const u8{
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["Firefox.app"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"app":["Sub Dir/My App.app"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["bin/tool"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["$HOMEBREW_PREFIX/bin/tool"]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.tar.gz","artifacts":[{"binary":["codex-aarch64-apple-darwin",{"target":"codex"}]}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.zip","artifacts":[{"font":["Some.ttf"],"target":"whatever/ignored"}]}
        ,
        \\{"token":"ok","version":"1.0","url":"https://e/x.pkg","artifacts":[{"pkg":["Thing.pkg"]}]}
        ,
    };
    for (ok) |json| {
        var cask = try parseCask(a, json);
        cask.deinit();
    }
}

test "verifyFileSha256 refuses an artifact with no declared hash" {
    // Homebrew always emits `sha256` for a cask — a real digest or the literal
    // `no_check`. Treating an *absent* field as "verified" silently downgrades
    // every such cask to transport-only integrity, and `installPkg` hands the
    // result to `sudo installer`.
    const io = std.Options.debug_io;
    const a = std.testing.allocator;
    // Process-unique so overlapping test runs can't share the fixture.
    const f = try std.fmt.allocPrint(a, "/tmp/malt_cask_nosha_{d}", .{std.c.getpid()});
    defer a.free(f);
    defer std.Io.Dir.cwd().deleteFile(io, f) catch {};
    {
        const fh = try std.Io.Dir.createFileAbsolute(io, f, .{ .truncate = true });
        defer fh.close(io);
        try fh.writeStreamingAll(io, "TAMPERED");
    }

    try std.testing.expectError(error.Sha256Missing, verifyFileSha256(io, f, null));
    // The explicit opt-out still works, and a real digest still verifies.
    try verifyFileSha256(io, f, "no_check");
    const good = try hashFileSha256(io, f);
    try verifyFileSha256(io, f, &good);
}

test "parseCask accepts legitimate token and version" {
    const a = std.testing.allocator;
    // The guard is charset-agnostic, so real versions an allowlist would
    // reject — uppercase, comma, colon, space — must survive, and the
    // absent-version `"unknown"` default must too.
    const ok = [_][]const u8{
        \\{"token":"google-chrome","version":"1.2.3,400","url":"https://e/x.dmg"}
        ,
        \\{"token":"firefox","version":"2.0:1 (Beta)","url":"https://e/x.dmg"}
        ,
        \\{"token":"firefox","url":"https://e/x.dmg"}
        ,
    };
    for (ok) |json| {
        var cask = try parseCask(a, json);
        cask.deinit();
    }
}

test "linkCaskBinary refuses a source symlink outside Caskroom" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_binary_source_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const root = try std.fmt.allocPrint(a, "{s}/Caskroom/tool/1.0", .{prefix});
    const victim = try std.fmt.allocPrint(a, "{s}/private", .{base});
    const bin_dir = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    const link = try std.fmt.allocPrint(a, "{s}/tool", .{bin_dir});
    try std.Io.Dir.cwd().createDirPath(io, bin_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, victim, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "PRIVATE");
    }
    try std.Io.Dir.symLinkAbsolute(io, victim, link, .{});

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };
    try std.testing.expectError(
        error.InstallFailed,
        installer.linkCaskBinary(root, "bin/tool", "tool"),
    );
}

test "linkCaskBinary refuses a prefix path outside its Caskroom version" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_binary_prefix_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const root = try std.fmt.allocPrint(a, "{s}/Caskroom/tool/1.0", .{prefix});
    const victim = try std.fmt.allocPrint(a, "{s}/etc/private", .{prefix});
    try std.Io.Dir.cwd().createDirPath(io, root);
    if (std.fs.path.dirname(victim)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, victim, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "PRIVATE");
    }

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };
    try std.testing.expectError(
        error.InstallFailed,
        installer.linkCaskBinary(root, "$HOMEBREW_PREFIX/etc/private", "tool"),
    );
}

test "linkCaskBinary links regular relative and in-prefix Caskroom sources" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_binary_regular_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const root = try std.fmt.allocPrint(a, "{s}/Caskroom/tool/1.0", .{prefix});
    const bin_dir = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    try std.Io.Dir.cwd().createDirPath(io, bin_dir);

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };
    const cases = [_]struct {
        src_name: []const u8,
        source_leaf: []const u8,
        link_name: []const u8,
    }{
        .{ .src_name = "bin/relative-tool", .source_leaf = "relative-tool", .link_name = "relative-tool" },
        .{
            .src_name = "$HOMEBREW_PREFIX/Caskroom/tool/1.0/bin/prefix-tool",
            .source_leaf = "prefix-tool",
            .link_name = "prefix-tool",
        },
    };

    for (cases) |case| {
        const source = try std.fmt.allocPrint(a, "{s}/{s}", .{ bin_dir, case.source_leaf });
        {
            const f = try std.Io.Dir.createFileAbsolute(io, source, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, "binary");
        }

        const linked = try installer.linkCaskBinary(root, case.src_name, case.link_name);
        const expected_link = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ prefix, case.link_name });
        try std.testing.expectEqualStrings(expected_link, linked);
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target_len = try std.Io.Dir.readLinkAbsolute(io, linked, &target_buf);
        var source_real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const source_real_len = try std.Io.Dir.cwd().realPathFile(io, source, &source_real_buf);
        try std.testing.expectEqualStrings(source_real_buf[0..source_real_len], target_buf[0..target_len]);
        const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
    }
}

test "installZip does not extract through a pre-existing predictable symlink" {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_zip_root_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const tmp_dir = try std.fmt.allocPrint(a, "{s}/tmp", .{prefix});
    const extract_link = try std.fmt.allocPrint(a, "{s}/cask_extract_evil", .{tmp_dir});
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{base});
    const source = try std.fmt.allocPrint(a, "{s}/source/Evil.app/Contents", .{base});
    const source_root = try std.fmt.allocPrint(a, "{s}/source/Evil.app", .{base});
    const payload = try std.fmt.allocPrint(a, "{s}/payload", .{source});
    const zip_path = try std.fmt.allocPrint(a, "{s}/evil.zip", .{base});
    const app_dir = try std.fmt.allocPrint(a, "{s}/Applications", .{base});

    try std.Io.Dir.cwd().createDirPath(io, tmp_dir);
    try std.Io.Dir.cwd().createDirPath(io, outside);
    try std.Io.Dir.cwd().createDirPath(io, source);
    try std.Io.Dir.cwd().createDirPath(io, app_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, payload, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "OWNED");
    }
    try std.Io.Dir.symLinkAbsolute(io, outside, extract_link, .{});

    const zip_argv = [_][]const u8{ system_tools.ditto, "-c", "-k", "--keepParent", source_root, zip_path };
    try child_mod.runOrFail(io, a, &zip_argv);

    var cask = try parseCask(a,
        \\{"token":"evil","name":["Evil"],"version":"1.0","url":"https://example.invalid/evil.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifacts":[{"app":["Evil.app"]}]}
    );
    defer cask.deinit();
    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };

    const installed = try installer.installZip(zip_path, app_dir, &cask);
    a.free(installed);

    const escaped_payload = try std.fmt.allocPrint(a, "{s}/Evil.app/Contents/payload", .{outside});
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, escaped_payload, .{}),
    );
}

test "parseCask does not length-cap a clean version" {
    const a = std.testing.allocator;
    // Versions have no length convention, so the guard must stay length-
    // agnostic — this locks out a future regression that grows an
    // over-eager cap and rejects a long but otherwise-clean version.
    var ver: [200]u8 = undefined;
    @memset(&ver, '9');
    const json = try std.fmt.allocPrint(
        a,
        \\{{"token":"firefox","version":"{s}","url":"https://e/x.dmg"}}
    ,
        .{ver},
    );
    defer a.free(json);
    var cask = try parseCask(a, json);
    cask.deinit();
}

test "installDmg does not adopt a predictable pre-existing mount point" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_dmg_mount_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const tmp_dir = try std.fmt.allocPrint(a, "{s}/tmp", .{prefix});
    // Derived from the token alone, so anything with prefix write access can
    // put its own directory here before the install runs.
    const planted = try std.fmt.allocPrint(a, "{s}/cask_mount_evil", .{tmp_dir});
    const source = try std.fmt.allocPrint(a, "{s}/source/Evil.app/Contents", .{base});
    const source_root = try std.fmt.allocPrint(a, "{s}/source", .{base});
    const dmg_path = try std.fmt.allocPrint(a, "{s}/evil.dmg", .{base});
    const app_dir = try std.fmt.allocPrint(a, "{s}/Applications", .{base});

    try std.Io.Dir.cwd().createDirPath(io, planted);
    try std.Io.Dir.cwd().createDirPath(io, source);
    try std.Io.Dir.cwd().createDirPath(io, app_dir);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/payload", .{source}),
        .data = "OWNED",
    });

    const mk = [_][]const u8{
        "/usr/bin/hdiutil", "create", "-quiet", "-srcfolder", source_root, "-volname", "EvilVol", dmg_path,
    };
    try child_mod.runOrFail(io, a, &mk);

    var cask = try parseCask(a,
        \\{"token":"evil","name":["Evil"],"version":"1.0","url":"https://example.invalid/evil.dmg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","artifacts":[{"app":["Evil.app"]}]}
    );
    defer cask.deinit();
    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };
    _ = installer.installDmg(dmg_path, app_dir, &cask) catch {};

    // Mounting over the planted directory and then removing it on teardown
    // destroys a directory malt never created. It must be left alone.
    try std.Io.Dir.cwd().access(io, planted, .{});
}

test "freshTempDir hands out a distinct private directory each call" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrintSentinel(a, "/tmp/malt_fresh_tmp_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/tmp", .{prefix}));

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };

    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;
    const first = try installer.freshTempDir(&buf_a, "mount", "tok");
    const second = try installer.freshTempDir(&buf_b, "mount", "tok");

    // Same cask, same kind, different directory - otherwise the name is
    // guessable and the path can be planted again.
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const st = try std.Io.Dir.cwd().statFile(io, first, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, st.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
}

test "freshTempDir fails instead of creating a prefix tmp dir that is absent" {
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrintSentinel(a, "/tmp/malt_fresh_tmp_missing_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    try std.Io.Dir.cwd().createDirPath(io, prefix); // no `tmp` underneath

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .db = undefined,
        .progress = null,
    };
    var buf: [512]u8 = undefined;
    // Creating the parent here would re-open the adoption hole it guards.
    try std.testing.expectError(error.InstallFailed, installer.freshTempDir(&buf, "mount", "tok"));
}
