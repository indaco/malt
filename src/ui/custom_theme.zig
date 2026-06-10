//! malt — user-defined colour themes: runtime palette/registry types and the
//! colour-value → SGR parser.
//!
//! The security crux of loading an untrusted theme file is this file's parser:
//! a role's colour is validated to integers and the SGR escape is *constructed
//! by malt*, never echoed from the file. That single rule is what keeps theme
//! loading safe against ANSI/escape injection — no byte of file input ever
//! reaches the terminal verbatim. A `std`-only leaf (plus `themes` for the
//! shared `Role`/`Polarity`/`NamedPalette`): the loader, file IO and registry
//! population live elsewhere.

const std = @import("std");
const testing = std.testing;

const themes = @import("themes.zig");

/// Registry sanity caps — compile-time constants, never config knobs, so a
/// malformed or hostile file stays bounded and cannot exhaust memory.
pub const max_themes = 32;
pub const max_name = 32;
pub const max_file_bytes = 64 * 1024;

/// Widest SGR a colour value lowers to: `"\x1b[38;2;255;255;255m"` (truecolor,
/// 19 bytes). The 256-colour form `"\x1b[38;5;255m"` is shorter, so this bounds
/// both.
const max_sgr_len = 19;

pub const ColorError = error{InvalidColorValue};

/// A malt-constructed SGR escape, stored inline (no allocation). Its bytes are
/// built from validated integers only — file input is never copied in — which
/// is what makes the conversion injection-proof.
pub const Sgr = struct {
    buf: [max_sgr_len]u8,
    len: usize,

    pub fn slice(self: *const Sgr) []const u8 {
        return self.buf[0..self.len];
    }
};

