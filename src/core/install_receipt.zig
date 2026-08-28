//! malt — Homebrew INSTALL_RECEIPT.json parser
//!
//! Extracts the small subset of fields malt's private-tap copy-from-Cellar
//! fallback needs from a keg's `INSTALL_RECEIPT.json`: source tap, stable
//! version, and runtime dependency names. The parser is deliberately
//! lenient — newer brew versions add fields we don't read, older ones
//! omit fields we tolerate as null/absent.

const std = @import("std");
const path_component = @import("../fs/path_component.zig");

pub const Receipt = struct {
    /// `"homebrew/core"` for stock formulae, `"<user>/<repo>"` for tap
    /// formulae. Empty when the receipt omits it (very old brew).
    tap: []const u8,
    /// `source.versions.stable`. Authoritative version for routing
    /// + DB recording. Empty when absent.
    version: []const u8,
    /// `source.path` — for tap formulae this is the absolute on-disk
    /// path to the `<name>.rb` source; for `homebrew/core` modern brew
    /// stores the API JWS cache path here instead. Empty when absent.
    source_path: []const u8,
    /// `runtime_dependencies[*].full_name`. Order preserved.
    runtime_deps: []const []const u8,

    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Receipt) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    InvalidReceipt,
    OutOfMemory,
};

/// Parse a Homebrew `INSTALL_RECEIPT.json` body. Tolerates absent / null
/// fields so receipts written by older brew versions don't break the
/// fallback. Returns the small subset of fields the migrate path uses;
/// caller owns the arena that backs every string.
pub fn parseInstallReceipt(parent: std.mem.Allocator, json_text: []const u8) ParseError!Receipt {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const a = arena.allocator();

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        a,
        json_text,
        .{ .ignore_unknown_fields = true },
    ) catch return ParseError.InvalidReceipt;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return ParseError.InvalidReceipt,
    };

    const source_obj: ?std.json.ObjectMap = blk: {
        const v = root.get("source") orelse break :blk null;
        switch (v) {
            .object => |o| break :blk o,
            else => break :blk null,
        }
    };

    const tap = blk: {
        const src = source_obj orelse break :blk "";
        const v = src.get("tap") orelse break :blk "";
        switch (v) {
            .string => |s| break :blk a.dupe(u8, s) catch return ParseError.OutOfMemory,
            .null => break :blk "",
            else => break :blk "",
        }
    };

    const version = blk: {
        const src = source_obj orelse break :blk "";
        const versions_v = src.get("versions") orelse break :blk "";
        const versions = switch (versions_v) {
            .object => |o| o,
            else => break :blk "",
        };
        const stable_v = versions.get("stable") orelse break :blk "";
        switch (stable_v) {
            .string => |s| break :blk a.dupe(u8, s) catch return ParseError.OutOfMemory,
            .null => break :blk "",
            else => break :blk "",
        }
    };

    // A foreign tool writes this receipt and the version lands in a Cellar
    // path. Absent stays tolerated; present must be a single component.
    if (version.len != 0 and !path_component.isPathComponent(version)) return ParseError.InvalidReceipt;

    const source_path = blk: {
        const src = source_obj orelse break :blk "";
        const v = src.get("path") orelse break :blk "";
        switch (v) {
            .string => |s| break :blk a.dupe(u8, s) catch return ParseError.OutOfMemory,
            .null => break :blk "",
            else => break :blk "",
        }
    };

    const deps = blk: {
        const v = root.get("runtime_dependencies") orelse break :blk &[_][]const u8{};
        const arr = switch (v) {
            .array => |arr| arr,
            else => break :blk &[_][]const u8{},
        };
        var list: std.ArrayList([]const u8) = .empty;
        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const name_v = obj.get("full_name") orelse continue;
            const name = switch (name_v) {
                .string => |s| s,
                else => continue,
            };
            const owned = a.dupe(u8, name) catch return ParseError.OutOfMemory;
            list.append(a, owned) catch return ParseError.OutOfMemory;
        }
        break :blk list.toOwnedSlice(a) catch return ParseError.OutOfMemory;
    };

    return .{
        .tap = tap,
        .version = version,
        .source_path = source_path,
        .runtime_deps = deps,
        .arena = arena,
    };
}

/// True for `homebrew/core` (the stock tap) or an empty/missing tap.
/// Anything else is a private/third-party tap.
pub fn isCoreTap(tap: []const u8) bool {
    return tap.len == 0 or std.mem.eql(u8, tap, "homebrew/core");
}

test "isCoreTap recognises the stock tap and absent values" {
    try std.testing.expect(isCoreTap("homebrew/core"));
    try std.testing.expect(isCoreTap(""));
}

