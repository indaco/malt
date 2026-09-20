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
const prefix_path = @import("../fs/prefix_path.zig");
const hash_mod = @import("hash.zig");
const child_mod = @import("child.zig");
const cask_font = @import("cask_font.zig");
const cask_variation = @import("../net/cask_variation.zig");
const steps_mod = @import("post_install_steps.zig");

pub const FlightLog = steps_mod.FallbackLog;

pub const CaskError = error{
    /// A declared preflight step failed, so the artefact was never placed.
    PreflightFailed,
    ParseFailed,
    DownloadFailed,
    InstallFailed,
    // Distinct from InstallFailed so callers can say *why*: `<prefix>/bin`
    // already holds an entry this cask does not own, and taking it over
    // would silently shadow a formula's executable.
    LinkConflict,
    // A restored version is back in place and recorded, but a command-line
    // link it declares could not be created: the caller reports, not undoes.
    LinksIncomplete,
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
    /// False when `depends_on.macos` rules out the running macOS.
    os_supported: bool = true,
    /// The `depends_on.macos` clause, borrowed from `parsed`, for the
    /// refusal message. Null only when the cask declares none, so it is
    /// always set when `os_supported` is false.
    os_requirement: ?cask_variation.Requirement = null,
    /// Declared `*_steps` per phase, borrowed from `parsed`; null when the
    /// cask ships none for that phase.
    flight_steps: FlightSteps = FlightSteps.initFill(null),

    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Cask) void {
        self.parsed.deinit();
    }
};

/// The four points at which a cask may declare steps, in install order.
pub const FlightPhase = enum {
    preflight,
    postflight,
    uninstall_preflight,
    uninstall_postflight,

    /// The artifact key the phase ships under.
    pub fn key(self: FlightPhase) []const u8 {
        return switch (self) {
            inline else => |p| @tagName(p) ++ "_steps",
        };
    }
};

pub const FlightSteps = std.EnumArray(FlightPhase, ?[]const std.json.Value);

/// Collect each phase's `steps` from its artifact entry. The DSL emits one
/// entry per phase, so the first well-formed one wins.
fn parseFlightSteps(obj: std.json.ObjectMap) FlightSteps {
    var out = FlightSteps.initFill(null);
    for (std.enums.values(FlightPhase)) |phase| {
        const entries = firstArtifactArray(obj, phase.key()) orelse continue;
        for (entries.items) |entry| {
            const steps = switch (entry) {
                .object => |o| o.get("steps") orelse continue,
                else => continue,
            };
            if (steps == .array) {
                out.set(phase, steps.array.items);
                break;
            }
        }
    }
    return out;
}

/// Parse cask JSON from Homebrew API, resolved for the running macOS.
pub fn parseCask(allocator: std.mem.Allocator, json_bytes: []const u8) !Cask {
    return parseCaskWithMajor(allocator, json_bytes, cask_variation.runningMacosMajor());
}

/// `parseCask` with the macOS product major injected, so tests never depend
/// on the host. Null (unreadable sysctl) keeps the top-level fields and
/// gates nothing, as brew does on an OS it does not know.
pub fn parseCaskWithMajor(allocator: std.mem.Allocator, json_bytes: []const u8, macos_major: ?u32) !Cask {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return CaskError.ParseFailed;
    errdefer parsed.deinit();

    // A non-object root is an inactive union field: reading a field off it
    // aborts the process instead of failing the command.
    const obj: *std.json.ObjectMap = switch (parsed.value) {
        .object => |*o| o,
        else => return CaskError.ParseFailed,
    };

    // Overlay before any screening so a variation is held to the same
    // path rules as the top-level fields it replaces.
    if (macos_major) |major| try overlayVariation(parsed.arena.allocator(), obj, major);

    const token = getStr(obj.*, "token") orelse return CaskError.ParseFailed;
    const version = getStr(obj.*, "version") orelse "unknown";
    // `token` and `version` are interpolated verbatim into Caskroom,
    // cache, and mount paths, so a value that escapes its own path
    // component must be rejected here — the one ingestion choke point —
    // before any sink sees it. A compromised tap is the threat.
    if (!path_component.isPathComponent(token) or !path_component.isPathComponent(version)) return CaskError.ParseFailed;
    // Artifact strings are the *other* half of the tap-controlled path surface:
    // `app` lands in `<app_dir>/<name>` ahead of a `deleteTree`, and `binary`
    // resolves under the keg and symlinks into `<prefix>/bin`. Screen them at
    // the same choke point rather than at each sink.
    try validateArtifactPaths(obj.*);

    // Read after the overlay so a variation's own clause is the one judged.
    const requirement = cask_variation.macosRequirement(obj.get("depends_on"));
    return .{
        .token = token,
        .name = getFirstName(obj.*) orelse token,
        .version = version,
        .desc = getStr(obj.*, "desc") orelse "",
        .homepage = getStr(obj.*, "homepage") orelse "",
        .url = getStr(obj.*, "url") orelse return CaskError.ParseFailed,
        .sha256 = getStr(obj.*, "sha256"),
        .auto_updates = getBool(obj.*, "auto_updates") orelse false,
        .os_supported = cask_variation.osSupported(requirement, macos_major),
        .os_requirement = requirement,
        .flight_steps = parseFlightSteps(obj.*),
        .parsed = parsed,
    };
}

/// Fields a variation may replace. Copied into the top-level object one by
/// one — a variation only carries what differs — so every later reader,
/// including the artifact walkers, sees the resolved cask.
const variation_fields = [_][]const u8{ "url", "sha256", "version", "artifacts", "depends_on" };

fn overlayVariation(arena: std.mem.Allocator, obj: *std.json.ObjectMap, major: u32) CaskError!void {
    var key_buf: [32]u8 = undefined;
    const key = cask_variation.variationKey(&key_buf, major) orelse return;
    const variation = cask_variation.variationObject(obj.get("variations"), key) orelse return;
    for (variation_fields) |field| {
        if (variation.get(field)) |val| obj.put(arena, field, val) catch return CaskError.OutOfMemory;
    }
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
) (sqlite.SqliteError || error{OutOfMemory})!void {
    // No COALESCE on the steps: an upgrade whose new version dropped them
    // must not keep replaying the old ones. Rollback carries them over
    // explicitly instead.
    var stmt = try db.prepare(
        "INSERT OR REPLACE INTO casks (token, name, version, url, sha256, app_path, auto_updates, pinned, tap, flight_steps)" ++
            " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, COALESCE((SELECT pinned FROM casks WHERE token = ?1), 0), ?8, ?9);",
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
    // The parse arena owns the JSON so nothing outlives `cask.deinit`.
    // A row that lost its uninstall gates to an allocation miss must not exist.
    if (try flightStepsJson(cask.parsed.arena.allocator(), cask.flight_steps)) |j| try stmt.bindText(9, j) else try stmt.bindNull(9);
    _ = try stmt.step();
}

/// The declared phases as one JSON object keyed by artifact name, or null
/// when the cask declares none.
fn flightStepsJson(allocator: std.mem.Allocator, steps: FlightSteps) error{OutOfMemory}!?[]const u8 {
    var any = false;
    for (std.enums.values(FlightPhase)) |phase| any = any or steps.get(phase) != null;
    if (!any) return null;
    return try std.json.Stringify.valueAlloc(allocator, .{
        .preflight_steps = steps.get(.preflight),
        .postflight_steps = steps.get(.postflight),
        .uninstall_preflight_steps = steps.get(.uninstall_preflight),
        .uninstall_postflight_steps = steps.get(.uninstall_postflight),
    }, .{ .emit_null_optional_fields = false });
}

/// The flight steps a cask's row stored at install time.
pub const StoredFlight = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn get(self: *const StoredFlight, phase: FlightPhase) ?[]const std.json.Value {
        const v = self.parsed.value.object.get(phase.key()) orelse return null;
        return if (v == .array) v.array.items else null;
    }

    pub fn deinit(self: *StoredFlight) void {
        self.parsed.deinit();
    }
};

pub const FlightReadError = LookupError || error{ParseFailed};

