//! malt — cask module
//! Cask JSON parsing and installation (DMG, PKG, ZIP).

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

const sqlite = @import("../db/sqlite.zig");
const client_mod = @import("../net/client.zig");

pub const CaskError = error{
    ParseFailed,
    DownloadFailed,
    InstallFailed,
    UninstallFailed,
    Sha256Mismatch,
    OutOfMemory,
};

pub const Cask = struct {
    token: []const u8,
    name: []const u8,
    version: []const u8,
    desc: []const u8,
    homepage: []const u8,
    url: []const u8,
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
pub fn recordInstall(db: *sqlite.Database, cask: *const Cask, app_path: ?[]const u8) !void {
    var stmt = db.prepare(
        "INSERT OR REPLACE INTO casks (token, name, version, url, sha256, app_path, auto_updates) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
    ) catch return;
    defer stmt.finalize();

    stmt.bindText(1, cask.token) catch return;
    stmt.bindText(2, cask.name) catch return;
    stmt.bindText(3, cask.version) catch return;
    stmt.bindText(4, cask.url) catch return;
    if (cask.sha256) |s| stmt.bindText(5, s) catch return else stmt.bindNull(5) catch return;
    if (app_path) |p| stmt.bindText(6, p) catch return else stmt.bindNull(6) catch return;
    stmt.bindInt(7, if (cask.auto_updates) 1 else 0) catch return;
    _ = stmt.step() catch {};
}

/// Remove cask record from database.
pub fn removeRecord(db: *sqlite.Database, token: []const u8) !void {
    var stmt = db.prepare("DELETE FROM casks WHERE token = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindText(1, token) catch return;
    _ = stmt.step() catch {};
}

/// Determine the artifact type from the cask download URL.
pub const ArtifactType = enum { dmg, zip, pkg, unknown };

pub fn artifactTypeFromUrl(url: []const u8) ArtifactType {
    if (std.mem.endsWith(u8, url, ".dmg")) return .dmg;
    if (std.mem.endsWith(u8, url, ".zip")) return .zip;
    if (std.mem.endsWith(u8, url, ".pkg")) return .pkg;
    // Some URLs have query params after extension
    if (std.mem.indexOf(u8, url, ".dmg?") != null or std.mem.indexOf(u8, url, ".dmg#") != null) return .dmg;
    if (std.mem.indexOf(u8, url, ".zip?") != null or std.mem.indexOf(u8, url, ".zip#") != null) return .zip;
    if (std.mem.indexOf(u8, url, ".pkg?") != null or std.mem.indexOf(u8, url, ".pkg#") != null) return .pkg;
    return .unknown;
}

/// Extract the .app bundle name from cask JSON artifacts array.
/// Homebrew cask JSON: "artifacts": [{"app": ["Firefox.app"]}, ...]
pub fn parseAppName(obj: std.json.ObjectMap) ?[]const u8 {
    const artifacts_val = obj.get("artifacts") orelse return null;
    const artifacts = switch (artifacts_val) {
        .array => |a| a,
        else => return null,
    };
    for (artifacts.items) |item| {
        switch (item) {
            .object => |art_obj| {
                if (art_obj.get("app")) |app_val| {
                    switch (app_val) {
                        .array => |app_arr| {
                            if (app_arr.items.len > 0) {
                                return switch (app_arr.items[0]) {
                                    .string => |s| s,
                                    else => null,
                                };
                            }
                        },
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

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Database, prefix: [:0]const u8) CaskInstaller {
        return .{ .allocator = allocator, .db = db, .prefix = prefix, .progress = null };
    }

    /// Install a cask. Downloads, verifies SHA256, and installs based on artifact type.
    /// Returns the installed app path on success.
    pub fn install(self: *CaskInstaller, cask: *const Cask) CaskError![]const u8 {
        const artifact_type = artifactTypeFromUrl(cask.url);
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
            fs_compat.cwd().deleteFile(cache_path) catch {};
            self.allocator.free(cache_path);
        }

        // Verify SHA256
        self.verifySha256(cache_path, cask.sha256) catch
            return CaskError.Sha256Mismatch;

        // Determine target: /Applications or ~/Applications
        var app_dir_buf: [512]u8 = undefined;
        const app_dir = applicationsDir(&app_dir_buf);

        // Install based on type
        const app_path = switch (artifact_type) {
            .dmg => self.installDmg(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .zip => self.installZip(cache_path, app_dir, cask) catch return CaskError.InstallFailed,
            .pkg => self.installPkg(cache_path) catch return CaskError.InstallFailed,
            .unknown => return CaskError.InstallFailed,
        };

        // Record in Caskroom
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
            if (isAppRunning(app_path)) return CaskError.UninstallFailed;

            // Remove the app bundle
            fs_compat.deleteTreeAbsolute(app_path) catch {};
        }

        // Remove Caskroom entry
        var caskroom_buf: [512]u8 = undefined;
        const caskroom_path = std.fmt.bufPrint(&caskroom_buf, "{s}/Caskroom/{s}", .{ self.prefix, token }) catch "";
        if (caskroom_path.len > 0) fs_compat.deleteTreeAbsolute(caskroom_path) catch {};

        // Remove cache entry
        var cache_buf: [512]u8 = undefined;
        for ([_][]const u8{ ".dmg", ".zip", ".pkg" }) |ext| {
            const cache_file = std.fmt.bufPrint(&cache_buf, "{s}/cache/Cask/{s}{s}", .{ self.prefix, token, ext }) catch continue;
            fs_compat.cwd().deleteFile(cache_file) catch {};
        }

        // Remove DB record
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
        const ext_str = switch (artifactTypeFromUrl(cask.url)) {
            .dmg => ".dmg",
            .zip => ".zip",
            .pkg => ".pkg",
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
        var mount_child = fs_compat.Child.init(&mount_argv, std.heap.c_allocator);
        mount_child.spawn() catch return error.InstallFailed;
        const mount_term = mount_child.wait() catch return error.InstallFailed;
        switch (mount_term) {
            .exited => |code| if (code != 0) return error.InstallFailed,
            else => return error.InstallFailed,
        }

        // Ensure we unmount on any exit
        defer {
            const detach_argv = [_][]const u8{ "hdiutil", "detach", mount_point, "-quiet" };
            var detach = fs_compat.Child.init(&detach_argv, std.heap.c_allocator);
            detach.spawn() catch {};
            _ = detach.wait() catch {};
            fs_compat.deleteDirAbsolute(mount_point) catch {};
        }

        // Find the .app bundle name (from JSON artifacts or by scanning mount point)
        const app_name = parseAppName(cask.parsed.value.object) orelse
            self.findAppInDir(mount_point) orelse
            return error.InstallFailed;

        // Source and destination paths
        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ mount_point, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // Remove existing app if present (reinstall/upgrade)
        fs_compat.deleteTreeAbsolute(dst_app) catch {};

        // Copy .app bundle using ditto (preserves resource forks, xattrs)
        const ditto_argv = [_][]const u8{ "ditto", src_app, dst_app };
        var ditto_child = fs_compat.Child.init(&ditto_argv, std.heap.c_allocator);
        ditto_child.spawn() catch return error.InstallFailed;
        const ditto_term = ditto_child.wait() catch return error.InstallFailed;
        switch (ditto_term) {
            .exited => |code| if (code != 0) return error.InstallFailed,
            else => return error.InstallFailed,
        }

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
        defer fs_compat.deleteTreeAbsolute(extract_dir) catch {};

        // Extract with ditto -xk (handles macOS-specific ZIP features)
        const ditto_argv = [_][]const u8{ "ditto", "-xk", zip_path, extract_dir };
        var ditto_child = fs_compat.Child.init(&ditto_argv, std.heap.c_allocator);
        ditto_child.spawn() catch return error.InstallFailed;
        const ditto_term = ditto_child.wait() catch return error.InstallFailed;
        switch (ditto_term) {
            .exited => |code| if (code != 0) return error.InstallFailed,
            else => return error.InstallFailed,
        }

        // Find the .app
        const app_name = parseAppName(cask.parsed.value.object) orelse
            self.findAppInDir(extract_dir) orelse
            return error.InstallFailed;

        var src_buf: [512]u8 = undefined;
        const src_app = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ extract_dir, app_name }) catch
            return error.InstallFailed;

        const dst_app = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ app_dir, app_name });
        errdefer self.allocator.free(dst_app);

        // Remove existing
        fs_compat.deleteTreeAbsolute(dst_app) catch {};

        // Move .app to /Applications
        const mv_argv = [_][]const u8{ "ditto", src_app, dst_app };
        var mv_child = fs_compat.Child.init(&mv_argv, std.heap.c_allocator);
        mv_child.spawn() catch return error.InstallFailed;
        const mv_term = mv_child.wait() catch return error.InstallFailed;
        switch (mv_term) {
            .exited => |code| if (code != 0) return error.InstallFailed,
            else => return error.InstallFailed,
        }

        return dst_app;
    }

    fn installPkg(self: *CaskInstaller, pkg_path: []const u8) ![]const u8 {
        // PKG installs require sudo — the caller must confirm
        const argv = [_][]const u8{ "sudo", "installer", "-pkg", pkg_path, "-target", "/" };
        var child = fs_compat.Child.init(&argv, std.heap.c_allocator);
        child.spawn() catch return error.InstallFailed;
        const term = child.wait() catch return error.InstallFailed;
        switch (term) {
            .exited => |code| if (code != 0) return error.InstallFailed,
            else => return error.InstallFailed,
        }
        // PKG installs don't have a single app path — record the pkg location
        return std.fmt.allocPrint(self.allocator, "{s}", .{pkg_path}) catch return error.OutOfMemory;
    }

    /// Public wrapper for isAppRunning (used by uninstall.zig).
    pub fn isAppRunningPub(app_path: []const u8) bool {
        return isAppRunning(app_path);
    }

    fn findAppInDir(_: *CaskInstaller, dir_path: []const u8) ?[]const u8 {
        var dir = fs_compat.openDirAbsolute(dir_path, .{ .iterate = true }) catch return null;
        defer dir.close();
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".app")) {
                return entry.name;
            }
        }
        return null;
    }

    fn recordCaskroom(self: *CaskInstaller, cask: *const Cask) !void {
        // Create Caskroom/{token}/{version}/ to match Homebrew layout
        var buf: [512]u8 = undefined;
        const caskroom_ver = std.fmt.bufPrint(&buf, "{s}/Caskroom/{s}/{s}", .{
            self.prefix, cask.token, cask.version,
        }) catch return;
        fs_compat.cwd().makePath(caskroom_ver) catch {};
    }
};

