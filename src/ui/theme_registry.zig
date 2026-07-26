//! malt — lower a themes.json byte slice into a ThemeRegistry.
//!
//! Pure `ui` leaf: `std` + `themes` + `custom_theme` only. It never touches the
//! filesystem — the caller hands it bytes already read through the hardened
//! `fs/theme_file` path, so the ui layer keeps its zero-dependency-on-fs shape.
//! Validation is strict and all-or-nothing: a single malformed field rejects
//! the whole file, so a hostile or fat-fingered theme file can never
//! partial-apply.

const std = @import("std");
const themes = @import("themes.zig");
const ct = @import("custom_theme.zig");

/// The only `version` the schema accepts today. A bump is a breaking change to
/// the file shape and must move in lockstep with user docs.
pub const supported_version = 1;

/// The six role keys every theme object must carry — exactly these, no more,
/// no fewer.
const role_keys = [_][]const u8{ "accent", "secondary", "success", "warning", "danger", "muted" };

pub const RegistryError = error{
    NotAnObject,
    UnsupportedVersion,
    NoThemes,
    TooManyThemes,
    NameTooLong,
    ThemeNotAnObject,
    MissingPolarity,
    InvalidPolarity,
    MissingRole,
    UnknownKey,
    InvalidColor,
    MissingDefault,
    UnresolvableDefault,
};

/// Backing storage for a loaded registry. Bundles the registry, the SGR byte
/// pool its palette slices point into, and the per-theme truecolor-requirement
/// flag in one struct so the three arrays cannot drift out of index-alignment
/// and share a single lifetime (module-static in `color.zig`, read-only after
/// boot).
pub const Storage = struct {
    registry: ct.ThemeRegistry,
    /// Owns the bytes every `registry.themes[i].palette.*` slice points into.
    pool: [ct.max_themes][role_keys.len]ct.Sgr,
    /// `requires_truecolor[i]`: theme `i` used at least one `#hex`/`[r,g,b]`
    /// colour, so it degrades wholesale on a non-truecolor terminal.
    requires_truecolor: [ct.max_themes]bool,
    /// `requires_at_least_256[i]`: theme `i` used at least one bare-integer
    /// colour, which always lowers to a `\x1b[38;5;N` escape — meaningless on a
    /// 16-colour terminal, so the theme degrades wholesale there too.
    requires_at_least_256: [ct.max_themes]bool,
};

/// Parse and strictly validate `bytes`, writing the lowered registry into
/// `out`. Returns the first failure; on error `out` is left partially written
/// and must not be read. `allocator` backs only the transient JSON parse — no
/// allocation escapes; every persistent byte is copied into `out`.
pub fn populate(allocator: std.mem.Allocator, bytes: []const u8, out: *Storage) RegistryError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return error.NotAnObject; // malformed JSON is just another rejected file
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotAnObject,
    };

    // Version gate: a missing, non-integer, or unknown version rejects the file
    // rather than guessing at a shape we don't support.
    const version = switch (root.get("version") orelse return error.UnsupportedVersion) {
        .integer => |n| n,
        else => return error.UnsupportedVersion,
    };
    if (version != supported_version) return error.UnsupportedVersion;

    const themes_obj = switch (root.get("themes") orelse return error.NoThemes) {
        .object => |o| o,
        else => return error.NoThemes,
    };
    const n = themes_obj.count();
    if (n == 0) return error.NoThemes;
    if (n > ct.max_themes) return error.TooManyThemes;

    var idx: usize = 0;
    var it = themes_obj.iterator();
    while (it.next()) |entry| : (idx += 1) {
        const name = entry.key_ptr.*;
        if (name.len > ct.max_name) return error.NameTooLong;

        const theme_obj = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.ThemeNotAnObject,
        };

        const polarity = switch (theme_obj.get("polarity") orelse return error.MissingPolarity) {
            .string => |s| if (std.mem.eql(u8, s, "dark"))
                themes.Polarity.dark
            else if (std.mem.eql(u8, s, "light"))
                themes.Polarity.light
            else
                return error.InvalidPolarity,
            else => return error.InvalidPolarity,
        };

        // Exactly polarity + the six roles, nothing else. The arity check plus
        // the per-role presence check below means any extra key is rejected and
        // any missing role is caught.
        if (theme_obj.count() != role_keys.len + 1) return error.UnknownKey;

        const t = &out.registry.themes[idx];
        @memcpy(t.name[0..name.len], name);
        t.name_len = name.len;
        t.polarity = polarity;

        var requires_tc = false;
        var requires_256 = false;
        // `key` is the JSON key, the NamedPalette field name, and (via `k`) the
        // pool slot — all the same ordering by construction, so `@field` wires
        // the slice straight into the matching role with no lookup table.
        inline for (role_keys, 0..) |key, k| {
            const cval = theme_obj.get(key) orelse return error.MissingRole;
            out.pool[idx][k] = ct.parseColorValue(cval) catch return error.InvalidColor;
            @field(t.palette, key) = out.pool[idx][k].slice();
            // Hex string / rgb array ⇒ truecolor; a bare integer is 256-index.
            switch (cval) {
                .string, .array => requires_tc = true,
                .integer => requires_256 = true,
                else => {},
            }
        }
        out.requires_truecolor[idx] = requires_tc;
        out.requires_at_least_256[idx] = requires_256;
    }
    out.registry.count = n;

    // The `default` marker must name a theme actually present in the file.
    const def_name = switch (root.get("default") orelse return error.MissingDefault) {
        .string => |s| s,
        else => return error.MissingDefault,
    };
    out.registry.default_index = resolveByName(out, def_name) orelse return error.UnresolvableDefault;
}