/// Null when the row is missing or stored no steps. A row that holds
/// something unreadable is an error, not "none": the uninstall phases exist
/// to gate a removal, so the caller must know the gate did not run.
pub fn readFlightSteps(db: *sqlite.Database, allocator: std.mem.Allocator, token: []const u8) FlightReadError!?StoredFlight {
    var stmt = try db.prepare("SELECT flight_steps FROM casks WHERE token = ?1 LIMIT 1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    if (!try stmt.step()) return null;
    const raw = stmt.columnText(0) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, std.mem.sliceTo(raw, 0), .{}) catch
        return error.ParseFailed;
    if (parsed.value != .object) {
        parsed.deinit();
        return error.ParseFailed;
    }
    return .{ .parsed = parsed };
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
/// Writes to the `<cache>/Cask/<token>-<version>.<ext>` naming and
/// stays surgical so `purge --old-versions` can drop a stale version
/// without touching the current one. Iterates every known extension because
/// `cask_versions.artifact_type` is nullable on rows backfilled
/// before v7. Returns true when every file that existed was removed
/// (or none existed); false when an existing file could not be
/// deleted — the caller uses that signal to gate the DB row delete
/// so a read-only mount doesn't orphan history.
/// `keep` spares one already-fetched artefact, so an upgrade's uninstall
/// cannot wipe the bytes it is about to install.
pub fn deletePerVersionCacheFile(io: std.Io, cache_dir: []const u8, token: []const u8, version: []const u8, keep: ?[]const u8) bool {
    for (cache_extensions ++ sidecar_extensions) |ext| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/Cask/{s}-{s}{s}", .{ cache_dir, token, version, ext }) catch continue;
        if (keep) |k| if (std.mem.eql(u8, path, k)) continue;
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
/// `keep` is an artefact an in-flight upgrade already fetched; wiping it would
/// force a second download of bytes we are about to install.
pub fn sweepOwnedVersionCache(io: std.Io, db: *sqlite.Database, cache_dir: []const u8, token: []const u8, keep: ?[]const u8) void {
    var stmt = db.prepare("SELECT version FROM cask_versions WHERE token = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return;

    while (stmt.step() catch false) {
        const ver_ptr = stmt.columnText(0) orelse continue;
        _ = deletePerVersionCacheFile(io, cache_dir, token, std.mem.sliceTo(ver_ptr, 0), keep);
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

/// Per-version stanza sidecars that travel with the artefact and go with it.
pub const sidecar_extensions = [_][]const u8{ ".fonts", ".binaries" };

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

/// One `binary` stanza: the file to link and, when the cask renames it,
/// the link name it gets in `<prefix>/bin`.
pub const BinaryEntry = struct {
    source: []const u8,
    target: ?[]const u8,
};

/// Every `binary` stanza in artifact order: a cask may declare one per
/// command-line tool, and all of them must be placed and rolled back.
/// Slices borrow `obj`'s arena; the caller owns the returned array.
pub fn collectBinaryArtifacts(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !?[]BinaryEntry {
    const artifacts = switch (obj.get("artifacts") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var entries: std.ArrayList(BinaryEntry) = .empty;
    errdefer entries.deinit(alloc);

    for (artifacts.items) |item| {
        const art = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const arr = switch (art.get("binary") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        if (arr.items.len == 0) continue;
        const source = switch (arr.items[0]) {
            .string => |s| s,
            else => continue,
        };
        var target: ?[]const u8 = null;
        if (art.get("target")) |tv| if (tv == .string) {
            target = binaryLinkName(tv.string);
        };
        for (arr.items[1..]) |opt| if (opt == .object) {
            if (opt.object.get("target")) |tv| if (tv == .string) {
                target = binaryLinkName(tv.string);
            };
        };
        try entries.append(alloc, .{ .source = source, .target = target });
    }

    if (entries.items.len == 0) {
        entries.deinit(alloc);
        return null;
    }
    return try entries.toOwnedSlice(alloc);
}

/// Homebrew lets a `binary` source name the prefix explicitly; the remainder is
/// still a subpath and is screened as one.
const homebrew_prefix_var = "$HOMEBREW_PREFIX/";

/// A `binary` source inside the placed bundle, e.g. `$APPDIR/X.app/Contents/MacOS/x`.
const appdir_var = "$APPDIR/";

/// Links an app cask placed beside its bundle, one absolute path per line
/// under `Caskroom/<token>/<version>/`. A bundle has one `app_path`
/// column, so the extra links need their own record for uninstall.
pub const LINKS_MANIFEST_NAME = ".malt-links";

/// True when any stanza links from the Caskroom copy rather than from a
/// placed bundle: a binary-only cask links everything from there, an app
/// cask keeps a copy of its stage for these.
fn hasCaskroomBinary(entries: []const BinaryEntry) bool {
    for (entries) |e| if (!std.mem.startsWith(u8, e.source, appdir_var)) return true;
    return false;
}

/// A source the Caskroom copy of the stage must hold: neither inside the
/// placed bundle nor an explicit prefix path.
fn linksFromCaskroom(source: []const u8) bool {
    return !std.mem.startsWith(u8, source, appdir_var) and !std.mem.startsWith(u8, source, homebrew_prefix_var);
}

fn firstComponent(path: []const u8) []const u8 {
    return path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse path.len];
}

/// The link name a `binary` target denotes, or null when it names anywhere
/// but one entry in `<prefix>/bin`: the API spells a target either as the
/// bare name or as the full `$HOMEBREW_PREFIX/bin/<name>` path.
fn binaryLinkName(target: []const u8) ?[]const u8 {
    const bin_dir = homebrew_prefix_var ++ "bin/";
    const name = if (std.mem.startsWith(u8, target, bin_dir)) target[bin_dir.len..] else target;
    return if (path_component.isPathComponent(name) and !hasControlByte(name)) name else null;
}

/// The sidecar and the links manifest are line- and tab-framed, so a
/// control byte in a name would split one record into two.
fn hasControlByte(s: []const u8) bool {
    for (s) |c| if (std.ascii.isControl(c)) return true;
    return false;
}

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
                    if (!path_component.isRelativeSubpath(rel) or hasControlByte(rel)) return CaskError.ParseFailed;
                },
                .object => |o| {
                    // Only the first element is the source; later objects are
                    // option hashes, and `target` is the one malt honours.
                    if (i == 0) continue;
                    if (o.get("target")) |tv| switch (tv) {
                        .string => |t| if (binaryLinkName(t) == null) return CaskError.ParseFailed,
                        else => {},
                    };
                },
                else => {},
            };
            // The API also emits `target` beside `binary`, as a full path.
            if (art.get("target")) |tv| switch (tv) {
                .string => |t| if (binaryLinkName(t) == null) return CaskError.ParseFailed,
                else => {},
            };
        };
    }
}

/// The artifact object carrying `key`, for the option keys that sit beside
/// the array rather than inside it.
fn firstArtifactObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const artifacts_val = obj.get("artifacts") orelse return null;
    if (artifacts_val != .array) return null;
    for (artifacts_val.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get(key)) |val| if (val == .array) return item.object;
    }
    return null;
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
    /// Root of the artefact cache (`<cache_dir>/Cask`), resolved by the
    /// cli/ caller so `MALT_CACHE` is honoured without core/ reading env.
    cache_dir: []const u8,
    db: *sqlite.Database,
    progress: ?client_mod.ProgressCallback,
    /// Pre-resolved type for extensionless URLs (HEAD fallback).
    artifact_type_override: ?ArtifactType = null,
    /// Font stanzas to place instead of parsing them from the cask JSON.
    /// Set by `reinstallFromHistory` from the per-version sidecar so a
    /// rollback's synthetic, artifact-less cask still restores its fonts.
    font_entries_override: ?[]const cask_font.FontEntry = null,
    /// Same contract for `binary` stanzas, read from the `.binaries` sidecar.
    /// A caller may pre-set it as a stand-in for a version with no sidecar.
    binary_entries_override: ?[]const BinaryEntry = null,
    /// The `<prefix>/bin` entry a `LinkConflict` refused, for the caller's
    /// message.
    conflict_buf: [std.fs.max_path_bytes]u8 = undefined,
    conflict_len: usize = 0,
    /// The bundle the `casks` row names while `install` runs, so links into
    /// it count as this cask's own even when the bundle name or app dir
    /// changes between versions.
    recorded_bundle: ?InstalledCask = null,
    /// Set by `reinstallFromHistory`: the version being placed is one the
    /// user already had, so a link that cannot be created is reported
    /// rather than paid for with the bundle.
    restoring: bool = false,
    links_incomplete: bool = false,
    /// Mirrors `ctx.offline` from the cli/ caller. Threaded onto the
    /// internal HttpClient so a download miss surfaces `OfflineRequired`
    /// instead of stalling on connect.
    offline: bool = false,
    /// An artefact the caller already fetched and verified. `install`
    /// consumes it instead of re-fetching and `uninstall` leaves it alone,
    /// which is what lets an upgrade survive a failed download even for a
    /// cask that pins no digest and so can never be validated from cache.
    prefetched_artifact: ?[]const u8 = null,
    /// An upgrade's uninstall is not the end of the cask: its history rows
    /// and cached artefacts stay, so a failed install can put the old
    /// version back and `mt rollback` can still reach it afterwards.
    retain_history: bool = false,
    /// Where declared flight steps report. Null skips them, so callers that
    /// only stage or roll back are unaffected.
    flight: ?FlightSink = null,
    /// Set once `install` reaches the preflight, so a caller reports that
    /// phase only when it ran: a download that failed first has no phase.
    preflight_ran: bool = false,

    /// The log borrows every detail from `allocator`, so both must outlive
    /// the caller's routing of the outcome.
    pub const FlightSink = struct {
        log: *FlightLog,
        allocator: std.mem.Allocator,
    };

    pub fn init(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, db: *sqlite.Database, prefix: [:0]const u8, cache_dir: []const u8) CaskInstaller {
        return .{ .allocator = allocator, .io = io, .environ = environ, .db = db, .prefix = prefix, .cache_dir = cache_dir, .progress = null };
    }

    /// Fetch + sha-verify the cask artefact into `<cache>/Cask/` and
    /// return the on-disk path. No `/Applications` writes, no DB inserts —
    /// the seam `mt install --download-only --cask <token>` reuses to warm
    /// the cache before going offline. Caller owns the returned slice.
    /// Run one phase's steps. `staged_path` defaults to the Caskroom version
    /// dir, which is where a tarball unpacks and what upstream means by it
    /// after staging. False when a step was fatal; the sink's log says why.
    pub fn runFlight(self: *CaskInstaller, token: []const u8, version: []const u8, steps: []const std.json.Value, staged_path: ?[]const u8) bool {
        const ctx = self.flightCtx(token, version, staged_path) orelse return false;
        // Judged on this phase's own entries: the log may carry an earlier one.
        const start = ctx.flog.entries().len;
        steps_mod.runSteps(ctx, steps);
        return !ctx.flog.hasFatalSince(start);
    }

    /// Re-run an install phase's steps in uninstall mode, before the
    /// artefact goes, so a `staged_path` source still resolves to the
    /// Caskroom version dir. That is where a tarball unpacked; a zip or dmg
    /// preflight saw a temporary stage instead, so its links never match.
    pub fn runFlightUninstall(self: *CaskInstaller, token: []const u8, version: []const u8, steps: []const std.json.Value) bool {
        const ctx = self.flightCtx(token, version, null) orelse return false;
        steps_mod.runUninstallSteps(ctx, steps);
        return !ctx.flog.hasFatal();
    }

    fn flightCtx(self: *CaskInstaller, token: []const u8, version: []const u8, staged_path: ?[]const u8) ?steps_mod.StepsCtx {
        // No sink is a caller bug, and a silent pass would be the declared
        // gate skipped; fail the phase instead.
        const sink = self.flight orelse return null;
        return self.flightCtxWith(sink, token, version, staged_path) catch {
            // An empty log would read as a clean phase; say why nothing ran.
            sink.log.log(.{ .formula = token, .reason = .system_command_failed, .detail = "could not build the step context", .loc = null });
            return null;
        };
    }

    fn flightCtxWith(self: *CaskInstaller, sink: FlightSink, token: []const u8, version: []const u8, staged_path: ?[]const u8) error{OutOfMemory}!steps_mod.StepsCtx {
        const a = sink.allocator;
        var app_dir_buf: [512]u8 = undefined;
        const caskroom_path = try std.fmt.allocPrint(a, "{s}/Caskroom/{s}", .{ self.prefix, token });
        return .{
            .io = self.io,
            .allocator = a,
            .name = token,
            .version = version,
            .prefix = self.prefix,
            .keg_path = caskroom_path,
            .subject = .{
                .cask = .{
                    .staged_path = staged_path orelse try std.fmt.allocPrint(a, "{s}/{s}", .{ caskroom_path, version }),
                    .caskroom_path = caskroom_path,
                    // Duped: the buffer dies with this frame, the log does not.
                    .appdir = try a.dupe(u8, applicationsDir(self.io, self.environ, self.prefix, &app_dir_buf)),
                    .home = std.process.Environ.getPosix(self.environ, "HOME") orelse "",
                },
            },
            .flog = sink.log,
            .environ = self.environ,
        };
    }

    /// Preflight over the staged tree, before any artifact moves.
    fn preflight(self: *CaskInstaller, cask: *const Cask, staged_path: ?[]const u8) CaskError!void {
        const steps = cask.flight_steps.get(.preflight) orelse return;
        self.preflight_ran = true;
        if (!self.runFlight(cask.token, cask.version, steps, staged_path)) return CaskError.PreflightFailed;
    }

    pub fn downloadOnly(self: *CaskInstaller, cask: *const Cask) CaskError![]const u8 {
        const artifact_type = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        if (artifact_type == .unknown) return CaskError.InstallFailed;

        var cache_buf: [512]u8 = undefined;
        const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/Cask", .{self.cache_dir}) catch
            return CaskError.OutOfMemory;
        // Recursive: nothing creates `$MALT_CACHE` itself.
        std.Io.Dir.cwd().createDirPath(self.io, cache_dir) catch return CaskError.InstallFailed;

        const fetched = self.downloadToCache(cask, cache_dir, self.progress) catch |e| switch (e) {
            // A retry re-fetches the same manifest and refuses identically, so
            // this must not reach the user wearing a transient error's name.
            error.InsecureUrlScheme => return CaskError.InsecureOrigin,
            error.WatchdogSpawnFailed => return CaskError.DownloadLocalResourceExhausted,
            else => return CaskError.DownloadFailed,
        };
        const cache_path = fetched.path;
        errdefer {
            std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
            self.allocator.free(cache_path);
        }

        if (!fetched.verified) self.verifySha256(cache_path, cask.sha256) catch |e| switch (e) {
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

        // Determine target: prefix-aware sandbox / /Applications / ~/Applications.
        var app_dir_buf: [512]u8 = undefined;
        const app_dir = applicationsDir(self.io, self.environ, self.prefix, &app_dir_buf);

        // A bin entry this cask cannot take over is refused now, while the
        // version on disk is still whole: after placement the refusal would
        // cost the user the bundle.
        defer self.recorded_bundle = null;
        try self.checkLinkConflicts(cask);

        const cache_path = if (self.prefetched_artifact) |p|
            try self.allocator.dupe(u8, p)
        else
            try self.downloadOnly(cask);
        errdefer {
            // A failed mount or copy says nothing about the bytes, and
            // `rollback --to` reads this exact file. An unpinned artefact
            // still goes: it can never be validated, so it is not reusable.
            if (artifactIntegrity(cask.sha256) != .digest_pinned) {
                std.Io.Dir.cwd().deleteFile(self.io, cache_path) catch {};
            }
            self.allocator.free(cache_path);
        }

        // Install based on type
        const app_path = switch (artifact_type) {
            .dmg => self.installDmg(cache_path, app_dir, cask) catch |e| return installError(e),
            .zip => self.installZip(cache_path, app_dir, cask) catch |e| return installError(e),
            .pkg => blk: {
                // No staging for a package: upstream's staged_path is the
                // Caskroom dir the .pkg would sit in.
                try self.preflight(cask, null);
                break :blk self.installPkg(cache_path) catch return CaskError.InstallFailed;
            },
            .tar_gz, .tar_xz => self.installTarball(cache_path, app_dir, cask, artifact_type) catch |e| return installError(e),
            .unknown => return CaskError.InstallFailed,
        };
        errdefer self.allocator.free(app_path);

        // An app cask's helpers are linked once its bundle is in place,
        // whatever container it came in. A pkg, a font cask and a binary-only
        // cask (which returns its first link) have nothing left to link.
        var bin_dir_buf: [512]u8 = undefined;
        const bin_dir = std.fmt.bufPrint(&bin_dir_buf, "{s}/bin/", .{self.prefix}) catch return CaskError.InstallFailed;
        const placed_bundle = artifact_type != .pkg and
            !std.mem.eql(u8, std.fs.path.basename(app_path), cask_font.MANIFEST_NAME) and
            !std.mem.startsWith(u8, app_path, bin_dir);
        if (placed_bundle) self.linkPlacedBinaries(cask, app_path) catch |e| {
            if (self.restoring) {
                // The stanzas were recorded or guessed for a bundle that may
                // differ from this one; the bundle stays, the gap is named.
                self.links_incomplete = true;
            } else {
                // A placed bundle with no row is a half-install nothing can
                // uninstall or roll back; the Caskroom copy or stage goes too.
                std.Io.Dir.cwd().deleteTree(self.io, app_path) catch {};
                self.wipeCaskroomVersion(cask);
                return installError(e);
            }
        };

        // Caskroom dir is bookkeeping; app is already in place.
        self.recordCaskroom(cask) catch {};

        // Persist the binary stanzas next to the cached artefact so a later
        // rollback re-links offline without the cask JSON. Best-effort, as
        // with the history row: a lost sidecar only degrades that rollback.
        // A record that just failed to link is not worth keeping.
        if (!self.links_incomplete) self.writeLinkedBinarySpec(cask) catch {};

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

    /// The refusals a caller can act on keep their names through the
    /// per-type catch-alls.
    fn installError(e: anyerror) CaskError {
        return switch (e) {
            error.PreflightFailed => CaskError.PreflightFailed,
            error.LinkConflict => CaskError.LinkConflict,
            else => CaskError.InstallFailed,
        };
    }

    /// The `<prefix>/bin` entry the last `LinkConflict` refused.
    pub fn conflictPath(self: *const CaskInstaller) ?[]const u8 {
        return if (self.conflict_len == 0) null else self.conflict_buf[0..self.conflict_len];
    }

    /// Refuse, before anything is placed, every link name this install
    /// would create over an entry that is not this cask's own. Public so an
    /// upgrade can ask before it removes the old version.
    pub fn checkLinkConflicts(self: *CaskInstaller, cask: *const Cask) CaskError!void {
        // Only the stanzas the install will link are screened: a pkg and a
        // font cask link none.
        const obj = cask.parsed.value.object;
        if ((self.artifact_type_override orelse artifactTypeFromUrl(cask.url)) == .pkg) return;
        if (try cask_font.collectFontArtifacts(self.allocator, obj)) |fonts| {
            self.allocator.free(fonts);
            return;
        }
        const entries = if (self.binary_entries_override) |o|
            try self.allocator.dupe(BinaryEntry, o)
        else
            (try collectBinaryArtifacts(self.allocator, obj)) orelse return;
        defer self.allocator.free(entries);
        // Stays set for the link pass that follows; `install` clears it.
        self.recorded_bundle = lookupInstalled(self.db, cask.token);
        // The bundle this install will place, when the cask names it; the
        // one on record covers a rollback's synthetic cask.
        var app_dir_buf: [512]u8 = undefined;
        var root_buf: [512]u8 = undefined;
        const root: ?[]const u8 = if (parseAppName(cask.parsed.value.object)) |name|
            std.fmt.bufPrint(&root_buf, "{s}/{s}", .{ applicationsDir(self.io, self.environ, self.prefix, &app_dir_buf), name }) catch null
        else
            null;
        for (entries) |e| {
            const name = e.target orelse std.fs.path.basename(e.source);
            var link_buf: [512]u8 = undefined;
            const link_path = std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ self.prefix, name }) catch return CaskError.InstallFailed;
            if (self.binEntryOwner(cask.token, root, link_path) == .foreign) return self.linkConflict(link_path);
        }
    }

    fn linkConflict(self: *CaskInstaller, link_path: []const u8) error{LinkConflict} {
        self.conflict_len = @min(link_path.len, self.conflict_buf.len);
        @memcpy(self.conflict_buf[0..self.conflict_len], link_path[0..self.conflict_len]);
        return error.LinkConflict;
    }

    const BinEntry = enum { absent, owned, foreign };

    /// Whether a `<prefix>/bin` entry is this cask's to replace or remove: a
    /// symlink resolving into its Caskroom, into the bundle on record, or
    /// into `root`. Anything else is a formula's link or the user's own file
    /// and is refused, as brew does. Links store resolved paths, so every
    /// root is resolved before the boundary-aware compare.
    fn binEntryOwner(self: *CaskInstaller, token: []const u8, root: ?[]const u8, link_path: []const u8) BinEntry {
        var target_buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = if (std.Io.Dir.readLinkAbsolute(self.io, link_path, &target_buf)) |n|
            target_buf[0..n]
        else |e|
            return if (e == error.FileNotFound) .absent else .foreign;
        var caskroom_buf: [512]u8 = undefined;
        const caskroom = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}", .{ self.prefix, token }) catch return .foreign;
        const recorded: ?[]const u8 = if (self.recorded_bundle) |*r| r.appPath() else null;
        for ([_]?[]const u8{ caskroom, root, recorded }) |candidate| {
            // The root itself may already be gone (a wiped Caskroom, a
            // replaced bundle) while its link still counts as ours, so the
            // parent is what gets resolved.
            const c = candidate orelse continue;
            var real_buf: [std.fs.max_path_bytes]u8 = undefined;
            const n = std.Io.Dir.realPathFileAbsolute(self.io, std.fs.path.dirname(c) orelse continue, &real_buf) catch continue;
            var owned_buf: [std.fs.max_path_bytes]u8 = undefined;
            const owned = std.fmt.bufPrint(&owned_buf, "{s}/{s}", .{ real_buf[0..n], std.fs.path.basename(c) }) catch continue;
            if (confined_source.pathHasPrefix(target, owned)) return .owned;
        }
        return .foreign;
    }

    /// Remove `Caskroom/<token>/<version>` and the token dir when that was
    /// its only version.
    fn wipeCaskroomVersion(self: *CaskInstaller, cask: *const Cask) void {
        var buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&buf, "{s}/Caskroom/{s}/{s}", .{ self.prefix, cask.token, cask.version }) catch return;
        std.Io.Dir.cwd().deleteTree(self.io, caskroom_ver) catch {};
        if (std.fs.path.dirname(caskroom_ver)) |token_dir| std.Io.Dir.deleteDirAbsolute(self.io, token_dir) catch {};
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
        var version_buf: [256]u8 = undefined;
        var version_len: usize = 0;
        {
            var stmt = self.db.prepare(
                "SELECT app_path, version FROM casks WHERE token = ?1 LIMIT 1;",
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
            if (stmt.columnText(1)) |v| {
                // A truncated version would silently miss the links manifest.
                const slice = std.mem.sliceTo(v, 0);
                if (slice.len > version_buf.len) return CaskError.UninstallFailed;
                version_len = slice.len;
                @memcpy(version_buf[0..version_len], slice);
            }
        }

        // A PKG cask records its cached artefact as `app_path`, so this can name
        // the very file an upgrade prefetched for the install pass to read.
        const spared = if (self.prefetched_artifact) |k|
            std.mem.eql(u8, k, app_path_buf[0..app_path_len])
        else
            false;

        if (app_path_len > 0 and !spared) {
            const app_path = app_path_buf[0..app_path_len];

            if (std.mem.eql(u8, std.fs.path.basename(app_path), cask_font.MANIFEST_NAME)) {
                // Font cask: app_path is the manifest, not a removable bundle.
                // Unlink each placed font; the Caskroom wipe below removes the
                // manifest itself.
                self.removeManifestedPaths(app_path);
            } else {
                // Refuse while the app is live: removing the old bundle would
                // yank a running app. Distinct error so the caller can say so.
                if (isAppRunning(self.io, app_path)) return CaskError.AppRunning;

                // The links this cask placed, while their targets still
                // resolve; the manifest goes with the Caskroom wipe below.
                self.removeOwnedLinks(token, version_buf[0..version_len], app_path, null);
                // app may already be gone (manual delete); continue to DB cleanup.
                std.Io.Dir.cwd().deleteTree(self.io, app_path) catch {};
            }
        }

        // Caskroom bookkeeping; continue so later removals still run.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}", .{ self.prefix, token }) catch "";
        if (caskroom_path.len > 0) std.Io.Dir.cwd().deleteTree(self.io, caskroom_path) catch {};

        if (!self.retain_history) {
            // Clean up cached artefacts. Two name shapes coexist: the legacy
            // `<token>.<ext>` and the per-version `<token>-<version>.<ext>`
            // shape that retains rollback targets. Wipe both for `uninstall`,
            // since after uninstall there is no version left to roll back to.
            var cache_buf: [512]u8 = undefined;
            for (cache_extensions) |ext| {
                const cache_file = std.fmt.bufPrint(&cache_buf, "{s}/Cask/{s}{s}", .{ self.cache_dir, token, ext }) catch continue;
                if (self.prefetched_artifact) |k| if (std.mem.eql(u8, k, cache_file)) continue;
                std.Io.Dir.cwd().deleteFile(self.io, cache_file) catch {};
            }
            // Must precede the history wipe below — the sweep reads the version
            // list from `cask_versions`, which the DELETE would otherwise empty.
            sweepOwnedVersionCache(self.io, self.db, self.cache_dir, token, self.prefetched_artifact);

            // Drop every history row so a future install starts clean.
            if (self.db.prepare("DELETE FROM cask_versions WHERE token = ?1;")) |prepared| {
                var hist_stmt = prepared;
                defer hist_stmt.finalize();
                hist_stmt.bindText(1, token) catch {};
                _ = hist_stmt.step() catch false;
            } else |_| {}
        }

        // DB row cleanup. User-visible work is done; surfacing the
        // failure lets the CLI caller log `db.errMsg()` instead of
        // silently leaving the row behind.
        try removeRecord(self.db, token);
    }

    /// Unlink every path recorded in the manifest at `manifest_path` (placed
    /// fonts, or the links of an app cask). Best-effort by contract: a
    /// missing manifest (manual Caskroom deletion) reads as empty and an
    /// already-removed path unlinks as a no-op, so uninstall always proceeds
    /// to DB cleanup. The manifest file itself is left for the caller's
    /// Caskroom wipe to remove.
    fn removeManifestedPaths(self: *CaskInstaller, manifest_path: []const u8) void {
        // A read error (e.g. permissions) leaves the paths in place rather
        // than aborting uninstall — drift is recoverable, a stuck row is not.
        const bytes = cask_font.readManifest(self.io, self.allocator, manifest_path) catch return;
        defer self.allocator.free(bytes);

        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            // Only absolute paths were ever written; anything else is damage,
            // and `deleteFileAbsolute` asserts rather than erroring on it.
            if (line.len == 0 or line[0] != '/') continue;
            // Stale entry (already gone) is a no-op; never abort here.
            std.Io.Dir.deleteFileAbsolute(self.io, line) catch {};
        }
    }

    /// Unlink the `<prefix>/bin` entries the `(token, version)` links
    /// manifest names, but only those that still resolve into this cask:
    /// an archive can plant the manifest, and a formula may have taken a
    /// name over since. `keep` are lines to leave alone. Best-effort, like
    /// the font manifest.
    fn removeOwnedLinks(self: *CaskInstaller, token: []const u8, version: []const u8, bundle: ?[]const u8, keep: ?[]const u8) void {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}/{s}/{s}", .{ self.prefix, token, version, LINKS_MANIFEST_NAME }) catch return;
        const bytes = cask_font.readManifest(self.io, self.allocator, path) catch return;
        defer self.allocator.free(bytes);

        var bin_buf: [512]u8 = undefined;
        const bin_dir = std.fmt.bufPrint(&bin_buf, "{s}/bin/", .{self.prefix}) catch return;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (!std.mem.startsWith(u8, line, bin_dir) or !path_component.isPathComponent(line[bin_dir.len..])) continue;
            if (keep) |k| if (manifestHasLine(k, line)) continue;
            if (self.binEntryOwner(token, bundle, line) != .owned) continue;
            std.Io.Dir.deleteFileAbsolute(self.io, line) catch {};
        }
    }

    fn manifestHasLine(bytes: []const u8, line: []const u8) bool {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
        return false;
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

        var synthetic: Cask = .{
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
        // The target version's own steps are not on record; the ones the
        // current install stored are the best guide for its later uninstall.
        // Read now, attached only after the install below: they are recorded,
        // never run, so a rollback needs no flight sink. Unreadable is none.
        var stored = readFlightSteps(self.db, self.allocator, token) catch null;
        defer if (stored) |*s| s.deinit();

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
        // A caller's stand-in stays when the version predates the sidecar.
        var bin_spec_opt = self.readBinarySpec(row.token, row.version) catch null;
        defer if (bin_spec_opt) |*s| s.deinit(self.allocator);
        if (bin_spec_opt) |*s| self.binary_entries_override = s.entries;
        defer self.binary_entries_override = null;

        self.restoring = true;
        self.links_incomplete = false;
        defer {
            self.restoring = false;
            self.links_incomplete = false;
        }
        const app_path = try self.install(&synthetic);
        defer self.allocator.free(app_path);

        // The swap installs over the outgoing version without uninstalling
        // it, so a link the target version does not declare would otherwise
        // survive, pointing at a helper the older bundle no longer ships.
        // Only after the install: a failed one must leave the outgoing
        // version whole.
        if (lookupInstalled(self.db, token)) |*cur| {
            var new_buf: [512]u8 = undefined;
            const new_manifest = std.fmt.bufPrint(&new_buf, "{s}/Caskroom/{s}/{s}/{s}", .{ self.prefix, token, row.version, LINKS_MANIFEST_NAME }) catch "";
            const keep = if (new_manifest.len == 0) null else cask_font.readManifest(self.io, self.allocator, new_manifest) catch null;
            defer if (keep) |k| self.allocator.free(k);
            self.removeOwnedLinks(token, cur.version(), cur.appPath(), keep);
            // A roll-forward re-installs from the cached artefact, so the
            // outgoing version's Caskroom dir has nothing left to serve.
            if (!std.mem.eql(u8, cur.version(), row.version)) {
                var out_buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&out_buf, "{s}/Caskroom/{s}/{s}", .{ self.prefix, token, cur.version() })) |outgoing| {
                    std.Io.Dir.cwd().deleteTree(self.io, outgoing) catch {};
                } else |_| {}
            }
        }
        if (stored) |*s| for (std.enums.values(FlightPhase)) |phase| synthetic.flight_steps.set(phase, s.get(phase));

        // Flip the `casks` row to the rolled-back version. `pinned`
        // survives via recordInstall's COALESCE; `auto_updates` and
        // `tap` survive via the preserved values above.
        recordInstall(self.db, &synthetic, app_path, meta.tap) catch return CaskError.InstallFailed;
        // Read before the defer above clears it.
        if (self.links_incomplete) return CaskError.LinksIncomplete;
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

    /// `verified` marks a cache hit whose hash was already checked here, so
    /// `downloadOnly` does not hash the same payload a second time.
    const CachedArtifact = struct { path: []const u8, verified: bool };

    fn downloadToCache(self: *CaskInstaller, cask: *const Cask, cache_dir: []const u8, progress: ?client_mod.ProgressCallback) !CachedArtifact {
        const resolved = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        const ext_str = artifactExtension(resolved);
        // Per-version filename so older versions' artefacts survive a
        // newer install — `mt rollback <cask> --to <ver>` reaches for
        // the cached file at `<token>-<version>.<ext>` before falling
        // back to a fresh download.
        const dest = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{s}{s}", .{ cache_dir, cask.token, cask.version, ext_str });
        errdefer self.allocator.free(dest);

        // A pinned digest proves the cached file is this exact artefact, so an
        // upgrade's prefetch makes the install that follows it free. Casks that
        // pin nothing reuse one filename across releases and must re-fetch.
        if (artifactIntegrity(cask.sha256) == .digest_pinned) reuse: {
            // A planted cache file must not let a `file://` or `data:`
            // manifest install without ever facing the scheme check.
            client_mod.HttpClient.requireSecureOrigin(cask.url, .digest_pinned) catch break :reuse;
            verifyFileSha256(self.io, dest, cask.sha256) catch break :reuse;
            return .{ .path = dest, .verified = true };
        }

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

        return .{ .path = dest, .verified = false };
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

        // A read-only mount is the staged tree here; a step that writes into
        // it fails loudly, as it would on any read-only stage.
        try self.preflight(cask, mount_point);

        // Find the .app bundle name (from JSON artifacts or by scanning mount point).
        // app_name_buf owns the fallback name past iterator teardown.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(self.io, mount_point, &app_name_buf) orelse
            return error.InstallFailed;

        // A helper beside the bundle is unmounted with the volume unless the
        // stage is copied first.
        const stanzas = try self.binaryStanzas(cask);
        defer if (stanzas) |e| self.allocator.free(e);
        return self.promoteBundle(mount_point, app_name, app_dir, cask, stanzas);
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
        try self.preflight(cask, extract_dir);

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

        // A bare executable and nothing else, as the tarball path already
        // handles. The stage is deleted on return, so the binary is kept
        // under the Caskroom and linked from there. A cask that places a
        // bundle takes the path below; `install` links its binaries once the
        // bundle is placed.
        const stanzas = try self.binaryStanzas(cask);
        defer if (stanzas) |e| self.allocator.free(e);
        var app_name_buf: [256]u8 = undefined;
        const bundle_name = self.placedBundleName(cask, extract_dir, &app_name_buf);
        if (bundle_name == null) if (stanzas) |entries| if (hasCaskroomBinary(entries)) {
            var caskroom_buf: [512]u8 = undefined;
            const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ self.prefix, cask.token, cask.version }) catch
                return error.InstallFailed;
            std.Io.Dir.cwd().createDirPath(self.io, caskroom_ver) catch return error.InstallFailed;
            // Nothing else reclaims the copy if a link below fails.
            errdefer self.wipeCaskroomVersion(cask);
            const copy_argv = [_][]const u8{ system_tools.ditto, extract_dir, caskroom_ver };
            child_mod.runOrFail(self.io, self.allocator, &copy_argv) catch return error.InstallFailed;
            return (try self.linkStanzas(cask, null, caskroom_ver, entries)) orelse error.InstallFailed;
        };

        const app_name = bundle_name orelse
            findAppInDir(self.io, extract_dir, &app_name_buf) orelse
            return error.InstallFailed;
        return self.promoteBundle(extract_dir, app_name, app_dir, cask, stanzas);
    }

    /// The bundle this install places, when known before the stage is read:
    /// the one the cask declares, or on a rollback (whose synthetic cask
    /// declares nothing) the one the stage holds - but only when the row
    /// says the outgoing version placed a bundle. A binary-only cask's
    /// archive may carry a `.app` that was never meant to be installed.
    fn placedBundleName(self: *CaskInstaller, cask: *const Cask, stage: []const u8, buf: []u8) ?[]const u8 {
        if (parseAppName(cask.parsed.value.object)) |name| return name;
        if (!self.restoring) return null;
        if (lookupInstalled(self.db, cask.token)) |*cur| {
            var bin_buf: [512]u8 = undefined;
            const bin_dir = std.fmt.bufPrint(&bin_buf, "{s}/bin/", .{self.prefix}) catch return null;
            if (std.mem.startsWith(u8, cur.appPath() orelse "", bin_dir)) return null;
        }
        return findAppInDir(self.io, stage, buf);
    }

    /// Copy `<stage>/<app_name>` to `<app_dir>/<app_name>`, keeping under
    /// the Caskroom whatever the `binary` stanzas link from the stage.
    /// Returns the placed bundle path, owned by the caller.
    fn promoteBundle(
        self: *CaskInstaller,
        stage: []const u8,
        app_name: []const u8,
        app_dir: []const u8,
        cask: *const Cask,
        stanzas: ?[]const BinaryEntry,
    ) ![]const u8 {
        // Before the bundle moves, so a failed copy leaves nothing placed.
        const kept_copy = try self.keepStageCopy(cask, stage, app_name, stanzas orelse &.{});
        errdefer if (kept_copy) self.wipeCaskroomVersion(cask);

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ stage, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present.
        std.Io.Dir.cwd().deleteTree(self.io, dst_app) catch {};

        // Copy .app bundle using ditto (preserves resource forks, xattrs)
        const ditto_argv = [_][]const u8{ system_tools.ditto, src_app, dst_app };
        child_mod.runOrFail(self.io, self.allocator, &ditto_argv) catch return error.InstallFailed;
        return dst_app;
    }

    /// Copy the top-level stage entries the caskroom-rooted stanzas live
    /// under to `Caskroom/<token>/<version>`: the root a relative `binary`
    /// source resolves against once the zip stage is deleted or the dmg
    /// detached. Only those entries, never the whole stage: the bundle is
    /// linked from where it lands, a dmg volume carries dot-directories no
    /// stanza names, and a symlinked entry can host no link source. Nothing
    /// is deleted inside the copy, so a planted symlink cannot redirect a
    /// removal. Returns whether a copy was made.
    fn keepStageCopy(self: *CaskInstaller, cask: *const Cask, stage: []const u8, app_name: []const u8, entries: []const BinaryEntry) !bool {
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ self.prefix, cask.token, cask.version }) catch
            return error.InstallFailed;
        const bundle_top = firstComponent(app_name);
        var copied = false;
        errdefer if (copied) self.wipeCaskroomVersion(cask);
        for (entries) |e| {
            if (!linksFromCaskroom(e.source)) continue;
            var top_buf: [256]u8 = undefined;
            const top = try self.stageEntryOf(stage, e.source, &top_buf);
            if (std.mem.eql(u8, top, bundle_top)) continue;
            var dst_buf: [512]u8 = undefined;
            const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{ caskroom_ver, top }) catch return error.InstallFailed;
            if (std.Io.Dir.accessAbsolute(self.io, dst, .{})) |_| continue else |_| {}
            var src_buf: [512]u8 = undefined;
            const src = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ stage, top }) catch return error.InstallFailed;
            const st = std.Io.Dir.cwd().statFile(self.io, src, .{ .follow_symlinks = false }) catch return error.InstallFailed;
            if (st.kind == .sym_link) return error.InstallFailed;
            if (!copied) {
                std.Io.Dir.cwd().createDirPath(self.io, caskroom_ver) catch return error.InstallFailed;
                copied = true;
            }
            const copy_argv = [_][]const u8{ system_tools.ditto, src, dst };
            child_mod.runOrFail(self.io, self.allocator, &copy_argv) catch return error.InstallFailed;
        }
        return copied;
    }

    /// The top-level stage entry a caskroom-rooted source lives under: its
    /// first component, or for a bare name the first component of where
    /// the stage holds it. A name the stage lacks is the missing helper
    /// `install` refuses to ship without.
    fn stageEntryOf(self: *CaskInstaller, stage: []const u8, source: []const u8, buf: []u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, source, '/') != null) return firstComponent(source);
        const found = (findFileInTree(self.io, self.allocator, stage, source) catch null) orelse return error.InstallFailed;
        defer self.allocator.free(found);
        const rel = found[stage.len + 1 ..];
        const top = firstComponent(rel);
        if (top.len > buf.len) return error.InstallFailed;
        @memcpy(buf[0..top.len], top);
        return buf[0..top.len];
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
        self.writeSpec(cask.token, cask.version, ".fonts", entries) catch {};

        return manifest_path;
    }

    /// Per-version sidecar of the placed stanzas, co-located with the
    /// cached artifact at `<cache>/Cask/<token>-<version>.<ext>`. It
    /// lets `reinstallFromHistory` re-place them offline without the cask
    /// JSON, which the synthetic rollback cask lacks. Format: one
    /// `source\ttarget` line per stanza; a tab-less line has no rename target.
    /// Sanitization still runs at placement, so the persisted strings are
    /// re-validated there rather than trusted here.
    pub fn Spec(comptime Entry: type) type {
        return struct {
            bytes: []u8,
            entries: []Entry,

            pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.entries);
                allocator.free(self.bytes);
            }
        };
    }
    pub const FontSpec = Spec(cask_font.FontEntry);
    pub const BinarySpec = Spec(BinaryEntry);

    fn specPath(self: *CaskInstaller, token: []const u8, version: []const u8, ext: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/Cask/{s}-{s}{s}", .{ self.cache_dir, token, version, ext });
    }

    /// Record the stanzas this install linked, so a rollback re-links them
    /// offline. Rollback's own override is recorded back as-is.
    fn writeLinkedBinarySpec(self: *CaskInstaller, cask: *const Cask) !void {
        const entries = (try self.binaryStanzas(cask)) orelse return;
        defer self.allocator.free(entries);
        if (entries.len != 0) try self.writeSpec(cask.token, cask.version, ".binaries", entries);
    }

    fn writeSpec(self: *CaskInstaller, token: []const u8, version: []const u8, ext: []const u8, entries: anytype) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.specPath(token, version, ext, &path_buf);

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
    /// (a cask without that stanza kind, or a pre-sidecar install). Entries
    /// borrow the returned `bytes`; free both via `deinit`.
    pub fn readFontSpec(self: *CaskInstaller, token: []const u8, version: []const u8) !?FontSpec {
        return self.readSpec(cask_font.FontEntry, token, version, ".fonts");
    }

    pub fn readBinarySpec(self: *CaskInstaller, token: []const u8, version: []const u8) !?BinarySpec {
        return self.readSpec(BinaryEntry, token, version, ".binaries");
    }

    fn readSpec(self: *CaskInstaller, comptime Entry: type, token: []const u8, version: []const u8, ext: []const u8) !?Spec(Entry) {
        var path_buf: [512]u8 = undefined;
        const path = try self.specPath(token, version, ext, &path_buf);

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

        const entries = try self.allocator.alloc(Entry, count);
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
        // The stage is the Caskroom dir itself, so nothing else reclaims it
        // when anything after extraction fails; the token dir goes too when
        // this was its only version.
        errdefer {
            std.Io.Dir.cwd().deleteTree(self.io, caskroom_ver) catch {};
            if (std.fs.path.dirname(caskroom_ver)) |token_dir| std.Io.Dir.deleteDirAbsolute(self.io, token_dir) catch {};
        }
        try self.preflight(cask, caskroom_ver);

        // Same precedence as the zip dispatch: fonts first (they carry no
        // `.app` and no `binary`), then binaries, then a wrapped bundle.
        if (self.font_entries_override) |entries| {
            return self.installFontArtifacts(caskroom_ver, cask, entries);
        }
        if (try cask_font.collectFontArtifacts(self.allocator, cask.parsed.value.object)) |entries| {
            defer self.allocator.free(entries);
            return self.installFontArtifacts(caskroom_ver, cask, entries);
        }

        const stanzas = try self.binaryStanzas(cask);
        defer if (stanzas) |e| self.allocator.free(e);
        var app_name_buf: [256]u8 = undefined;
        const bundle_name = self.placedBundleName(cask, caskroom_ver, &app_name_buf);
        if (bundle_name == null) if (stanzas) |entries| if (hasCaskroomBinary(entries))
            return (try self.linkStanzas(cask, null, caskroom_ver, entries)) orelse error.InstallFailed;

        // Fallback: .app inside a tar.gz (uncommon but valid). Reuse the
        // zip path's "promote .app to app_dir" shape; the stage already is
        // the Caskroom dir, so a helper beside the bundle links from there
        // without a copy.
        const app_name = bundle_name orelse
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
        // The duplicate bundle under the Caskroom is only wasted disk, so
        // reclaiming it never fails an install whose bundle is in place. A
        // nested name is left alone: its parent could be an archive symlink
        // and the removal would follow it.
        if (std.mem.indexOfScalar(u8, app_name, '/') == null) std.Io.Dir.cwd().deleteTree(self.io, src_app) catch {};
        return dst_app;
    }

    /// The `binary` stanzas to place: rollback's override, else the cask
    /// JSON. Caller owns the slice.
    fn binaryStanzas(self: *CaskInstaller, cask: *const Cask) !?[]BinaryEntry {
        if (self.binary_entries_override) |o| return try self.allocator.dupe(BinaryEntry, o);
        return collectBinaryArtifacts(self.allocator, cask.parsed.value.object);
    }

    /// Link every binary of an app cask once its bundle sits at `app_path`:
    /// `$APPDIR/...` sources from the bundle, the rest from the Caskroom copy
    /// of its stage. Public so the pass is testable without ditto.
    pub fn linkPlacedBinaries(self: *CaskInstaller, cask: *const Cask, app_path: []const u8) !void {
        const entries = (try self.binaryStanzas(cask)) orelse return;
        defer self.allocator.free(entries);
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{ self.prefix, cask.token, cask.version }) catch
            return error.InstallFailed;
        if (try self.linkStanzas(cask, app_path, caskroom_ver, entries)) |first| self.allocator.free(first);
    }

    /// Link every stanza, each against its own root, unwinding them all if
    /// one fails, and record every link under the Caskroom so `uninstall`
    /// removes them all: `app_path` can carry only one. One pass for both
    /// roots because the manifest is written with replace semantics.
    /// Returns the first link (owned by the caller), or null when no stanza
    /// applied.
    fn linkStanzas(self: *CaskInstaller, cask: *const Cask, bundle: ?[]const u8, caskroom_ver: []const u8, entries: []const BinaryEntry) !?[]const u8 {
        var manifest: std.ArrayList(u8) = .empty;
        defer manifest.deinit(self.allocator);
        errdefer {
            var it = std.mem.splitScalar(u8, manifest.items, '\n');
            while (it.next()) |line| if (line.len != 0) std.Io.Dir.deleteFileAbsolute(self.io, line) catch {};
        }
        var first: ?[]const u8 = null;
        errdefer if (first) |f| self.allocator.free(f);
        for (entries) |e| {
            // A source inside the bundle - spelled `$APPDIR/X.app/...` or by
            // its staged name `X.app/...` - is linked from where the bundle
            // landed, as upstream's post-move symlink lets it resolve. With
            // no bundle placed it is a declaration this install cannot
            // honour, not a skip.
            const in_bundle = std.mem.startsWith(u8, e.source, appdir_var) or
                (bundle != null and std.mem.eql(u8, firstComponent(e.source), std.fs.path.basename(bundle.?)));
            const root = if (in_bundle) bundle orelse return error.InstallFailed else caskroom_ver;
            const root_kind: BinaryRoot = if (in_bundle) .bundle else .caskroom;
            const link = try self.linkCaskBinary(cask.token, root, root_kind, e.source, e.target orelse std.fs.path.basename(e.source));
            try manifest.appendSlice(self.allocator, link);
            try manifest.append(self.allocator, '\n');
            if (first == null) first = link else self.allocator.free(link);
        }
        if (first == null) return null;

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/Caskroom/{s}/{s}/{s}", .{
            self.prefix, cask.token, cask.version, LINKS_MANIFEST_NAME,
        }) catch return error.InstallFailed;
        cask_font.writeManifest(self.io, path, manifest.items) catch return error.InstallFailed;
        return first;
    }

    /// What a `binary` source resolves against: the Caskroom copy of the
    /// stage, or the bundle an app cask just placed.
    const BinaryRoot = enum { caskroom, bundle };

    /// Resolve the source path of a `binary` artifact. Four shapes
    /// appear in the wild:
    ///   - Bare name (`copilot`) — walk the extraction tree.
    ///   - Relative path (`darwin-arm64/btp`) — join to the extraction
    ///     root; matches the `Caskroom/<token>/<version>/` layout.
    ///   - Homebrew `$HOMEBREW_PREFIX/...` absolute path — rewrite the
    ///     prefix to malt's active one; the tail already points at the
    ///     extracted file since Caskroom lives under the prefix.
    ///   - `$APPDIR/<Name>.app/...` - inside the bundle at `root`, and only
    ///     that bundle; the other shapes never resolve against a bundle.
    /// Returned slice is owned by the caller.
    fn resolveCaskBinaryPath(self: *CaskInstaller, root: []const u8, root_kind: BinaryRoot, src: []const u8) ![]u8 {
        if (root_kind == .bundle) {
            const rel = if (std.mem.startsWith(u8, src, appdir_var)) src[appdir_var.len..] else src;
            if (!path_component.isRelativeSubpath(rel)) return error.InstallFailed;
            // Second line of defence, as below: a stanza naming a neighbour
            // bundle would otherwise be opened read-write and chmod'd.
            const bundle_name = rel[0 .. std.mem.indexOfScalar(u8, rel, '/') orelse rel.len];
            if (!std.mem.eql(u8, bundle_name, std.fs.path.basename(root))) return error.InstallFailed;
            const app_dir = std.fs.path.dirname(root) orelse return error.InstallFailed;
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, rel });
        }
        if (std.mem.startsWith(u8, src, appdir_var)) return error.InstallFailed;
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

    /// Resolve `src_name` inside `root`, chmod +x, and symlink it at
    /// `<prefix>/bin/<link_name>`. `src_name` and `link_name` diverge when
    /// the cask uses the `binary [..., {target: ...}]` rename form. Returns
    /// the symlink path, which the caller records so `uninstall` knows what
    /// to remove.
    fn linkCaskBinary(
        self: *CaskInstaller,
        cask_token: []const u8,
        root: []const u8,
        root_kind: BinaryRoot,
        src_name: []const u8,
        link_name: []const u8,
    ) ![]const u8 {
        const candidate = try self.resolveCaskBinaryPath(root, root_kind, src_name);
        defer self.allocator.free(candidate);

        var source = confined_source.openFile(
            self.io,
            self.allocator,
            root,
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

        // Second look at the same rule `checkLinkConflicts` applied: the
        // entry may have changed hands since.
        if (self.binEntryOwner(cask_token, root, link_path) == .foreign) return self.linkConflict(link_path);
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
    const quote = std.mem.indexOfAny(u8, app_path, ere_meta) != null;
    var prev: u8 = 0;
    for (app_path, 0..) |c, i| {
        // Rows recorded before trailing slashes were trimmed carry `//`; argv never does.
        if (c == '/' and prev == '/') continue;
        prev = c;
        if (quote) {
            if (std.mem.indexOfScalar(u8, ere_meta, c) != null) w.writeByte('\\') catch return null;
            w.writeByte(c) catch return null;
        } else if (i == 0) {
            // Nothing to quote, so the pattern still reads as itself: class the first byte.
            w.print("[{c}]", .{c}) catch return null;
        } else {
            w.writeByte(c) catch return null;
        }
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
///   1. `MALT_APPDIR` env override (caller passes the value): absolute,
///      non-root, traversal-free; anything else is ignored.
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
        // Trailing slashes are trimmed so `app_path` keeps one separator and
        // the running-app guard still matches it; a bare `/` trims to empty.
        const slice = std.mem.trimEnd(u8, std.mem.sliceTo(dir, 0), "/");
        const ok = if (prefix_path.validateShape(slice)) true else |_| false;
        if (ok and slice.len <= out.len) {
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

test "pgrepPattern collapses a doubled separator so rows recorded with one still match" {
    // A trailing-slash MALT_APPDIR used to store `<appdir>//<Name>.app`; the
    // live argv never carries `//`, so the guard silently missed those rows.
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/A/Foo\\.app", pgrepPattern(&buf, "/A//Foo.app").?);
    try std.testing.expectEqualStrings("[/]tmp/plain", pgrepPattern(&buf, "/tmp///plain").?);
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

/// Never reached: the tests below plant no cache artefact.
const unused_cache_dir = "/nonexistent/malt_cask_test_cache";

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
        .cache_dir = unused_cache_dir,
        .db = undefined,
        .progress = null,
    };
    try std.testing.expectError(
        error.InstallFailed,
        installer.linkCaskBinary("tool", root, .caskroom, "bin/tool", "tool"),
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
        .cache_dir = unused_cache_dir,
        .db = undefined,
        .progress = null,
    };
    try std.testing.expectError(
        error.InstallFailed,
        installer.linkCaskBinary("tool", root, .caskroom, "$HOMEBREW_PREFIX/etc/private", "tool"),
    );
}

test "resolveCaskBinaryPath resolves an APPDIR source only inside the placed bundle" {
    var installer: CaskInstaller = .{
        .allocator = std.testing.allocator,
        .io = std.Options.debug_io,
        .environ = .empty,
        .prefix = "/opt/h",
        .cache_dir = "/alt",
        .db = undefined,
        .progress = null,
    };
    const bundle = "/opt/h/Applications/Editor.app";

    const inside = try installer.resolveCaskBinaryPath(bundle, .bundle, "$APPDIR/Editor.app/Contents/MacOS/editor");
    defer std.testing.allocator.free(inside);
    try std.testing.expectEqualStrings("/opt/h/Applications/Editor.app/Contents/MacOS/editor", inside);

    // A neighbour bundle, a traversal, and the Caskroom root are all refused;
    // so is any other shape against a bundle root.
    for ([_]struct { root_kind: CaskInstaller.BinaryRoot, src: []const u8 }{
        .{ .root_kind = .bundle, .src = "$APPDIR/Other.app/Contents/MacOS/x" },
        .{ .root_kind = .bundle, .src = "$APPDIR/Editor.app/../Other.app/x" },
        .{ .root_kind = .bundle, .src = "$APPDIR//Editor.app/x" },
        .{ .root_kind = .bundle, .src = "$APPDIR/" },
        .{ .root_kind = .caskroom, .src = "$APPDIR/Editor.app/Contents/MacOS/editor" },
        .{ .root_kind = .bundle, .src = "editor" },
        .{ .root_kind = .bundle, .src = "$HOMEBREW_PREFIX/bin/editor" },
    }) |case| {
        try std.testing.expectError(error.InstallFailed, installer.resolveCaskBinaryPath(bundle, case.root_kind, case.src));
    }
}

test "hasCaskroomBinary is false when every stanza lives inside the bundle" {
    const inside = [_]BinaryEntry{
        .{ .source = "$APPDIR/A.app/Contents/MacOS/a", .target = "a" },
        .{ .source = "$APPDIR/A.app/Contents/MacOS/b", .target = null },
    };
    try std.testing.expect(!hasCaskroomBinary(&inside));
    try std.testing.expect(!hasCaskroomBinary(&.{}));
    const mixed = inside ++ [_]BinaryEntry{.{ .source = "cli", .target = null }};
    try std.testing.expect(hasCaskroomBinary(&mixed));
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
        .cache_dir = unused_cache_dir,
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

        const linked = try installer.linkCaskBinary("tool", root, .caskroom, case.src_name, case.link_name);
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

test "keepStageCopy copies only the stage entries the caskroom-rooted stanzas need" {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_stage_copy_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    const prefix = try std.fmt.allocPrintSentinel(a, "{s}/prefix", .{base}, 0);
    const stage = try std.fmt.allocPrint(a, "{s}/stage", .{base});
    for ([_][]const u8{ "Pad.app/Contents/MacOS/pad", "pad-cli", "Extras/pad.sh", "Extras/Manual.pdf", "Other.app/Contents/Info.plist", ".Trashes/x" }) |rel| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ stage, rel });
        try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
        const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
        f.close(io);
    }
    try std.Io.Dir.symLinkAbsolute(io, "/Applications", try std.fmt.allocPrint(a, "{s}/Applications", .{stage}), .{});

    var cask = try parseCask(a,
        \\{"token":"pad","name":["Pad"],"version":"1.0","url":"https://example.invalid/pad.dmg","sha256":"no_check","artifacts":[{"app":["Pad.app"]}]}
    );
    defer cask.deinit();
    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .cache_dir = unused_cache_dir,
        .db = undefined,
        .progress = null,
    };
    const copy = try std.fmt.allocPrint(a, "{s}/Caskroom/pad/1.0", .{prefix});

    // Both containers share this copy, so what a relative source resolves
    // against is pinned here: the named entries, whole, and nothing else.
    const stanzas = [_]BinaryEntry{
        .{ .source = "pad-cli", .target = null },
        .{ .source = "Extras/pad.sh", .target = "pad-sh" },
        .{ .source = "Pad.app/Contents/MacOS/pad", .target = null },
        .{ .source = "$APPDIR/Pad.app/Contents/MacOS/pad", .target = "pad2" },
        .{ .source = "$HOMEBREW_PREFIX/bin/pad3", .target = null },
    };
    try std.testing.expect(try installer.keepStageCopy(&cask, stage, "Pad.app", &stanzas));
    for ([_][]const u8{ "pad-cli", "Extras/pad.sh", "Extras/Manual.pdf" }) |rel| {
        try std.Io.Dir.accessAbsolute(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ copy, rel }), .{});
    }
    for ([_][]const u8{ "Pad.app", "Other.app", ".Trashes", "Applications" }) |rel| {
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ copy, rel }), .{}));
    }
    try std.Io.Dir.accessAbsolute(io, try std.fmt.allocPrint(a, "{s}/Pad.app/Contents/MacOS/pad", .{stage}), .{});

    // Nothing to copy when every stanza resolves elsewhere.
    std.Io.Dir.cwd().deleteTree(io, copy) catch {};
    try std.testing.expect(!try installer.keepStageCopy(&cask, stage, "Pad.app", stanzas[2..]));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, copy, .{}));

    // A helper the stage lacks, or one reachable only through a symlink, is
    // refused before the bundle moves, and leaves no Caskroom dir behind.
    const token_dir = try std.fmt.allocPrint(a, "{s}/Caskroom/pad", .{prefix});
    const missing = [_]BinaryEntry{ .{ .source = "pad-cli", .target = null }, .{ .source = "gone", .target = null } };
    try std.testing.expectError(error.InstallFailed, installer.keepStageCopy(&cask, stage, "Pad.app", &missing));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, token_dir, .{}));
    const through_link = [_]BinaryEntry{.{ .source = "Applications/Utilities/x", .target = null }};
    try std.testing.expectError(error.InstallFailed, installer.keepStageCopy(&cask, stage, "Pad.app", &through_link));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, token_dir, .{}));
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
        .cache_dir = unused_cache_dir,
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
        .cache_dir = unused_cache_dir,
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
        .cache_dir = unused_cache_dir,
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
        .cache_dir = unused_cache_dir,
        .db = undefined,
        .progress = null,
    };
    var buf: [512]u8 = undefined;
    // Creating the parent here would re-open the adoption hole it guards.
    try std.testing.expectError(error.InstallFailed, installer.freshTempDir(&buf, "mount", "tok"));
}

