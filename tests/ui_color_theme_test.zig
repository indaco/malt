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
