//! malt — terminal-background detection + semantic palette
//!
//! These pure helpers feed `SemanticStyle.*.code()` so every output
//! site renders legibly on both backgrounds, at both colour tiers.

const std = @import("std");
const testing = std.testing;
const color = @import("malt").color;

// ─── classifyLuminance ───────────────────────────────────────────────
//
// W3C relative luminance: Y = 0.2126·R + 0.7152·G + 0.0722·B
// (all in [0,1]). Cutoff at 0.5 — same threshold lipgloss uses.

test "classifyLuminance flags pure black as dark" {
    try testing.expectEqual(color.Background.dark, color.classifyLuminance(.{ .r = 0, .g = 0, .b = 0 }));
}

test "classifyLuminance flags pure white as light" {
    try testing.expectEqual(color.Background.light, color.classifyLuminance(.{ .r = 255, .g = 255, .b = 255 }));
}

test "classifyLuminance flags typical IDE dark palette (0x1e1e1e) as dark" {
    try testing.expectEqual(color.Background.dark, color.classifyLuminance(.{ .r = 0x1e, .g = 0x1e, .b = 0x1e }));
}

test "classifyLuminance flags Solarized Light (0xfdf6e3) as light" {
    try testing.expectEqual(color.Background.light, color.classifyLuminance(.{ .r = 0xfd, .g = 0xf6, .b = 0xe3 }));
}

test "classifyLuminance flags Solarized Dark (0x002b36) as dark" {
    try testing.expectEqual(color.Background.dark, color.classifyLuminance(.{ .r = 0x00, .g = 0x2b, .b = 0x36 }));
}

test "classifyLuminance tilts on the green channel (W3C weighting)" {
    // Pure green at full intensity carries the heaviest weight — the
    // cutoff should put it on the light side.
    try testing.expectEqual(color.Background.light, color.classifyLuminance(.{ .r = 0, .g = 255, .b = 0 }));
    // Pure blue is the darkest of the three primaries.
    try testing.expectEqual(color.Background.dark, color.classifyLuminance(.{ .r = 0, .g = 0, .b = 255 }));
}

// ─── parseOsc11Response ──────────────────────────────────────────────
//
// Terminal answers OSC 11 with `ESC ] 11 ; rgb:RRRR/GGGG/BBBB ST/BEL`.
// Component width is typically 4 hex digits (16-bit) but 2-digit
// (8-bit) is also legal. We take the high 8 bits, so either form
// parses the same way.

test "parseOsc11Response reads a 4-digit ST-terminated response" {
    const resp = "\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\";
    const rgb = color.parseOsc11Response(resp) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, 0x1e), rgb.r);
    try testing.expectEqual(@as(u8, 0x1e), rgb.g);
    try testing.expectEqual(@as(u8, 0x1e), rgb.b);
}

test "parseOsc11Response reads a BEL-terminated response" {
    const resp = "\x1b]11;rgb:ffff/ffff/ffff\x07";
    const rgb = color.parseOsc11Response(resp) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, 0xff), rgb.r);
    try testing.expectEqual(@as(u8, 0xff), rgb.g);
    try testing.expectEqual(@as(u8, 0xff), rgb.b);
}

test "parseOsc11Response reads a 2-digit form (older terminals)" {
    const resp = "\x1b]11;rgb:ab/cd/ef\x07";
    const rgb = color.parseOsc11Response(resp) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(u8, 0xab), rgb.r);
    try testing.expectEqual(@as(u8, 0xcd), rgb.g);
    try testing.expectEqual(@as(u8, 0xef), rgb.b);
}

test "parseOsc11Response returns null on a garbled response" {
    try testing.expect(color.parseOsc11Response("") == null);
    try testing.expect(color.parseOsc11Response("no escape here") == null);
    try testing.expect(color.parseOsc11Response("\x1b]11;notrgb:1e1e\x07") == null);
    try testing.expect(color.parseOsc11Response("\x1b]11;rgb:1e1e/1e1e\x07") == null); // missing B
    try testing.expect(color.parseOsc11Response("\x1b]11;rgb:zzzz/zzzz/zzzz\x07") == null);
}