test "downloadToCache reuses a cached artifact only when its digest pins the bytes" {
    // The upgrade routes prefetch, then install; without this reuse every cask
    // upgrade would fetch its artifact twice. `offline` makes any real fetch a
    // distinct error, so a returned path proves nothing went over the wire.
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cache_dir = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_cachehit_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, cache_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);

    const dest = try std.fmt.allocPrint(a, "{s}/cached-1.0.zip", .{cache_dir});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, dest, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "artifact bytes");
    }
    const digest = try hashFileSha256(io, dest);

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = "/tmp/malt_cask_cachehit_prefix",
        .cache_dir = unused_cache_dir,
        .db = undefined,
        .progress = null,
    };
    installer.offline = true;

    const json_fmt =
        \\{{"token":"cached","name":["Cached"],"version":"{s}","url":"https://example.invalid/cached.zip","sha256":"{s}","artifacts":[{{"app":["Cached.app"]}}]}}
    ;
    var json_buf: [512]u8 = undefined;

    {
        // Pinned to the bytes already on disk: reused as-is.
        var c = try parseCask(a, try std.fmt.bufPrint(&json_buf, json_fmt, .{ "1.0", digest[0..] }));
        defer c.deinit();
        const hit = try installer.downloadToCache(&c, cache_dir, null);
        defer a.free(hit.path);
        try std.testing.expectEqualStrings(dest, hit.path);
        // Already hashed here, so `downloadOnly` must not hash it again.
        try std.testing.expect(hit.verified);
    }

    {
        // Same filename, different digest — the cached bytes are the wrong
        // artifact and must not be handed back.
        var c = try parseCask(a, try std.fmt.bufPrint(&json_buf, json_fmt, .{ "1.0", "a" ** 64 }));
        defer c.deinit();
        try std.testing.expectError(error.OfflineRequired, installer.downloadToCache(&c, cache_dir, null));
    }

    {
        // `no_check` casks reuse one filename across releases, so a cached file
        // is unverifiable and a stale hit would silently install an old version.
        var c = try parseCask(a, try std.fmt.bufPrint(&json_buf, json_fmt, .{ "1.0", "no_check" }));
        defer c.deinit();
        try std.testing.expectError(error.OfflineRequired, installer.downloadToCache(&c, cache_dir, null));
    }

    {
        // Nothing cached — every first install. An absent file must fall
        // through to the download, never surface as the lookup's own error.
        var c = try parseCask(a, try std.fmt.bufPrint(&json_buf, json_fmt, .{ "2.0", digest[0..] }));
        defer c.deinit();
        try std.testing.expectError(error.OfflineRequired, installer.downloadToCache(&c, cache_dir, null));
    }
}