/// Index of the theme whose name matches `name` (ASCII case-insensitive, since
/// selection lower-cases too), or null. Used for the `default` marker and reused
/// by the resolver for `MALT_THEME=<name>`.
pub fn resolveByName(out: *const Storage, name: []const u8) ?usize {
    var i: usize = 0;
    while (i < out.registry.count) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(out.registry.themes[i].nameSlice(), name)) return i;
    }
    return null;
}

// ─── tests ───────────────────────────────────────────────────────────

test "valid v1 file with two themes and a default populates the registry" {
    const src =
        \\{
        \\  "version": 1,
        \\  "default": "ocean",
        \\  "themes": {
        \\    "ocean": {
        \\      "polarity": "dark",
        \\      "accent": "#bd93f9",
        \\      "secondary": [139, 233, 253],
        \\      "success": "#50fa7b",
        \\      "warning": "#ffb86c",
        \\      "danger": "#ff5555",
        \\      "muted": 102
        \\    },
        \\    "sand": {
        \\      "polarity": "light",
        \\      "accent": 33, "secondary": 34, "success": 35,
        \\      "warning": 36, "danger": 37, "muted": 38
        \\    }
        \\  }
        \\}
    ;
    var storage: Storage = undefined;
    try populate(std.testing.allocator, src, &storage);

    try std.testing.expectEqual(@as(usize, 2), storage.registry.count);
    try std.testing.expectEqual(@as(usize, 0), storage.registry.default_index);

    const ocean = &storage.registry.themes[0];
    try std.testing.expectEqualStrings("ocean", ocean.nameSlice());
    try std.testing.expectEqual(themes.Polarity.dark, ocean.polarity);
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", ocean.palette.get(.accent));
    try std.testing.expectEqualStrings("\x1b[38;2;139;233;253m", ocean.palette.get(.secondary));
    // ocean used hex/array colours → must degrade wholesale without truecolor.
    try std.testing.expect(storage.requires_truecolor[0]);
    try std.testing.expect(storage.requires_at_least_256[0]); // and `muted: 102` is an index

    const sand = &storage.registry.themes[1];
    try std.testing.expectEqualStrings("sand", sand.nameSlice());
    try std.testing.expectEqual(themes.Polarity.light, sand.polarity);
    try std.testing.expectEqualStrings("\x1b[38;5;33m", sand.palette.get(.accent));
    // sand is entirely 256-index → paints on a 256-colour terminal, but not on
    // a 16-colour one: the escapes it emits are `\x1b[38;5;N` either way.
    try std.testing.expect(!storage.requires_truecolor[1]);
    try std.testing.expect(storage.requires_at_least_256[1]);
}

test "an all-hex theme needs truecolor and nothing from the 256 tier" {
    // The two flags are independent, not a ladder read off one value: a theme
    // with no integer role has no 256-index escape to gate.
    const src = "{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"accent\":\"#ff0000\",\"secondary\":\"#00ff00\",\"success\":[1,2,3],\"warning\":\"#ffffff\",\"danger\":\"#000000\",\"muted\":\"#123456\"}},\"default\":\"a\"}";
    var storage: Storage = undefined;
    try populate(std.testing.allocator, src, &storage);
    try std.testing.expect(storage.requires_truecolor[0]);
    try std.testing.expect(!storage.requires_at_least_256[0]);
}

/// A theme object body with all six roles as 256-index colours, parameterised by
/// polarity so a fixture can pick a side. Used to keep the rejection fixtures
/// focused on the one field under test.
const ok_roles_256 =
    \\"accent":1,"secondary":2,"success":3,"warning":4,"danger":5,"muted":6
;