/// SHA256 buffer size — one positional read per 64 KiB.
const sha256_read_chunk: usize = 64 * 1024;

/// Compute the SHA256 of `file_path` as lowercase hex. Streams via
/// `fs_compat.streamFile` so the file-reading loop lives in exactly
/// one place — no more hand-rolled offset bookkeeping.
pub fn hashFileSha256(file_path: []const u8) ![64]u8 {
    const file = try fs_compat.openFileAbsolute(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [sha256_read_chunk]u8 = undefined;
    try fs_compat.streamFile(file, &read_buf, .{
        .context = @ptrCast(&hasher),
        .func = &sha256Update,
    });
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return std.fmt.bytesToHex(hash, .lower);
}

/// Bridge `streamFile`'s erased-context callback to `Sha256.update`.
fn sha256Update(ctx: *anyopaque, chunk: []const u8) anyerror!void {
    const hasher: *std.crypto.hash.sha2.Sha256 = @ptrCast(@alignCast(ctx));
    hasher.update(chunk);
}

/// Verify `file_path` hashes to `expected` (lowercase hex). A null
/// `expected` or the literal `"no_check"` skips verification —
/// mirrors Homebrew's `sha256 :no_check` escape hatch for casks that
/// cannot be pinned (auto-updating installers).
pub fn verifyFileSha256(file_path: []const u8, expected: ?[]const u8) !void {
    const expected_hash = expected orelse return;
    if (std.mem.eql(u8, expected_hash, "no_check")) return;

    const got = try hashFileSha256(file_path);
    if (!std.mem.eql(u8, &got, expected_hash)) return error.Sha256Mismatch;
}

/// Check if an application is currently running by its path.
fn isAppRunning(app_path: []const u8) bool {
    const argv = [_][]const u8{ "pgrep", "-f", app_path };
    var child = fs_compat.Child.init(&argv, std.heap.c_allocator);
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .exited => |code| code == 0, // pgrep exits 0 if match found
        else => false,
    };
}

/// Determine the applications directory.
/// Uses /Applications if writable, otherwise ~/Applications formatted into `out`.
/// The caller owns `out`; the returned slice is either a compile-time literal
/// (no aliasing) or a slice of `out` (lives as long as `out`).
fn applicationsDir(out: []u8) []const u8 {
    // Check if /Applications is writable
    const test_path = "/Applications/.malt_write_test";
    const file = fs_compat.createFileAbsolute(test_path, .{}) catch {
        // Fallback to ~/Applications
        if (fs_compat.getenv("HOME")) |home| {
            const home_slice = std.mem.sliceTo(home, 0);
            const home_apps = std.fmt.bufPrint(out, "{s}/Applications", .{home_slice}) catch return "/Applications";
            fs_compat.makeDirAbsolute(home_apps) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return "/Applications",
            };
            return home_apps;
        }
        return "/Applications";
    };
    file.close();
    fs_compat.cwd().deleteFile(test_path) catch {};
    return "/Applications";
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