test "a failed install keeps a digest-pinned artefact in the cache" {
    // The bytes were sha-verified before the install ran, so a failed mount or
    // copy is no reason to throw them away — `rollback --to` reads this file,
    // and re-fetching it is not always possible.
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const prefix = try std.fmt.allocPrintSentinel(a, "/tmp/malt_cask_keep_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    const cache_root = try std.fs.path.join(a, &.{ prefix, "cache" });
    const cache_dir = try std.fmt.allocPrint(a, "{s}/Cask", .{cache_root});
    try std.Io.Dir.cwd().createDirPath(io, cache_dir);
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(a, "{s}/Applications", .{prefix}));

    // Not a zip, so the extraction below fails after the cache hit.
    const dest = try std.fmt.allocPrint(a, "{s}/keeper-1.0.zip", .{cache_dir});
    {
        const f = try std.Io.Dir.createFileAbsolute(io, dest, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "not an archive");
    }
    const digest = try hashFileSha256(io, dest);

    var json_buf: [512]u8 = undefined;
    var cask = try parseCask(a, try std.fmt.bufPrint(&json_buf,
        \\{{"token":"keeper","name":["Keeper"],"version":"1.0","url":"https://example.invalid/keeper.zip","sha256":"{s}","artifacts":[{{"app":["Keeper.app"]}}]}}
    , .{digest[0..]}));
    defer cask.deinit();

    var installer: CaskInstaller = .{
        .allocator = a,
        .io = io,
        .environ = .empty,
        .prefix = prefix,
        .cache_dir = cache_root,
        .db = undefined,
        .progress = null,
    };
    installer.offline = true; // proves the cache hit, not a re-download, fed the install

    try std.testing.expectError(CaskError.InstallFailed, installer.install(&cask));
    try std.Io.Dir.accessAbsolute(io, dest, .{});
}

