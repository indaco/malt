//! malt — built-in TUI colour themes.
//!
//! A theme is a closed table of role → colour. `color.zig` owns the resolver
//! and the background-aware `default` theme; this file is only the named
//! palettes plus the env→theme map. One file (not a `ui/themes/` folder): nine
//! small comptime tables fit on a screen. Split into a folder only if themes
//! later carry metadata (display names, sub-palettes). `Rgb` is intentionally
//! local so this module imports `std` alone (no cycle with color.zig).

const std = @import("std");

/// Semantic paint role. Every TUI colour site asks for one of these; the
/// resolver in color.zig maps it to an escape for the active (theme, bg, tier).
pub const Role = enum { accent, secondary, success, warning, danger, muted };

/// Built-in themes. `default` is resolved by color.zig's background-aware
/// tiers; the rest are fixed truecolor tables below.
pub const Theme = enum {
    default,
    dracula,
    catppuccin_mocha,
    catppuccin_latte,
    rose_pine,
    rose_pine_dawn,
    nord,
    tokyo_night,
    gruvbox_dark,
    gruvbox_light,
    everforest,
};

/// The background a named theme is designed for. `color.zig` gates a theme on
/// this: a theme whose polarity contradicts the *detected* terminal background
/// degrades to the background-aware `default` so colours stay legible.
pub const Polarity = enum { dark, light };

const Rgb = struct { r: u8, g: u8, b: u8 };

