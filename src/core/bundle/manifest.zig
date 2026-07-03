//! malt — bundle manifest (JSON canonical form)
//!
//! The `Manifest` struct is the in-memory representation shared by both the
//! JSON (`Maltfile.json`) reader/writer and the Brewfile reader/writer. It
//! owns its backing memory via an arena allocator.

const std = @import("std");

pub const schema_version: u32 = 1;

pub const ManifestError = error{
    UnsupportedVersion,
    UnknownKind,
    MalformedJson,
    OutOfMemory,
};

pub fn describeError(err: ManifestError) []const u8 {
    return switch (err) {
        ManifestError.UnsupportedVersion => "unsupported bundle schema version (expected 1)",
        ManifestError.UnknownKind => "unknown bundle member kind",
        ManifestError.MalformedJson => "malformed bundle JSON",
        ManifestError.OutOfMemory => "out of memory parsing bundle",
    };
}

pub const FormulaEntry = struct {
    name: []const u8,
    version: ?[]const u8 = null,
    restart_service: bool = false,
};

pub const CaskEntry = struct {
    name: []const u8,
};

pub const ServiceEntry = struct {
    name: []const u8,
    auto_start: bool = false,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8 = "",
    version: u32 = schema_version,
    formulas: []FormulaEntry = &.{},
    casks: []CaskEntry = &.{},
    taps: [][]const u8 = &.{},
    services: []ServiceEntry = &.{},

    pub fn init(parent: std.mem.Allocator) Manifest {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Manifest) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub fn parseJson(parent: std.mem.Allocator, json_text: []const u8) ManifestError!Manifest {
    var manifest = Manifest.init(parent);
    errdefer manifest.deinit();
    const a = manifest.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, a, json_text, .{}) catch
        return ManifestError.MalformedJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ManifestError.MalformedJson;
    const obj = root.object;

    if (obj.get("version")) |v| {
        if (v != .integer) return ManifestError.MalformedJson;
        if (v.integer != @as(i64, schema_version)) return ManifestError.UnsupportedVersion;
        manifest.version = schema_version;
    }

    if (obj.get("name")) |v| {
        if (v != .string) return ManifestError.MalformedJson;
        manifest.name = a.dupe(u8, v.string) catch return ManifestError.OutOfMemory;
    }

    if (obj.get("taps")) |v| {
        if (v != .array) return ManifestError.MalformedJson;
        const arr = v.array.items;
        const dst = a.alloc([]const u8, arr.len) catch return ManifestError.OutOfMemory;
        for (arr, 0..) |item, i| {
            if (item != .string) return ManifestError.MalformedJson;
            dst[i] = a.dupe(u8, item.string) catch return ManifestError.OutOfMemory;
        }
        manifest.taps = dst;
    }

    if (obj.get("formulas")) |v| {
        if (v != .array) return ManifestError.MalformedJson;
        const arr = v.array.items;
        const dst = a.alloc(FormulaEntry, arr.len) catch return ManifestError.OutOfMemory;
        for (arr, 0..) |item, i| {
            if (item != .object) return ManifestError.MalformedJson;
            const fo = item.object;
            const n = fo.get("name") orelse return ManifestError.MalformedJson;
            if (n != .string) return ManifestError.MalformedJson;
            var entry: FormulaEntry = .{
                .name = a.dupe(u8, n.string) catch return ManifestError.OutOfMemory,
            };
            if (fo.get("version")) |ver| {
                if (ver != .string) return ManifestError.MalformedJson;
                entry.version = a.dupe(u8, ver.string) catch return ManifestError.OutOfMemory;
            }
            if (fo.get("restart_service")) |rs| {
                if (rs != .bool) return ManifestError.MalformedJson;
                entry.restart_service = rs.bool;
            }
            dst[i] = entry;
        }
        manifest.formulas = dst;
    }

    if (obj.get("casks")) |v| {
        if (v != .array) return ManifestError.MalformedJson;
        const arr = v.array.items;
        const dst = a.alloc(CaskEntry, arr.len) catch return ManifestError.OutOfMemory;
        for (arr, 0..) |item, i| {
            if (item != .object) return ManifestError.MalformedJson;
            const n = item.object.get("name") orelse return ManifestError.MalformedJson;
            if (n != .string) return ManifestError.MalformedJson;
            dst[i] = .{ .name = a.dupe(u8, n.string) catch return ManifestError.OutOfMemory };
        }
        manifest.casks = dst;
    }

    if (obj.get("services")) |v| {
        if (v != .array) return ManifestError.MalformedJson;
        const arr = v.array.items;
        const dst = a.alloc(ServiceEntry, arr.len) catch return ManifestError.OutOfMemory;
        for (arr, 0..) |item, i| {
            if (item != .object) return ManifestError.MalformedJson;
            const so = item.object;
            const n = so.get("name") orelse return ManifestError.MalformedJson;
            if (n != .string) return ManifestError.MalformedJson;
            var entry: ServiceEntry = .{
                .name = a.dupe(u8, n.string) catch return ManifestError.OutOfMemory,
            };
            if (so.get("auto_start")) |b| {
                if (b != .bool) return ManifestError.MalformedJson;
                entry.auto_start = b.bool;
            }
            dst[i] = entry;
        }
        manifest.services = dst;
    }

    return manifest;
}