test "isCoreTap rejects private taps" {
    try std.testing.expect(!isCoreTap("charmbracelet/tap"));
    try std.testing.expect(!isCoreTap("user/private"));
    try std.testing.expect(!isCoreTap("homebrew/cask"));
}

test "parseInstallReceipt extracts tap, stable version, and runtime_dependencies" {
    const src =
        \\{
        \\  "source": {
        \\    "tap": "charmbracelet/tap",
        \\    "spec": "stable",
        \\    "versions": {
        \\      "stable": "0.2.2",
        \\      "head": null
        \\    }
        \\  },
        \\  "runtime_dependencies": [
        \\    {"full_name": "oniguruma", "version": "6.9.10"},
        \\    {"full_name": "zlib", "version": "1.3"}
        \\  ]
        \\}
    ;
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqualStrings("charmbracelet/tap", r.tap);
    try std.testing.expectEqualStrings("0.2.2", r.version);
    try std.testing.expectEqual(@as(usize, 2), r.runtime_deps.len);
    try std.testing.expectEqualStrings("oniguruma", r.runtime_deps[0]);
    try std.testing.expectEqualStrings("zlib", r.runtime_deps[1]);
}

test "parseInstallReceipt extracts source.path so the migrate fallback can find the tap's .rb" {
    const src =
        \\{
        \\  "source": {
        \\    "tap": "charmbracelet/tap",
        \\    "path": "/opt/homebrew/Library/Taps/charmbracelet/homebrew-tap/Formula/glow.rb",
        \\    "versions": {"stable": "0.2.2"}
        \\  }
        \\}
    ;
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqualStrings(
        "/opt/homebrew/Library/Taps/charmbracelet/homebrew-tap/Formula/glow.rb",
        r.source_path,
    );
}

test "parseInstallReceipt tolerates missing optional fields" {
    const src = "{\"source\": {}}";
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.tap);
    try std.testing.expectEqualStrings("", r.version);
    try std.testing.expectEqualStrings("", r.source_path);
    try std.testing.expectEqual(@as(usize, 0), r.runtime_deps.len);
}

test "parseInstallReceipt tolerates a missing source object" {
    const src = "{}";
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.tap);
    try std.testing.expectEqualStrings("", r.version);
}

test "parseInstallReceipt skips runtime_dependencies entries lacking full_name" {
    const src =
        \\{
        \\  "source": {"tap": "x/y", "versions": {"stable": "1.0"}},
        \\  "runtime_dependencies": [
        \\    {"full_name": "good"},
        \\    {"version": "1.0"},
        \\    "raw-string-not-an-object",
        \\    {"full_name": "also-good"}
        \\  ]
        \\}
    ;
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.runtime_deps.len);
    try std.testing.expectEqualStrings("good", r.runtime_deps[0]);
    try std.testing.expectEqualStrings("also-good", r.runtime_deps[1]);
}

test "parseInstallReceipt rejects invalid JSON with InvalidReceipt" {
    try std.testing.expectError(ParseError.InvalidReceipt, parseInstallReceipt(std.testing.allocator, "not json"));
    try std.testing.expectError(ParseError.InvalidReceipt, parseInstallReceipt(std.testing.allocator, "[1,2,3]"));
    try std.testing.expectError(ParseError.InvalidReceipt, parseInstallReceipt(std.testing.allocator, ""));
}

test "parseInstallReceipt rejects a stable version that is not a path component" {
    const bad = [_][]const u8{
        \\{"source":{"versions":{"stable":"../../../canary"}}}
        ,
        \\{"source":{"versions":{"stable":"a/b"}}}
        ,
        \\{"source":{"versions":{"stable":"."}}}
        ,
        \\{"source":{"versions":{"stable":".."}}}
        ,
        // Escaped so the JSON itself is well-formed: the guard must be what
        // rejects it, not the parser.
        \\{"source":{"versions":{"stable":"a\u0000b"}}}
        ,
    };
    for (bad) |json| {
        try std.testing.expectError(
            ParseError.InvalidReceipt,
            parseInstallReceipt(std.testing.allocator, json),
        );
    }
}

test "parseInstallReceipt keeps the versions real formulae ship" {
    const ok = [_][]const u8{ "3.2.1", "1.2.3_1", "3.0.16", "2024-01-02" };
    for (ok) |v| {
        var buf: [128]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf, "{{\"source\":{{\"versions\":{{\"stable\":\"{s}\"}}}}}}", .{v});
        var r = try parseInstallReceipt(std.testing.allocator, json);
        defer r.deinit();
        try std.testing.expectEqualStrings(v, r.version);
    }
}
