//! malt — cask module
//! Cask JSON parsing and installation (DMG, PKG, ZIP, tar.gz).

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");
const install_cmd = @import("../cli/install.zig");
const archive_mod = @import("../fs/archive.zig");
const hash_mod = @import("hash.zig");
const child_mod = @import("child.zig");

pub const CaskError = error{
    ParseFailed,
    DownloadFailed,
    InstallFailed,
    UninstallFailed,
    Sha256Mismatch,
    OutOfMemory,
};

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

    const obj = parsed.value.object;

    return .{
        .token = getStr(obj, "token") orelse return CaskError.ParseFailed,
        .name = getFirstName(obj) orelse getStr(obj, "token") orelse return CaskError.ParseFailed,
        .version = getStr(obj, "version") orelse "unknown",
        .desc = getStr(obj, "desc") orelse "",
        .homepage = getStr(obj, "homepage") orelse "",
        .url = getStr(obj, "url") orelse return CaskError.ParseFailed,
        .sha256 = getStr(obj, "sha256"),
        .auto_updates = getBool(obj, "auto_updates") orelse false,
        .parsed = parsed,
    };
}

/// Record cask installation in database.
pub fn recordInstall(db: *sqlite.Database, cask: *const Cask, app_path: ?[]const u8) sqlite.SqliteError!void {
    var stmt = try db.prepare(
        "INSERT OR REPLACE INTO casks (token, name, version, url, sha256, app_path, auto_updates) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
    );
    defer stmt.finalize();

    try stmt.bindText(1, cask.token);
    try stmt.bindText(2, cask.name);
    try stmt.bindText(3, cask.version);
    try stmt.bindText(4, cask.url);
    if (cask.sha256) |s| try stmt.bindText(5, s) else try stmt.bindNull(5);
    if (app_path) |p| try stmt.bindText(6, p) else try stmt.bindNull(6);
    try stmt.bindInt(7, if (cask.auto_updates) 1 else 0);
    _ = try stmt.step();
}

