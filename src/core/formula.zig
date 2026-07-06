//! malt — Homebrew formula JSON parser
//! Parses formula metadata from the Homebrew API and selects
//! the correct bottle artifact for the current platform.

const std = @import("std");
const builtin = @import("builtin");

const service_types = @import("services/types.zig");
const cron = @import("services/cron.zig");
pub const Schedule = service_types.Schedule;

pub const FormulaError = error{
    InvalidJson,
    MissingField,
    NoBottleAvailable,
    /// `run_type` is neither immediate, interval, nor cron.
    UnknownRunType,
    /// `run_type :interval` with a missing, non-numeric, or out-of-range
    /// `interval`. Never falls back to `.immediate`.
    InvalidInterval,
    /// The embedded `name` or `version` carries a path separator or `..`,
    /// so it would hop out of its on-disk directory component.
    UnsafePathComponent,
};

/// Bottle descriptor for one platform. All three strings live in the
/// parent `Formula._parsed` (either source-borrowed or arena-allocated
/// by the JSON parser); callers that hold a `BottleFile` beyond
/// `Formula.deinit()` must dupe first.
pub const BottleFile = struct {
    cellar: []const u8,
    url: []const u8,
    sha256: []const u8,
};

/// Optional service definition lifted from the upstream Homebrew formula's
/// `service` block. Strings borrow from `Formula._parsed`.
pub const ServiceDef = struct {
    /// Argv passed to launchd's ProgramArguments. Always non-empty when the
    /// service block is present.
    run: []const []const u8,
    working_dir: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    error_log_path: ?[]const u8 = null,
    keep_alive: bool = true,
    schedule: Schedule = .immediate,
};

/// Format Homebrew's canonical on-disk version label into `buf`.
/// `revision > 0` appends `_<revision>` (matching Homebrew's
/// `PkgVersion`); otherwise the plain `version` is returned
/// unchanged. Revisions ≤ 0 are treated as zero — defensive against
/// upstream JSON glitches. Used everywhere a filesystem path under
/// `Cellar/<name>/` is assembled; getting this wrong produces
/// `dyld: Library not loaded` errors because bottles hard-code the
/// full path in LC_LOAD_DYLIB entries.
pub fn pkgVersion(buf: []u8, version: []const u8, revision: i64) ![]const u8 {
    if (revision <= 0) return std.fmt.bufPrint(buf, "{s}", .{version});
    return std.fmt.bufPrint(buf, "{s}_{d}", .{ version, revision });
}

/// Parsed Homebrew formula. Every `[]const u8` and `[]const []const u8`
/// field is owned by `_parsed` (either borrowed from the JSON source
/// buffer or allocated through the parse arena); valid only until
/// `deinit()`.
pub const Formula = struct {
    /// Borrowed from `_parsed`.
    name: []const u8,
    /// Borrowed from `_parsed`.
    full_name: []const u8,
    /// Borrowed from `_parsed`.
    tap: []const u8,
    /// Borrowed from `_parsed`.
    desc: []const u8,
    /// Borrowed from `_parsed`.
    version: []const u8,
    /// Canonical on-disk version name: equals `version` when
    /// `revision == 0`, else `<version>_<revision>` formatted into the
    /// parse arena. Use this for every Cellar/opt/receipt path — never
    /// raw `version`.
    pkg_version: []const u8,
    revision: i64,
    /// Borrowed from `_parsed` when present.
    license: ?[]const u8,
    /// Borrowed from `_parsed`.
    homepage: []const u8,
    /// Outer slice allocated through `_parsed.arena`; element strings
    /// live in `_parsed`.
    dependencies: []const []const u8,
    keg_only: bool,
    post_install_defined: bool,
    /// Map storage is allocated through `_parsed.arena`; map keys and
    /// `BottleFile` string fields live in `_parsed`.
    bottle_files: ?std.json.ArrayHashMap(BottleFile),
    /// Borrowed from `_parsed`.
    bottle_root_url: ?[]const u8,
    /// Outer slice allocated through `_parsed.arena`; element strings
    /// live in `_parsed`.
    oldnames: []const []const u8,
    /// Optional launchd service block. Populated when the upstream formula
    /// JSON contains a `service` object with at least a `run` array.
    /// All string fields inside borrow from `_parsed`.
    service: ?ServiceDef = null,

    /// Holds the parsed JSON tree. Must stay alive as long as the Formula
    /// is in use because string fields point into the JSON source buffer.
    _parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Formula) void {
        self._parsed.deinit();
    }
};

