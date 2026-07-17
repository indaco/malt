//! malt — parse `mt outdated --json` into TUI-local structs.
//!
//! Leaf module: imports only `std`. The unified `outdated` array (formulae and
//! casks mixed, each tagged `type`) is the contract; `schema_version`, `time_ms`,
//! and any future field are ignored, so a schema addition never breaks parsing.
//! The structs are TUI-local — never the core outdated structs — so the `--json`
//! shape is the only coupling.

const std = @import("std");

pub const Error = error{ BadJson, OutOfMemory };

pub const Kind = enum { formula, cask };

/// One outdated package row — the subset the Outdated tab paints and upgrades.
/// `installed`→`latest` are the current and target versions; `pinned` rows are
/// shown but held back from a bulk upgrade; `tap` is empty when unattributed.
pub const OutdatedRow = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
    kind: Kind,
    pinned: bool,
    tap: []const u8,
};

/// Owns the parsed rows; `items` borrow from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Doc),
    items: []const OutdatedRow,

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

// The JSON shape we read. `type` matches the wire key; everything outside
// `outdated` is dropped via `ignore_unknown_fields`. `tap` defaults so a row
// that omits it still parses.
const Row = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
    type: Kind,
    pinned: bool,
    tap: []const u8 = "",
};

const Doc = struct {
    outdated: []Row,
};

/// Parse the captured `mt outdated --json` document. Malformed or non-conforming
/// input is `BadJson`; the caller restores the terminal and surfaces it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    const doc = std.json.parseFromSlice(Doc, allocator, bytes, .{
        .ignore_unknown_fields = true,
        // Copy strings into the arena: the shell frees the source buffer right
        // after parsing while the tab keeps borrowing the rows.
        .allocate = .alloc_always,
    }) catch |e| switch (e) {
        error.OutOfMemory => |o| return o,
        else => return error.BadJson,
    };
    errdefer doc.deinit();

    // Restructure into the public `OutdatedRow` (wire key `type` → `kind`);
    // strings stay borrowed from the doc arena, so the whole result frees in one
    // `deinit`.
    const arena = doc.arena.allocator();
    const items = arena.alloc(OutdatedRow, doc.value.outdated.len) catch return error.OutOfMemory;
    for (doc.value.outdated, items) |row, *out| out.* = .{
        .name = row.name,
        .installed = row.installed,
        .latest = row.latest,
        .kind = row.type,
        .pinned = row.pinned,
        .tap = row.tap,
    };
    return .{ .doc = doc, .items = items };
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parse reads the outdated array with all columns" {
    const bytes =
        \\{"schema_version":1,"outdated":[
        \\{"name":"wget","installed":"1.24.5","latest":"1.25.0","type":"formula","pinned":false,"tap":""},
        \\{"name":"firefox","installed":"120.0","latest":"121.0","type":"cask","pinned":true,"tap":"user/repo"}
        \\],"time_ms":7}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqualStrings("wget", p.items[0].name);
    try testing.expectEqualStrings("1.24.5", p.items[0].installed);
    try testing.expectEqualStrings("1.25.0", p.items[0].latest);
    try testing.expectEqual(Kind.formula, p.items[0].kind);
    try testing.expectEqual(false, p.items[0].pinned);
    try testing.expectEqualStrings("", p.items[0].tap);
    // The cask row carries its type, pinned flag, and tap through.
    try testing.expectEqual(Kind.cask, p.items[1].kind);
    try testing.expectEqual(true, p.items[1].pinned);
    try testing.expectEqualStrings("user/repo", p.items[1].tap);
}

test "parse ignores unknown fields and schema_version" {
    const bytes =
        \\{"schema_version":1,"outdated":[{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false,"tap":""}],
        \\"future_key":42,"time_ms":1}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("a", p.items[0].name);
}

test "parse tolerates an absent tap (defaults to empty)" {
    const bytes =
        \\{"outdated":[{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("", p.items[0].tap);
}

test "parse yields zero items for an empty outdated array" {
    var p = try parse(testing.allocator, "{\"schema_version\":1,\"outdated\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse rejects malformed and empty input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
    try testing.expectError(error.BadJson, parse(testing.allocator, "{}")); // no outdated key
}

test "parse propagates a parse-time OOM instead of relabeling it BadJson" {
    // A real allocator exhaustion during the parse is fatal, not a malformed
    // contract; the fatal-OOM guard must restore the terminal, not banner BadJson.
    const bytes =
        \\{"outdated":[{"name":"a","installed":"1","latest":"2","type":"formula","pinned":false,"tap":""}]}
    ;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(fa.allocator(), bytes));
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the tab
    // keeps borrowing the rows, so the parse must copy, not reference the input.
    const src =
        \\{"outdated":[{"name":"wget","installed":"1.24.5","latest":"1.25.0","type":"formula","pinned":false,"tap":"x"}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would now read garbage
    try testing.expectEqualStrings("wget", p.items[0].name);
    try testing.expectEqualStrings("1.25.0", p.items[0].latest);
    try testing.expectEqualStrings("x", p.items[0].tap);
}