// ─── parseColorFgBg ──────────────────────────────────────────────────
//
// rxvt/urxvt convention: bg in {0..6, 8} ⇒ dark; {7, 9..15} ⇒ light.
// The value may carry an optional middle field (`fg;default;bg`).

test "parseColorFgBg maps classic dark values to .dark" {
    try testing.expectEqual(color.Background.dark, color.parseColorFgBg("15;0"));
    try testing.expectEqual(color.Background.dark, color.parseColorFgBg("7;0"));
    try testing.expectEqual(color.Background.dark, color.parseColorFgBg("15;8"));
}

test "parseColorFgBg maps classic light values to .light" {
    try testing.expectEqual(color.Background.light, color.parseColorFgBg("0;15"));
    try testing.expectEqual(color.Background.light, color.parseColorFgBg("0;7"));
    try testing.expectEqual(color.Background.light, color.parseColorFgBg("15;9"));
}

test "parseColorFgBg tolerates the 3-field form with a default middle" {
    try testing.expectEqual(color.Background.dark, color.parseColorFgBg("15;default;0"));
    try testing.expectEqual(color.Background.light, color.parseColorFgBg("0;default;15"));
}

test "parseColorFgBg returns .unknown on malformed or unrecognised input" {
    try testing.expectEqual(color.Background.unknown, color.parseColorFgBg(""));
    try testing.expectEqual(color.Background.unknown, color.parseColorFgBg("garbage"));
    try testing.expectEqual(color.Background.unknown, color.parseColorFgBg("0"));
    try testing.expectEqual(color.Background.unknown, color.parseColorFgBg("0;99"));
}

// ─── themeFromEnv ────────────────────────────────────────────────────
//
// User escape hatch: MALT_THEME={light,dark,auto}. Auto ⇒ null so the
// detection chain continues (OSC 11 → COLORFGBG → fallback dark).

test "themeFromEnv honours explicit overrides case-insensitively" {
    try testing.expectEqual(color.Background.light, color.themeFromEnv("light").?);
    try testing.expectEqual(color.Background.dark, color.themeFromEnv("dark").?);
    try testing.expectEqual(color.Background.light, color.themeFromEnv("LIGHT").?);
    try testing.expectEqual(color.Background.dark, color.themeFromEnv("Dark").?);
}

test "themeFromEnv returns null for auto or empty" {
    try testing.expect(color.themeFromEnv("auto") == null);
    try testing.expect(color.themeFromEnv("") == null);
    try testing.expect(color.themeFromEnv(null) == null);
}

test "themeFromEnv returns null on an unrecognised value" {
    try testing.expect(color.themeFromEnv("banana") == null);
}

// `themedStyle` / `detailStyle` were the stopgap helpers before the
// SemanticStyle palette landed; coverage for the replacement lives in
// the paletteCode + SemanticStyle.code sections below.

// ─── truecolorSupported ──────────────────────────────────────────────

test "truecolorSupported reads COLORTERM=truecolor" {
    try testing.expect(color.truecolorFromEnv("truecolor"));
}
test "truecolorSupported reads COLORTERM=24bit" {
    try testing.expect(color.truecolorFromEnv("24bit"));
}
test "truecolorSupported is false on other COLORTERM values" {
    try testing.expect(!color.truecolorFromEnv(""));
    try testing.expect(!color.truecolorFromEnv("256"));
    try testing.expect(!color.truecolorFromEnv("ansi"));
    try testing.expect(!color.truecolorFromEnv(null));
}

// ─── SemanticStyle palette ───────────────────────────────────────────
//
// Each role × (bg, truecolor) combination maps to a single escape
// string. The tests pin every cell of the 5×4 matrix so swapping a
// hex value is a visible, reviewable diff — not silent drift.

test "paletteCode: dark + truecolor palette (Tailwind sky/amber/green/red/slate)" {
    const c = color.paletteCode;
    const d = color.Background.dark;
    try testing.expectEqualStrings("\x1b[38;2;125;211;252m", c(.info, d, true));
    try testing.expectEqualStrings("\x1b[38;2;251;191;36m", c(.warn, d, true));
    try testing.expectEqualStrings("\x1b[38;2;74;222;128m", c(.success, d, true));
    try testing.expectEqualStrings("\x1b[38;2;248;113;113m", c(.err, d, true));
    try testing.expectEqualStrings("\x1b[38;2;148;163;184m", c(.detail, d, true));
}

