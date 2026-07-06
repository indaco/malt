//! malt — Homebrew API client
//! Fetches formula and cask metadata from formulae.brew.sh with caching.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const path_component = @import("../fs/path_component.zig");
const client_mod = @import("client.zig");
const mirror_mod = @import("mirror.zig");

const cache_ttl_secs: i64 = 300; // 5 minutes

/// Names-index TTL. The full Homebrew name list changes on the order of days
/// (new formulae merged, tokens renamed), so a 24 h window avoids burning
/// ~40 MiB of fetch per search while still picking up changes within a day.
pub const index_ttl_secs: i64 = 24 * 60 * 60;

/// Versions-index TTL. The outdated report needs fresher upstream data
/// than search's 24 h name list, so this matches the per-formula cache
/// (`cache_ttl_secs`) and the snapshot's max age. Invariant:
/// `versions_ttl_secs <= snapshot_default_max_age_minutes * 60`.
pub const versions_ttl_secs: i64 = 5 * 60;

pub const ApiError = error{
    NotFound,
    ApiUnreachable,
    InvalidResponse,
    InvalidName,
    CacheError,
    /// Offline mode is active and the snapshot cache had no entry for
    /// this key. Distinct from `ApiUnreachable` so the CLI can route
    /// straight to "offline mode: <kind> '<name>' not cached" instead
    /// of the generic network-failure message.
    OfflineRequired,
    OutOfMemory,
};

/// Validate a formula/cask name to prevent path traversal and URL injection.
/// Allowed characters: [a-z0-9@._+-]
pub fn validateName(name: []const u8) ApiError!void {
    if (name.len == 0 or name.len > 128) return ApiError.InvalidName;
    if (std.mem.indexOf(u8, name, "..") != null) return ApiError.InvalidName;
    for (name) |ch| {
        switch (ch) {
            'a'...'z', '0'...'9', '@', '.', '_', '+', '-' => {},
            else => return ApiError.InvalidName,
        }
    }
}

/// Parse a Homebrew formula.json / cask.json body and emit a newline-
/// delimited list of names (formulae) or tokens (casks). The caller owns
/// the returned bytes. Uses `ignore_unknown_fields` so the parser skips
/// the megabytes of metadata we don't need — only the name/token string
/// per entry is retained.
pub fn extractNames(
    allocator: std.mem.Allocator,
    kind: BrewApi.Kind,
    json_body: []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (kind) {
        .formula => {
            const Entry = struct { name: []const u8 };
            const parsed = try std.json.parseFromSliceLeaky(
                []Entry,
                a,
                json_body,
                .{ .ignore_unknown_fields = true },
            );
            for (parsed) |e| {
                // Drop tap-controlled names that aren't a clean path component;
                // the search index feeds path-building sinks downstream.
                if (!path_component.isPathComponent(e.name)) continue;
                try out.appendSlice(allocator, e.name);
                try out.append(allocator, '\n');
            }
        },
        .cask => {
            const Entry = struct { token: []const u8 };
            const parsed = try std.json.parseFromSliceLeaky(
                []Entry,
                a,
                json_body,
                .{ .ignore_unknown_fields = true },
            );
            for (parsed) |e| {
                if (!path_component.isPathComponent(e.token)) continue;
                try out.appendSlice(allocator, e.token);
                try out.append(allocator, '\n');
            }
        },
    }

    return out.toOwnedSlice(allocator);
}