/// Write `s` as a quoted JSON string literal (RFC 8259 escapes). Duplicated
/// from `ui.output.jsonStr` on purpose: `core → ui` is an upward layer edge,
/// so the ~15 lines are copied rather than imported.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    var start: usize = 0;
    for (s, 0..) |byte, i| {
        const escape: ?[]const u8 = switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            else => null,
        };
        if (escape) |esc| {
            if (i > start) try w.writeAll(s[start..i]);
            try w.writeAll(esc);
            start = i + 1;
        } else if (byte < 0x20) {
            if (i > start) try w.writeAll(s[start..i]);
            var hex_buf: [6]u8 = undefined;
            const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{byte}) catch unreachable;
            try w.writeAll(hex);
            start = i + 1;
        }
    }
    if (start < s.len) try w.writeAll(s[start..]);
    try w.writeByte('"');
}

pub fn emitJson(manifest: Manifest, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\n  \"name\": ");
    try writeJsonString(writer, manifest.name);
    try writer.print(",\n  \"version\": {d}", .{manifest.version});

    if (manifest.taps.len > 0) {
        try writer.writeAll(",\n  \"taps\": [");
        for (manifest.taps, 0..) |t, i| {
            if (i != 0) try writer.writeAll(", ");
            try writeJsonString(writer, t);
        }
        try writer.writeAll("]");
    }

    if (manifest.formulas.len > 0) {
        try writer.writeAll(",\n  \"formulas\": [");
        for (manifest.formulas, 0..) |f, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.writeAll("{\"name\": ");
            try writeJsonString(writer, f.name);
            if (f.version) |v| {
                try writer.writeAll(", \"version\": ");
                try writeJsonString(writer, v);
            }
            if (f.restart_service) try writer.writeAll(", \"restart_service\": true");
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    if (manifest.casks.len > 0) {
        try writer.writeAll(",\n  \"casks\": [");
        for (manifest.casks, 0..) |c, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.writeAll("{\"name\": ");
            try writeJsonString(writer, c.name);
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    if (manifest.services.len > 0) {
        try writer.writeAll(",\n  \"services\": [");
        for (manifest.services, 0..) |s, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.writeAll("{\"name\": ");
            try writeJsonString(writer, s.name);
            if (s.auto_start) try writer.writeAll(", \"auto_start\": true");
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("\n}\n");
}

test "parse minimal JSON" {
    const testing = std.testing;
    const json =
        \\{"name": "tiny", "version": 1, "formulas": [{"name": "wget"}]}
    ;
    var m = try parseJson(testing.allocator, json);
    defer m.deinit();

    try testing.expectEqualStrings("tiny", m.name);
    try testing.expectEqual(@as(u32, 1), m.version);
    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("wget", m.formulas[0].name);
}

test "parse full JSON with all member kinds" {
    const testing = std.testing;
    const json =
        \\{
        \\  "name": "devtools",
        \\  "version": 1,
        \\  "taps": ["homebrew/cask-fonts"],
        \\  "formulas": [{"name": "wget"}, {"name": "jq", "version": "1.7"}],
        \\  "casks": [{"name": "ghostty"}],
        \\  "services": [{"name": "postgresql@16", "auto_start": true}]
        \\}
    ;
    var m = try parseJson(testing.allocator, json);
    defer m.deinit();

    try testing.expectEqualStrings("devtools", m.name);
    try testing.expectEqual(@as(usize, 1), m.taps.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", m.taps[0]);
    try testing.expectEqual(@as(usize, 2), m.formulas.len);
    try testing.expectEqualStrings("jq", m.formulas[1].name);
    try testing.expectEqualStrings("1.7", m.formulas[1].version.?);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
    try testing.expectEqualStrings("ghostty", m.casks[0].name);
    try testing.expectEqual(@as(usize, 1), m.services.len);
    try testing.expect(m.services[0].auto_start);
}

test "reject version mismatch" {
    const testing = std.testing;
    const json =
        \\{"name": "x", "version": 2}
    ;
    try testing.expectError(ManifestError.UnsupportedVersion, parseJson(testing.allocator, json));
}

test "reject malformed json" {
    const testing = std.testing;
    try testing.expectError(ManifestError.MalformedJson, parseJson(testing.allocator, "not json at all"));
}

test "round-trip survives quotes and backslashes in every string field" {
    const testing = std.testing;
    // std.json decodes \" \\ \n \t on the way in, so these fields hold raw
    // quote/backslash/control bytes — the exact case a raw {s} emitter corrupts.
    // The name carries a newline+tab to also exercise the control-char escapes.
    const json =
        \\{"name":"a\"b\\c\n\t","version":1,"taps":["t\"p"],"formulas":[{"name":"w\"g","version":"1\\2"}],"casks":[{"name":"c\"k"}],"services":[{"name":"s\"v","auto_start":true}]}
    ;
    var m1 = try parseJson(testing.allocator, json);
    defer m1.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(m1, &aw.writer);

    var m2 = try parseJson(testing.allocator, aw.written());
    defer m2.deinit();

    try testing.expectEqualStrings(m1.name, m2.name);
    try testing.expectEqualStrings(m1.taps[0], m2.taps[0]);
    try testing.expectEqualStrings(m1.formulas[0].name, m2.formulas[0].name);
    try testing.expectEqualStrings(m1.formulas[0].version.?, m2.formulas[0].version.?);
    try testing.expectEqualStrings(m1.casks[0].name, m2.casks[0].name);
    try testing.expectEqualStrings(m1.services[0].name, m2.services[0].name);
}

test "emitJson output format is byte-stable for a plain manifest" {
    // Golden lock: the escaper refactor must not drift the emitted layout for
    // ordinary (escape-free) input. Any format change fails here loudly.
    const testing = std.testing;
    const json =
        \\{"name":"dev","version":1,"taps":["homebrew/core"],"formulas":[{"name":"wget"},{"name":"jq","version":"1.7","restart_service":true}],"casks":[{"name":"ghostty"}],"services":[{"name":"pg","auto_start":true}]}
    ;
    var m = try parseJson(testing.allocator, json);
    defer m.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(m, &aw.writer);

    const expected =
        \\{
        \\  "name": "dev",
        \\  "version": 1,
        \\  "taps": ["homebrew/core"],
        \\  "formulas": [{"name": "wget"}, {"name": "jq", "version": "1.7", "restart_service": true}],
        \\  "casks": [{"name": "ghostty"}],
        \\  "services": [{"name": "pg", "auto_start": true}]
        \\}
        \\
    ;
    try testing.expectEqualStrings(expected, aw.written());
}

test "round-trip covers control chars, utf-8, empty strings and multiple entries" {
    const testing = std.testing;
    // The name mixes \b (0x08), \f (0x0c) named escapes with a raw UTF-8
    // sequence; taps/version/cask carry empty strings. Every value must
    // survive emit->parse, and the emitted text must be valid JSON.
    const json =
        \\{"name":"\b\fé🍺","version":1,"taps":["",""],"formulas":[{"name":"a\"1","version":""},{"name":"b\\2"}],"casks":[{"name":""}],"services":[{"name":"s\ty"}]}
    ;
    var m1 = try parseJson(testing.allocator, json);
    defer m1.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(m1, &aw.writer);

    // Emitted text is well-formed JSON (independent of our own parser).
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    parsed.deinit();

    var m2 = try parseJson(testing.allocator, aw.written());
    defer m2.deinit();

    try testing.expectEqualStrings(m1.name, m2.name);
    try testing.expectEqual(@as(usize, 2), m2.taps.len);
    try testing.expectEqualStrings("", m2.taps[0]);
    try testing.expectEqualStrings("a\"1", m2.formulas[0].name);
    try testing.expectEqualStrings("", m2.formulas[0].version.?);
    try testing.expectEqualStrings("b\\2", m2.formulas[1].name);
    try testing.expectEqualStrings("", m2.casks[0].name);
    try testing.expectEqualStrings("s\ty", m2.services[0].name);
}

test "writeJsonString escapes unnamed control bytes as \\uXXXX and round-trips" {
    const testing = std.testing;
    // Build in-memory so the raw 0x01/0x1f bytes never sit in a source literal.
    var m1 = Manifest.init(testing.allocator);
    defer m1.deinit();
    const a = m1.allocator();
    m1.name = try a.dupe(u8, "x\x01y\x1fz");

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(m1, &aw.writer);

    // The two unnamed controls must appear as \u0001 / \u001f, not raw bytes.
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\\u001f") != null);
    try testing.expect(std.mem.indexOfScalar(u8, aw.written(), 0x01) == null);

    var m2 = try parseJson(testing.allocator, aw.written());
    defer m2.deinit();
    try testing.expectEqualStrings(m1.name, m2.name);
}

test "emitJson round-trips every ASCII byte in a name" {
    // Exhaustive over 0x00..0x7f — the range that is a valid lone byte in a JSON
    // string (higher bytes are only legal as multi-byte UTF-8). Every one must
    // emit as valid JSON and survive the round-trip.
    const testing = std.testing;
    var b: usize = 0;
    while (b < 0x80) : (b += 1) {
        var m1 = Manifest.init(testing.allocator);
        defer m1.deinit();
        const a = m1.allocator();
        const name = try a.alloc(u8, 3);
        name[0] = 'x';
        name[1] = @intCast(b);
        name[2] = 'y';
        m1.name = name;

        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try emitJson(m1, &aw.writer);

        var m2 = parseJson(testing.allocator, aw.written()) catch |e| {
            std.debug.print("byte 0x{x:0>2} emitted invalid JSON: {s}\n", .{ b, @errorName(e) });
            return e;
        };
        defer m2.deinit();
        testing.expectEqualStrings(name, m2.name) catch |e| {
            std.debug.print("byte 0x{x:0>2} did not round-trip\n", .{b});
            return e;
        };
    }
}

test "round-trip parse emit parse" {
    const testing = std.testing;
    const json =
        \\{"name": "rt", "version": 1, "formulas": [{"name": "wget"}], "casks": [{"name": "ghostty"}]}
    ;
    var m1 = try parseJson(testing.allocator, json);
    defer m1.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitJson(m1, &aw.writer);

    var m2 = try parseJson(testing.allocator, aw.written());
    defer m2.deinit();

    try testing.expectEqualStrings(m1.name, m2.name);
    try testing.expectEqual(m1.formulas.len, m2.formulas.len);
    try testing.expectEqualStrings(m1.formulas[0].name, m2.formulas[0].name);
    try testing.expectEqual(m1.casks.len, m2.casks.len);
}