test "paletteCode: light + truecolor palette (orange warn for AA contrast on white)" {
    const c = color.paletteCode;
    const l = color.Background.light;
    try testing.expectEqualStrings("\x1b[38;2;2;132;199m", c(.info, l, true));
    try testing.expectEqualStrings("\x1b[38;2;180;83;9m", c(.warn, l, true));
    try testing.expectEqualStrings("\x1b[38;2;21;128;61m", c(.success, l, true));
    try testing.expectEqualStrings("\x1b[38;2;185;28;28m", c(.err, l, true));
    // Detail mirrors the dark palette's slate-400 so meta info recedes
    // instead of out-weighting the default-foreground body text.
    try testing.expectEqualStrings("\x1b[38;2;148;163;184m", c(.detail, l, true));
}

test "paletteCode: dark + basic falls back to today's legacy palette" {
    const c = color.paletteCode;
    const d = color.Background.dark;
    try testing.expectEqualStrings("\x1b[36m", c(.info, d, false));
    try testing.expectEqualStrings("\x1b[33m", c(.warn, d, false));
    try testing.expectEqualStrings("\x1b[32m", c(.success, d, false));
    try testing.expectEqualStrings("\x1b[31m", c(.err, d, false));
    try testing.expectEqualStrings("\x1b[2m", c(.detail, d, false));
}

test "paletteCode: light + basic swaps fade-prone hues (cyan→blue, yellow→magenta) and shares dark-basic faint" {
    const c = color.paletteCode;
    const l = color.Background.light;
    try testing.expectEqualStrings("\x1b[34m", c(.info, l, false));
    try testing.expectEqualStrings("\x1b[35m", c(.warn, l, false));
    try testing.expectEqualStrings("\x1b[32m", c(.success, l, false));
    try testing.expectEqualStrings("\x1b[31m", c(.err, l, false));
    // Same faint as dark-basic: both basic palettes render detail identically.
    try testing.expectEqualStrings("\x1b[2m", c(.detail, l, false));
}

test "paletteCode: unknown background behaves like dark" {
    const c = color.paletteCode;
    try testing.expectEqualStrings(
        c(.warn, color.Background.dark, true),
        c(.warn, color.Background.unknown, true),
    );
    try testing.expectEqualStrings(
        c(.detail, color.Background.dark, false),
        c(.detail, color.Background.unknown, false),
    );
}

// ─── SemanticStyle.code() — the runtime-cached entry point ───────────

test "SemanticStyle.code picks the cached palette cell" {
    color.setBackgroundForTest(color.Background.light);
    color.setTruecolorForTest(true);
    defer color.setBackgroundForTest(null);
    defer color.setTruecolorForTest(null);
    try testing.expectEqualStrings("\x1b[38;2;180;83;9m", color.SemanticStyle.warn.code());
}

test "SemanticStyle.code falls back to basic when truecolor is off" {
    color.setBackgroundForTest(color.Background.light);
    color.setTruecolorForTest(false);
    defer color.setBackgroundForTest(null);
    defer color.setTruecolorForTest(null);
    try testing.expectEqualStrings("\x1b[35m", color.SemanticStyle.warn.code());
}

// ─── theme resolution (TUI roles) ────────────────────────────────────

test "resolveThemeFromEnv: unknown value falls back to default" {
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv("not-a-theme"));
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv(null));
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv("")); // the len==0 guard
    // A value longer than the 32-byte lowercase buffer must not overflow it — it
    // falls back to default (the raw.len > buf.len guard).
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv("d" ** 64));
}

test "resolveThemeFromEnv: reserved background values resolve to default theme" {
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv("light"));
    try testing.expectEqual(color.Theme.default, color.resolveThemeFromEnv("dark"));
}

test "resolveThemeFromEnv: case-insensitive named theme" {
    try testing.expectEqual(color.Theme.dracula, color.resolveThemeFromEnv("Dracula"));
    try testing.expectEqual(color.Theme.dracula, color.resolveThemeFromEnv("DRACULA"));
}