test "specPath composes the sidecar under the resolved cache dir, not the prefix" {
    // The sidecar must sit next to the artefact `downloadOnly` wrote, and
    // that lives under whatever the caller resolved (`MALT_CACHE` or
    // `{prefix}/cache`); composing from the prefix would strand it.
    var installer: CaskInstaller = .{
        .allocator = std.testing.allocator,
        .io = std.Options.debug_io,
        .environ = .empty,
        .prefix = "/opt/h",
        .cache_dir = "/alt",
        .db = undefined,
        .progress = null,
    };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/alt/Cask/font-x-1.0.fonts", try installer.specPath("font-x", "1.0", ".fonts", &buf));
    try std.testing.expectEqualStrings("/alt/Cask/tool-1.0.binaries", try installer.specPath("tool", "1.0", ".binaries", &buf));
}

// --- variations / depends_on ---

/// Top-level `url` names the Golden Gate build; the running-OS variation
/// names a different one. Both arch keys carry the same override so the
/// test reads the same on an arm64 and an Intel host.
const variation_fixture =
    \\{"token":"cocktail","version":"20.0.2","url":"https://e/Cocktail20GG.dmg","sha256":"aa",
    \\ "artifacts":[{"app":["Cocktail.app"]}],
    \\ "variations":{
    \\   "arm64_tahoe":{"url":"https://e/Cocktail19TE.dmg","sha256":"bb","version":"19.10"},
    \\   "tahoe":{"url":"https://e/Cocktail19TE.dmg","sha256":"bb","version":"19.10"}}}
