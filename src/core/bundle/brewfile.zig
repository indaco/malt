//! malt — Brewfile parser
//!
//! Brewfile is Homebrew's Ruby-syntax bundle format. Malt supports a
//! deliberately narrow subset: top-level directive calls with a single string
//! argument and optional trailing hash options. Conditionals (`if OS.mac?`),
//! blocks, and variable interpolation are rejected with a clear error so users
//! can migrate to `Maltfile.json`.
//!
//! Supported directives: `tap`, `brew`, `cask`, `mas`, `vscode`.
//! Unknown directives produce a warning and are skipped.

const std = @import("std");
const manifest_mod = @import("manifest.zig");

pub const BrewfileError = error{
    UnexpectedToken,
    UnterminatedString,
    ExpectedString,
    ConditionalsUnsupported,
    BlocksUnsupported,
    InterpolationUnsupported,
    OutOfMemory,
    MalformedJson,
    UnsupportedVersion,
    UnknownKind,
};

pub fn describeError(err: BrewfileError) []const u8 {
    return switch (err) {
        BrewfileError.UnexpectedToken => "unexpected token in Brewfile",
        BrewfileError.UnterminatedString => "unterminated string in Brewfile",
        BrewfileError.ExpectedString => "directive expects a quoted string argument",
        BrewfileError.ConditionalsUnsupported => "Brewfile conditionals are unsupported; convert to Maltfile.json",
        BrewfileError.BlocksUnsupported => "Brewfile `do ... end` blocks are unsupported",
        BrewfileError.InterpolationUnsupported => "Brewfile string interpolation (`#{...}`) is unsupported; convert to Maltfile.json",
        BrewfileError.OutOfMemory => "out of memory parsing Brewfile",
        BrewfileError.MalformedJson => "malformed bundle JSON",
        BrewfileError.UnsupportedVersion => "unsupported bundle schema version",
        BrewfileError.UnknownKind => "unknown bundle member kind",
    };
}

/// Caller-owned out-bag for non-fatal parser warnings (currently: unknown
/// directives we skip) plus the 1-based line of a fatal parse error. Core
/// returns outcomes; UI renders at the boundary — `cli/bundle.zig` drains
/// `warnings` into `output.warn` and reports `error_line` on failure.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    warnings: std.ArrayList([]const u8),
    error_line: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator, .warnings = .empty };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.warnings.items) |w| self.allocator.free(w);
        self.warnings.deinit(self.allocator);
        self.* = undefined;
    }
};

// Ruby control-flow keywords the narrow subset can't model. They are rejected
// up front so the user gets a clear error instead of a misleading token error.
const conditional_keywords = [_][]const u8{ "if", "unless", "elsif", "else", "case", "when" };
const block_keywords = [_][]const u8{ "do", "while", "until", "for", "begin", "end" };

/// Record the failing line for the UI boundary and propagate the error.
fn parseFail(diag: ?*Diagnostics, line_no: usize, err: BrewfileError) BrewfileError {
    if (diag) |d| d.error_line = line_no;
    return err;
}

pub fn parse(
    parent: std.mem.Allocator,
    brewfile_text: []const u8,
    diag: ?*Diagnostics,
) BrewfileError!manifest_mod.Manifest {
    var m = manifest_mod.Manifest.init(parent);
    errdefer m.deinit();
    const a = m.allocator();

    var taps: std.ArrayList([]const u8) = .empty;
    var formulas: std.ArrayList(manifest_mod.FormulaEntry) = .empty;
    var casks: std.ArrayList(manifest_mod.CaskEntry) = .empty;
    var services: std.ArrayList(manifest_mod.ServiceEntry) = .empty;

    var it = std.mem.splitScalar(u8, brewfile_text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        const trimmed = trim(raw);
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;

        // Strip the comment once and reject unsupported Ruby on the code only;
        // parseLine reuses the stripped slice (matchers handle string spans).
        const code = stripTrailingComment(trimmed);
        if (firstMatch(code, &conditional_keywords)) return parseFail(diag, line_no, BrewfileError.ConditionalsUnsupported);
        if (firstMatch(code, &block_keywords)) return parseFail(diag, line_no, BrewfileError.BlocksUnsupported);
        if (hasInterpolation(code)) return parseFail(diag, line_no, BrewfileError.InterpolationUnsupported);

        parseLine(a, code, &taps, &formulas, &casks, &services, diag) catch |e|
            return parseFail(diag, line_no, e);
    }

    m.taps = taps.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.formulas = formulas.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.casks = casks.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.services = services.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.version = manifest_mod.schema_version;
    return m;
}