/// Parse the same bulk dump as `extractNames`, but keep the data the
/// outdated check needs: `<name>\t<versions.stable>\t<revision>` per line.
/// Formulae carry `versions.stable` + integer `revision` (missing → 0);
/// casks carry their top-level `version` (no revision, emitted as 0).
/// Entries without a usable version string are skipped — an empty version
/// can't be compared, so it never reaches the map. `ignore_unknown_fields`
/// drops the megabytes we don't need; caller owns the returned bytes.
pub fn extractVersions(
    allocator: std.mem.Allocator,
    kind: BrewApi.Kind,
    json_body: []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    switch (kind) {
        .formula => {
            // Defaults make missing `versions`/`revision` non-fatal; the
            // optional `stable` lets us drop unversioned entries.
            const Versions = struct { stable: ?[]const u8 = null };
            const Entry = struct {
                name: []const u8 = "",
                versions: Versions = .{},
                revision: i64 = 0,
            };
            const parsed = try std.json.parseFromSliceLeaky(
                []Entry,
                a,
                json_body,
                .{ .ignore_unknown_fields = true },
            );
            for (parsed) |e| {
                const stable = e.versions.stable orelse continue;
                try appendVersionLine(allocator, &out, e.name, stable, e.revision);
            }
        },
        .cask => {
            // Casks use a flat `version`; the dump carries no revision.
            const Entry = struct {
                token: []const u8 = "",
                version: ?[]const u8 = null,
            };
            const parsed = try std.json.parseFromSliceLeaky(
                []Entry,
                a,
                json_body,
                .{ .ignore_unknown_fields = true },
            );
            for (parsed) |e| {
                const ver = e.version orelse continue;
                try appendVersionLine(allocator, &out, e.token, ver, 0);
            }
        },
    }

    return out.toOwnedSlice(allocator);
}

/// Append one `<name>\t<stable>\t<revision>\n` record, skipping entries
/// with an empty name or version (nothing the consumer can key or compare).
fn appendVersionLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    stable: []const u8,
    revision: i64,
) !void {
    if (stable.len == 0) return;
    // Drop a name/token that isn't a clean path component (rejects empty too);
    // it keys the outdated map against on-disk kegs.
    if (!path_component.isPathComponent(name)) return;
    // Untrusted dump fields: a tab or newline would corrupt the line-
    // delimited side-car the consumer splits on, so drop the whole entry
    // rather than emit a record that mis-parses downstream.
    if (containsDelimiter(name) or containsDelimiter(stable)) return;
    try out.appendSlice(allocator, name);
    try out.append(allocator, '\t');
    try out.appendSlice(allocator, stable);
    try out.append(allocator, '\t');
    // Negative revision can't match an installed keg path; clamp to 0.
    const rev = @max(revision, 0);
    // [24]u8 holds any i64 ("-9223372036854775808" is 20 chars), so the
    // bufPrint can't fail — unreachable is a provable bound, not a guess.
    var rbuf: [24]u8 = undefined;
    const rstr = std.fmt.bufPrint(&rbuf, "{d}", .{rev}) catch unreachable;
    try out.appendSlice(allocator, rstr);
    try out.append(allocator, '\n');
}

/// True when `s` carries a tab or newline — the two bytes that delimit the
/// version side-car. Such an entry can't be represented and is dropped.
fn containsDelimiter(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\t\n") != null;
}

