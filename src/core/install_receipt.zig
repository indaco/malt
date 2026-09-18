//! malt — Homebrew INSTALL_RECEIPT.json parser
//!
//! Extracts the small subset of fields malt's private-tap copy-from-Cellar
//! fallback needs from a keg's `INSTALL_RECEIPT.json`: source tap, stable
//! version, runtime dependency names, and whether the keg was installed on
//! request. The parser is deliberately
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
    /// `installed_on_request`. True when absent: very old brew receipts
    /// omit the pair, and metadata must never demote a keg.
    on_request: bool,
    /// Keg-relative files the bottler rewrote, so relocation can visit only
    /// those. `null` when the bottle predates the metadata (walk the keg);
    /// empty when the bottler found nothing to rewrite.
    changed_files: ?[]const []const u8,
    linkage_files: ?[]const []const u8,
    binary_relocation_files: ?[]const []const u8,

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

    const on_request = blk: {
        const v = root.get("installed_on_request") orelse break :blk true;
        break :blk switch (v) {
            .bool => |b| b,
            else => true,
        };
    };

    return .{
        .tap = tap,
        .version = version,
        .source_path = source_path,
        .runtime_deps = deps,
        .on_request = on_request,
        .changed_files = try optionalStringList(a, root, "changed_files"),
        .linkage_files = try optionalStringList(a, root, "linkage_files"),
        .binary_relocation_files = try optionalStringList(a, root, "binary_relocation_files"),
        .arena = arena,
    };
}

/// Null unless `key` is an array of strings: a list malt cannot trust must
/// read as "no list", never as a partial one.
fn optionalStringList(a: std.mem.Allocator, root: std.json.ObjectMap, key: []const u8) ParseError!?[]const []const u8 {
    const v = root.get(key) orelse return null;
    const arr = switch (v) {
        .array => |arr| arr,
        else => return null,
    };
    const out = a.alloc([]const u8, arr.items.len) catch return ParseError.OutOfMemory;
    for (arr.items, out) |item, *slot| {
        slot.* = switch (item) {
            .string => |s| a.dupe(u8, s) catch return ParseError.OutOfMemory,
            else => return null,
        };
    }
    return out;
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
    // Very old brew receipts omit the reason pair; absent means requested.
    try std.testing.expect(r.on_request);
}

test "parseInstallReceipt reads installed_on_request true" {
    const src = "{\"installed_as_dependency\": true, \"installed_on_request\": true}";
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expect(r.on_request);
}

test "parseInstallReceipt reads installed_on_request false" {
    const src = "{\"installed_as_dependency\": true, \"installed_on_request\": false}";
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expect(!r.on_request);
}

test "parseInstallReceipt treats a null or non-bool installed_on_request as requested" {
    for ([_][]const u8{
        "{\"installed_on_request\": null}",
        "{\"installed_on_request\": \"false\"}",
        "{\"installed_on_request\": 0}",
    }) |src| {
        var r = try parseInstallReceipt(std.testing.allocator, src);
        defer r.deinit();
        try std.testing.expect(r.on_request);
    }
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

test "parseInstallReceipt distinguishes absent, null and empty changed_files" {
    // Absent or null: the bottle predates the metadata and the whole keg
    // must be walked. Empty: the bottler checked and nothing needs it.
    var absent = try parseInstallReceipt(std.testing.allocator, "{}");
    defer absent.deinit();
    try std.testing.expect(absent.changed_files == null);

    var nulled = try parseInstallReceipt(std.testing.allocator, "{\"changed_files\": null}");
    defer nulled.deinit();
    try std.testing.expect(nulled.changed_files == null);

    var empty = try parseInstallReceipt(std.testing.allocator, "{\"changed_files\": []}");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.changed_files.?.len);
}

test "parseInstallReceipt reads the relocation file lists in order" {
    const src =
        \\{
        \\  "changed_files": ["bin/magick-config", "lib/pkgconfig/x.pc"],
        \\  "linkage_files": ["bin/magick", "lib/libMagick.dylib"],
        \\  "binary_relocation_files": ["lib/libMagickCore.dylib"]
        \\}
    ;
    var r = try parseInstallReceipt(std.testing.allocator, src);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, 2), r.changed_files.?.len);
    try std.testing.expectEqualStrings("bin/magick-config", r.changed_files.?[0]);
    try std.testing.expectEqualStrings("lib/pkgconfig/x.pc", r.changed_files.?[1]);
    try std.testing.expectEqual(@as(usize, 2), r.linkage_files.?.len);
    try std.testing.expectEqualStrings("bin/magick", r.linkage_files.?[0]);
    try std.testing.expectEqualStrings("lib/libMagick.dylib", r.linkage_files.?[1]);
    try std.testing.expectEqual(@as(usize, 1), r.binary_relocation_files.?.len);
    try std.testing.expectEqualStrings("lib/libMagickCore.dylib", r.binary_relocation_files.?[0]);
}

test "parseInstallReceipt treats a malformed relocation list as absent" {
    // A list malt cannot trust must send the keg down the full walk, never
    // a partial one.
    for ([_][]const u8{
        "{\"linkage_files\": \"bin/magick\"}",
        "{\"linkage_files\": [\"bin/magick\", 7]}",
        "{\"linkage_files\": [null]}",
    }) |src| {
        var r = try parseInstallReceipt(std.testing.allocator, src);
        defer r.deinit();
        try std.testing.expect(r.linkage_files == null);
    }
}
