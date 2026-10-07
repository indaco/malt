//! malt — macOS variation resolution
//! Which cask `variations` key, `depends_on.macos` verdict and formula bottle
//! tag apply to the host running malt. Shared by the parsers and the bulk
//! index extractor so a package resolves the same way on every path.

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

/// The `variations` or bottle key for a macOS major: `arm64_<codename>` on
/// Apple silicon, the bare codename on Intel.
pub fn variationKey(buf: []u8, major: u32) ?[]const u8 {
    const codename = macosCodename(major) orelse return null;
    const prefix: []const u8 = if (builtin.cpu.arch == .aarch64) "arm64_" else "";
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, codename }) catch null;
}

/// macOS majors that publish bottle tags, newest first.
const bottle_majors = [_]u32{ 27, 26, 15, 14, 13, 12, 11 };

/// The tag to pour from a tag-keyed bottle map, in Homebrew's order: the
/// host's own, then `all`, then the newest not newer than the host. A newer
/// tag's binaries would not load here. Null when nothing fits.
pub fn bottleKey(buf: []u8, files: anytype, host_major: ?u32) ?[]const u8 {
    if (host_major) |host| {
        if (variationKey(buf, host)) |key| if (files.contains(key)) return key;
    }
    if (files.contains("all")) return "all";
    for (bottle_majors) |major| {
        // An unreadable host version keeps the newest-first pick: refusing
        // every install would be worse than the risk it guards.
        if (host_major) |host| if (major > host) continue;
        const key = variationKey(buf, major) orelse continue;
        if (files.contains(key)) return key;
    }
    return null;
}

/// The macOS major a bottle tag was built for; null for `all`, another
/// arch's tag, or a codename the map does not know.
pub fn tagMajor(tag: []const u8) ?u32 {
    var buf: [32]u8 = undefined;
    for (bottle_majors) |major| {
        const key = variationKey(&buf, major) orelse continue;
        if (std.mem.eql(u8, key, tag)) return major;
    }
    return null;
}

/// Whether a formula document's `bottle` object offers this host a bottle.
pub fn bottlePourable(bottle: ?std.json.Value, host_major: ?u32) bool {
    const files = objectAt(bottle, &.{ "stable", "files" }) orelse return true;
    var buf: [32]u8 = undefined;
    return bottleKey(&buf, files, host_major) != null;
}

fn objectAt(root: ?std.json.Value, path: []const []const u8) ?std.json.ObjectMap {
    var v = root orelse return null;
    for (path) |key| {
        if (v != .object) return null;
        v = v.object.get(key) orelse return null;
    }
    return if (v == .object) v.object else null;
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

test "bottlePourable refuses only a bottle map with nothing this macOS can load" {
    const a = std.testing.allocator;
    const arch = if (builtin.cpu.arch == .aarch64) "arm64_" else "";
    var newer = try std.json.parseFromSlice(std.json.Value, a, "{\"stable\":{\"files\":{\"" ++ arch ++ "tahoe\":{},\"" ++ arch ++ "sequoia\":{}}}}", .{});
    defer newer.deinit();
    try std.testing.expect(!bottlePourable(newer.value, 14));
    try std.testing.expect(bottlePourable(newer.value, 15));
    try std.testing.expect(bottlePourable(newer.value, null));

    var all = try std.json.parseFromSlice(std.json.Value, a, "{\"stable\":{\"files\":{\"all\":{}}}}", .{});
    defer all.deinit();
    try std.testing.expect(bottlePourable(all.value, 14));

    // No bottle map says nothing about this host, so it is not refused.
    var bare = try std.json.parseFromSlice(std.json.Value, a, "{}", .{});
    defer bare.deinit();
    try std.testing.expect(bottlePourable(bare.value, 14));
    try std.testing.expect(bottlePourable(null, 14));
}

test "tagMajor maps this arch's tags back to their macOS major" {
    const arch = if (builtin.cpu.arch == .aarch64) "arm64_" else "";
    try std.testing.expectEqual(@as(?u32, 27), tagMajor(arch ++ "golden_gate"));
    try std.testing.expectEqual(@as(?u32, 26), tagMajor(arch ++ "tahoe"));
    try std.testing.expectEqual(@as(?u32, 11), tagMajor(arch ++ "big_sur"));
}

test "tagMajor gives no major for tags this host could never have poured" {
    const other = if (builtin.cpu.arch == .aarch64) "golden_gate" else "arm64_golden_gate";
    try std.testing.expectEqual(@as(?u32, null), tagMajor(other));
    // `all` runs everywhere, so it carries no OS floor.
    try std.testing.expectEqual(@as(?u32, null), tagMajor("all"));
    try std.testing.expectEqual(@as(?u32, null), tagMajor("x86_64_linux"));
    try std.testing.expectEqual(@as(?u32, null), tagMajor(""));
}