/// Case-insensitive substring scan over a newline-delimited names index.
/// Returns a list of slices into `index` (caller-owned container, elements
/// are borrowed — caller must keep `index` alive for their lifetime).
///
/// Matches brew's `search <term>` UX: a single substring test per entry,
/// no ranking. Queries are lowercased once, the index once, and compared
/// with `indexOf`. For a ~200 KiB combined index this is well under 1 ms.
pub fn findNameMatches(
    allocator: std.mem.Allocator,
    index: []const u8,
    query: []const u8,
) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);

    // Pre-lowercase the query once. Names from the Homebrew index are
    // already lowercase by convention, so the scan is effectively
    // case-insensitive without an extra transform per candidate.
    var qbuf: [128]u8 = undefined;
    if (query.len == 0 or query.len > qbuf.len) return out.toOwnedSlice(allocator);
    const qlower = std.ascii.lowerString(qbuf[0..query.len], query);

    var it = std.mem.splitScalar(u8, index, '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (std.mem.indexOf(u8, name, qlower) != null) {
            try out.append(allocator, name);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const BrewApi = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,
    cache_dir: []const u8,
    /// Metadata-API base URL. Mutable post-init so cli/ call sites can
    /// drop in `ctx.mirrors.api_base`; mirror precedence + HTTPS
    /// validation are enforced upstream by `mirror.resolve`.
    base_url: []const u8 = mirror_mod.default_api_base_url,
    /// When true, every fetch serves from the snapshot cache (any age)
    /// and returns `OfflineRequired` on a miss instead of dialing out.
    /// Set by cli/ call sites from `ctx.offline`.
    offline: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, http: *client_mod.HttpClient, cache_dir: []const u8) BrewApi {
        return .{
            .io = io,
            .allocator = allocator,
            .http = http,
            .cache_dir = cache_dir,
        };
    }

    /// Build the formula JSON URL for `name`. Pure — `pub` so tests
    /// can pin the override-honouring shape without driving the cache.
    pub fn buildFormulaUrl(buf: []u8, base: []const u8, name: []const u8) ApiError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/formula/{s}.json", .{ base, name }) catch
            ApiError.OutOfMemory;
    }

    /// Build the cask JSON URL for `token`. Pure — see `buildFormulaUrl`.
    pub fn buildCaskUrl(buf: []u8, base: []const u8, token: []const u8) ApiError![]const u8 {
        return std.fmt.bufPrint(buf, "{s}/cask/{s}.json", .{ base, token }) catch
            ApiError.OutOfMemory;
    }

    /// Build the names-index URL for `kind`. Pure — see `buildFormulaUrl`.
    pub fn buildNamesIndexUrl(buf: []u8, base: []const u8, kind: Kind) ApiError![]const u8 {
        const suffix: []const u8 = switch (kind) {
            .formula => "/formula.json",
            .cask => "/cask.json",
        };
        return std.fmt.bufPrint(buf, "{s}{s}", .{ base, suffix }) catch
            ApiError.OutOfMemory;
    }

    /// Fetch formula JSON. Returns caller-owned bytes.
    pub fn fetchFormula(self: *BrewApi, name: []const u8) ApiError![]const u8 {
        try validateName(name);
        var url_buf: [512]u8 = undefined;
        const url = try buildFormulaUrl(&url_buf, self.base_url, name);
        return self.fetchCached(name, url, "formula_");
    }

    /// Fetch cask JSON. Returns caller-owned bytes.
    pub fn fetchCask(self: *BrewApi, token: []const u8) ApiError![]const u8 {
        try validateName(token);
        var url_buf: [512]u8 = undefined;
        const url = try buildCaskUrl(&url_buf, self.base_url, token);
        return self.fetchCached(token, url, "cask_");
    }

    pub const Kind = enum { formula, cask };

    /// Cache filename prefix for each `Kind`. Centralised so probe and
    /// fetch helpers can't drift out of sync over which name they stat.
    fn prefixForKind(kind: Kind) []const u8 {
        return switch (kind) {
            .formula => "formula_",
            .cask => "cask_",
        };
    }

    /// Existence probe that reuses the same cache layout as `fetchFormula` /
    /// `fetchCask` without ever reading the cached body. On a warm 5-minute
    /// cache this is a single `statFile` call; on a miss it falls through to
    /// the regular fetch path so the caller's subsequent install still finds
    /// the body on disk. Returns `false` for names that 404; `InvalidName` /
    /// `ApiUnreachable` are propagated.
    pub fn exists(self: *BrewApi, name: []const u8, kind: Kind) ApiError!bool {
        try validateName(name);
        const prefix = prefixForKind(kind);

        if (self.readNotFoundCache(name, prefix)) return false;
        if (self.cachedFresh(name, prefix)) return true;

        // Cache miss — do a real fetch so the body is cached for any
        // follow-up `install`. We own the result but don't need it.
        const body = (switch (kind) {
            .formula => self.fetchFormula(name),
            .cask => self.fetchCask(name),
        }) catch |e| switch (e) {
            ApiError.NotFound => return false,
            else => return e,
        };
        self.allocator.free(body);
        return true;
    }

    /// Single-stat presence probe — no body read, no parse, no TTL gate
    /// (freshness is `fetchCached`'s problem). Used to skip the cask-
    /// ambiguity warning when no cask of that name has ever been cached.
    pub fn cachedExists(self: *BrewApi, name: []const u8, kind: Kind) bool {
        const prefix = prefixForKind(kind);
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, name }) catch return false;
        _ = std.Io.Dir.cwd().statFile(self.io, cache_path, .{}) catch return false;
        return true;
    }

    /// Return true iff a fresh 200 cache entry exists for `key` — same
    /// TTL rule as `readCache`, but without reading the body.
    fn cachedFresh(self: *BrewApi, key: []const u8, prefix: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return false;
        const stat = std.Io.Dir.cwd().statFile(self.io, cache_path, .{}) catch return false;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        return now - mtime_secs <= cache_ttl_secs;
    }

    /// Cache key infix for each `Kind`, shared by both side-cars.
    fn indexKey(kind: Kind) []const u8 {
        return switch (kind) {
            .formula => "formula",
            .cask => "cask",
        };
    }

    /// Both side-cars from one bulk parse; caller owns both slices.
    const IndexPair = struct { names: []const u8, versions: []const u8 };

    /// Fetch the newline-delimited names index for all formulae or casks.
    /// Caller-owned bytes. Backed by a 24 h on-disk cache: the one-time
    /// parse of the ~28 MiB / ~14 MiB Homebrew JSON dump produces a
    /// ~130 KiB / ~70 KiB plain-text list, which substring search can
    /// then linear-scan in well under 1 ms.
    pub fn fetchNamesIndex(self: *BrewApi, kind: Kind) ApiError![]const u8 {
        const key = indexKey(kind);
        if (self.readIndexFile("names_", key, index_ttl_secs)) |cached| return cached;

        if (self.offline) {
            // Names index has no 404 form — a miss in offline mode means
            // the user never warmed the index, so search can't run at all.
            if (self.readIndexFile("names_", key, null)) |cached| return cached;
            return ApiError.OfflineRequired;
        }

        const pair = try self.fetchAndWriteIndex(kind, key);
        self.allocator.free(pair.versions);
        return pair.names;
    }

    /// Fetch the `<name>\t<stable>\t<revision>` version side-car for all
    /// formulae or casks. Caller-owned bytes. Shares the names fetch's
    /// single bulk download — a cold call here serves whichever side-car
    /// the other already wrote rather than re-pulling the dump. Pinned to
    /// a tighter TTL (`versions_ttl_secs`) than the names list because an
    /// outdated report must reflect releases the search list can lag.
    pub fn fetchVersionsIndex(self: *BrewApi, kind: Kind) ApiError![]const u8 {
        const key = indexKey(kind);
        if (self.readIndexFile("versions_", key, versions_ttl_secs)) |cached| return cached;

        if (self.offline) {
            // Mirror names: serve a stale-but-present map rather than fail —
            // an offline user wants their last warmed versions, not an error.
            if (self.readIndexFile("versions_", key, null)) |cached| return cached;
            return ApiError.OfflineRequired;
        }

        const pair = try self.fetchAndWriteIndex(kind, key);
        self.allocator.free(pair.names);
        return pair.versions;
    }

    /// Download the bulk dump once, extract both side-cars, write both.
    /// Folding the two extractors into one fetch is a requirement, not an
    /// optimisation: it stops a cold versions fetch from re-pulling a dump
    /// the names fetch already has on disk. Caller owns both slices.
    ///
    /// The GET is conditional: a stored ETag rides as `If-None-Match`, so an
    /// unchanged dump answers 304 with no body and both side-cars are merely
    /// marked fresh. A 200 (changed dump, or first-ever fetch) re-extracts
    /// both and persists the new ETag. The public dump needs no auth header,
    /// so none is sent — formulae.brew.sh is a CDN that ignores it.
    fn fetchAndWriteIndex(self: *BrewApi, kind: Kind, key: []const u8) ApiError!IndexPair {
        var url_buf: [512]u8 = undefined;
        const url = try buildNamesIndexUrl(&url_buf, self.base_url, kind);

        const stored_etag = self.readIndexEtag(key);
        defer if (stored_etag) |e| self.allocator.free(e);

        var resp = self.http.getConditional(url, stored_etag, &.{}) catch return ApiError.ApiUnreachable;
        defer resp.deinit();

        if (resp.not_modified) {
            // Unchanged upstream: restart both side-cars' TTL without a
            // rewrite and serve the bytes already on disk.
            self.touchIndex("names_", key);
            self.touchIndex("versions_", key);
            if (self.readIndexFile("names_", key, null)) |names| {
                if (self.readIndexFile("versions_", key, null)) |versions| {
                    return .{ .names = names, .versions = versions };
                }
                self.allocator.free(names);
            }
            // ETag present but a side-car is gone (evicted / wiped): drop the
            // ETag so the next refresh re-downloads unconditionally rather
            // than looping on a 304 it can no longer satisfy.
            self.deleteIndexEtag(key);
            return ApiError.ApiUnreachable;
        }

        if (resp.status != 200) return ApiError.ApiUnreachable;

        const names = extractNames(self.allocator, kind, resp.body) catch |e| switch (e) {
            error.OutOfMemory => return ApiError.OutOfMemory,
            else => return ApiError.InvalidResponse,
        };
        errdefer self.allocator.free(names);
        const versions = extractVersions(self.allocator, kind, resp.body) catch |e| switch (e) {
            error.OutOfMemory => return ApiError.OutOfMemory,
            else => return ApiError.InvalidResponse,
        };
        errdefer self.allocator.free(versions);

        self.writeIndexFile("names_", key, names);
        self.writeIndexFile("versions_", key, versions);
        self.writeIndexEtag(key, resp.etag);
        return .{ .names = names, .versions = versions };
    }

    /// Read an index side-car (`names_` / `versions_`) for `key`. `ttl`
    /// gates freshness; null bypasses the gate so offline mode can serve a
    /// stale-but-present file. Returns caller-owned bytes, or null on any
    /// miss / read error.
    fn readIndexFile(self: *BrewApi, infix: []const u8, key: []const u8, ttl: ?i64) ?[]const u8 {
        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.txt", .{ self.cache_dir, infix, key }) catch return null;

        if (ttl) |limit| {
            const stat = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch return null;
            const now = std.Io.Clock.real.now(self.io).toSeconds();
            const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
            if (now - mtime_secs > limit) return null;
        }

        const file = std.Io.Dir.cwd().openFile(self.io, p, .{}) catch return null;
        defer file.close(self.io);
        const s = file.stat(self.io) catch return null;
        const buf = self.allocator.alloc(u8, s.size) catch return null;
        const n = file.readPositionalAll(self.io, buf, 0) catch {
            self.allocator.free(buf);
            return null;
        };
        if (n < buf.len) {
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }

    fn writeIndexFile(self: *const BrewApi, infix: []const u8, key: []const u8, data: []const u8) void {
        var dir_buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.txt", .{ self.cache_dir, infix, key }) catch return;

        const f = std.Io.Dir.cwd().createFile(self.io, p, .{}) catch return;
        defer f.close(self.io);
        // Partial index is discarded on next miss; next fetch re-populates from network.
        f.writeStreamingAll(self.io, data) catch {};
    }

    /// Real ETags are tens of bytes; anything larger is corrupt and ignored
    /// so a garbage `If-None-Match` never rides out to upstream.
    const max_etag_bytes: u64 = 256;

    /// Read the stored bulk-dump ETag for `key` (`api/<key>.etag`), or null
    /// if absent / unreadable / implausibly large. Caller owns the bytes.
    fn readIndexEtag(self: *BrewApi, key: []const u8) ?[]const u8 {
        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}.etag", .{ self.cache_dir, key }) catch return null;
        const file = std.Io.Dir.cwd().openFile(self.io, p, .{}) catch return null;
        defer file.close(self.io);
        const s = file.stat(self.io) catch return null;
        if (s.size == 0 or s.size > max_etag_bytes) return null;
        const buf = self.allocator.alloc(u8, s.size) catch return null;
        const n = file.readPositionalAll(self.io, buf, 0) catch {
            self.allocator.free(buf);
            return null;
        };
        if (n < buf.len) {
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }

    /// Persist the bulk-dump ETag for `key` atomically so a crash mid-write
    /// can't leave a torn token that forces a needless full re-download. A
    /// null `etag` (server omitted the header) clears any stored value so
    /// the next fetch is unconditional rather than replaying a stale token.
    fn writeIndexEtag(self: *const BrewApi, key: []const u8, etag: ?[]const u8) void {
        const e = etag orelse return self.deleteIndexEtag(key);
        var dir_buf: [512]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.Io.Dir.createDirAbsolute(self.io, dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };
        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}.etag", .{ self.cache_dir, key }) catch return;
        // Best-effort: a failed write just means the next fetch is
        // unconditional, never wrong — the side-cars are already on disk.
        atomic.atomicWriteFile(self.io, p, e) catch {};
    }

    /// Remove the stored ETag for `key`; best-effort.
    fn deleteIndexEtag(self: *const BrewApi, key: []const u8) void {
        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}.etag", .{ self.cache_dir, key }) catch return;
        // A leftover ETag at worst triggers one needless conditional GET;
        // a delete failure is harmless, so swallow it.
        std.Io.Dir.cwd().deleteFile(self.io, p) catch {};
    }

    /// Reset a side-car's mtime to now so a 304 restarts its TTL window
    /// without rewriting the bytes already on disk.
    fn touchIndex(self: *const BrewApi, infix: []const u8, key: []const u8) void {
        var path_buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.txt", .{ self.cache_dir, infix, key }) catch return;
        const file = std.Io.Dir.cwd().openFile(self.io, p, .{ .mode = .write_only }) catch return;
        defer file.close(self.io);
        // If the touch fails the side-car just looks stale next time and we
        // re-issue the (cheap) conditional GET — correctness is unaffected.
        file.setTimestampsNow(self.io) catch {};
    }

    /// Invalidate all cached API responses.
    pub fn invalidateCache(self: *BrewApi) void {
        var api_path_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&api_path_buf, "{s}/api", .{self.cache_dir}) catch return;
        // Cache dir absent on first-ever run; wipe is purely opportunistic.
        std.Io.Dir.cwd().deleteTree(self.io, api_path) catch {};
    }

    // --- internal ---

    fn fetchCached(self: *BrewApi, key: []const u8, url: []const u8, prefix: []const u8) ApiError![]const u8 {
        // Fast path: if a prior lookup already learned this name is a 404
        // (e.g. cask-ambiguity probe for a formula), bail before we hit
        // the network. Without this, `malt install <formula>` did one
        // real HTTP round-trip on every single run because 404s were
        // never cached.
        if (self.readNotFoundCache(key, prefix)) return ApiError.NotFound;

        // Offline mode: serve from the snapshot at any age, or hard-fail
        // with OfflineRequired. Skipping the TTL gate matches the
        // air-gapped use case: a stale entry is still bytes the user
        // can install from.
        if (self.offline) {
            if (self.readCacheBytes(key, prefix)) |cached| return cached;
            return ApiError.OfflineRequired;
        }

        // Try the normal success cache.
        if (self.readCache(key, prefix)) |cached| return cached;

        // Cache miss or expired — fetch from API
        var resp = self.http.get(url) catch return ApiError.ApiUnreachable;
        defer resp.deinit();

        if (resp.status == 404) {
            self.writeNotFoundCache(key, prefix);
            return ApiError.NotFound;
        }
        if (resp.status != 200) return ApiError.ApiUnreachable;

        // Save to cache (best effort)
        self.writeCache(key, prefix, resp.body);

        // Return owned copy
        return self.allocator.dupe(u8, resp.body) catch return ApiError.OutOfMemory;
    }

    pub fn readCache(self: *BrewApi, key: []const u8, prefix: []const u8) ?[]const u8 {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return null;

        // Check freshness
        const stat = std.Io.Dir.cwd().statFile(self.io, cache_path, .{}) catch return null;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        if (now - mtime_secs > cache_ttl_secs) return null;

        return self.readCacheBytes(key, prefix);
    }

    /// TTL-bypass cache read. Returns caller-owned bytes if the file
    /// exists and is readable, regardless of mtime. Used by the offline
    /// path so a stale snapshot still serves bytes; the regular
    /// `readCache` adds the freshness gate on top.
    pub fn readCacheBytes(self: *BrewApi, key: []const u8, prefix: []const u8) ?[]const u8 {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return null;

        const file = std.Io.Dir.cwd().openFile(self.io, cache_path, .{}) catch return null;
        defer file.close(self.io);
        const file_stat = file.stat(self.io) catch return null;
        const content = self.allocator.alloc(u8, file_stat.size) catch return null;
        const bytes_read = file.readPositionalAll(self.io, content, 0) catch {
            self.allocator.free(content);
            return null;
        };
        if (bytes_read < content.len) {
            self.allocator.free(content);
            return null;
        }
        return content;
    }

    pub fn writeCache(self: *const BrewApi, key: []const u8, prefix: []const u8, data: []const u8) void {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.Io.Dir.createDirAbsolute(self.io, dir_path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.json", .{ self.cache_dir, prefix, key }) catch return;

        // Atomic write so a crash mid-`writeAll` can't leave a
        // truncated JSON file that breaks the next install until the
        // cache is manually wiped.
        //
        // Cache is a latency optimization; a write failure (disk full,
        // permissions) just means the next call re-fetches over the network.
        atomic.atomicWriteFile(self.io, cache_path, data) catch {};
    }

    /// Check for a cached 404 marker. Returns true if a fresh marker
    /// exists for this key — callers should treat that as `NotFound`
    /// and skip the network. Uses the same TTL as success responses
    /// so the cache auto-refreshes if the upstream ever starts
    /// returning 200.
    pub fn readNotFoundCache(self: *BrewApi, key: []const u8, prefix: []const u8) bool {
        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.404", .{ self.cache_dir, prefix, key }) catch return false;

        const stat = std.Io.Dir.cwd().statFile(self.io, cache_path, .{}) catch return false;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const mtime_secs: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
        if (now - mtime_secs > cache_ttl_secs) return false;
        return true;
    }

    /// Write a zero-byte marker file to record that this key 404s. The
    /// file's mtime is the TTL anchor — `readNotFoundCache` checks it
    /// against `cache_ttl_secs`. Best-effort; failures are silent so a
    /// missing cache dir never breaks an install.
    pub fn writeNotFoundCache(self: *const BrewApi, key: []const u8, prefix: []const u8) void {
        var dir_buf: [512]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return;
        std.Io.Dir.createDirAbsolute(self.io, dir_path, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return,
        };

        var path_buf: [512]u8 = undefined;
        const cache_path = std.fmt.bufPrint(&path_buf, "{s}/api/{s}{s}.404", .{ self.cache_dir, prefix, key }) catch return;

        const file = std.Io.Dir.cwd().createFile(self.io, cache_path, .{}) catch return;
        file.close(self.io);
    }

    /// Maximum cache size (200 MB). Entries are evicted by age (oldest first).
    const max_cache_bytes: u64 = 200 * 1024 * 1024;

    /// Evict oldest cache entries until total size is under max_cache_bytes.
    /// Called by `malt cleanup` and `malt doctor`.
    pub fn evictCache(self: *BrewApi) u32 {
        var dir_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return 0;

        var dir = std.Io.Dir.openDirAbsolute(self.io, api_path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        // Collect entries with size + mtime
        const Entry = struct { name_buf: [256]u8, name_len: usize, size: u64, mtime: i128 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);
        var total_size: u64 = 0;

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            const stat = dir.statFile(self.io, e.name, .{}) catch continue;
            var entry: Entry = .{ .name_buf = undefined, .name_len = e.name.len, .size = stat.size, .mtime = stat.mtime.nanoseconds };
            if (e.name.len > entry.name_buf.len) continue;
            @memcpy(entry.name_buf[0..e.name.len], e.name);
            entries.append(self.allocator, entry) catch continue;
            total_size += stat.size;
        }

        if (total_size <= max_cache_bytes) return 0;

        // Sort by mtime ascending (oldest first)
        std.mem.sort(Entry, entries.items, {}, struct {
            fn cmp(_: void, a: Entry, b: Entry) bool {
                return a.mtime < b.mtime;
            }
        }.cmp);

        var evicted: u32 = 0;
        for (entries.items) |entry| {
            if (total_size <= max_cache_bytes) break;
            const name = entry.name_buf[0..entry.name_len];
            dir.deleteFile(self.io, name) catch continue;
            total_size -|= entry.size;
            evicted += 1;
        }
        return evicted;
    }

    /// Return total cache size in bytes. Used by `malt doctor` for warnings.
    pub fn cacheSize(self: *BrewApi) u64 {
        var dir_buf: [512]u8 = undefined;
        const api_path = std.fmt.bufPrint(&dir_buf, "{s}/api", .{self.cache_dir}) catch return 0;

        var dir = std.Io.Dir.openDirAbsolute(self.io, api_path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);

        var total: u64 = 0;
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            const stat = dir.statFile(self.io, e.name, .{}) catch continue;
            total += stat.size;
        }
        return total;
    }
};

