//! malt — parse `mt search <query> --json` into TUI-local structs.
//!
//! Leaf module: imports only `std`. The unified `results` array (formulae and
//! casks mixed, each tagged `type`, each carrying its `installed` state) is the
//! contract; `schema_version`, the echoed `query`, and any future field are
//! ignored, so a schema addition never breaks parsing. `Match` is TUI-local —
//! never a core search struct — so the `--json` shape is the only coupling.

const std = @import("std");

pub const Error = error{ BadJson, OutOfMemory };

pub const Kind = enum { formula, cask };

/// One search hit — the subset the Search tab paints and installs. `installed`
/// is the install-aware marker derived by the backend; re-running the search
/// after an install flips it (no separate `mt list` call needed).
pub const Match = struct {
    name: []const u8,
    kind: Kind,
    installed: bool,
};

/// Owns the parsed matches; `items` borrow from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Doc),
    items: []const Match,

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

// The JSON shape we read. `type` matches the wire key; everything outside
// `results` (schema_version, the echoed query) is dropped via
// `ignore_unknown_fields`.
const Row = struct {
    name: []const u8,
    type: Kind,
    installed: bool,
};

const Doc = struct {
    results: []Row,
};

/// Parse the captured `mt search <query> --json` document. Malformed or
/// non-conforming input is `BadJson`; the caller restores the terminal and
/// surfaces it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    const doc = std.json.parseFromSlice(Doc, allocator, bytes, .{
        .ignore_unknown_fields = true,
        // Copy strings into the arena: the shell frees the source buffer right
        // after parsing while the tab keeps borrowing the matches.
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    errdefer doc.deinit();

    // Restructure into the public `Match` (wire key `type` → `kind`); strings
    // stay borrowed from the doc arena, so the whole result frees in one
    // `deinit`.
    const arena = doc.arena.allocator();
    const items = arena.alloc(Match, doc.value.results.len) catch return error.OutOfMemory;
    for (doc.value.results, items) |row, *out| out.* = .{
        .name = row.name,
        .kind = row.type,
        .installed = row.installed,
    };
    return .{ .doc = doc, .items = items };
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parse reads the results array with name, kind, and installed" {
    const bytes =
        \\{"schema_version":1,"query":"fire","results":[
        \\{"name":"firefox","type":"cask","installed":true},
        \\{"name":"wget","type":"formula","installed":false}
        \\]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqualStrings("firefox", p.items[0].name);
    try testing.expectEqual(Kind.cask, p.items[0].kind);
    try testing.expectEqual(true, p.items[0].installed);
    try testing.expectEqualStrings("wget", p.items[1].name);
    try testing.expectEqual(Kind.formula, p.items[1].kind);
    try testing.expectEqual(false, p.items[1].installed);
}

test "parse ignores unknown fields, schema_version, and the echoed query" {
    const bytes =
        \\{"schema_version":1,"query":"jq","results":[{"name":"jq","type":"formula","installed":true}],
        \\"future_key":42,"time_ms":1}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("jq", p.items[0].name);
}

test "parse yields zero items for an empty results array (a no-matches search)" {
    var p = try parse(testing.allocator, "{\"schema_version\":1,\"query\":\"zzz\",\"results\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse rejects malformed and empty input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
    try testing.expectError(error.BadJson, parse(testing.allocator, "{}")); // no results key
}

test "parse rejects an unknown kind so the closed enum never silently widens" {
    const bytes =
        \\{"results":[{"name":"x","type":"tap","installed":false}]}
    ;
    try testing.expectError(error.BadJson, parse(testing.allocator, bytes));
}

test "parse rejects a row missing a required field as BadJson" {
    // Every field is mandatory (no struct defaults), so a row dropping one is
    // non-conforming, not a silently-zeroed Match.
    try testing.expectError(error.BadJson, parse(testing.allocator,
        \\{"results":[{"name":"jq","type":"formula"}]}
    )); // no `installed`
    try testing.expectError(error.BadJson, parse(testing.allocator,
        \\{"results":[{"type":"formula","installed":true}]}
    )); // no `name`
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the tab
    // keeps borrowing the matches, so the parse must copy, not reference the input.
    const src =
        \\{"results":[{"name":"firefox","type":"cask","installed":true}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would now read garbage
    try testing.expectEqualStrings("firefox", p.items[0].name);
    try testing.expectEqual(Kind.cask, p.items[0].kind);
}