fn parseLine(
    a: std.mem.Allocator,
    code: []const u8,
    taps: *std.ArrayList([]const u8),
    formulas: *std.ArrayList(manifest_mod.FormulaEntry),
    casks: *std.ArrayList(manifest_mod.CaskEntry),
    services: *std.ArrayList(manifest_mod.ServiceEntry),
    diag: ?*Diagnostics,
) BrewfileError!void {
    var cursor: usize = 0;
    const directive = nextIdent(code, &cursor) orelse return BrewfileError.UnexpectedToken;
    skipSpaces(code, &cursor);

    const first = try expectString(a, code, &cursor);
    skipSpaces(code, &cursor);

    // Optional trailing hash options: ", key: value, key: value"
    var opt_version: ?[]const u8 = null;
    var opt_restart: bool = false;

    while (cursor < code.len and code[cursor] == ',') {
        cursor += 1;
        skipSpaces(code, &cursor);
        const key = nextIdent(code, &cursor) orelse return BrewfileError.UnexpectedToken;
        skipSpaces(code, &cursor);
        if (cursor >= code.len or code[cursor] != ':') return BrewfileError.UnexpectedToken;
        cursor += 1;
        skipSpaces(code, &cursor);

        if (std.mem.eql(u8, key, "version")) {
            opt_version = try expectString(a, code, &cursor);
        } else if (std.mem.eql(u8, key, "restart_service")) {
            opt_restart = try expectBool(code, &cursor);
        } else if (std.mem.eql(u8, key, "start_service") or std.mem.eql(u8, key, "link")) {
            // Recognised but not yet meaningful; consume the value.
            _ = consumeValue(code, &cursor);
        } else if (std.mem.eql(u8, key, "id")) {
            // mas id: 12345 — consume integer
            _ = consumeValue(code, &cursor);
        } else {
            // Unknown option — consume value and continue.
            _ = consumeValue(code, &cursor);
        }
        skipSpaces(code, &cursor);
    }

    if (std.mem.eql(u8, directive, "tap")) {
        taps.append(a, first) catch return BrewfileError.OutOfMemory;
    } else if (std.mem.eql(u8, directive, "brew")) {
        formulas.append(a, .{
            .name = first,
            .version = opt_version,
            .restart_service = opt_restart,
        }) catch return BrewfileError.OutOfMemory;
        if (opt_restart) {
            services.append(a, .{ .name = first, .auto_start = true }) catch
                return BrewfileError.OutOfMemory;
        }
    } else if (std.mem.eql(u8, directive, "cask")) {
        casks.append(a, .{ .name = first }) catch return BrewfileError.OutOfMemory;
    } else if (std.mem.eql(u8, directive, "mas") or std.mem.eql(u8, directive, "vscode")) {
        // Recognised but not yet installable by malt — record as formulas w/ a
        // synthetic prefix so users see them round-tripped.
        formulas.append(a, .{ .name = first }) catch return BrewfileError.OutOfMemory;
    } else if (diag) |d| {
        const msg = std.fmt.allocPrint(
            d.allocator,
            "skipping unknown Brewfile directive: {s}",
            .{directive},
        ) catch return BrewfileError.OutOfMemory;
        errdefer d.allocator.free(msg);
        d.warnings.append(d.allocator, msg) catch return BrewfileError.OutOfMemory;
    }
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

fn stripTrailingComment(s: []const u8) []const u8 {
    // Honour `#` only when it is outside a string literal.
    var in_str = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_str) {
            if (c == '\\' and i + 1 < s.len) {
                i += 1;
                continue;
            }
            if (c == quote) in_str = false;
        } else {
            if (c == '"' or c == '\'') {
                in_str = true;
                quote = c;
            } else if (c == '#') {
                return trim(s[0..i]);
            }
        }
    }
    return s;
}

