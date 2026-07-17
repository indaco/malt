//! malt — parse `mt list --json --size --linked` into TUI-local structs.
//!
//! Leaf module: imports only `std`. The `installed` array is the contract; the
//! legacy `formulae`/`casks` arrays, `schema_version`, `time_ms`, and any future
//! field are ignored, so a schema addition never breaks parsing. The structs are
//! TUI-local — never the core list structs — so the `--json` shape is the only
//! coupling.

const std = @import("std");

pub const Error = error{ BadJson, OutOfMemory };

pub const Kind = enum { formula, cask };

/// One installed package row — the subset the Installed tab paints and filters.
/// `size_bytes`/`linked` are optional: absent unless `--size`/`--linked` were
/// passed, so a default `mt list --json` still parses.
pub const Pkg = struct {
    name: []const u8,
    version: []const u8,
    kind: Kind,
    pinned: bool,
    size_bytes: ?u64,
    linked: ?bool,
};

/// Owns the parsed rows; `items` borrow from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Doc),
    items: []const Pkg,

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

// The JSON shape we read. `@"type"` matches the wire key; everything outside
// `installed` is dropped via `ignore_unknown_fields`.
const Row = struct {
    name: []const u8,
    version: []const u8,
    type: Kind,
    pinned: bool,
    size_bytes: ?u64 = null,
    linked: ?bool = null,
};

const Doc = struct {
    installed: []Row,
};

/// Parse the captured `mt list --json` document. Malformed or non-conforming
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

    // Restructure into the public `Pkg` (wire key `type` → `kind`); strings stay
    // borrowed from the doc arena, so the whole result frees in one `deinit`.
    const arena = doc.arena.allocator();
    const items = arena.alloc(Pkg, doc.value.installed.len) catch return error.OutOfMemory;
    for (doc.value.installed, items) |row, *out| out.* = .{
        .name = row.name,
        .version = row.version,
        .kind = row.type,
        .pinned = row.pinned,
        .size_bytes = row.size_bytes,
        .linked = row.linked,
    };
    return .{ .doc = doc, .items = items };
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parse reads the installed array with all columns" {
    const bytes =
        \\{"schema_version":1,"installed":[
        \\{"name":"jq","version":"1.8.1","type":"formula","pinned":false,"size_bytes":1212921,"linked":true},
        \\{"name":"flux","version":"1.0","type":"cask","pinned":true,"size_bytes":42,"linked":false}
        \\],"time_ms":3}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqualStrings("jq", p.items[0].name);
    try testing.expectEqualStrings("1.8.1", p.items[0].version);
    try testing.expectEqual(Kind.formula, p.items[0].kind);
    try testing.expectEqual(false, p.items[0].pinned);
    try testing.expectEqual(@as(?u64, 1212921), p.items[0].size_bytes);
    try testing.expectEqual(@as(?bool, true), p.items[0].linked);
    try testing.expectEqual(Kind.cask, p.items[1].kind);
    try testing.expectEqual(true, p.items[1].pinned);
}

test "parse ignores unknown fields and the legacy arrays" {
    const bytes =
        \\{"schema_version":1,"installed":[{"name":"a","version":"1","type":"formula","pinned":false,"size_bytes":1,"linked":true}],
        \\"formulae":[{"name":"a","version":"1","pinned":false}],"casks":[],"future_key":42,"time_ms":1}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("a", p.items[0].name);
}

test "parse tolerates absent size_bytes/linked (no --size/--linked)" {
    const bytes =
        \\{"installed":[{"name":"a","version":"1","type":"formula","pinned":false}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(?u64, null), p.items[0].size_bytes);
    try testing.expectEqual(@as(?bool, null), p.items[0].linked);
}

test "parse yields zero items for an empty installed array" {
    var p = try parse(testing.allocator, "{\"installed\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse rejects malformed and empty input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
    try testing.expectError(error.BadJson, parse(testing.allocator, "{}")); // no installed key
}

test "parse propagates a parse-time OOM instead of relabeling it BadJson" {
    // A real allocator exhaustion during the parse is fatal, not a malformed
    // contract; the fatal-OOM guard must restore the terminal, not banner BadJson.
    const bytes =
        \\{"installed":[{"name":"a","version":"1","type":"formula","pinned":false}]}
    ;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(fa.allocator(), bytes));
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the tab
    // keeps borrowing the rows, so the parse must copy, not reference the input.
    const src =
        \\{"installed":[{"name":"jq","version":"1.8.1","type":"formula","pinned":false}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would now read garbage
    try testing.expectEqualStrings("jq", p.items[0].name);
    try testing.expectEqualStrings("1.8.1", p.items[0].version);
}