/// Pre-rendered truecolor SGR for a role's RGB. Comptime so the tables hold
/// ready strings — no per-frame formatting.
fn esc(comptime c: Rgb) []const u8 {
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

/// One theme's six role escapes.
pub const NamedPalette = struct {
    accent: []const u8,
    secondary: []const u8,
    success: []const u8,
    warning: []const u8,
    danger: []const u8,
    muted: []const u8,

    pub fn get(self: *const NamedPalette, role: Role) []const u8 {
        return switch (role) {
            .accent => self.accent,
            .secondary => self.secondary,
            .success => self.success,
            .warning => self.warning,
            .danger => self.danger,
            .muted => self.muted,
        };
    }
};

/// Build a palette from six RGBs at comptime.
fn palette(comptime t: struct {
    accent: Rgb,
    secondary: Rgb,
    success: Rgb,
    warning: Rgb,
    danger: Rgb,
    muted: Rgb,
}) NamedPalette {
    return .{
        .accent = esc(t.accent),
        .secondary = esc(t.secondary),
        .success = esc(t.success),
        .warning = esc(t.warning),
        .danger = esc(t.danger),
        .muted = esc(t.muted),
    };
}

// Canonical hex from each theme's published palette; role choices documented in
// the design doc (accent = signature hue, warning = an amber/yellow that reads
// as caution, muted = the theme's comment/overlay colour).
const dracula = palette(.{
    .accent = .{ .r = 0xbd, .g = 0x93, .b = 0xf9 },
    .secondary = .{ .r = 0x8b, .g = 0xe9, .b = 0xfd },
    .success = .{ .r = 0x50, .g = 0xfa, .b = 0x7b },
    .warning = .{ .r = 0xff, .g = 0xb8, .b = 0x6c },
    .danger = .{ .r = 0xff, .g = 0x55, .b = 0x55 },
    .muted = .{ .r = 0x62, .g = 0x72, .b = 0xa4 },
});

const catppuccin_mocha = palette(.{
    .accent = .{ .r = 0xcb, .g = 0xa6, .b = 0xf7 },
    .secondary = .{ .r = 0x89, .g = 0xb4, .b = 0xfa },
    .success = .{ .r = 0xa6, .g = 0xe3, .b = 0xa1 },
    .warning = .{ .r = 0xf9, .g = 0xe2, .b = 0xaf },
    .danger = .{ .r = 0xf3, .g = 0x8b, .b = 0xa8 },
    .muted = .{ .r = 0x6c, .g = 0x70, .b = 0x86 },
});

const catppuccin_latte = palette(.{
    .accent = .{ .r = 0x88, .g = 0x39, .b = 0xef },
    .secondary = .{ .r = 0x1e, .g = 0x66, .b = 0xf5 },
    .success = .{ .r = 0x40, .g = 0xa0, .b = 0x2b },
    .warning = .{ .r = 0xdf, .g = 0x8e, .b = 0x1d },
    .danger = .{ .r = 0xd2, .g = 0x0f, .b = 0x39 },
    .muted = .{ .r = 0x6c, .g = 0x6f, .b = 0x85 },
});

const rose_pine = palette(.{
    .accent = .{ .r = 0xc4, .g = 0xa7, .b = 0xe7 },
    .secondary = .{ .r = 0x9c, .g = 0xcf, .b = 0xd8 },
    .success = .{ .r = 0x31, .g = 0x74, .b = 0x8f },
    .warning = .{ .r = 0xf6, .g = 0xc1, .b = 0x77 },
    .danger = .{ .r = 0xeb, .g = 0x6f, .b = 0x92 },
    .muted = .{ .r = 0x6e, .g = 0x6a, .b = 0x86 },
});

const rose_pine_dawn = palette(.{
    .accent = .{ .r = 0x90, .g = 0x7a, .b = 0xa9 },
    .secondary = .{ .r = 0x56, .g = 0x94, .b = 0x9f },
    .success = .{ .r = 0x28, .g = 0x69, .b = 0x83 },
    .warning = .{ .r = 0xea, .g = 0x9d, .b = 0x34 },
    .danger = .{ .r = 0xb4, .g = 0x63, .b = 0x7a },
    .muted = .{ .r = 0x98, .g = 0x93, .b = 0xa5 },
});

const nord = palette(.{
    .accent = .{ .r = 0x88, .g = 0xc0, .b = 0xd0 },
    .secondary = .{ .r = 0x81, .g = 0xa1, .b = 0xc1 },
    .success = .{ .r = 0xa3, .g = 0xbe, .b = 0x8c },
    .warning = .{ .r = 0xeb, .g = 0xcb, .b = 0x8b },
    .danger = .{ .r = 0xbf, .g = 0x61, .b = 0x6a },
    .muted = .{ .r = 0x4c, .g = 0x56, .b = 0x6a },
});

const tokyo_night = palette(.{
    .accent = .{ .r = 0x7a, .g = 0xa2, .b = 0xf7 },
    .secondary = .{ .r = 0x7d, .g = 0xcf, .b = 0xff },
    .success = .{ .r = 0x9e, .g = 0xce, .b = 0x6a },
    .warning = .{ .r = 0xe0, .g = 0xaf, .b = 0x68 },
    .danger = .{ .r = 0xf7, .g = 0x76, .b = 0x8e },
    .muted = .{ .r = 0x56, .g = 0x5f, .b = 0x89 },
});

const gruvbox_dark = palette(.{
    .accent = .{ .r = 0xfe, .g = 0x80, .b = 0x19 },
    .secondary = .{ .r = 0x83, .g = 0xa5, .b = 0x98 },
    .success = .{ .r = 0xb8, .g = 0xbb, .b = 0x26 },
    .warning = .{ .r = 0xfa, .g = 0xbd, .b = 0x2f },
    .danger = .{ .r = 0xfb, .g = 0x49, .b = 0x34 },
    .muted = .{ .r = 0x92, .g = 0x83, .b = 0x74 },
});

const gruvbox_light = palette(.{
    .accent = .{ .r = 0xaf, .g = 0x3a, .b = 0x03 },
    .secondary = .{ .r = 0x07, .g = 0x66, .b = 0x78 },
    .success = .{ .r = 0x79, .g = 0x74, .b = 0x0e },
    .warning = .{ .r = 0xb5, .g = 0x76, .b = 0x14 },
    .danger = .{ .r = 0x9d, .g = 0x00, .b = 0x06 },
    .muted = .{ .r = 0x7c, .g = 0x6f, .b = 0x64 },
});

// The only green-led palette: everforest's soft forest greens, the standout in a
// gallery otherwise full of muted purples and blues.
const everforest = palette(.{
    .accent = .{ .r = 0xa7, .g = 0xc0, .b = 0x80 },
    .secondary = .{ .r = 0x7f, .g = 0xbb, .b = 0xb3 },
    .success = .{ .r = 0xa7, .g = 0xc0, .b = 0x80 },
    .warning = .{ .r = 0xdb, .g = 0xbc, .b = 0x7f },
    .danger = .{ .r = 0xe6, .g = 0x7e, .b = 0x80 },
    .muted = .{ .r = 0x85, .g = 0x92, .b = 0x89 },
});

/// The named palette for a theme, or null for `.default` (resolved by
/// color.zig's background-aware tiers).
pub fn named(t: Theme) ?*const NamedPalette {
    return switch (t) {
        .default => null,
        .dracula => &dracula,
        .catppuccin_mocha => &catppuccin_mocha,
        .catppuccin_latte => &catppuccin_latte,
        .rose_pine => &rose_pine,
        .rose_pine_dawn => &rose_pine_dawn,
        .nord => &nord,
        .tokyo_night => &tokyo_night,
        .gruvbox_dark => &gruvbox_dark,
        .gruvbox_light => &gruvbox_light,
        .everforest => &everforest,
    };
}

/// A named theme's intended background, or null for `.default` (which is itself
/// background-aware and never conflicts). Exhaustive over `Theme` so a future
/// theme forces a polarity decision at compile time.
pub fn polarity(t: Theme) ?Polarity {
    return switch (t) {
        .default => null,
        .dracula, .catppuccin_mocha, .rose_pine, .nord, .tokyo_night, .gruvbox_dark, .everforest => .dark,
        .catppuccin_latte, .rose_pine_dawn, .gruvbox_light => .light,
    };
}

test "polarity classifies every named theme; default has none" {
    try std.testing.expectEqual(@as(?Polarity, null), polarity(.default));
    try std.testing.expectEqual(Polarity.dark, polarity(.dracula).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.catppuccin_mocha).?);
    try std.testing.expectEqual(Polarity.light, polarity(.catppuccin_latte).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.rose_pine).?);
    try std.testing.expectEqual(Polarity.light, polarity(.rose_pine_dawn).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.nord).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.tokyo_night).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.gruvbox_dark).?);
    try std.testing.expectEqual(Polarity.light, polarity(.gruvbox_light).?);
    try std.testing.expectEqual(Polarity.dark, polarity(.everforest).?);
}