/// True when `word` occurs in `code` as a whole identifier token outside any
/// string literal. Catches Ruby `if`/`do` openers in every spacing form
/// (`if cond`, `if(cond)`, `do`, `do|f|`) while ignoring keyword text inside
/// quoted args ("my if tool") and longer words ("download"/"redo").
fn hasKeyword(code: []const u8, word: []const u8) bool {
    var in_str = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (in_str) {
            if (c == '\\' and i + 1 < code.len) {
                i += 1; // skip the escaped byte
            } else if (c == quote) {
                in_str = false;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = true;
            quote = c;
        } else if (isIdentByte(c)) {
            const start = i;
            while (i < code.len and isIdentByte(code[i])) i += 1;
            if (std.mem.eql(u8, code[start..i], word)) return true;
            i -= 1; // re-examine the boundary byte next iteration
        }
    }
    return false;
}

fn isIdentByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn firstMatch(code: []const u8, words: []const []const u8) bool {
    for (words) |w| if (hasKeyword(code, w)) return true;
    return false;
}

/// True when a double-quoted string in `code` contains a `#{...}` interpolation.
/// Single-quoted strings are literal in Ruby, so only `"` spans count.
fn hasInterpolation(code: []const u8) bool {
    var in_str = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < code.len) : (i += 1) {
        const c = code[i];
        if (in_str) {
            if (c == '\\' and i + 1 < code.len) {
                i += 1; // skip the escaped byte
            } else if (c == quote) {
                in_str = false;
            } else if (quote == '"' and c == '#' and i + 1 < code.len and code[i + 1] == '{') {
                return true;
            }
        } else if (c == '"' or c == '\'') {
            in_str = true;
            quote = c;
        }
    }
    return false;
}

fn skipSpaces(s: []const u8, cursor: *usize) void {
    while (cursor.* < s.len and (s[cursor.*] == ' ' or s[cursor.*] == '\t')) cursor.* += 1;
}

fn nextIdent(s: []const u8, cursor: *usize) ?[]const u8 {
    skipSpaces(s, cursor);
    const start = cursor.*;
    while (cursor.* < s.len) {
        const c = s[cursor.*];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_')
        {
            cursor.* += 1;
        } else break;
    }
    if (cursor.* == start) return null;
    return s[start..cursor.*];
}

fn expectString(a: std.mem.Allocator, s: []const u8, cursor: *usize) BrewfileError![]const u8 {
    skipSpaces(s, cursor);
    if (cursor.* >= s.len) return BrewfileError.ExpectedString;
    const quote = s[cursor.*];
    if (quote != '"' and quote != '\'') return BrewfileError.ExpectedString;
    cursor.* += 1;
    const start = cursor.*;
    var saw_escape = false;
    while (cursor.* < s.len) {
        const c = s[cursor.*];
        if (c == '\\' and cursor.* + 1 < s.len) {
            saw_escape = true;
            cursor.* += 2;
            continue;
        }
        if (c == quote) {
            const raw = s[start..cursor.*];
            cursor.* += 1;
            // Faithful round-trip: undo the emitter's `\"`/`\\` escaping. Common
            // case (no backslash) keeps the original raw-span dup, no scan.
            if (!saw_escape) return a.dupe(u8, raw) catch return BrewfileError.OutOfMemory;
            return decodeEscapes(a, raw, quote) catch return BrewfileError.OutOfMemory;
        }
        cursor.* += 1;
    }
    return BrewfileError.UnterminatedString;
}