;

test "variation overlay picks arm64_<codename> url and sha256" {
    var c = try parseCaskWithMajor(std.testing.allocator, variation_fixture, 26);
    defer c.deinit();
    try std.testing.expectEqualStrings("https://e/Cocktail19TE.dmg", c.url);
    try std.testing.expectEqualStrings("bb", c.sha256.?);
    try std.testing.expectEqualStrings("19.10", c.version);
}

test "variation overlay leaves top-level when key is absent" {
    var c = try parseCaskWithMajor(std.testing.allocator, variation_fixture, 27);
    defer c.deinit();
    try std.testing.expectEqualStrings("https://e/Cocktail20GG.dmg", c.url);
    try std.testing.expectEqualStrings("aa", c.sha256.?);
    try std.testing.expectEqualStrings("20.0.2", c.version);
}

test "variation overlay copies artifacts when the variation redefines them" {
    const json =
        \\{"token":"t","version":"1","url":"https://e/x.dmg","artifacts":[{"app":["Old.app"]}],
        \\ "variations":{"arm64_sonoma":{"artifacts":[{"app":["New.app"]}]},
        \\               "sonoma":{"artifacts":[{"app":["New.app"]}]}}}
    ;
    var c = try parseCaskWithMajor(std.testing.allocator, json, 14);
    defer c.deinit();
    // The uninstall path reads artifacts back from the parsed object, so
    // the resolved set must be what every reader sees.
    try std.testing.expectEqualStrings("New.app", parseAppName(c.parsed.value.object).?);
    try std.testing.expectEqualStrings("https://e/x.dmg", c.url);
}