test "resolveRole: default theme on dark+basic matches today's TUI hues" {
    try testing.expectEqualStrings("\x1b[36m", color.resolveRole(.default, .accent, .dark, false));
    try testing.expectEqualStrings("\x1b[32m", color.resolveRole(.default, .success, .dark, false));
    try testing.expectEqualStrings("\x1b[33m", color.resolveRole(.default, .warning, .dark, false));
    try testing.expectEqualStrings("\x1b[31m", color.resolveRole(.default, .danger, .dark, false));
    try testing.expectEqualStrings("\x1b[2m", color.resolveRole(.default, .muted, .dark, false));
}

test "resolveRole: default theme is background-aware on truecolor" {
    try testing.expectEqualStrings("\x1b[38;2;125;211;252m", color.resolveRole(.default, .accent, .dark, true));
    try testing.expectEqualStrings("\x1b[38;2;2;132;199m", color.resolveRole(.default, .accent, .light, true));
}

test "resolveRole: named theme returns its RGB on truecolor" {
    try testing.expectEqualStrings("\x1b[38;2;189;147;249m", color.resolveRole(.dracula, .accent, .dark, true));
}

test "resolveRole: named theme degrades to default-basic on a non-truecolor terminal" {
    try testing.expectEqualStrings(
        color.resolveRole(.default, .accent, .dark, false),
        color.resolveRole(.dracula, .accent, .dark, false),
    );
    try testing.expectEqualStrings("\x1b[36m", color.resolveRole(.dracula, .accent, .dark, false));
    // Degradation passes the background through: a light terminal gets the
    // light-basic cell, not the dark one.
    try testing.expectEqualStrings("\x1b[34m", color.resolveRole(.dracula, .accent, .light, false));
}

test "roleCode: wires theme + background + truecolor caches together" {
    color.setThemeForTest(.dracula);
    color.setBackgroundForTest(.dark);
    color.setTruecolorForTest(true);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    try testing.expectEqualStrings("\x1b[38;2;189;147;249m", color.roleCode(.accent));
}

test "resolveRole: secondary role has its own blue, distinct from accent" {
    try testing.expectEqualStrings("\x1b[34m", color.resolveRole(.default, .secondary, .dark, false));
    try testing.expect(!std.mem.eql(
        u8,
        color.resolveRole(.default, .secondary, .dark, true),
        color.resolveRole(.default, .accent, .dark, true),
    ));
}

test "resolveRole: default theme uses the light tier on a light background" {
    // light+basic warning is magenta (yellow washes out on white) — proves the
    // role map honours the light tier, not just dark.
    try testing.expectEqualStrings("\x1b[35m", color.resolveRole(.default, .warning, .light, false));
    try testing.expectEqualStrings("\x1b[38;2;180;83;9m", color.resolveRole(.default, .warning, .light, true));
}

test "resolveRole: a light named theme applies on light/unknown but degrades on a dark terminal" {
    // catppuccin-latte accent = Mauve #8839ef. A light theme applies on its own
    // (light) background and on unknown, but a detected-dark terminal contradicts
    // its polarity, so it falls back to the default dark palette for legibility.
    try testing.expectEqualStrings("\x1b[38;2;136;57;239m", color.resolveRole(.catppuccin_latte, .accent, .light, true));
    try testing.expectEqualStrings("\x1b[38;2;136;57;239m", color.resolveRole(.catppuccin_latte, .accent, .unknown, true));
    try testing.expectEqualStrings(
        color.resolveRole(.default, .accent, .dark, true),
        color.resolveRole(.catppuccin_latte, .accent, .dark, true),
    );
}

// ─── theme polarity + CLI/TUI alignment ──────────────────────────────
//
// MALT_THEME drives BOTH surfaces. A named theme applies only on a truecolor
// terminal whose detected background does not contradict the theme's own
// polarity; otherwise both CLI and TUI fall back to the background-aware default
// palette. An unknown background never conflicts — we override an explicit
// MALT_THEME only on positive evidence the theme would be illegible.

test "resolveRole: a dark theme on a detected-light terminal degrades to default" {
    // dracula is a dark theme; on a light background its muted RGB drops below AA,
    // so it falls back to the default light palette instead of its own RGB.
    try testing.expectEqualStrings(
        color.resolveRole(.default, .accent, .light, true),
        color.resolveRole(.dracula, .accent, .light, true),
    );
}

