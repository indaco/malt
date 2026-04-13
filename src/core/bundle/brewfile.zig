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
const output = @import("../../ui/output.zig");

pub const BrewfileError = error{
    UnexpectedToken,
    UnterminatedString,
    ExpectedString,
    ConditionalsUnsupported,
    BlocksUnsupported,
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
        BrewfileError.OutOfMemory => "out of memory parsing Brewfile",
        BrewfileError.MalformedJson => "malformed bundle JSON",
        BrewfileError.UnsupportedVersion => "unsupported bundle schema version",
        BrewfileError.UnknownKind => "unknown bundle member kind",
    };
}

const Line = struct {
    text: []const u8,
    num: usize,
};

pub fn parse(parent: std.mem.Allocator, brewfile_text: []const u8) BrewfileError!manifest_mod.Manifest {
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

        if (std.mem.indexOf(u8, trimmed, " if ") != null or std.mem.endsWith(u8, trimmed, " if")) {
            return BrewfileError.ConditionalsUnsupported;
        }
        if (std.mem.indexOf(u8, trimmed, " do") != null or std.mem.endsWith(u8, trimmed, " do")) {
            return BrewfileError.BlocksUnsupported;
        }

        try parseLine(a, trimmed, line_no, &taps, &formulas, &casks, &services);
    }

    m.taps = taps.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.formulas = formulas.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.casks = casks.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.services = services.toOwnedSlice(a) catch return BrewfileError.OutOfMemory;
    m.version = manifest_mod.SCHEMA_VERSION;
    return m;
}

fn parseLine(
    a: std.mem.Allocator,
    line: []const u8,
    line_no: usize,
    taps: *std.ArrayList([]const u8),
    formulas: *std.ArrayList(manifest_mod.FormulaEntry),
    casks: *std.ArrayList(manifest_mod.CaskEntry),
    services: *std.ArrayList(manifest_mod.ServiceEntry),
) BrewfileError!void {
    _ = line_no;

    const code = stripTrailingComment(line);
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
    } else {
        output.warn("skipping unknown Brewfile directive: {s}", .{directive});
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
    while (cursor.* < s.len) {
        const c = s[cursor.*];
        if (c == '\\' and cursor.* + 1 < s.len) {
            cursor.* += 2;
            continue;
        }
        if (c == quote) {
            const raw = s[start..cursor.*];
            cursor.* += 1;
            return a.dupe(u8, raw) catch return BrewfileError.OutOfMemory;
        }
        cursor.* += 1;
    }
    return BrewfileError.UnterminatedString;
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
