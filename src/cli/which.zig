//! malt — which command
//! Resolve a prefix binary (or absolute path) to the keg that owns it.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const fs_compat = @import("../fs/compat.zig");
const color = @import("../ui/color.zig");
const io_mod = @import("../ui/io.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const ResolveError = error{
    NotACellarPath,
    MalformedCellarPath,
};

/// All three fields are borrowed slices into the input target —
/// the caller must keep that buffer alive for the lifetime of the
/// `Resolution`. `keg` is `<...>/Cellar/<name>/<version>`.
pub const Resolution = struct {
    name: []const u8,
    version: []const u8,
    keg: []const u8,
};

/// Parse a symlink target like `<...>/Cellar/<name>/<version>/<rest>` into
/// its keg coordinates. Prefix-agnostic: anchors on `/Cellar/` so any
/// `MALT_PREFIX` works.
pub fn resolveFromTarget(target: []const u8) ResolveError!Resolution {
    const cellar_marker = "/Cellar/";
    const idx = std.mem.indexOf(u8, target, cellar_marker) orelse
        return ResolveError.NotACellarPath;
    const after = target[idx + cellar_marker.len ..];
    const name_end = std.mem.indexOfScalar(u8, after, '/') orelse
        return ResolveError.MalformedCellarPath;
    const name = after[0..name_end];
    if (name.len == 0) return ResolveError.MalformedCellarPath;

    const ver_and_rest = after[name_end + 1 ..];
    const ver_end = std.mem.indexOfScalar(u8, ver_and_rest, '/') orelse ver_and_rest.len;
    const version = ver_and_rest[0..ver_end];
    if (version.len == 0) return ResolveError.MalformedCellarPath;

    const keg_end = idx + cellar_marker.len + name_end + 1 + ver_end;
    return .{
        .name = name,
        .version = version,
        .keg = target[0..keg_end],
    };
}

pub fn encodeJson(w: *std.Io.Writer, res: Resolution) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, res.name);
    try w.writeAll(",\"version\":");
    try output.jsonStr(w, res.version);
    try w.writeAll(",\"keg\":");
    try output.jsonStr(w, res.keg);
    try w.writeAll("}\n");
}

/// Mirror `mt info`'s installed-keg layout: bold `<name>: <version>` header
/// followed by an aligned `Keg:` field row.
pub fn encodeHuman(w: *std.Io.Writer, res: Resolution, colorize: bool) !void {
    if (colorize) try w.writeAll(color.Style.bold.code());
    try w.writeAll(res.name);
    if (colorize) try w.writeAll(color.Style.reset.code());
    try w.writeAll(": ");
    if (colorize) try w.writeAll(color.Style.bold.code());
    try w.writeAll(res.version);
    if (colorize) try w.writeAll(color.Style.reset.code());
    try w.writeAll("\n");

    // "Keg:" (4 chars + colon = 5) is the only field; widen if more land later.
    const col: usize = 5;
    var scratch: [1024]u8 = undefined;
    try output.writeField(w, &scratch, colorize, col, "Keg", "{s}", .{res.keg});
}