test "resolveRole: a dark theme still applies on dark or unknown backgrounds" {
    try testing.expectEqualStrings("\x1b[38;2;189;147;249m", color.resolveRole(.dracula, .accent, .dark, true));
    try testing.expectEqualStrings("\x1b[38;2;189;147;249m", color.resolveRole(.dracula, .accent, .unknown, true));
}

// ─── SemanticStyle.code() under a named theme (CLI alignment) ─────────

test "SemanticStyle.code: a named theme colours CLI output, mapping each role" {
    color.setThemeForTest(.dracula);
    color.setBackgroundForTest(.dark);
    color.setTruecolorForTest(true);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    // info→accent, notice→secondary, success→success, warn→warning, err→danger, detail→muted
    try testing.expectEqualStrings("\x1b[38;2;189;147;249m", color.SemanticStyle.info.code()); // dracula accent
    try testing.expectEqualStrings("\x1b[38;2;139;233;253m", color.SemanticStyle.notice.code()); // dracula secondary
    try testing.expectEqualStrings("\x1b[38;2;80;250;123m", color.SemanticStyle.success.code()); // dracula success
    try testing.expectEqualStrings("\x1b[38;2;255;184;108m", color.SemanticStyle.warn.code()); // dracula warning
    try testing.expectEqualStrings("\x1b[38;2;255;85;85m", color.SemanticStyle.err.code()); // dracula danger
    try testing.expectEqualStrings("\x1b[38;2;98;114;164m", color.SemanticStyle.detail.code()); // dracula muted
}

test "SemanticStyle.code: a dark theme on a light terminal falls back to the default palette" {
    // The polarity guard at the CLI seam: dracula's low-contrast hues never reach
    // a light terminal — it renders the legible default light cell instead.
    color.setThemeForTest(.dracula);
    color.setBackgroundForTest(.light);
    color.setTruecolorForTest(true);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    try testing.expectEqualStrings(color.paletteCode(.info, .light, true), color.SemanticStyle.info.code());
}

test "SemanticStyle.code: a named theme degrades to default-basic without truecolor" {
    // 8-colour terminals can't carry a theme's RGB identity, so the CLI drops to
    // the default basic cell — same fallback target as a polarity mismatch.
    color.setThemeForTest(.dracula);
    color.setBackgroundForTest(.dark);
    color.setTruecolorForTest(false);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    try testing.expectEqualStrings(color.paletteCode(.info, .dark, false), color.SemanticStyle.info.code());
}

test "SemanticStyle.code: the default theme is unchanged (notice/detail keep their own cells)" {
    // Guards the no-regression promise: under .default the CLI must keep its own
    // notice/detail hues, not borrow the named-theme secondary/muted mapping.
    color.setThemeForTest(.default);
    color.setBackgroundForTest(.dark);
    color.setTruecolorForTest(true);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    try testing.expectEqualStrings(color.paletteCode(.notice, .dark, true), color.SemanticStyle.notice.code());
    try testing.expectEqualStrings(color.paletteCode(.detail, .dark, true), color.SemanticStyle.detail.code());
}

test "resolveRole: a named theme degrades every role to the default cells without truecolor" {
    // Degradation must be total — not just the accent role the tab bar happened
    // to exercise first.
    const roles = [_]color.Role{ .accent, .secondary, .success, .warning, .danger, .muted };
    inline for (roles) |r| {
        try testing.expectEqualStrings(
            color.resolveRole(.default, r, .dark, false),
            color.resolveRole(.dracula, r, .dark, false),
        );
    }
}

test "SemanticStyle.code: a named theme degrades every CLI role to its default cell without truecolor" {
    // The CLI fallback has to hold for every semantic role, not only info.
    color.setThemeForTest(.dracula);
    color.setBackgroundForTest(.dark);
    color.setTruecolorForTest(false);
    defer {
        color.setThemeForTest(null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
    }
    const roles = [_]color.SemanticStyle{ .info, .notice, .success, .warn, .err, .detail };
    inline for (roles) |role| {
        try testing.expectEqualStrings(color.paletteCode(role, .dark, false), role.code());
    }
}