/// Remove cask record from database.
pub fn removeRecord(db: *sqlite.Database, token: []const u8) sqlite.SqliteError!void {
    var stmt = try db.prepare("DELETE FROM casks WHERE token = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, token);
    _ = try stmt.step();
}

/// Determine the artifact type from the cask download URL.
/// `tar_gz` covers both `.tar.gz` and `.tgz` — the two spellings are
/// treated as a single container format here; the extractor is the same.
pub const ArtifactType = enum { dmg, zip, pkg, tar_gz, unknown };

pub fn artifactTypeFromUrl(url: []const u8) ArtifactType {
    if (std.mem.endsWith(u8, url, ".dmg")) return .dmg;
    if (std.mem.endsWith(u8, url, ".zip")) return .zip;
    if (std.mem.endsWith(u8, url, ".pkg")) return .pkg;
    if (std.mem.endsWith(u8, url, ".tar.gz")) return .tar_gz;
    if (std.mem.endsWith(u8, url, ".tgz")) return .tar_gz;
    // Some URLs have query params after extension
    if (std.mem.indexOf(u8, url, ".dmg?") != null or std.mem.indexOf(u8, url, ".dmg#") != null) return .dmg;
    if (std.mem.indexOf(u8, url, ".zip?") != null or std.mem.indexOf(u8, url, ".zip#") != null) return .zip;
    if (std.mem.indexOf(u8, url, ".pkg?") != null or std.mem.indexOf(u8, url, ".pkg#") != null) return .pkg;
    if (std.mem.indexOf(u8, url, ".tar.gz?") != null or std.mem.indexOf(u8, url, ".tar.gz#") != null) return .tar_gz;
    if (std.mem.indexOf(u8, url, ".tgz?") != null or std.mem.indexOf(u8, url, ".tgz#") != null) return .tar_gz;
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
    prefix: [:0]const u8,
    db: *sqlite.Database,
    progress: ?client_mod.ProgressCallback,
    /// Pre-resolved type for extensionless URLs (HEAD fallback).
    artifact_type_override: ?ArtifactType = null,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Database, prefix: [:0]const u8) CaskInstaller {
        return .{ .allocator = allocator, .db = db, .prefix = prefix, .progress = null };
    }

    /// Install a cask. Downloads, verifies SHA256, and installs based on artifact type.
    /// Returns the installed app path on success.
    pub fn install(self: *CaskInstaller, cask: *const Cask) CaskError![]const u8 {
        const artifact_type = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        if (artifact_type == .unknown) return CaskError.InstallFailed;

        // Ensure cache/Cask/ directory exists
        var cache_buf: [512]u8 = undefined;
        const cache_dir = std.fmt.bufPrint(&cache_buf, "{s}/cache/Cask", .{self.prefix}) catch
            return CaskError.OutOfMemory;
        fs_compat.makeDirAbsolute(cache_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return CaskError.InstallFailed,
        };

        // Download to cache
        const cache_path = self.downloadToCache(cask, cache_dir, self.progress) catch
            return CaskError.DownloadFailed;
        errdefer {
            // cache already leaked to disk; nothing to do on cleanup failure.
            fs_compat.cwd().deleteFile(cache_path) catch {};
            self.allocator.free(cache_path);
        }

        // Verify SHA256
        self.verifySha256(cache_path, cask.sha256) catch
            return CaskError.Sha256Mismatch;

        // Determine target: prefix-aware sandbox / /Applications / ~/Applications.
        var app_dir_buf: [512]u8 = undefined;
        const app_dir = applicationsDir(self.prefix, &app_dir_buf);

        // Install based on type
        const app_path = switch (artifact_type) {
            .dmg => self.installDmg(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .zip => self.installZip(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .pkg => self.installPkg(cache_path) catch return CaskError.InstallFailed,
            .tar_gz => self.installTarGz(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .unknown => return CaskError.InstallFailed,
        };

        // Caskroom dir is bookkeeping; app is already in place.
        self.recordCaskroom(cask) catch {};

        // Clean up cache file (keep for uninstall/upgrade reference if desired)
        // We keep the cache file so reinstalls are faster.

        self.allocator.free(cache_path);
        return app_path;
    }

    /// Uninstall a cask by token. Looks up app_path from DB, removes app, cleans up.
    pub fn uninstall(self: *CaskInstaller, token: []const u8) CaskError!void {
        // Look up from DB
        var stmt = self.db.prepare(
            "SELECT app_path FROM casks WHERE token = ?1 LIMIT 1;",
        ) catch return CaskError.UninstallFailed;
        defer stmt.finalize();
        stmt.bindText(1, token) catch return CaskError.UninstallFailed;

        const found = stmt.step() catch return CaskError.UninstallFailed;
        if (!found) return CaskError.UninstallFailed;

        const path_ptr = stmt.columnText(0);
        if (path_ptr) |p| {
            // sqlite3_column_text returns a null-terminated UTF-8 string per
            // the SQLite C API contract, so `sliceTo(.., 0)` is safe here.
            // There is an inherent TOCTOU window between this read and the
            // `deleteTreeAbsolute` below — accepted because cask uninstall
            // is a single-user operation and the bundle is protected by
            // filesystem permissions.
            const app_path = std.mem.sliceTo(p, 0);

            // Check if the app is running (best-effort)
            if (isAppRunning(self.allocator, app_path)) return CaskError.UninstallFailed;

            // app may already be gone (manual delete); continue to DB cleanup.
            fs_compat.deleteTreeAbsolute(app_path) catch {};
        }

        // Caskroom bookkeeping; continue so later removals still run.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}", .{ self.prefix, token }) catch "";
        if (caskroom_path.len > 0) fs_compat.deleteTreeAbsolute(caskroom_path) catch {};

        var cache_buf: [512]u8 = undefined;
        for ([_][]const u8{ ".dmg", ".zip", ".pkg", ".tar.gz" }) |ext| {
            const cache_file = std.fmt.bufPrint(&cache_buf, "{s}/cache/Cask/{s}{s}", .{ self.prefix, token, ext }) catch continue;
            // cache file may not exist for this extension.
            fs_compat.cwd().deleteFile(cache_file) catch {};
        }

        // DB row cleanup; uninstall already did the user-visible work.
        removeRecord(self.db, token) catch {};
    }

    /// Check installed version vs API version. Returns true if outdated.
    pub fn isOutdated(self: *CaskInstaller, token: []const u8, latest_version: []const u8) bool {
        var stmt = self.db.prepare(
            "SELECT version FROM casks WHERE token = ?1 LIMIT 1;",
        ) catch return false;
        defer stmt.finalize();
        stmt.bindText(1, token) catch return false;

        const found = stmt.step() catch return false;
        if (!found) return false;

        const ver_ptr = stmt.columnText(0) orelse return false;
        const installed = std.mem.sliceTo(ver_ptr, 0);
        return !std.mem.eql(u8, installed, latest_version);
    }

    // --- Private helpers ---

    fn downloadToCache(self: *CaskInstaller, cask: *const Cask, cache_dir: []const u8, progress: ?client_mod.ProgressCallback) ![]const u8 {
        const resolved = self.artifact_type_override orelse artifactTypeFromUrl(cask.url);
        const ext_str = switch (resolved) {
            .dmg => ".dmg",
            .zip => ".zip",
            .pkg => ".pkg",
            .tar_gz => ".tar.gz",
            .unknown => ".bin",
        };
        const dest = try std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ cache_dir, cask.token, ext_str });
        errdefer self.allocator.free(dest);

        // Download via HTTP client
        var http = client_mod.HttpClient.init(self.allocator);
        defer http.deinit();

        var resp = try http.getWithHeaders(cask.url, &.{}, progress);
        defer resp.deinit();

        if (resp.status != 200) return error.DownloadFailed;

        // Write to file
        const file = try fs_compat.createFileAbsolute(dest, .{});
        defer file.close();
        try file.writeAll(resp.body);

        return dest;
    }

    fn verifySha256(_: *CaskInstaller, file_path: []const u8, expected: ?[]const u8) !void {
        return verifyFileSha256(file_path, expected);
    }

    fn installDmg(self: *CaskInstaller, dmg_path: []const u8, app_dir: []const u8, cask: *const Cask) ![]const u8 {
        // Create a temp mount point
        var mount_buf: [512]u8 = undefined;
        const mount_point = std.fmt.bufPrint(&mount_buf, "{s}/tmp/cask_mount_{s}", .{ self.prefix, cask.token }) catch
            return error.InstallFailed;
        fs_compat.makeDirAbsolute(mount_point) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return error.InstallFailed,
        };

        // Mount DMG (hdiutil attach -nobrowse -readonly -mountpoint {path} {dmg})
        const mount_argv = [_][]const u8{
            "hdiutil",     "attach",
            "-nobrowse",   "-readonly",
            "-mountpoint", mount_point,
            dmg_path,
        };
        child_mod.runOrFail(self.allocator, &mount_argv) catch return error.InstallFailed;

        // Unmount on any exit; kernel reaps stuck mounts on reboot if both fail.
        defer {
            const detach_argv = [_][]const u8{ "hdiutil", "detach", mount_point, "-quiet" };
            child_mod.runOrFail(self.allocator, &detach_argv) catch {};
            fs_compat.deleteDirAbsolute(mount_point) catch {};
        }

        // Find the .app bundle name (from JSON artifacts or by scanning mount point).
        // app_name_buf owns the fallback name past iterator teardown.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(mount_point, &app_name_buf) orelse
            return error.InstallFailed;

        // Source and destination paths
        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ mount_point, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present (fresh install).
        fs_compat.deleteTreeAbsolute(dst_app) catch {};

        // Copy .app bundle using ditto (preserves resource forks, xattrs)
        const ditto_argv = [_][]const u8{ "ditto", src_app, dst_app };
        child_mod.runOrFail(self.allocator, &ditto_argv) catch return error.InstallFailed;

        return dst_app;
    }

    fn installZip(self: *CaskInstaller, zip_path: []const u8, app_dir: []const u8, cask: *const Cask) ![]const u8 {
        // Create temp extraction directory
        var tmp_buf: [512]u8 = undefined;
        const extract_dir = std.fmt.bufPrint(&tmp_buf, "{s}/tmp/cask_extract_{s}", .{ self.prefix, cask.token }) catch
            return error.InstallFailed;
        fs_compat.makeDirAbsolute(extract_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return error.InstallFailed,
        };
        // temp extract dir; leftover tolerated if teardown races.
        defer fs_compat.deleteTreeAbsolute(extract_dir) catch {};

        // Extract with ditto -xk (handles macOS-specific ZIP features)
        const ditto_argv = [_][]const u8{ "ditto", "-xk", zip_path, extract_dir };
        child_mod.runOrFail(self.allocator, &ditto_argv) catch return error.InstallFailed;

        // Find the .app. app_name_buf owns the fallback past iterator teardown.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(extract_dir, &app_name_buf) orelse
            return error.InstallFailed;

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ extract_dir, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present.
        fs_compat.deleteTreeAbsolute(dst_app) catch {};

        // Move .app to /Applications
        const mv_argv = [_][]const u8{ "ditto", src_app, dst_app };
        child_mod.runOrFail(self.allocator, &mv_argv) catch return error.InstallFailed;

        return dst_app;
    }

    /// Install a `.tar.gz` cask. Two shapes are supported:
    ///   1. `binary` artifacts — extract into `Caskroom/<token>/<version>/`
    ///      and symlink the first `binary` entry into `<prefix>/bin/`.
    ///   2. `app` artifacts — extract and promote the `.app` to `app_dir`,
    ///      mirroring the zip path for the rare tar.gz-wrapped bundle.
    ///
    /// Returns the bin symlink for binary casks, the `.app` path for app
    /// casks — whichever the uninstaller needs to remove later.
    fn installTarGz(
        self: *CaskInstaller,
        archive_path: []const u8,
        app_dir: []const u8,
        cask: *const Cask,
    ) ![]const u8 {
        // Caskroom/<token>/<version>/ doubles as the extraction root so
        // the extracted payload is already at its final home — binaries
        // then just need a stable symlink off `<prefix>/bin/`.
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return error.InstallFailed;
        fs_compat.cwd().makePath(caskroom_ver) catch return error.InstallFailed;

        archive_mod.extractTarGz(archive_path, caskroom_ver) catch return error.InstallFailed;

        if (parseBinaryName(cask.parsed.value.object)) |src_name| {
            const link_name = parseBinaryTarget(cask.parsed.value.object) orelse
                std.fs.path.basename(src_name);
            return try self.linkCaskBinary(caskroom_ver, src_name, link_name);
        }

        // Fallback: .app inside a tar.gz (uncommon but valid). Reuse the
        // zip path's "promote .app to app_dir" shape.
        var app_name_buf: [256]u8 = undefined;
        const app_name = parseAppName(cask.parsed.value.object) orelse
            findAppInDir(caskroom_ver, &app_name_buf) orelse
            return error.InstallFailed;

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ caskroom_ver, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // existing app may not be present.
        fs_compat.deleteTreeAbsolute(dst_app) catch {};
        const mv_argv = [_][]const u8{ "ditto", src_app, dst_app };
        child_mod.runOrFail(self.allocator, &mv_argv) catch return error.InstallFailed;
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
            return try std.fmt.allocPrint(
                self.allocator,
                "{s}/{s}",
                .{ self.prefix, src[env_prefix.len..] },
            );
        }
        if (std.mem.indexOfScalar(u8, src, '/') != null) {
            return try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, src });
        }
        return (findFileInTree(self.allocator, root, src) catch null) orelse
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
        const abs_bin = try self.resolveCaskBinaryPath(caskroom_ver, src_name);
        defer self.allocator.free(abs_bin);

        // Archives sometimes land without the x-bit when built on CI.
        const exec_file = fs_compat.openFileAbsolute(abs_bin, .{ .mode = .read_write }) catch
            return error.InstallFailed;
        // chmod may fail on FUSE/NFS mounts; symlink still works if bit was set.
        exec_file.chmod(0o755) catch {};
        exec_file.close();

        var bin_parent_buf: [512]u8 = undefined;
        const bin_parent = std.fmt.bufPrint(&bin_parent_buf, "{s}/bin", .{self.prefix}) catch
            return error.InstallFailed;
        fs_compat.cwd().makePath(bin_parent) catch return error.InstallFailed;

        const link_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ bin_parent, link_name });
        errdefer self.allocator.free(link_path);

        // stale link may not exist (fresh install); symLink below is authoritative.
        fs_compat.cwd().deleteFile(link_path) catch {};
        fs_compat.symLinkAbsolute(abs_bin, link_path, .{}) catch return error.InstallFailed;
        return link_path;
    }

    fn installPkg(self: *CaskInstaller, pkg_path: []const u8) ![]const u8 {
        // PKG installs require sudo — the caller must confirm
        const argv = [_][]const u8{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" };
        child_mod.runOrFail(self.allocator, &argv) catch return error.InstallFailed;
        // PKG installs don't have a single app path — record the pkg location
        return std.fmt.allocPrint(self.allocator, "{s}", .{pkg_path}) catch return error.OutOfMemory;
    }

    /// Public wrapper for isAppRunning (used by uninstall.zig).
    pub fn isAppRunningPub(allocator: std.mem.Allocator, app_path: []const u8) bool {
        return isAppRunning(allocator, app_path);
    }

    fn recordCaskroom(self: *CaskInstaller, cask: *const Cask) !void {
        // Create Caskroom/{token}/{version}/ to match Homebrew layout
        var buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return;
        // Caskroom dir is cosmetic bookkeeping; install already recorded in DB.
        fs_compat.cwd().makePath(caskroom_ver) catch {};
    }
};