test "variation overlay is screened like the top-level fields" {
    const json =
        \\{"token":"t","version":"1","url":"https://e/x.dmg",
        \\ "variations":{"arm64_sonoma":{"artifacts":[{"app":["../Evil.app"]}]},
        \\               "sonoma":{"artifacts":[{"app":["../Evil.app"]}]}}}
    ;
    try std.testing.expectError(CaskError.ParseFailed, parseCaskWithMajor(std.testing.allocator, json, 14));
}

test "depends_on macos >= gates os_supported" {
    const a = std.testing.allocator;
    const ge =
        \\{"token":"t","version":"1","url":"https://e/x.dmg","depends_on":{"macos":{">=":["15"]}}}
    ;
    {
        var c = try parseCaskWithMajor(a, ge, 14);
        defer c.deinit();
        try std.testing.expect(!c.os_supported);
        try std.testing.expectEqualStrings(">=", c.os_requirement.?.op);
        try std.testing.expectEqualStrings("15", c.os_requirement.?.version());
    }
    {
        var c = try parseCaskWithMajor(a, ge, 15);
        defer c.deinit();
        try std.testing.expect(c.os_supported);
    }
    const eq =
        \\{"token":"t","version":"1","url":"https://e/x.dmg","depends_on":{"macos":{"==":["14"]}}}
    ;
    {
        var c = try parseCaskWithMajor(a, eq, 14);
        defer c.deinit();
        try std.testing.expect(c.os_supported);
    }
    {
        var c = try parseCaskWithMajor(a, eq, 15);
        defer c.deinit();
        try std.testing.expect(!c.os_supported);
    }
    // A variation may tighten the requirement for the OS it targets.
    const via_variation =
        \\{"token":"t","version":"1","url":"https://e/x.dmg",
        \\ "variations":{"arm64_sonoma":{"depends_on":{"macos":{">=":["15"]}}},
        \\               "sonoma":{"depends_on":{"macos":{">=":["15"]}}}}}
    ;
    {
        var c = try parseCaskWithMajor(a, via_variation, 14);
        defer c.deinit();
        try std.testing.expect(!c.os_supported);
    }
    {
        var c = try parseCaskWithMajor(a,
            \\{"token":"t","version":"1","url":"https://e/x.dmg"}
        , 11);
        defer c.deinit();
        try std.testing.expect(c.os_supported);
        try std.testing.expect(c.os_requirement == null);
    }
}

