//! malt — parse `mt info <pkg> --json` into a TUI-local struct.
//!
//! Leaf module: imports only `std`. Feeds the detail pane the fields the `list`
//! row can't carry — the dependency list and the tap. Every field defaults, so
//! the same parse handles the installed-formula shape (deps + pinned) and the
//! installed-cask shape (no deps, no pinned). Unknown fields are ignored. The
//! struct is TUI-local — never the core info structs — so the schema is the only
//! coupling.

const std = @import("std");

pub const Error = error{BadJson};

/// The detail-pane-relevant subset of `mt info <pkg> --json`. `dependencies` is
/// empty for casks and not-installed packages; `tap` is empty when unattributed.
pub const Info = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    tap: []const u8 = "",
    pinned: bool = false,
    dependencies: []const []const u8 = &.{},
};

/// Owns the parsed document; `info` borrows from the arena. Free with `deinit`.
pub const Parsed = struct {
    doc: std.json.Parsed(Info),
    info: Info,

    pub fn deinit(self: Parsed) void {
        self.doc.deinit();
    }
};

/// Parse the captured `mt info <pkg> --json` document. Malformed input is
/// `BadJson`; the caller restores the terminal and surfaces it.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Parsed {
    const doc = std.json.parseFromSlice(Info, allocator, bytes, .{
        .ignore_unknown_fields = true,
        // Copy strings into the arena: the shell frees the source buffer right
        // after parsing while the detail pane keeps borrowing tap + deps.
        .allocate = .alloc_always,
    }) catch return error.BadJson;
    return .{ .doc = doc, .info = doc.value };
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parse reads an installed formula's deps, tap, version, pinned" {
    const bytes =
        \\{"schema_version":1,"name":"curl","type":"formula","installed":true,"version":"8.20.0",
        \\"tap":"homebrew/core","dependencies":["brotli","zstd"],"pinned":true,"installed_at":"x",
        \\"available_rollback_versions":[]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("curl", p.info.name);
    try testing.expectEqualStrings("homebrew/core", p.info.tap);
    try testing.expectEqual(true, p.info.pinned);
    try testing.expectEqual(@as(usize, 2), p.info.dependencies.len);
    try testing.expectEqualStrings("brotli", p.info.dependencies[0]);
}

test "parse tolerates the cask shape: no dependencies, no pinned" {
    const bytes =
        \\{"schema_version":1,"name":"flux","type":"cask","installed":true,"version":"1.0",
        \\"full_name":"Flux","url":"https://x","app_path":"/Applications/Flux.app","auto_updates":false,
        \\"installed_at":"x","tap":"","available_rollback_versions":[]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqualStrings("flux", p.info.name);
    try testing.expectEqual(@as(usize, 0), p.info.dependencies.len);
    try testing.expectEqual(false, p.info.pinned);
}

test "parse yields an empty dependency list, not a crash, when deps are empty" {
    var p = try parse(testing.allocator, "{\"name\":\"a\",\"dependencies\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.info.dependencies.len);
}

test "parse rejects malformed and empty input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
}

test "parsed strings own their bytes — the source buffer can be freed/overwritten" {
    // The shell frees the captured `--json` buffer right after parsing; the detail
    // pane keeps borrowing tap + deps, so the parse must copy, not reference input.
    const src =
        \\{"name":"curl","tap":"homebrew/core","dependencies":["brotli","zstd"],"pinned":true}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    defer testing.allocator.free(buf);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source — a referencing parse would now read garbage
    try testing.expectEqualStrings("homebrew/core", p.info.tap);
    try testing.expectEqualStrings("brotli", p.info.dependencies[0]);
}
