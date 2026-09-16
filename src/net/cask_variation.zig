//! malt — cask variation resolution
//! Which `variations` key and `depends_on.macos` verdict apply to the host
//! running malt. Shared by the per-cask parser and the bulk index extractor
//! so a cask resolves the same way on both paths.

const std = @import("std");
const builtin = @import("builtin");

/// Product major of the running macOS, or null when the sysctl is unreadable.
/// Same five lines as `post_install_steps.sysctlMajor`, kept apart so this
/// leaf does not grow an edge into the step executor.
pub fn runningMacosMajor() ?u32 {
    var buf: [32]u8 = undefined;
    var len: usize = buf.len;
    if (std.c.sysctlbyname("kern.osproductversion", &buf, &len, null, 0) != 0) return null;
    const text = std.mem.sliceTo(buf[0..len], 0);
    const major = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
    return std.fmt.parseInt(u32, major, 10) catch null;
}

/// Homebrew's `MacOSVersion` symbol for a product major; null for a release
/// the map does not know, which then falls back to the top-level fields.
pub fn macosCodename(major: u32) ?[]const u8 {
    return switch (major) {
        11 => "big_sur",
        12 => "monterey",
        13 => "ventura",
        14 => "sonoma",
        15 => "sequoia",
        26 => "tahoe",
        27 => "golden_gate",
        else => null,
    };
}

/// The `variations` key for this host: `arm64_<codename>` on Apple silicon,
/// the bare codename on Intel.
pub fn variationKey(buf: []u8, major: u32) ?[]const u8 {
    const codename = macosCodename(major) orelse return null;
    const prefix: []const u8 = if (builtin.cpu.arch == .aarch64) "arm64_" else "";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, codename }) catch null;
}

/// One `depends_on.macos` clause, e.g. `{">=": ["12"]}` or
/// `{"==": ["13", "14"]}`. Borrows from the parsed document.
pub const Requirement = struct {
    op: []const u8,
    versions: []const std.json.Value,

    /// The first listed version, for messages; `""` when none is a string.
    pub fn version(self: Requirement) []const u8 {
        for (self.versions) |v| if (v == .string) return v.string;
        return "";
    }
};

/// `variations[key]` of a cask document, when the document carries one.
pub fn variationObject(variations: ?std.json.Value, key: ?[]const u8) ?std.json.ObjectMap {
    const k = key orelse return null;
    const all = variations orelse return null;
    if (all != .object) return null;
    const one = all.object.get(k) orelse return null;
    return if (one == .object) one.object else null;
}

/// First clause of a `depends_on` value's `macos` entry, or null when the
/// cask declares none.
pub fn macosRequirement(depends_on: ?std.json.Value) ?Requirement {
    const d = depends_on orelse return null;
    if (d != .object) return null;
    const macos = switch (d.object.get("macos") orelse return null) {
        .object => |o| o,
        else => return null,
    };
    var it = macos.iterator();
    const entry = it.next() orelse return null;
    return switch (entry.value_ptr.*) {
        .array => |a| .{ .op = entry.key_ptr.*, .versions = a.items },
        else => null,
    };
}

/// Null on either side gates nothing: no clause, or an OS malt cannot read.
pub fn osSupported(requirement: ?Requirement, macos_major: ?u32) bool {
    const req = requirement orelse return true;
    const major = macos_major orelse return true;
    // `>=` names one floor; `==` lists every release the cask runs on.
    if (std.mem.eql(u8, req.op, ">=")) {
        if (req.versions.len == 0) return true;
        const floor = majorOf(req.versions[0]) orelse return true;
        return major >= floor;
    }
    if (std.mem.eql(u8, req.op, "==")) {
        var readable = false;
        for (req.versions) |v| {
            const m = majorOf(v) orelse continue;
            readable = true;
            if (m == major) return true;
        }
        // Nothing readable gates nothing, the same way `>=` falls open.
        return !readable;
    }
    // ponytail: only the two operators the live API emits; an unknown one
    // is left to the download rather than refused on a guess.
    return true;
}

/// Major of a listed version string, bare ("12") or dotted ("10.15").
fn majorOf(v: std.json.Value) ?u32 {
    if (v != .string) return null;
    const text = v.string;
    const head = text[0 .. std.mem.indexOfScalar(u8, text, '.') orelse text.len];
    return std.fmt.parseInt(u32, head, 10) catch null;
}

fn requirementOf(a: std.mem.Allocator, json: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

test "== lists every macOS the cask runs on, so any match supports it" {
    const a = std.testing.allocator;
    var p = try requirementOf(a,
        \\{"macos":{"==":["11","12","13","14","15","26"]}}
    );
    defer p.deinit();
    const req = macosRequirement(p.value);
    try std.testing.expect(osSupported(req, 26));
    try std.testing.expect(osSupported(req, 11));
    try std.testing.expect(!osSupported(req, 27));
    try std.testing.expectEqualStrings("11", req.?.version());
}

test "a clause with no parseable version gates nothing, whichever operator" {
    // Refusing on data malt cannot read would turn a schema drift into a
    // refusal; both operators fall open the same way.
    const a = std.testing.allocator;
    var ge = try requirementOf(a,
        \\{"macos":{">=":[15]}}
    );
    defer ge.deinit();
    try std.testing.expect(osSupported(macosRequirement(ge.value), 14));
    var eq = try requirementOf(a,
        \\{"macos":{"==":[15, null]}}
    );
    defer eq.deinit();
    try std.testing.expect(osSupported(macosRequirement(eq.value), 14));
    // A parseable entry beside junk still decides.
    var mixed = try requirementOf(a,
        \\{"macos":{"==":[null, "15"]}}
    );
    defer mixed.deinit();
    try std.testing.expect(!osSupported(macosRequirement(mixed.value), 14));
    try std.testing.expect(osSupported(macosRequirement(mixed.value), 15));
    var odd = try requirementOf(a,
        \\{"macos":{"<":["15"]}}
    );
    defer odd.deinit();
    try std.testing.expect(osSupported(macosRequirement(odd.value), 26));
}

test ">= compares the major against the first listed version" {
    const a = std.testing.allocator;
    var p = try requirementOf(a,
        \\{"macos":{">=":["10.15"]}}
    );
    defer p.deinit();
    const req = macosRequirement(p.value);
    try std.testing.expect(osSupported(req, 10));
    try std.testing.expect(!osSupported(req, 9));
    try std.testing.expectEqualStrings(">=", req.?.op);
}

test "an empty macos clause, an unknown major, or no clause gates nothing" {
    const a = std.testing.allocator;
    var p = try requirementOf(a,
        \\{"macos":{}}
    );
    defer p.deinit();
    try std.testing.expect(macosRequirement(p.value) == null);
    try std.testing.expect(osSupported(null, 14));
    try std.testing.expect(osSupported(.{ .op = ">=", .versions = &.{} }, null));
}