// ── inline tests: pure URL builders + base_url default ──────────────────

const testing = std.testing;

test "BrewApi.init defaults base_url to the upstream Homebrew API" {
    var http = client_mod.HttpClient.init(std.Options.debug_io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    const api = BrewApi.init(std.Options.debug_io, testing.allocator, &http, "/tmp/mt_api_base_default");
    try testing.expectEqualStrings(mirror_mod.default_api_base_url, api.base_url);
}

test "buildFormulaUrl threads the override base into the path" {
    var buf: [256]u8 = undefined;
    const url = try BrewApi.buildFormulaUrl(&buf, "https://mirror.example.com/api", "wget");
    try testing.expectEqualStrings("https://mirror.example.com/api/formula/wget.json", url);
}

test "buildCaskUrl threads the override base into the path" {
    var buf: [256]u8 = undefined;
    const url = try BrewApi.buildCaskUrl(&buf, "https://mirror.example.com/api", "firefox");
    try testing.expectEqualStrings("https://mirror.example.com/api/cask/firefox.json", url);
}

test "buildNamesIndexUrl emits formula vs cask paths against the override" {
    var buf: [256]u8 = undefined;
    const f = try BrewApi.buildNamesIndexUrl(&buf, "https://mirror.example.com/api", .formula);
    try testing.expectEqualStrings("https://mirror.example.com/api/formula.json", f);
    const c = try BrewApi.buildNamesIndexUrl(&buf, "https://mirror.example.com/api", .cask);
    try testing.expectEqualStrings("https://mirror.example.com/api/cask.json", c);
}

test "buildFormulaUrl returns OutOfMemory when the buffer can't hold the URL" {
    var tiny: [4]u8 = undefined;
    try testing.expectError(ApiError.OutOfMemory, BrewApi.buildFormulaUrl(&tiny, "https://example.com", "wget"));
}

// ── extractVersions: the outdated-check producer ──────────────────────

test "extractVersions emits name<TAB>stable<TAB>revision per formula entry" {
    const body =
        \\[{"name":"wget","versions":{"stable":"1.21.4"},"revision":0},
        \\ {"name":"openssl@3","versions":{"stable":"3.2.1"},"revision":2}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("wget\t1.21.4\t0\nopenssl@3\t3.2.1\t2\n", out);
}

test "extractVersions defaults a missing revision to 0" {
    const body =
        \\[{"name":"jq","versions":{"stable":"1.7"}}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("jq\t1.7\t0\n", out);
}

test "extractVersions skips entries with no stable version and tolerates unknown fields" {
    // Third-party JSON: a renamed/absent field must not crash the parse,
    // and an unversioned entry is dropped rather than emitted empty.
    const body =
        \\[{"name":"nostable","desc":"x","revision":0},
        \\ {"name":"good","versions":{"stable":"2.0"},"extra":true}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("good\t2.0\t0\n", out);
}

test "extractVersions reads a cask's top-level version with revision 0" {
    const body =
        \\[{"token":"firefox","version":"125.0"}]
    ;
    const out = try extractVersions(testing.allocator, .cask, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("firefox\t125.0\t0\n", out);
}

test "extractVersions drops entries whose name or version embeds a delimiter" {
    // Hostile / schema-shifted JSON: a tab or newline in a field would
    // corrupt the line-delimited side-car the consumer splits on. `\t`/`\n`
    // here are JSON escapes, so the parsed strings carry real control chars.
    const body =
        \\[{"name":"a\tb","versions":{"stable":"1.0"}},
        \\ {"name":"nl","versions":{"stable":"2.0\n3.0"}},
        \\ {"name":"ok","versions":{"stable":"4.0"}}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ok\t4.0\t0\n", out);
}

test "extractVersions drops a name that isn't a clean path component" {
    // The name keys the outdated map against on-disk kegs; a `/` or `..` from
    // a hostile tap must never reach that sink.
    const body =
        \\[{"name":"../evil","versions":{"stable":"1.0"}},
        \\ {"name":"a/b","versions":{"stable":"1.0"}},
        \\ {"name":"ok","versions":{"stable":"2.0"}}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ok\t2.0\t0\n", out);
}

test "extractNames drops a name that isn't a clean path component" {
    const body =
        \\[{"name":"../evil"},{"name":"redis"}]
    ;
    const out = try extractNames(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("redis\n", out);
}

test "extractVersions clamps a negative revision to 0" {
    // A negative revision can't match any installed keg path; emit 0 so the
    // side-car never carries a value the consumer would format oddly.
    const body =
        \\[{"name":"x","versions":{"stable":"1.0"},"revision":-3}]
    ;
    const out = try extractVersions(testing.allocator, .formula, body);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("x\t1.0\t0\n", out);
}
