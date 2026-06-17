//! malt — parse `mt doctor --json` `checks[]` into TUI-local structs.
//!
//! Leaf module: imports only `std`. The versioned `checks` array drives the
//! findings list; `cask_history`, `tap_cache`, and `taps` are read for their
//! disk/tap totals (flat `Stats`). `schema_version` and any future field are
//! ignored, and the consumed keys are defaulted, so a schema addition or an
//! older payload never breaks parsing. `Finding` is TUI-local — never the core
//! `render.Finding` — so the `--json` shape is the only coupling. Unlike the
//! Services tab's free-form `state`, `severity` and
//! `fix_class` are **closed** enums: the TUI-004/005 contract pins their
//! vocabulary, so an exhaustive `switch` (no `else`) maps each glyph/fix target
//! and a renamed/new tag is a compile error here, not a silent miss.

const std = @import("std");
const testing = std.testing;

pub const Error = error{ BadJson, OutOfMemory };

/// Finding severity, mirroring the CLI's `CheckStatus` wire tags `ok`/`warn`/
/// `err`. Closed enum: a new severity must bump the schema, so parsing it is a
/// deliberate change, not a tolerated unknown.
pub const Severity = enum { ok, warn, err };

/// Safe-fix class, mirroring the CLI `--fix` vocabulary. `none` is the wire tag
/// for a non-fixable finding. The fixable findings' `f` action delegates to
/// `mt doctor --fix <fix_class>` — the class, not the finding id, is the token
/// `mt doctor --fix` resolves.
pub const FixClass = enum { none, stale_lock, orphaned_store, broken_symlinks };

/// One doctor finding — the subset the Doctor tab paints and acts on. Field
/// names match the wire keys so `std.json` parses straight in; `severity` and
/// `fix_class` are decoded as enums (an unknown tag fails the parse).
pub const Finding = struct {
    id: []const u8,
    severity: Severity,
    title: []const u8,
    detail: []const u8 = "",
    fixable: bool = false,
    fix_class: FixClass = .none,
};

/// Flat, copy-by-value disk/tap totals lifted off the wire. Plain scalars, so
/// they outlive the parsed document's arena without borrowing it.
pub const Stats = struct {
    cask_bytes: u64 = 0,
    tap_cache_bytes: u64 = 0,
    retained_versions: usize = 0,
    taps: usize = 0,
};

/// Owns the parsed findings; `items` borrow from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Doc),
    items: []const Finding,
    stats: Stats = .{},

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

// Disk/tap fields the CLI already emits. Defaulted so an older `mt` whose schema
// omits them still parses; everything else is dropped via `ignore_unknown_fields`.
const Doc = struct {
    checks: []Finding,
    cask_history: CaskHistory = .{},
    tap_cache: TapCache = .{},
    taps: []Tap = &.{},

    const CaskHistory = struct { retained_versions: usize = 0, bytes: u64 = 0 };
    const TapCache = struct { bytes: u64 = 0 };
    const Tap = struct {}; // only its count is used
};

/// Parse the captured `mt doctor --json` document. Malformed, non-conforming, or
/// unknown-vocabulary input is `BadJson`; the caller restores the terminal and
/// surfaces it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    const doc = std.json.parseFromSlice(Doc, allocator, bytes, .{
        .ignore_unknown_fields = true,
        // Copy strings into the arena: the shell frees the source buffer right
        // after parsing while the tab keeps borrowing the findings.
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    return .{
        .doc = doc,
        .items = doc.value.checks,
        .stats = .{
            .cask_bytes = doc.value.cask_history.bytes,
            .tap_cache_bytes = doc.value.tap_cache.bytes,
            .retained_versions = doc.value.cask_history.retained_versions,
            .taps = doc.value.taps.len,
        },
    };
}

/// The `--fix <token>` the `f` action delegates to. Exhaustive `switch` (no
/// `else`) so a new `FixClass` is a compile error here, not a silent miss; the
/// returned token is exactly what `mt doctor --fix` resolves. `none` has no fix
/// target — the caller gates on `fixable` and never asks for it.
pub fn fixClassTag(c: FixClass) []const u8 {
    return switch (c) {
        .none => "none",
        .stale_lock => "stale_lock",
        .orphaned_store => "orphaned_store",
        .broken_symlinks => "broken_symlinks",
    };
}

// ─── tests ───────────────────────────────────────────────────────────

