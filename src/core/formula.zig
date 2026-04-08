//! malt — Homebrew formula JSON parser
//! Parses formula metadata from the Homebrew API and selects
//! the correct bottle artifact for the current platform.

const std = @import("std");
const builtin = @import("builtin");

pub const FormulaError = error{
    InvalidJson,
    MissingField,
    NoBottleAvailable,
};

pub const BottleFile = struct {
    cellar: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const Formula = struct {
    name: []const u8,
    full_name: []const u8,
    tap: []const u8,
    desc: []const u8,
    version: []const u8,
    revision: i64,
    license: ?[]const u8,
    homepage: []const u8,
    dependencies: []const []const u8,
    keg_only: bool,
    post_install_defined: bool,
    bottle_files: ?std.json.ArrayHashMap(BottleFile),
    bottle_root_url: ?[]const u8,
    oldnames: []const []const u8,

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

/// Parse a Homebrew formula JSON blob into a `Formula`.
/// The returned value borrows from the parsed JSON; call `deinit()` when done.
pub fn parseFormula(allocator: std.mem.Allocator, json_data: []const u8) !Formula {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_data,
        .{},
    ) catch return FormulaError.InvalidJson;

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return FormulaError.InvalidJson,
    };

    // Required string fields
    const name = getString(root, "name") orelse return FormulaError.MissingField;
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

    // dependencies
    const dependencies = try getStringArray(allocator, root, "dependencies");

    // oldnames (may be absent)
    const oldnames = try getStringArray(allocator, root, "oldnames");

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
                                map.map.put(allocator, platform_name, bf) catch continue;
                            }
                            bottle_files = map;
                        }
                    }
                }
            }
        }
    }

    return Formula{
        .name = name,
        .full_name = full_name,
        .tap = tap,
        .desc = desc,
        .version = version_str,
        .revision = revision,
        .license = license,
        .homepage = homepage,
        .dependencies = dependencies,
        .keg_only = keg_only,
        .post_install_defined = post_install_defined,
        .bottle_files = bottle_files,
        .bottle_root_url = bottle_root_url,
        .oldnames = oldnames,
        ._parsed = parsed,
    };
}

// ---------------------------------------------------------------------------
// Bottle selection
// ---------------------------------------------------------------------------

/// macOS version codenames in descending order (newest first).
const macos_arm64_platforms = [_][]const u8{
    "arm64_sequoia",
    "arm64_sonoma",
    "arm64_ventura",
    "arm64_monterey",
};

const macos_x86_platforms = [_][]const u8{
    "sequoia",
    "sonoma",
    "ventura",
    "monterey",
};

/// Select the best matching bottle for the current platform.
pub fn resolveBottle(allocator: std.mem.Allocator, formula: *const Formula) !BottleFile {
    _ = allocator;

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