/// Walk `root` looking for a regular file whose basename equals `name`
/// and return its absolute path (owned by the caller). tar.gz archives
/// often nest the binary one or two levels deep, so the installer can't
/// assume it sits at the extraction root. Returns null on no match.
pub fn findFileInTree(
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
) !?[]u8 {
    var dir = fs_compat.openDirAbsolute(root, .{ .iterate = true }) catch return null;
    defer dir.close();

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
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
pub fn findAppInDir(dir_path: []const u8, out_buf: []u8) ?[]const u8 {
    var dir = fs_compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
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
pub fn hashFileSha256(file_path: []const u8) ![64]u8 {
    return hash_mod.hashFileSha256Hex(file_path);
}

/// Verify `file_path` hashes to `expected` (lowercase hex). A null
/// `expected` or the literal `"no_check"` skips verification —
/// mirrors Homebrew's `sha256 :no_check` escape hatch for casks that
/// cannot be pinned (auto-updating installers).
pub fn verifyFileSha256(file_path: []const u8, expected: ?[]const u8) !void {
    const expected_hash = expected orelse return;
    if (std.mem.eql(u8, expected_hash, "no_check")) return;

    const got = try hashFileSha256(file_path);
    // Constant-time SHA compare — mirrors install.zig to close the
    // byte-by-byte timing oracle on the expected hash.
    if (!install_cmd.constantTimeEql(u8, &got, expected_hash)) return error.Sha256Mismatch;
}

/// Check if an application is currently running by its path.
fn isAppRunning(allocator: std.mem.Allocator, app_path: []const u8) bool {
    const argv = [_][]const u8{ "pgrep", "-f", app_path };
    var child = fs_compat.Child.init(&argv, allocator);
    child.spawn() catch return false;
    const term = child.wait() catch return false;
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
fn applicationsDir(prefix: []const u8, out: []u8) []const u8 {
    const env_appdir = fs_compat.getenv("MALT_APPDIR");
    const env_home = fs_compat.getenv("HOME");

    const test_path = "/Applications/.malt_write_test";
    const probe = fs_compat.createFileAbsolute(test_path, .{});
    const system_writable = if (probe) |f| blk: {
        f.close();
        // probe file cleanup; leaving it behind would still be benign.
        fs_compat.cwd().deleteFile(test_path) catch {};
        break :blk true;
    } else |_| false;

    const chosen = resolveAppDir(prefix, env_appdir, env_home, system_writable, out);

    // mkdir the chosen path unless it's the system /Applications (which
    // is a literal, not a slice of `out`, and either pre-exists or we
    // already proved it unwritable above).
    if (chosen.ptr != "/Applications".ptr) {
        fs_compat.makeDirAbsolute(chosen) catch |e| switch (e) {
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

    pub fn version(self: *const InstalledCask) []const u8 {
        return self.version_buf[0..self.version_len];
    }

    pub fn appPath(self: *const InstalledCask) ?[]const u8 {
        if (!self.has_app_path) return null;
        return self.app_path_buf[0..self.app_path_len];
    }
};

/// Look up installed cask info from DB. Copies data to avoid dangling pointers.
pub fn lookupInstalled(db: *sqlite.Database, token: []const u8) ?InstalledCask {
    var stmt = db.prepare(
        "SELECT version, app_path FROM casks WHERE token = ?1 LIMIT 1;",
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