/// Decode the escapes the emitter writes, per Ruby quote semantics. Unknown
/// escapes stay verbatim, so no bytes are lost and malt stays a narrow subset
/// rather than a full Ruby string evaluator. Escapes never grow the string, so
/// the raw length is a safe upper bound.
fn decodeEscapes(a: std.mem.Allocator, raw: []const u8, quote: u8) BrewfileError![]const u8 {
    const out = a.alloc(u8, raw.len) catch return BrewfileError.OutOfMemory;
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            if (decodeEscape(quote, raw[i + 1])) |byte| {
                out[w] = byte;
                w += 1;
                i += 2;
                continue;
            }
        }
        out[w] = raw[i];
        w += 1;
        i += 1;
    }
    return out[0..w];
}

/// The byte `\c` decodes to under `quote`'s Ruby semantics, or null when `\c`
/// is not a recognized escape (kept verbatim). Single quotes process only `\\`
/// and `\'`; double quotes also decode `\"` and the `\n`/`\r`/`\t` whitespace
/// controls the emitter escapes.
fn decodeEscape(quote: u8, c: u8) ?u8 {
    if (quote == '\'') return switch (c) {
        '\\' => '\\',
        '\'' => '\'',
        else => null,
    };
    return switch (c) {
        '\\' => '\\',
        '\'' => '\'',
        '"' => '"',
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => null,
    };
}

fn expectBool(s: []const u8, cursor: *usize) BrewfileError!bool {
    skipSpaces(s, cursor);
    if (std.mem.startsWith(u8, s[cursor.*..], "true")) {
        cursor.* += 4;
        return true;
    }
    if (std.mem.startsWith(u8, s[cursor.*..], "false")) {
        cursor.* += 5;
        return false;
    }
    // Ruby symbols like :changed / :always are commonly used with
    // `restart_service:` — treat any symbol as truthy (consume the token).
    if (cursor.* < s.len and s[cursor.*] == ':') {
        cursor.* += 1;
        _ = nextIdent(s, cursor) orelse return BrewfileError.UnexpectedToken;
        return true;
    }
    return BrewfileError.UnexpectedToken;
}

fn consumeValue(s: []const u8, cursor: *usize) []const u8 {
    skipSpaces(s, cursor);
    const start = cursor.*;
    if (cursor.* < s.len and (s[cursor.*] == '"' or s[cursor.*] == '\'')) {
        const q = s[cursor.*];
        cursor.* += 1;
        while (cursor.* < s.len and s[cursor.*] != q) : (cursor.* += 1) {}
        if (cursor.* < s.len) cursor.* += 1;
        return s[start..cursor.*];
    }
    while (cursor.* < s.len and s[cursor.*] != ',') cursor.* += 1;
    return s[start..cursor.*];
}

const testing = std.testing;

test "comment containing if does not abort the import" {
    // The conditional guard must run on code, not on the trailing comment.
    var m = try parse(testing.allocator, "brew \"wget\" # build if needed\n", null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("wget", m.formulas[0].name);
}

test "comment with do-prefixed word does not abort the import" {
    // `do` needs a word boundary so "download"/"do not" stay valid, and a
    // formula name that embeds "do" (pandoc) must not trip the guard.
    const txt =
        \\brew "git" # download manager
        \\brew "pandoc"
        \\cask "firefox" # do not remove
    ;
    var m = try parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 2), m.formulas.len);
    try testing.expectEqualStrings("git", m.formulas[0].name);
    try testing.expectEqualStrings("pandoc", m.formulas[1].name);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
    try testing.expectEqualStrings("firefox", m.casks[0].name);
}

test "real conditional still rejected after comment stripping" {
    try testing.expectError(
        BrewfileError.ConditionalsUnsupported,
        parse(testing.allocator, "brew \"wget\" if OS.mac?\n", null),
    );
}

test "real do block opener still rejected across boundary forms" {
    // Every `do` opener form must trip BlocksUnsupported: trailing EOL,
    // space-pipe, and the pipe-without-space / tab forms the literal " do "
    // check used to miss (silent partial parse).
    const openers = [_][]const u8{
        "brew \"wget\" do\n  link\nend\n",
        "brew \"wget\" do |f|\nend\n",
        "brew \"wget\" do|f|\nend\n",
        "brew \"wget\" do\t|f|\nend\n",
    };
    for (openers) |txt| {
        try testing.expectError(
            BrewfileError.BlocksUnsupported,
            parse(testing.allocator, txt, null),
        );
    }
}