test "parse populates stats from cask_history, tap_cache, and the taps count" {
    const bytes =
        \\{"checks":[{"id":"a","severity":"ok","title":"A"}],
        \\"cask_history":{"retained_versions":3,"bytes":4096},
        \\"tap_cache":{"bytes":512},
        \\"taps":[{"name":"x/y"},{"name":"z/w"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 4096), p.stats.cask_bytes);
    try testing.expectEqual(@as(u64, 512), p.stats.tap_cache_bytes);
    try testing.expectEqual(@as(usize, 3), p.stats.retained_versions);
    try testing.expectEqual(@as(usize, 2), p.stats.taps);
}

test "parse without disk/tap keys yields zeroed stats and still succeeds" {
    // An older `mt` whose schema omits these keys must still parse.
    const bytes =
        \\{"checks":[{"id":"x","severity":"ok","title":"X"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(Stats{}, p.stats);
}

test "stats.taps counts the array length regardless of element fields" {
    const bytes =
        \\{"checks":[],"taps":[{"name":"a/b","extra":1},{"name":"c/d"},{"weird":true}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 3), p.stats.taps);
}

test "unknown nested keys (a future cask_history.entries[]) are tolerated" {
    // The per-cask census is deliberately off the wire; if a newer mt ever adds
    // it, the nested ignore must keep the aggregate readable, not fail the parse.
    const bytes =
        \\{"checks":[],"cask_history":{"retained_versions":2,"bytes":99,"entries":[{"name":"a","bytes":1}]}}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(u64, 99), p.stats.cask_bytes);
    try testing.expectEqual(@as(usize, 2), p.stats.retained_versions);
}

test "fixClassTag maps each fixable class to the mt doctor --fix token" {
    try testing.expectEqualStrings("stale_lock", fixClassTag(.stale_lock));
    try testing.expectEqualStrings("orphaned_store", fixClassTag(.orphaned_store));
    try testing.expectEqualStrings("broken_symlinks", fixClassTag(.broken_symlinks));
}

test "parse reads the checks array with every field" {
    const bytes =
        \\{"schema_version":1,"checks":[
        \\{"id":"sqlite_integrity","severity":"err","title":"SQLite integrity","detail":"database malformed","fixable":false,"fix_class":"none"},
        \\{"id":"orphaned_store_entries","severity":"warn","title":"Orphaned store entries","detail":"3 orphaned","fixable":true,"fix_class":"orphaned_store"}
        \\],"cask_history":{"retained_versions":0,"bytes":0},"tap_cache":{"bytes":0},"taps":[]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);

    try testing.expectEqualStrings("sqlite_integrity", p.items[0].id);
    try testing.expectEqual(Severity.err, p.items[0].severity);
    try testing.expectEqualStrings("SQLite integrity", p.items[0].title);
    try testing.expectEqualStrings("database malformed", p.items[0].detail);
    try testing.expectEqual(false, p.items[0].fixable);
    try testing.expectEqual(FixClass.none, p.items[0].fix_class);

    // The id and the fix_class deliberately differ — `f` must address the class.
    try testing.expectEqualStrings("orphaned_store_entries", p.items[1].id);
    try testing.expectEqual(Severity.warn, p.items[1].severity);
    try testing.expectEqual(true, p.items[1].fixable);
    try testing.expectEqual(FixClass.orphaned_store, p.items[1].fix_class);
}

test "parse decodes every severity tag" {
    const bytes =
        \\{"checks":[
        \\{"id":"a","severity":"ok","title":"A"},
        \\{"id":"b","severity":"warn","title":"B"},
        \\{"id":"c","severity":"err","title":"C"}
        \\]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(Severity.ok, p.items[0].severity);
    try testing.expectEqual(Severity.warn, p.items[1].severity);
    try testing.expectEqual(Severity.err, p.items[2].severity);
}

test "parse decodes every fix_class tag" {
    const bytes =
        \\{"checks":[
        \\{"id":"a","severity":"warn","title":"A","fixable":true,"fix_class":"stale_lock"},
        \\{"id":"b","severity":"warn","title":"B","fixable":true,"fix_class":"orphaned_store"},
        \\{"id":"c","severity":"warn","title":"C","fixable":true,"fix_class":"broken_symlinks"}
        \\]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(FixClass.stale_lock, p.items[0].fix_class);
    try testing.expectEqual(FixClass.orphaned_store, p.items[1].fix_class);
    try testing.expectEqual(FixClass.broken_symlinks, p.items[2].fix_class);
}

test "parse defaults detail/fixable/fix_class when omitted" {
    const bytes =
        \\{"checks":[{"id":"x","severity":"ok","title":"X"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("", p.items[0].detail);
    try testing.expectEqual(false, p.items[0].fixable);
    try testing.expectEqual(FixClass.none, p.items[0].fix_class);
}

test "parse ignores unknown fields and schema_version" {
    const bytes =
        \\{"schema_version":1,"checks":[{"id":"a","severity":"ok","title":"A"}],"future_key":42,"taps":[]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("a", p.items[0].id);
}

test "parse yields zero items for an empty checks array" {
    var p = try parse(testing.allocator, "{\"schema_version\":1,\"checks\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse rejects malformed input, an absent checks key, and an unknown tag" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
    try testing.expectError(error.BadJson, parse(testing.allocator, "{}")); // no checks key
    // An unknown severity is a contract break, not a tolerated unknown — reject it.
    try testing.expectError(error.BadJson, parse(testing.allocator, "{\"checks\":[{\"id\":\"a\",\"severity\":\"meh\",\"title\":\"A\"}]}"));
}

test "stats survive overwriting the source buffer — plain scalars, no borrow" {
    // T-004 keeps `stats` after the shell frees the captured buffer; the scalars
    // must be copied, never sliced into the input.
    const src =
        \\{"checks":[{"id":"a","severity":"ok","title":"A"}],"cask_history":{"retained_versions":7,"bytes":2048},"tap_cache":{"bytes":64},"taps":[{"name":"x/y"}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a borrowing parse would read garbage
    try testing.expectEqual(@as(u64, 2048), p.stats.cask_bytes);
    try testing.expectEqual(@as(u64, 64), p.stats.tap_cache_bytes);
    try testing.expectEqual(@as(usize, 7), p.stats.retained_versions);
    try testing.expectEqual(@as(usize, 1), p.stats.taps);
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the tab
    // keeps borrowing the findings, so the parse must copy, not reference input.
    const src =
        \\{"checks":[{"id":"stale_lock","severity":"warn","title":"Stale lock","detail":"dead PID 42","fixable":true,"fix_class":"stale_lock"}]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would read garbage
    try testing.expectEqualStrings("stale_lock", p.items[0].id);
    try testing.expectEqualStrings("Stale lock", p.items[0].title);
    try testing.expectEqualStrings("dead PID 42", p.items[0].detail);
}