// Keep in sync with BottleInfo used by other modules.
pub const BottleInfo = BottleFile;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

/// Map a service block's `run_type` to a `Schedule`. Absent/`"immediate"`
/// keeps today's run-at-load behaviour; `"interval"` requires a numeric,
/// in-range `interval`; `"cron"` parses its expression into calendar entries;
/// anything else is rejected loudly so a mis-scheduled service never
/// materialises silently. Calendar entries are allocated in `arena`.
fn parseSchedule(arena: std.mem.Allocator, so: std.json.ObjectMap) !Schedule {
    const run_type = getString(so, "run_type") orelse return .immediate;
    if (std.mem.eql(u8, run_type, "immediate")) return .immediate;
    if (std.mem.eql(u8, run_type, "cron")) {
        // A missing `cron` string is a hard error, never a silent fallback.
        const expr = getString(so, "cron") orelse return cron.CronError.CronMalformed;
        return .{ .calendar = try cron.parseCron(arena, expr) };
    }
    if (!std.mem.eql(u8, run_type, "interval")) return FormulaError.UnknownRunType;

    const iv = so.get("interval") orelse return FormulaError.InvalidInterval;
    const secs = switch (iv) {
        .integer => |n| n,
        else => return FormulaError.InvalidInterval,
    };
    if (secs < 1 or secs > service_types.max_interval_secs) return FormulaError.InvalidInterval;
    return .{ .interval = @intCast(secs) };
}