test "conditional without spacing around the keyword is rejected" {
    // `foo if(cond)` is a valid Ruby modifier; the keyword needs no flanking
    // spaces, only token boundaries.
    try testing.expectError(
        BrewfileError.ConditionalsUnsupported,
        parse(testing.allocator, "brew \"wget\" if(OS.mac?)\n", null),
    );
}

test "keyword inside the quoted argument does not trip the guard" {
    // The arg is a string literal, not code — `if`/`do` within it are data.
    const txt =
        \\brew "my if tool"
        \\cask "my do thing"
    ;
    var m = try parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("my if tool", m.formulas[0].name);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
    try testing.expectEqualStrings("my do thing", m.casks[0].name);
}

test "other control-flow keywords are rejected with a clear error" {
    try testing.expectError(
        BrewfileError.ConditionalsUnsupported,
        parse(testing.allocator, "unless OS.linux?\nbrew \"wget\"\nend\n", null),
    );
    try testing.expectError(
        BrewfileError.BlocksUnsupported,
        parse(testing.allocator, "brew \"wget\" while retry?\n", null),
    );
}

test "double-quoted interpolation is rejected, single-quoted is literal" {
    // Ruby interpolates only in double quotes, so `'a#{b}'` is a literal name.
    try testing.expectError(
        BrewfileError.InterpolationUnsupported,
        parse(testing.allocator, "brew \"foo#{ENV['X']}\"\n", null),
    );

    var m = try parse(testing.allocator, "brew 'foo#{bar}'\n", null);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("foo#{bar}", m.formulas[0].name);
}

test "Brewfile round-trip preserves quotes, backslashes and newlines in names" {
    const emit = @import("brewfile_emit.zig");
    // Build a manifest whose fields carry quote/backslash/newline bytes, emit
    // it, then re-parse: a faithful round-trip must return the same bytes, not a
    // value truncated at the first unescaped quote or split across a raw newline.
    var src = manifest_mod.Manifest.init(testing.allocator);
    defer src.deinit();
    const a = src.allocator();

    const taps = try a.alloc([]const u8, 1);
    taps[0] = try a.dupe(u8, "t\"p");
    src.taps = taps;
    const formulas = try a.alloc(manifest_mod.FormulaEntry, 1);
    formulas[0] = .{ .name = try a.dupe(u8, "a\"b\\c\nd"), .version = try a.dupe(u8, "1\"2") };
    src.formulas = formulas;
    const casks = try a.alloc(manifest_mod.CaskEntry, 1);
    casks[0] = .{ .name = try a.dupe(u8, "c\\k") };
    src.casks = casks;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit.emit(src, &aw.writer);

    var back = try parse(testing.allocator, aw.written(), null);
    defer back.deinit();

    try testing.expectEqualStrings("t\"p", back.taps[0]);
    try testing.expectEqualStrings("a\"b\\c\nd", back.formulas[0].name);
    try testing.expectEqualStrings("1\"2", back.formulas[0].version.?);
    try testing.expectEqualStrings("c\\k", back.casks[0].name);
}

test "single quotes decode only Ruby's literal escapes" {
    // Ruby single-quoted strings process only \\ and \'; every other backslash
    // (notably \") stays literal. Double quotes still unescape \".
    var m = try parse(
        testing.allocator,
        "tap 'e\\'f'\nbrew 'a\\\"b'\ncask 'c\\\\d'\n",
        null,
    );
    defer m.deinit();

    try testing.expectEqualStrings("e'f", m.taps[0]); // \' -> '
    try testing.expectEqualStrings("a\\\"b", m.formulas[0].name); // \" stays literal
    try testing.expectEqualStrings("c\\d", m.casks[0].name); // \\ -> \

    // Double-quoted \" still collapses, so the emit->parse round-trip holds.
    var d = try parse(testing.allocator, "brew \"a\\\"b\"\n", null);
    defer d.deinit();
    try testing.expectEqualStrings("a\"b", d.formulas[0].name);
}