fn expectReject(src: []const u8, want: RegistryError) !void {
    var storage: Storage = undefined;
    try std.testing.expectError(want, populate(std.testing.allocator, src, &storage));
}

test "a malformed file is rejected whole, with the failing field named" {
    // version gate
    try expectReject("{\"themes\":{\"a\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.UnsupportedVersion); // missing version
    try expectReject("{\"version\":2,\"themes\":{\"a\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.UnsupportedVersion); // unknown version
    try expectReject("{\"version\":\"1\",\"themes\":{\"a\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.UnsupportedVersion); // stringly version

    // structural
    try expectReject("[]", error.NotAnObject);
    try expectReject("not json", error.NotAnObject);
    try expectReject("{\"version\":1,\"default\":\"a\"}", error.NoThemes); // themes absent
    try expectReject("{\"version\":1,\"themes\":{},\"default\":\"a\"}", error.NoThemes); // themes empty

    // per-theme shape
    try expectReject("{\"version\":1,\"themes\":{\"a\":{" ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.MissingPolarity);
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"grey\"," ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.InvalidPolarity);
    // missing one role (only five present, plus polarity = 6 keys ≠ 7)
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"accent\":1,\"secondary\":2,\"success\":3,\"warning\":4,\"danger\":5}},\"default\":\"a\"}", error.UnknownKey);
    // an extra key (8 keys) is refused
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"extra\":9," ++ ok_roles_256 ++ "}},\"default\":\"a\"}", error.UnknownKey);
    // a wrong-named key replacing a role keeps arity 7 but the role is absent
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"akzent\":1,\"secondary\":2,\"success\":3,\"warning\":4,\"danger\":5,\"muted\":6}},\"default\":\"a\"}", error.MissingRole);
    // out-of-range colour delegates to the T-068 parser
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"accent\":256,\"secondary\":2,\"success\":3,\"warning\":4,\"danger\":5,\"muted\":6}},\"default\":\"a\"}", error.InvalidColor);
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"accent\":\"#gggggg\",\"secondary\":2,\"success\":3,\"warning\":4,\"danger\":5,\"muted\":6}},\"default\":\"a\"}", error.InvalidColor);

    // default marker
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}}}", error.MissingDefault);
    try expectReject("{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"b\"}", error.UnresolvableDefault);
}

test "a name longer than the cap is rejected" {
    // 33 'a's > max_name (32).
    const long = "a" ** (ct.max_name + 1);
    const src = "{\"version\":1,\"themes\":{\"" ++ long ++ "\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"" ++ long ++ "\"}";
    try expectReject(src, error.NameTooLong);
}

test "more than max_themes is rejected before any colour work" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"version\":1,\"default\":\"t0\",\"themes\":{");
    var tmp: [96]u8 = undefined;
    var i: usize = 0;
    while (i < ct.max_themes + 1) : (i += 1) {
        const sep = if (i == 0) "" else ",";
        const chunk = try std.fmt.bufPrint(&tmp, "{s}\"t{d}\":{{\"polarity\":\"dark\",{s}}}", .{ sep, i, ok_roles_256 });
        try buf.appendSlice(a, chunk);
    }
    try buf.appendSlice(a, "}}");
    try expectReject(buf.items, error.TooManyThemes);
}

test "a name of exactly the cap length is accepted" {
    const at_cap = "a" ** ct.max_name;
    const src = "{\"version\":1,\"themes\":{\"" ++ at_cap ++ "\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"" ++ at_cap ++ "\"}";
    var storage: Storage = undefined;
    try populate(std.testing.allocator, src, &storage);
    try std.testing.expectEqualStrings(at_cap, storage.registry.themes[0].nameSlice());
}

test "the default marker matches a theme name case-insensitively" {
    const src = "{\"version\":1,\"themes\":{\"Ocean\":{\"polarity\":\"dark\"," ++ ok_roles_256 ++ "}},\"default\":\"ocean\"}";
    var storage: Storage = undefined;
    try populate(std.testing.allocator, src, &storage);
    try std.testing.expectEqual(@as(usize, 0), storage.registry.default_index);
}

test "a mixed theme with any hex/array role requires truecolor wholesale" {
    // five 256-index roles + one hex ⇒ the whole theme needs truecolor.
    const src = "{\"version\":1,\"themes\":{\"a\":{\"polarity\":\"dark\",\"accent\":\"#ff0000\",\"secondary\":2,\"success\":3,\"warning\":4,\"danger\":5,\"muted\":6}},\"default\":\"a\"}";
    var storage: Storage = undefined;
    try populate(std.testing.allocator, src, &storage);
    try std.testing.expect(storage.requires_truecolor[0]);
    try std.testing.expect(storage.requires_at_least_256[0]); // the five index roles still count
}