test "unknown macOS major skips variation lookup" {
    var c = try parseCaskWithMajor(std.testing.allocator, variation_fixture, 99);
    defer c.deinit();
    try std.testing.expectEqualStrings("https://e/Cocktail20GG.dmg", c.url);
    try std.testing.expect(cask_variation.macosCodename(99) == null);
    var buf: [32]u8 = undefined;
    try std.testing.expect(cask_variation.variationKey(&buf, 99) == null);
    const key = cask_variation.variationKey(&buf, 26).?;
    try std.testing.expect(std.mem.endsWith(u8, key, "tahoe"));
    try std.testing.expectEqual(builtin.cpu.arch == .aarch64, std.mem.startsWith(u8, key, "arm64_"));
}

test "flightStepsJson reports allocation failure instead of storing no steps" {
    var c = try parseCaskWithMajor(std.testing.allocator,
        \\{"token":"box","version":"1","url":"https://x/b.zip","artifacts":[{"uninstall_preflight_steps":[{"steps":[{"type":"warn","message":"m"}]}]}]}
    , null);
    defer c.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, flightStepsJson(failing.allocator(), c.flight_steps));
    try std.testing.expect((try flightStepsJson(c.parsed.arena.allocator(), c.flight_steps)) != null);
}

test "parse keeps the four flight step arrays and ignores the rest" {
    var c = try parseCaskWithMajor(std.testing.allocator,
        \\{"token":"box","version":"6.0","url":"https://x/b.zip","artifacts":[
        \\ {"preflight_steps":[{"steps":[{"type":"mkdir_p","path":{"base":"home","path":"Library/roms"}}]}]},
        \\ {"app":["Box.app"]},
        \\ {"postflight_steps":[{"steps":[{"type":"write","path":{"base":"home","path":"Library/a"},"content":"x"},{"type":"warn","message":"m"}]}]},
        \\ {"uninstall_preflight_steps":[{"steps":[]}]},
        \\ {"uninstall_postflight_steps":[{"steps":[{"type":"terminate_process","name":"boxd"}]}]},
        \\ {"zap":[{"trash":["~/Library/Box"]}]}]}
    , null);
    defer c.deinit();

    try std.testing.expectEqual(@as(usize, 1), c.flight_steps.get(.preflight).?.len);
    try std.testing.expectEqual(@as(usize, 2), c.flight_steps.get(.postflight).?.len);
    try std.testing.expectEqual(@as(usize, 0), c.flight_steps.get(.uninstall_preflight).?.len);
    try std.testing.expectEqual(@as(usize, 1), c.flight_steps.get(.uninstall_postflight).?.len);
    try std.testing.expectEqualStrings("terminate_process", c.flight_steps.get(.uninstall_postflight).?[0].object.get("type").?.string);
}

test "a cask without flight steps parses every phase as absent" {
    var c = try parseCaskWithMajor(std.testing.allocator,
        \\{"token":"plain","version":"1","url":"https://x/p.zip","artifacts":[{"app":["P.app"]},{"preflight_steps":[{"steps":"not-an-array"}]}]}
    , null);
    defer c.deinit();
    for (std.enums.values(FlightPhase)) |phase| try std.testing.expect(c.flight_steps.get(phase) == null);
}

test "a variation's artifacts replace the flight steps too" {
    var c = try parseCaskWithMajor(std.testing.allocator,
        \\{"token":"v","version":"1","url":"https://x/v.zip",
        \\ "artifacts":[{"postflight_steps":[{"steps":[{"type":"warn","message":"top"}]}]}],
        \\ "variations":{"arm64_tahoe":{"artifacts":[{"postflight_steps":[{"steps":[{"type":"warn","message":"a"},{"type":"warn","message":"b"}]}]}]},
        \\               "tahoe":{"artifacts":[{"postflight_steps":[{"steps":[{"type":"warn","message":"a"},{"type":"warn","message":"b"}]}]}]}}}
    , 26);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), c.flight_steps.get(.postflight).?.len);
}

test "collectBinaryArtifacts returns every binary stanza in artifact order with its link name" {
    // The editor shape: two stanzas, each with a sibling full-path target.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"artifacts":[{"app":["Editor.app"]},
        \\ {"binary":["$APPDIR/Editor.app/Contents/Resources/app/bin/code"],"target":"$HOMEBREW_PREFIX/bin/code"},
        \\ {"binary":["$APPDIR/Editor.app/Contents/Resources/app/bin/code-tunnel"],"target":"$HOMEBREW_PREFIX/bin/code-tunnel"},
        \\ {"binary":["cli-aarch64",{"target":"cli"}]},
        \\ {"binary":["plain"]}]}
    , .{});
    defer parsed.deinit();

    const entries = (try collectBinaryArtifacts(std.testing.allocator, parsed.value.object)).?;
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("$APPDIR/Editor.app/Contents/Resources/app/bin/code", entries[0].source);
    try std.testing.expectEqualStrings("code", entries[0].target.?);
    try std.testing.expectEqualStrings("code-tunnel", entries[1].target.?);
    try std.testing.expectEqualStrings("cli-aarch64", entries[2].source);
    try std.testing.expectEqualStrings("cli", entries[2].target.?);
    try std.testing.expectEqualStrings("plain", entries[3].source);
    try std.testing.expect(entries[3].target == null);
}

test "collectBinaryArtifacts is null when the cask declares no binary" {
    for ([_][]const u8{
        "{}",
        \\{"artifacts":[{"app":["A.app"]}]}
        ,
        \\{"artifacts":[{"binary":[]}]}
        ,
        \\{"artifacts":"nope"}
        ,
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
        defer parsed.deinit();
        try std.testing.expect((try collectBinaryArtifacts(std.testing.allocator, parsed.value.object)) == null);
    }
}