test "Brewfile emit output format is byte-stable for a plain manifest" {
    // Golden lock for the escaper refactor: escape-free input must keep its
    // exact single-line layout.
    const emit = @import("brewfile_emit.zig");
    const original =
        \\tap "homebrew/core"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
    ;
    var m = try parse(testing.allocator, original, null);
    defer m.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit.emit(m, &aw.writer);

    const expected =
        \\tap "homebrew/core"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "Brewfile round-trip covers CR, tab, empty and utf-8 values" {
    const emit = @import("brewfile_emit.zig");
    var src = manifest_mod.Manifest.init(testing.allocator);
    defer src.deinit();
    const a = src.allocator();

    const formulas = try a.alloc(manifest_mod.FormulaEntry, 4);
    formulas[0] = .{ .name = try a.dupe(u8, "a\r\tb") }; // CR + tab escape/decode
    formulas[1] = .{ .name = try a.dupe(u8, "") }; // empty value
    formulas[2] = .{ .name = try a.dupe(u8, "cafÉ🍺") }; // raw UTF-8 passes through
    formulas[3] = .{ .name = try a.dupe(u8, "trail\\") }; // trailing backslash -> \\
    src.formulas = formulas;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emit.emit(src, &aw.writer);

    // Emitted text stays single-line-per-entry: one line per formula + trailing \n.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, aw.written(), "\n"));

    var back = try parse(testing.allocator, aw.written(), null);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 4), back.formulas.len);
    try testing.expectEqualStrings("a\r\tb", back.formulas[0].name);
    try testing.expectEqualStrings("", back.formulas[1].name);
    try testing.expectEqualStrings("cafÉ🍺", back.formulas[2].name);
    try testing.expectEqualStrings("trail\\", back.formulas[3].name);
}

test "unknown double-quote escapes are kept verbatim" {
    // malt is a narrow subset, not a full Ruby evaluator: \z is not a known
    // escape, so the backslash is preserved rather than dropped.
    var m = try parse(testing.allocator, "brew \"a\\zb\"\n", null);
    defer m.deinit();
    try testing.expectEqualStrings("a\\zb", m.formulas[0].name);
}

test "Brewfile round-trips every byte value in a name" {
    // Exhaustive proof that leaving rare control bytes unescaped is safe: with
    // the value always interior (`brew "..."`), no byte can break line splitting
    // (only \n does, and it is escaped) or get eaten by trim (VT/FF are interior,
    // never leading/trailing). Every byte 0..255 must survive emit->parse.
    const emit = @import("brewfile_emit.zig");
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        var src = manifest_mod.Manifest.init(testing.allocator);
        defer src.deinit();
        const a = src.allocator();
        const name = try a.alloc(u8, 3);
        name[0] = 'x';
        name[1] = @intCast(b);
        name[2] = 'y';
        const formulas = try a.alloc(manifest_mod.FormulaEntry, 1);
        formulas[0] = .{ .name = name };
        src.formulas = formulas;

        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try emit.emit(src, &aw.writer);

        var back = parse(testing.allocator, aw.written(), null) catch |e| {
            std.debug.print("byte 0x{x:0>2} failed to parse: {s}\n", .{ b, @errorName(e) });
            return e;
        };
        defer back.deinit();
        testing.expectEqualStrings(name, back.formulas[0].name) catch |e| {
            std.debug.print("byte 0x{x:0>2} did not round-trip\n", .{b});
            return e;
        };
    }
}

test "diagnostics records the 1-based line of a parse failure" {
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    try testing.expectError(
        BrewfileError.ConditionalsUnsupported,
        parse(testing.allocator, "brew \"wget\"\n\nbrew \"jq\" if OS.mac?\n", &diag),
    );
    try testing.expectEqual(@as(?usize, 3), diag.error_line);
}
