//! malt — parse `mt services list --json` into TUI-local structs.
//!
//! Leaf module: imports only `std`. The versioned `services` array is the
//! contract; `schema_version`, `time_ms`, and any future field are ignored, so a
//! schema addition never breaks parsing. `ServiceRow` is TUI-local — never the
//! core `JsonRow` — so the `--json` shape is the only coupling. `state` is kept a
//! free-form string: the renderer buckets it, so an unknown/future runtime state
//! parses without an enum to break against.

const std = @import("std");
const testing = std.testing;

pub const Error = error{ BadJson, OutOfMemory };

/// One service row — the subset the Services tab paints and acts on. `state` is
/// the runtime state verbatim (`running`/`stopped`/`not-loaded`/…); `auto_start`
/// drives the auto/manual hint; `keg_name` is the owning keg.
pub const ServiceRow = struct {
    name: []const u8,
    state: []const u8,
    auto_start: bool,
    keg_name: []const u8 = "",
    /// Schedule label ("interval 300s", "cron 30 4 * * 6"); "" / absent for
    /// run-at-load. Defaulted so a row from an older malt still parses.
    schedule: []const u8 = "",
};

/// Owns the parsed rows; `items` borrow from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Doc),
    items: []const ServiceRow,

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

// The wire keys match `ServiceRow`'s field names, so we parse straight into it;
// `keg_name` defaults so a row that omits it still parses. Everything outside
// `services` is dropped via `ignore_unknown_fields`.
const Doc = struct {
    services: []ServiceRow,
};

/// Parse the captured `mt services list --json` document. Malformed or
/// non-conforming input is `BadJson`; the caller restores the terminal and
/// surfaces it.
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
    return .{ .doc = doc, .items = doc.value.services };
}

// ─── tests ───────────────────────────────────────────────────────────

test "parse reads the services array with all columns" {
    const bytes =
        \\{"schema_version":1,"services":[
        \\{"name":"redis","state":"running","auto_start":true,"keg_name":"redis"},
        \\{"name":"postgres","state":"not-loaded","auto_start":false,"keg_name":"postgresql@16"}
        \\],"time_ms":3}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    try testing.expectEqualStrings("redis", p.items[0].name);
    try testing.expectEqualStrings("running", p.items[0].state);
    try testing.expectEqual(true, p.items[0].auto_start);
    try testing.expectEqualStrings("redis", p.items[0].keg_name);
    try testing.expectEqualStrings("postgres", p.items[1].name);
    try testing.expectEqualStrings("not-loaded", p.items[1].state);
    try testing.expectEqual(false, p.items[1].auto_start);
    try testing.expectEqualStrings("postgresql@16", p.items[1].keg_name);
}

test "parse keeps an unusual state string verbatim (no enum to break against)" {
    const bytes =
        \\{"services":[{"name":"weird","state":"degraded","auto_start":false,"keg_name":"weird"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("degraded", p.items[0].state);
}

test "parse ignores unknown fields and schema_version" {
    const bytes =
        \\{"schema_version":1,"services":[{"name":"a","state":"running","auto_start":true,"keg_name":"a"}],
        \\"future_key":42,"time_ms":1}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("a", p.items[0].name);
}

test "parse reads the schedule label when present" {
    const bytes =
        \\{"services":[{"name":"backup","state":"loaded","auto_start":false,"keg_name":"backup","schedule":"interval 300s"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("interval 300s", p.items[0].schedule);
}

test "parse tolerates an absent schedule (defaults to empty — backward compatible)" {
    const bytes =
        \\{"services":[{"name":"redis","state":"running","auto_start":true,"keg_name":"redis"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("", p.items[0].schedule);
}

test "parse tolerates an absent keg_name (defaults to empty)" {
    const bytes =
        \\{"services":[{"name":"a","state":"running","auto_start":true}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("", p.items[0].keg_name);
}

test "parse yields zero items for an empty services array" {
    var p = try parse(testing.allocator, "{\"schema_version\":1,\"services\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse rejects malformed and empty input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
    try testing.expectError(error.BadJson, parse(testing.allocator, "{}")); // no services key
}

test "parse propagates a parse-time OOM instead of relabeling it BadJson" {
    // A real allocator exhaustion during the parse is fatal, not a malformed
    // contract; the fatal-OOM guard must restore the terminal, not banner BadJson.
    const bytes =
        \\{"services":[{"name":"redis","state":"running","auto_start":true,"keg_name":"redis"}]}
    ;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(fa.allocator(), bytes));
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the tab
    // keeps borrowing the rows, so the parse must copy, not reference the input.
    const src =
        \\{"services":[{"name":"redis","state":"running","auto_start":true,"keg_name":"redis"}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would now read garbage
    try testing.expectEqualStrings("redis", p.items[0].name);
    try testing.expectEqualStrings("running", p.items[0].state);
}
