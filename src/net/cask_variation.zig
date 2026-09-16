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

/// One `depends_on.macos` clause, e.g. `{">=": ["12"]}` → (`>=`, `12`).
/// Strings borrow from the parsed document.
pub const Requirement = struct { op: []const u8, version: []const u8 };

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
    const versions = switch (entry.value_ptr.*) {
        .array => |a| a,
        else => return null,
    };
    if (versions.items.len == 0) return null;
    return switch (versions.items[0]) {
        .string => |v| .{ .op = entry.key_ptr.*, .version = v },
        else => null,
    };
}

/// Null on either side gates nothing: no clause, or an OS malt cannot read.
pub fn osSupported(requirement: ?Requirement, macos_major: ?u32) bool {
    const req = requirement orelse return true;
    const major = macos_major orelse return true;
    // Requirement majors are bare ("12") or dotted ("10.15"); compare majors.
    const text = req.version[0 .. std.mem.indexOfScalar(u8, req.version, '.') orelse req.version.len];
    const required = std.fmt.parseInt(u32, text, 10) catch return true;
    if (std.mem.eql(u8, req.op, ">=")) return major >= required;
    if (std.mem.eql(u8, req.op, "==")) return major == required;
    // ponytail: only the two operators the live API emits; an unknown one
    // is left to the download rather than refused on a guess.
    return true;
}