pub fn execute(_: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "which")) return;

    var arg: ?[]const u8 = null;
    for (args) |a| {
        if (a.len > 0 and a[0] != '-') {
            arg = a;
            break;
        }
    }
    const target_arg = arg orelse {
        output.err("Usage: mt which <name|path>", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefix();

    // Bare name -> {prefix}/bin/<name>; absolute path -> as-is. The
    // readlink result is the source of truth: the cellar path encodes
    // keg identity, so we resolve everything through it.
    var link_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const link_path = if (target_arg[0] == '/')
        target_arg
    else
        std.fmt.bufPrint(&link_buf, "{s}/bin/{s}", .{ prefix, target_arg }) catch {
            // Only triggers on a name that overflows max_path_bytes; the underlying error is OOM-ish, not informative.
            output.err("name too long: {s}", .{target_arg});
            return error.Aborted;
        };

    var target_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const link_target = fs_compat.readLinkAbsolute(link_path, &target_buf) catch {
        // Missing entry, plain file, or unreadable — all surface the same way: not owned by malt.
        output.err("{s}: not owned by malt (no symlink under {s}/bin)", .{ target_arg, prefix });
        return error.Aborted;
    };

    const res = resolveFromTarget(link_target) catch {
        // Symlink resolves but does not point into a Cellar keg — both NotACellarPath and MalformedCellarPath read the same to a user.
        output.err("{s}: symlink target {s} is not in {s}/Cellar", .{ target_arg, link_target, prefix });
        return error.Aborted;
    };

    var stdout_buf: [1024]u8 = undefined;
    var stdout_fw = io_mod.stdoutFile().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    if (output.isJson()) {
        try encodeJson(stdout, res);
    } else {
        try encodeHuman(stdout, res, color.isColorEnabled());
    }
}

// --- inline unit tests --------------------------------------------------

const testing = std.testing;

test "resolveFromTarget extracts name, version, and keg from a typical target" {
    const res = try resolveFromTarget("/opt/malt/Cellar/jq/1.7.1/bin/jq");
    try testing.expectEqualStrings("jq", res.name);
    try testing.expectEqualStrings("1.7.1", res.version);
    try testing.expectEqualStrings("/opt/malt/Cellar/jq/1.7.1", res.keg);
}

test "resolveFromTarget handles versioned formula names with @" {
    const res = try resolveFromTarget("/opt/malt/Cellar/openssl@3/3.4.0/lib/libssl.dylib");
    try testing.expectEqualStrings("openssl@3", res.name);
    try testing.expectEqualStrings("3.4.0", res.version);
    try testing.expectEqualStrings("/opt/malt/Cellar/openssl@3/3.4.0", res.keg);
}

test "resolveFromTarget honors any prefix (anchors on /Cellar/)" {
    const res = try resolveFromTarget("/tmp/mt.sandbox/Cellar/wget/1.25.0/bin/wget");
    try testing.expectEqualStrings("wget", res.name);
    try testing.expectEqualStrings("1.25.0", res.version);
    try testing.expectEqualStrings("/tmp/mt.sandbox/Cellar/wget/1.25.0", res.keg);
}

test "resolveFromTarget handles a target ending exactly at the version dir" {
    const res = try resolveFromTarget("/opt/malt/Cellar/tree/2.2.1");
    try testing.expectEqualStrings("tree", res.name);
    try testing.expectEqualStrings("2.2.1", res.version);
    try testing.expectEqualStrings("/opt/malt/Cellar/tree/2.2.1", res.keg);
}

test "resolveFromTarget rejects paths without /Cellar/" {
    try testing.expectError(ResolveError.NotACellarPath, resolveFromTarget("/usr/local/bin/jq"));
}

test "resolveFromTarget rejects a Cellar path missing the version segment" {
    try testing.expectError(ResolveError.MalformedCellarPath, resolveFromTarget("/opt/malt/Cellar/jq"));
}

test "resolveFromTarget rejects a Cellar path with empty name segment" {
    try testing.expectError(ResolveError.MalformedCellarPath, resolveFromTarget("/opt/malt/Cellar//1.0/bin/x"));
}

test "encodeJson emits {name, version, keg} in stable order" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, .{
        .name = "jq",
        .version = "1.7.1",
        .keg = "/opt/malt/Cellar/jq/1.7.1",
    });
    try testing.expectEqualStrings(
        "{\"name\":\"jq\",\"version\":\"1.7.1\",\"keg\":\"/opt/malt/Cellar/jq/1.7.1\"}\n",
        aw.written(),
    );
}

test "encodeJson escapes special characters so output stays valid JSON" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeJson(&aw.writer, .{
        .name = "weird\"name",
        .version = "1.0\\beta",
        .keg = "/odd\npath",
    });
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.trimEnd(u8, aw.written(), "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("weird\"name", parsed.value.object.get("name").?.string);
    try testing.expectEqualStrings("1.0\\beta", parsed.value.object.get("version").?.string);
    try testing.expectEqualStrings("/odd\npath", parsed.value.object.get("keg").?.string);
}

test "encodeHuman matches mt info's header+field shape" {
    // Layout: bold header `<name>: <version>`, then a `Keg:` field row
    // aligned the same way info aligns its installed-keg fields.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, .{
        .name = "jq",
        .version = "1.7.1",
        .keg = "/opt/malt/Cellar/jq/1.7.1",
    }, false);
    try testing.expectEqualStrings(
        \\jq: 1.7.1
        \\Keg: /opt/malt/Cellar/jq/1.7.1
        \\
    ,
        aw.written(),
    );
}

test "encodeHuman in colorize mode wraps name and version in bold codes" {
    // Just check the bold ANSI prefix shows up — the exact byte layout
    // matches what `output.writeFieldKey` and info's encodeHeader emit.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try encodeHuman(&aw.writer, .{
        .name = "jq",
        .version = "1.7.1",
        .keg = "/opt/malt/Cellar/jq/1.7.1",
    }, true);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "Keg:") != null);
}