/// One user-defined theme: a bounded name, its intended background, and the six
/// role escapes. Same shape the resolver already consumes for built-ins, so a
/// custom theme drops into the existing (theme, background, tier) path
/// unchanged.
pub const CustomTheme = struct {
    name: [max_name]u8,
    name_len: usize,
    polarity: themes.Polarity,
    palette: themes.NamedPalette,

    pub fn nameSlice(self: *const CustomTheme) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// The loaded set of user themes. Fixed capacity — no allocation, and a hostile
/// file cannot grow it without bound.
pub const ThemeRegistry = struct {
    themes: [max_themes]CustomTheme,
    count: usize,
    default_index: usize,
};

/// Parse one untrusted colour value into a malt-constructed SGR escape. Accepts
/// exactly three forms and rejects everything else:
///   - `"#rgb"` / `"#rrggbb"`  hex string  → 24-bit truecolor
///   - `[r, g, b]`             ints 0–255   → 24-bit truecolor
///   - `n`                     int 0–255    → 256-colour index
/// The escape is always rebuilt here from parsed integers, so no byte of
/// `value` is ever emitted verbatim.
pub fn parseColorValue(value: std.json.Value) ColorError!Sgr {
    return switch (value) {
        .string => |s| parseHex(s),
        .array => |a| parseRgbArray(a),
        .integer => |n| index256(n),
        // float / bool / null / object / number_string are never a colour.
        else => ColorError.InvalidColorValue,
    };
}

/// `"#rgb"` or `"#rrggbb"` → truecolor. Requires a leading `'#'` and then
/// exactly three or six hex digits; any other length, a missing `'#'`, or a
/// non-hex byte (ESC, `';'`, `'m'`, space, …) fails here and is never emitted.
fn parseHex(s: []const u8) ColorError!Sgr {
    if (s.len == 0 or s[0] != '#') return ColorError.InvalidColorValue;
    const digits = s[1..];
    return switch (digits.len) {
        // Shorthand: each nibble is doubled, like CSS (#abc → #aabbcc). n*17
        // equals n*16+n, so a 0–15 nibble maps to 0x00…0xff without overflow.
        3 => truecolor(
            (hexDigit(digits[0]) orelse return ColorError.InvalidColorValue) * 17,
            (hexDigit(digits[1]) orelse return ColorError.InvalidColorValue) * 17,
            (hexDigit(digits[2]) orelse return ColorError.InvalidColorValue) * 17,
        ),
        6 => truecolor(
            hexByte(digits[0..2]) orelse return ColorError.InvalidColorValue,
            hexByte(digits[2..4]) orelse return ColorError.InvalidColorValue,
            hexByte(digits[4..6]) orelse return ColorError.InvalidColorValue,
        ),
        else => ColorError.InvalidColorValue,
    };
}

/// `[r, g, b]` of integers 0–255 → truecolor. Wrong arity, a non-integer
/// element, or an out-of-range channel rejects.
fn parseRgbArray(a: std.json.Array) ColorError!Sgr {
    if (a.items.len != 3) return ColorError.InvalidColorValue;
    const r = channel(a.items[0]) orelse return ColorError.InvalidColorValue;
    const g = channel(a.items[1]) orelse return ColorError.InvalidColorValue;
    const b = channel(a.items[2]) orelse return ColorError.InvalidColorValue;
    return truecolor(r, g, b);
}

/// A single 0–255 integer → 256-colour index.
fn index256(n: i64) ColorError!Sgr {
    if (n < 0 or n > 255) return ColorError.InvalidColorValue;
    return sgr("\x1b[38;5;{d}m", .{@as(u8, @intCast(n))});
}

/// One array element as a 0–255 channel, or null if it is not an integer in
/// range — floats, strings, negatives and >255 all reject.
fn channel(v: std.json.Value) ?u8 {
    const n = switch (v) {
        .integer => |i| i,
        else => return null,
    };
    if (n < 0 or n > 255) return null;
    return @intCast(n);
}

/// A two-char hex pair → byte, or null on any non-hex digit. Strict: no sign,
/// no `'_'` separators (unlike `std.fmt.parseUnsigned`), no whitespace.
fn hexByte(pair: *const [2]u8) ?u8 {
    const hi = hexDigit(pair[0]) orelse return null;
    const lo = hexDigit(pair[1]) orelse return null;
    return hi * 16 + lo;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn truecolor(r: u8, g: u8, b: u8) Sgr {
    return sgr("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
}

/// Render an SGR from validated `u8` arguments into the inline buffer. The
/// widest output is `max_sgr_len` bytes, so `bufPrint` can never overflow.
fn sgr(comptime fmt: []const u8, args: anytype) Sgr {
    var out: Sgr = .{ .buf = undefined, .len = 0 };
    const s = std.fmt.bufPrint(&out.buf, fmt, args) catch unreachable; // u8 args ≤ max_sgr_len
    out.len = s.len;
    return out;
}

// ─── tests ───────────────────────────────────────────────────────────

/// Build a `std.json.Value` from a JSON literal the way the theme loader will —
/// exercising the real shapes (`.string`/`.array`/`.integer`/…) the parser must
/// accept or reject.
fn jsonValue(src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
}

fn expectParses(src: []const u8, want: []const u8) !void {
    const p = try jsonValue(src);
    defer p.deinit();
    const escape = try parseColorValue(p.value);
    try testing.expectEqualStrings(want, escape.slice());
}

fn expectRejects(src: []const u8) !void {
    const p = try jsonValue(src);
    defer p.deinit();
    try testing.expectError(ColorError.InvalidColorValue, parseColorValue(p.value));
}

test "valid #rrggbb hex lowers to a truecolor SGR malt builds itself" {
    try expectParses("\"#bd93f9\"", "\x1b[38;2;189;147;249m");
    try expectParses("\"#000000\"", "\x1b[38;2;0;0;0m");
    try expectParses("\"#ffffff\"", "\x1b[38;2;255;255;255m");
    // Upper-case hex digits are equally valid.
    try expectParses("\"#FF00aa\"", "\x1b[38;2;255;0;170m");
}

test "valid #rgb short hex expands each nibble (CSS shorthand)" {
    // #abc → #aabbcc: each nibble doubled (0xa → 0xaa), like CSS.
    try expectParses("\"#fff\"", "\x1b[38;2;255;255;255m");
    try expectParses("\"#000\"", "\x1b[38;2;0;0;0m");
    try expectParses("\"#abc\"", "\x1b[38;2;170;187;204m");
    try expectParses("\"#F0A\"", "\x1b[38;2;255;0;170m"); // upper-case, doubled
}

test "valid [r,g,b] array lowers to the same truecolor SGR" {
    try expectParses("[189,147,249]", "\x1b[38;2;189;147;249m");
    try expectParses("[0,0,0]", "\x1b[38;2;0;0;0m");
    try expectParses("[255,255,255]", "\x1b[38;2;255;255;255m");
}

test "valid 0–255 integer lowers to a 256-colour index SGR" {
    try expectParses("0", "\x1b[38;5;0m");
    try expectParses("42", "\x1b[38;5;42m");
    try expectParses("255", "\x1b[38;5;255m");
}

test "malformed hex is rejected, never emitted" {
    // Lengths between/around the two valid arities (3 and 6 digits).
    try expectRejects("\"#\""); // '#' alone, zero digits
    try expectRejects("\"#f\""); // 1 digit
    try expectRejects("\"#ff\""); // 2 digits
    try expectRejects("\"#ffff\""); // 4 digits
    try expectRejects("\"#fffff\""); // 5 digits
    try expectRejects("\"#fffffff\""); // 7 digits, too long
    // Shape and content errors at both valid arities.
    try expectRejects("\"bd93f9\""); // missing leading '#'
    try expectRejects("\"fff\""); // short form missing '#'
    try expectRejects("\"#gggggg\""); // non-hex letters (long)
    try expectRejects("\"#ggg\""); // non-hex letters (short)
    try expectRejects("\"#12 45f\""); // embedded space (long)
    try expectRejects("\"#1 2\""); // embedded space (short)
    try expectRejects("\"#0x0fff\""); // 0x prefix is not hex digits
    try expectRejects("\"\""); // empty string
    try expectRejects("\"#fff \""); // trailing space → length 4, not 3
    try expectRejects("\" #fff\""); // leading space → '#' not first
}

test "out-of-range and wrong-shape arrays are rejected" {
    try expectRejects("[189,147]"); // arity 2
    try expectRejects("[1,2,3,4]"); // arity 4
    try expectRejects("[]"); // arity 0
    try expectRejects("[256,0,0]"); // channel > 255
    try expectRejects("[-1,0,0]"); // negative channel
    try expectRejects("[1,2,\"x\"]"); // non-integer element
    try expectRejects("[1,2,3.5]"); // float element
}

test "out-of-range and non-integer scalars are rejected" {
    try expectRejects("256"); // > 255
    try expectRejects("-1"); // negative
    try expectRejects("3.5"); // float
    try expectRejects("255.0"); // float, not integer
    try expectRejects("true"); // bool
    try expectRejects("null"); // null
    try expectRejects("{}"); // object
    try expectRejects("99999999999999999999"); // overflow → number_string
}

test "an escape sequence cannot be smuggled through any colour form" {
    // ESC inside an otherwise hex-shaped string: still rejected as non-hex,
    // proving output is built from parsed integers, not copied from input.
    try expectRejects("\"#fff\\u001b[2J\""); // ESC after a short hex run (len 8)
    try expectRejects("\"#\\u001bfffff\""); // ESC in the hex body, exact length 7
    try expectRejects("\"#fff;0m\""); // ';' and 'm' — the SGR delimiters — rejected
}

test "each hex channel maps independently — no r/g/b swap (long)" {
    try expectParses("\"#ff0000\"", "\x1b[38;2;255;0;0m"); // pure red
    try expectParses("\"#00ff00\"", "\x1b[38;2;0;255;0m"); // pure green
    try expectParses("\"#0000ff\"", "\x1b[38;2;0;0;255m"); // pure blue
    try expectParses("\"#102030\"", "\x1b[38;2;16;32;48m"); // all distinct, ordered
    try expectParses("\"#AbCdEf\"", "\x1b[38;2;171;205;239m"); // mixed case
}

test "each hex channel maps independently — no r/g/b swap (short)" {
    try expectParses("\"#f00\"", "\x1b[38;2;255;0;0m");
    try expectParses("\"#0f0\"", "\x1b[38;2;0;255;0m");
    try expectParses("\"#00f\"", "\x1b[38;2;0;0;255m");
}

test "short and long hex for the same colour produce identical SGR" {
    // #abc is exactly #aabbcc; the parser must agree on both forms.
    const expected = "\x1b[38;2;170;187;204m";
    try expectParses("\"#abc\"", expected);
    try expectParses("\"#aabbcc\"", expected);
    // Case must not change the bytes.
    try expectParses("\"#AABBCC\"", expected);
}

test "hex rejects sign and underscore — not std.fmt.parseUnsigned semantics" {
    // parseUnsigned would accept '_' separators and could accept a sign; the
    // strict per-digit parser must not, or "#1_" smuggles a shorter value.
    try expectRejects("\"#1_3_5_\""); // underscores (long)
    try expectRejects("\"#1_3\""); // underscore (short)
    try expectRejects("\"#+f0000\""); // leading '+'
    try expectRejects("\"#-f0000\""); // leading '-'
}

test "hex rejects an embedded control byte in any position" {
    try expectRejects("\"#\\u0000fffff\""); // NUL in body (len 7)
    try expectRejects("\"#ff\\u0007ff\""); // BEL mid-body
    try expectRejects("\"#ff\\u001bff\""); // ESC mid-body
    try expectRejects("\"#ff\\u000aff\""); // newline mid-body
    try expectRejects("\"#f\\u0009f\""); // tab in short form
}

test "JSON whitespace inside an rgb array does not matter" {
    try expectParses("[ 189 , 147 , 249 ]", "\x1b[38;2;189;147;249m");
    try expectParses("[\n  0,\n  128,\n  255\n]", "\x1b[38;2;0;128;255m");
}

test "rgb array rejects rgba and every non-3-integer shape" {
    try expectRejects("[255]"); // arity 1
    try expectRejects("[255,0,0,128]"); // rgba (arity 4) — explicitly unsupported
    try expectRejects("[true,0,0]"); // bool element
    try expectRejects("[null,0,0]"); // null element
    try expectRejects("[[1],2,3]"); // nested array element
    try expectRejects("[{},2,3]"); // object element
    try expectRejects("[\"189\",147,249]"); // stringified number
    try expectRejects("[256,256,256]"); // all out of range
    try expectRejects("[-1,-1,-1]"); // all negative
}

test "an over-long hex string is rejected on length alone (no scan, no DoS)" {
    // 4096 'f's after '#': neither arity, so it fails before any digit is read.
    try expectRejects("\"#" ++ ("f" ** 4096) ++ "\"");
}

test "rgb array rejects an out-of-i64-range element (number_string)" {
    // A value too large for i64 arrives as number_string, never .integer.
    try expectRejects("[99999999999999999999,0,0]");
}

test "256-colour index spans the full range at its boundaries" {
    try expectParses("16", "\x1b[38;5;16m"); // start of the colour cube
    try expectParses("231", "\x1b[38;5;231m"); // end of the colour cube
    try expectParses("232", "\x1b[38;5;232m"); // start of the greyscale ramp
    try expectRejects("-128"); // well below range
    try expectRejects("1000"); // well above range
}

test "CSS-style function and named-colour forms are rejected — only #hex and [r,g,b]" {
    try expectRejects("\"rgb(255,0,0)\""); // function form, unsupported
    try expectRejects("\"rgba(255,0,0,1)\""); // alpha channel, unsupported
    try expectRejects("\"hsl(0,100%,50%)\""); // other colour space
    try expectRejects("\"red\""); // named colour
    try expectRejects("\"#ff0000ff\""); // 8-digit (RGBA hex), unsupported
    try expectRejects("\"\\u001b[31m\""); // a raw SGR string is never a colour
}

test "caps are compile-time constants with the documented bounds" {
    try testing.expectEqual(@as(usize, 32), max_themes);
    try testing.expectEqual(@as(usize, 32), max_name);
    try testing.expectEqual(@as(usize, 64 * 1024), max_file_bytes);
    // Caps are `comptime`-usable (array dimensions), proving they are constants.
    comptime {
        _ = [max_themes]u8;
        _ = [max_name]u8;
    }
}

test "CustomTheme carries a bounded name and the six role escapes" {
    var t: CustomTheme = .{
        .name = undefined,
        .name_len = 0,
        .polarity = .dark,
        .palette = .{
            .accent = "\x1b[38;2;1;2;3m",
            .secondary = "\x1b[38;2;4;5;6m",
            .success = "\x1b[38;2;7;8;9m",
            .warning = "\x1b[38;2;10;11;12m",
            .danger = "\x1b[38;2;13;14;15m",
            .muted = "\x1b[38;2;16;17;18m",
        },
    };
    const written = "mytheme";
    @memcpy(t.name[0..written.len], written);
    t.name_len = written.len;
    try testing.expectEqualStrings("mytheme", t.nameSlice());
    try testing.expectEqualStrings("\x1b[38;2;1;2;3m", t.palette.get(.accent));
    try testing.expectEqualStrings("\x1b[38;2;16;17;18m", t.palette.get(.muted));
}

test "ThemeRegistry holds a fixed-capacity table with a default index" {
    var reg: ThemeRegistry = .{ .themes = undefined, .count = 0, .default_index = 0 };
    try testing.expectEqual(@as(usize, max_themes), reg.themes.len);
    reg.count = 1;
    reg.default_index = 0;
    try testing.expectEqual(@as(usize, 1), reg.count);
}