/// Env value → theme. `light`/`dark`/`auto`/`default` resolve to `.default`
/// (the light/dark *background* pin is handled by color.zig's existing
/// detection path, not here). Both `-` and `_` spellings are accepted. Keys are
/// lowercase; the caller lowercases the env value before lookup.
pub const from_env = std.StaticStringMap(Theme).initComptime(.{
    .{ "default", Theme.default },
    .{ "auto", Theme.default },
    .{ "light", Theme.default },
    .{ "dark", Theme.default },
    .{ "dracula", Theme.dracula },
    .{ "catppuccin-mocha", Theme.catppuccin_mocha },
    .{ "catppuccin_mocha", Theme.catppuccin_mocha },
    .{ "catppuccin-latte", Theme.catppuccin_latte },
    .{ "catppuccin_latte", Theme.catppuccin_latte },
    .{ "rose-pine", Theme.rose_pine },
    .{ "rose_pine", Theme.rose_pine },
    .{ "rose-pine-dawn", Theme.rose_pine_dawn },
    .{ "rose_pine_dawn", Theme.rose_pine_dawn },
    .{ "nord", Theme.nord },
    .{ "tokyo-night", Theme.tokyo_night },
    .{ "tokyo_night", Theme.tokyo_night },
    .{ "gruvbox-dark", Theme.gruvbox_dark },
    .{ "gruvbox_dark", Theme.gruvbox_dark },
    .{ "gruvbox-light", Theme.gruvbox_light },
    .{ "gruvbox_light", Theme.gruvbox_light },
    .{ "everforest", Theme.everforest },
});

test "every named theme resolves all six roles to a non-empty truecolor escape" {
    inline for (.{
        Theme.dracula,     Theme.catppuccin_mocha, Theme.catppuccin_latte,
        Theme.rose_pine,   Theme.rose_pine_dawn,   Theme.nord,
        Theme.tokyo_night, Theme.gruvbox_dark,     Theme.gruvbox_light,
        Theme.everforest,
    }) |t| {
        const p = named(t).?;
        inline for (.{ Role.accent, .secondary, .success, .warning, .danger, .muted }) |r| {
            const code = p.get(r);
            try std.testing.expect(code.len > 0);
            try std.testing.expect(std.mem.startsWith(u8, code, "\x1b[38;2;"));
        }
    }
}

test "dracula accent is the published mauve RGB" {
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", named(.dracula).?.accent);
}

test "everforest accent is the published forest green RGB" {
    try std.testing.expectEqualStrings("\x1b[38;2;167;192;128m", named(.everforest).?.accent);
}

test "from_env accepts both - and _ spellings for every multi-word theme" {
    const cases = .{
        .{ "catppuccin-mocha", "catppuccin_mocha", Theme.catppuccin_mocha },
        .{ "catppuccin-latte", "catppuccin_latte", Theme.catppuccin_latte },
        .{ "rose-pine", "rose_pine", Theme.rose_pine },
        .{ "rose-pine-dawn", "rose_pine_dawn", Theme.rose_pine_dawn },
        .{ "tokyo-night", "tokyo_night", Theme.tokyo_night },
        .{ "gruvbox-dark", "gruvbox_dark", Theme.gruvbox_dark },
        .{ "gruvbox-light", "gruvbox_light", Theme.gruvbox_light },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[2], from_env.get(c[0]).?);
        try std.testing.expectEqual(c[2], from_env.get(c[1]).?);
    }
}

test "from_env maps the reserved background values to default" {
    try std.testing.expectEqual(Theme.default, from_env.get("light").?);
    try std.testing.expectEqual(Theme.default, from_env.get("dark").?);
    try std.testing.expectEqual(Theme.default, from_env.get("auto").?);
}

test "default theme has no named palette" {
    try std.testing.expect(named(.default) == null);
}
