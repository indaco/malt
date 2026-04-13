//! malt — bundle manifest (JSON canonical form)
//!
//! The `Manifest` struct is the in-memory representation shared by both the
//! JSON (`Maltfile.json`) reader/writer and the Brewfile reader/writer. It
//! owns its backing memory via an arena allocator.

const std = @import("std");

pub const SCHEMA_VERSION: u32 = 1;

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
    version: u32 = SCHEMA_VERSION,
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
        const n = v.integer;
        if (n != @as(i64, SCHEMA_VERSION)) return ManifestError.UnsupportedVersion;
        manifest.version = @intCast(n);
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

pub fn emitJson(manifest: Manifest, writer: anytype) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"name\": \"{s}\",\n", .{manifest.name});
    try writer.print("  \"version\": {d}", .{manifest.version});

    if (manifest.taps.len > 0) {
        try writer.writeAll(",\n  \"taps\": [");
        for (manifest.taps, 0..) |t, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{t});
        }
        try writer.writeAll("]");
    }

    if (manifest.formulas.len > 0) {
        try writer.writeAll(",\n  \"formulas\": [");
        for (manifest.formulas, 0..) |f, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{{\"name\": \"{s}\"", .{f.name});
            if (f.version) |v| try writer.print(", \"version\": \"{s}\"", .{v});
            if (f.restart_service) try writer.writeAll(", \"restart_service\": true");
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    if (manifest.casks.len > 0) {
        try writer.writeAll(",\n  \"casks\": [");
        for (manifest.casks, 0..) |c, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{{\"name\": \"{s}\"}}", .{c.name});
        }
        try writer.writeAll("]");
    }

    if (manifest.services.len > 0) {
        try writer.writeAll(",\n  \"services\": [");
        for (manifest.services, 0..) |s, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{{\"name\": \"{s}\"", .{s.name});
            if (s.auto_start) try writer.writeAll(", \"auto_start\": true");
            try writer.writeAll("}");
        }
        try writer.writeAll("]");
    }

    try writer.writeAll("\n}\n");
}