fn getStringArray(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    const arr = switch (v) {
        .array => |a| a,
        else => return &.{},
    };
    if (arr.items.len == 0) return &.{};
    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = switch (item) {
            .string => |s| s,
            else => "",
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// True when `s` is a single, safe path component. Charset-agnostic: formula
/// names and versions carry `@`, `+`, and dots that an allowlist would wrongly
/// reject, so this bars only the shapes that hop out of a component — `.`/`..`,
/// an embedded `/` or `..`, or a NUL. Empty is left to the caller (a missing
/// version is legitimate; a missing name is caught as MissingField).
fn isSafePathComponent(s: []const u8) bool {
    if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    if (std.mem.indexOfScalar(u8, s, '/') != null) return false;
    if (std.mem.indexOf(u8, s, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    return true;
}

/// Parse a Homebrew formula JSON blob into a `Formula`.
/// The returned value borrows from the parsed JSON; call `deinit()` when done.
pub fn parseFormula(allocator: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_data,
        .{},
    ) catch return FormulaError.InvalidJson;
    errdefer parsed.deinit();
    // Funnel auxiliary slices through the parse arena so one
    // `_parsed.deinit()` reclaims them; otherwise the outer arrays leak.
    const arena = parsed.arena.allocator();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return FormulaError.InvalidJson,
    };

    // Required string fields
    const name = getString(root, "name") orelse return FormulaError.MissingField;
    // The embedded name never re-passes the requested-name screen yet becomes
    // every keg/cellar/receipt path; full_name is tap-qualified (`/`), so skip.
    if (!isSafePathComponent(name)) return FormulaError.UnsafePathComponent;
    const full_name = getString(root, "full_name") orelse name;
    const tap = getString(root, "tap") orelse "";
    const desc = getString(root, "desc") orelse "";
    const homepage = getString(root, "homepage") orelse "";
    const license = getString(root, "license");
    const revision = getInt(root, "revision");
    const keg_only = getBool(root, "keg_only");
    const post_install_defined = getBool(root, "post_install_defined");

    // versions.stable -> version
    const version_str = blk: {
        const versions_val = root.get("versions") orelse break :blk "";
        const versions_obj = switch (versions_val) {
            .object => |o| o,
            else => break :blk "",
        };
        break :blk getString(versions_obj, "stable") orelse "";
    };
    // version feeds pkg_version → the revision-tagged cellar/keg dir; an empty
    // version is legitimate, but a present one must stay a single component.
    if (version_str.len != 0 and !isSafePathComponent(version_str))
        return FormulaError.UnsafePathComponent;

    // dependencies
    const dependencies = try getStringArray(arena, root, "dependencies");

    // oldnames (may be absent)
    const oldnames = try getStringArray(arena, root, "oldnames");

    // service block (optional — Homebrew formulas opt in)
    var service_def: ?ServiceDef = null;
    if (root.get("service")) |sv| {
        if (sv == .object) {
            const so = sv.object;
            const run_val = so.get("run");
            if (run_val) |rv| {
                const items: ?[]std.json.Value = switch (rv) {
                    .array => |a| a.items,
                    .string => |s| blk: {
                        const one = try arena.alloc(std.json.Value, 1);
                        one[0] = .{ .string = s };
                        break :blk one;
                    },
                    else => null,
                };
                if (items) |arr| if (arr.len > 0) {
                    const run = try arena.alloc([]const u8, arr.len);
                    for (arr, 0..) |item, i| {
                        run[i] = switch (item) {
                            .string => |s| s,
                            else => "",
                        };
                    }
                    service_def = .{
                        .run = run,
                        .working_dir = getString(so, "working_dir"),
                        .log_path = getString(so, "log_path"),
                        .error_log_path = getString(so, "error_log_path"),
                        // The API encodes keep_alive as a directive object
                        // (`{"always": true}`, …), not just a bool — treat any
                        // present value as "keep alive" unless it is literally
                        // `false`, which malt renders as no KeepAlive.
                        .keep_alive = if (so.get("keep_alive")) |k|
                            (k != .bool or k.bool)
                        else
                            true,
                        .schedule = try parseSchedule(arena, so),
                    };
                };
            }
        }
    }

    // bottle.stable.root_url and bottle.stable.files
    var bottle_root_url: ?[]const u8 = null;
    var bottle_files: ?std.json.ArrayHashMap(BottleFile) = null;
    if (root.get("bottle")) |bottle_val| {
        if (bottle_val == .object) {
            const bottle_obj = bottle_val.object;
            if (bottle_obj.get("stable")) |stable_val| {
                if (stable_val == .object) {
                    const stable_obj = stable_val.object;
                    bottle_root_url = getString(stable_obj, "root_url");

                    if (stable_obj.get("files")) |files_val| {
                        if (files_val == .object) {
                            const files_obj = files_val.object;
                            var map = std.json.ArrayHashMap(BottleFile){};
                            var it = files_obj.iterator();
                            while (it.next()) |entry| {
                                const platform_name = entry.key_ptr.*;
                                const file_obj = switch (entry.value_ptr.*) {
                                    .object => |o| o,
                                    else => continue,
                                };
                                const bf = BottleFile{
                                    .cellar = getString(file_obj, "cellar") orelse "",
                                    .url = getString(file_obj, "url") orelse continue,
                                    .sha256 = getString(file_obj, "sha256") orelse "",
                                };
                                map.map.put(arena, platform_name, bf) catch continue;
                            }
                            bottle_files = map;
                        }
                    }
                }
            }
        }
    }

    // Pre-compute the revision-aware path label once into the parse
    // arena so every downstream consumer can borrow a stable slice
    // instead of re-formatting per call site.
    const pkg_version_str = blk: {
        if (revision <= 0) break :blk version_str;
        break :blk try std.fmt.allocPrint(arena, "{s}_{d}", .{ version_str, revision });
    };

    return Formula{
        .name = name,
        .full_name = full_name,
        .tap = tap,
        .desc = desc,
        .version = version_str,
        .pkg_version = pkg_version_str,
        .revision = revision,
        .license = license,
        .homepage = homepage,
        .dependencies = dependencies,
        .keg_only = keg_only,
        .post_install_defined = post_install_defined,
        .bottle_files = bottle_files,
        .bottle_root_url = bottle_root_url,
        .oldnames = oldnames,
        .service = service_def,
        ._parsed = parsed,
    };
}

// ---------------------------------------------------------------------------
// Bottle selection
// ---------------------------------------------------------------------------

/// macOS version codenames in descending order (newest first).
const macos_arm64_platforms = [_][]const u8{
    "arm64_tahoe",
    "arm64_sequoia",
    "arm64_sonoma",
    "arm64_ventura",
    "arm64_monterey",
};

const macos_x86_platforms = [_][]const u8{
    "tahoe",
    "sequoia",
    "sonoma",
    "ventura",
    "monterey",
};

/// Select the best matching bottle for the current platform.
pub fn resolveBottle(formula: *const Formula) !BottleFile {
    const files = formula.bottle_files orelse return FormulaError.NoBottleAvailable;

    const candidates: []const []const u8 = switch (builtin.cpu.arch) {
        .aarch64 => &macos_arm64_platforms,
        .x86_64 => &macos_x86_platforms,
        else => &macos_arm64_platforms,
    };

    // Try each platform candidate in preference order
    for (candidates) |platform| {
        if (files.map.get(platform)) |bf| {
            return bf;
        }
    }

    // Fallback: "all" (used by some header-only / arch-independent bottles)
    if (files.map.get("all")) |bf| {
        return bf;
    }

    return FormulaError.NoBottleAvailable;
}

// ---------------------------------------------------------------------------
// Alias resolution
// ---------------------------------------------------------------------------

/// Check whether `name` is an old name for the formula described by `json_data`.
/// If so, return the formula's canonical name. Otherwise return null.
pub fn resolveAlias(allocator: std.mem.Allocator, name: []const u8, json_data: []const u8) !?[]const u8 {
    var formula = try parseFormula(allocator, json_data);
    defer formula.deinit();

    for (formula.oldnames) |oldname| {
        if (std.mem.eql(u8, oldname, name)) {
            // Dupe so caller owns the returned string beyond formula lifetime.
            return try allocator.dupe(u8, formula.name);
        }
    }

    return null;
}

/// Inverse of `pkgVersion`. Returns the upstream version slice (borrowed
/// from `label`) and the trailing revision integer. Anything that isn't
/// a strict `<…>_<digits>` suffix is treated as part of the version
/// (e.g. Homebrew-style `0.1.0_p1`), so the round-trip
/// `pkgVersion(parsePkgVersion(s)) == s` only holds for labels this
/// tool actually emits.
pub const ParsedPkgVersion = struct { version: []const u8, revision: i64 };

pub fn parsePkgVersion(label: []const u8) ParsedPkgVersion {
    const us = std.mem.lastIndexOfScalar(u8, label, '_') orelse
        return .{ .version = label, .revision = 0 };
    const tail = label[us + 1 ..];
    if (tail.len == 0) return .{ .version = label, .revision = 0 };
    const rev = std.fmt.parseInt(i64, tail, 10) catch
        return .{ .version = label, .revision = 0 };
    if (rev < 0) return .{ .version = label, .revision = 0 };
    return .{ .version = label[0..us], .revision = rev };
}

const testing = std.testing;

test "parsePkgVersion splits revision suffix" {
    const r = parsePkgVersion("1.9.2_2");
    try testing.expectEqualStrings("1.9.2", r.version);
    try testing.expectEqual(@as(i64, 2), r.revision);
}

test "parsePkgVersion treats no-suffix as revision zero" {
    const r = parsePkgVersion("1.0.0");
    try testing.expectEqualStrings("1.0.0", r.version);
    try testing.expectEqual(@as(i64, 0), r.revision);
}

test "parsePkgVersion preserves non-numeric underscore tails" {
    // Homebrew patch-level versions like `0.1.0_p1` are part of the
    // upstream version, not a revision bump.
    const r = parsePkgVersion("0.1.0_p1");
    try testing.expectEqualStrings("0.1.0_p1", r.version);
    try testing.expectEqual(@as(i64, 0), r.revision);
}

test "parsePkgVersion round-trips with pkgVersion" {
    var buf: [64]u8 = undefined;
    const formatted = try pkgVersion(&buf, "3.14.4", 1);
    const r = parsePkgVersion(formatted);
    try testing.expectEqualStrings("3.14.4", r.version);
    try testing.expectEqual(@as(i64, 1), r.revision);
}

test "parseFormula rejects path separators in embedded name or version" {
    // `name` and `version` become on-disk directory components (keg, cellar,
    // receipt, service label); the JSON's own fields never re-pass the
    // fetch-time name screen, so parse must reject a component-hopping value.
    const bad = [_][]const u8{
        \\{"name":"../evil","versions":{"stable":"1.0"}}
        ,
        \\{"name":"a/b","versions":{"stable":"1.0"}}
        ,
        \\{"name":".","versions":{"stable":"1.0"}}
        ,
        \\{"name":"..","versions":{"stable":"1.0"}}
        ,
        \\{"name":"foo/","versions":{"stable":"1.0"}}
        ,
        \\{"name":"a\u0000b","versions":{"stable":"1.0"}}
        ,
        \\{"name":"ok","versions":{"stable":"../1.0"}}
        ,
        \\{"name":"ok","versions":{"stable":"1..0"}}
        ,
    };
    for (bad) |json| {
        try testing.expectError(FormulaError.UnsafePathComponent, parseFormula(testing.allocator, json));
    }

    // Real names/versions carry `@`, `+`, dots — charset-agnostic, must pass.
    const ok =
        \\{"name":"openssl@3","versions":{"stable":"3.2.1+dfsg"}}
    ;
    var formula = try parseFormula(testing.allocator, ok);
    defer formula.deinit();
    try testing.expectEqualStrings("openssl@3", formula.name);

    // A formula with no stable version parses to an empty version, unchanged.
    const nover =
        \\{"name":"nostable","versions":{}}
    ;
    var f2 = try parseFormula(testing.allocator, nover);
    defer f2.deinit();
    try testing.expectEqualStrings("", f2.version);
}

test "parseFormula releases every auxiliary allocation through deinit" {
    // testing.allocator (no arena wrapper) trips on any auxiliary slice
    // that escapes _parsed: dependencies, oldnames, service.run,
    // bottle_files map storage, and the revision-bumped pkg_version.
    const json =
        \\{"name":"alpha","full_name":"alpha","tap":"homebrew/core","desc":"","homepage":"","license":null,"revision":2,"keg_only":false,"post_install_defined":false,"versions":{"stable":"1.0"},"dependencies":["beta","gamma"],"oldnames":["alpha-old"],"service":{"run":["/usr/bin/alpha","--daemon"]},"bottle":{"stable":{"root_url":"https://example.test","files":{"arm64_sequoia":{"cellar":"/opt","url":"https://example.test/a","sha256":"deadbeef"}}}}}
    ;
    var formula = try parseFormula(testing.allocator, json);
    defer formula.deinit();
    try testing.expectEqualStrings("1.0_2", formula.pkg_version);
    try testing.expectEqual(@as(usize, 2), formula.dependencies.len);
    try testing.expectEqual(@as(usize, 1), formula.oldnames.len);
    try testing.expect(formula.service != null);
    try testing.expect(formula.bottle_files != null);
}
