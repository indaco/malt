//! malt — locate and securely read the user theme file.
//!
//! This is the *only* place that touches the filesystem for custom themes, and
//! it lives in `fs` (below `ui`) so the ui layer keeps its zero-dependency-on-fs
//! shape: the caller hands the resulting bytes to `ui/color`, which never sees a
//! path or a file handle. Hardening: a `validatePrefix`-style path check, a
//! leaf-symlink refusal, a regular-file check on the opened fd, and a size cap.
//! Anything off-pattern returns null and the caller keeps the built-in themes.

const std = @import("std");
const atomic = @import("atomic.zig");
const prefix_path = @import("prefix_path.zig");

const default_suffix = "/etc/malt/themes.json";

/// Resolve the theme file path: `MALT_THEMES_FILE` if set, else
/// `{MALT_PREFIX}/etc/malt/themes.json`. Both env paths pass the same tight
/// `validatePrefix` check (absolute, NUL-free, no `..`, bounded charset); a bad
/// value resolves to null so the loader simply keeps built-ins. The default is
/// written into `buf`.
fn resolvePath(environ: std.process.Environ, buf: []u8) ?[]const u8 {
    if (environ.getPosix("MALT_THEMES_FILE")) |f| {
        prefix_path.validatePrefix(f) catch return null;
        return f;
    }
    const prefix = environ.getPosix("MALT_PREFIX") orelse "/opt/malt";
    prefix_path.validatePrefix(prefix) catch return null;
    return std.fmt.bufPrint(buf, "{s}" ++ default_suffix, .{prefix}) catch return null;
}

/// Read the user theme file into `buf`, or null when there is nothing safe to
/// read (missing file, symlinked leaf, non-regular file, oversized, or any IO
/// error). Never throws: a missing file is the common case, not an error. The
/// returned slice aliases `buf`; the caller sizes `buf` to its accepted maximum.
pub fn read(io: std.Io, environ: std.process.Environ, buf: []u8) ?[]const u8 {
    var path_buf: [atomic.max_prefix_len + default_suffix.len]u8 = undefined;
    const path = resolvePath(environ, &path_buf) orelse return null;

    // `std.Io` exposes no `O_NOFOLLOW` on the open path, so we lstat the leaf
    // through its parent dir with `follow_symlinks = false`: a symlink then
    // reports `kind == .sym_link` and is refused, as are a directory, fifo,
    // device, or missing file. Operating relative to the opened parent fd also
    // pins the directory for the open that follows.
    const dir_path = std.fs.path.dirname(path) orelse return null;
    const base = std.fs.path.basename(path);
    var parent = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return null;
    defer parent.close(io);

    const lst = parent.statFile(io, base, .{ .follow_symlinks = false }) catch return null;
    if (lst.kind != .file) return null;
    if (lst.size > buf.len) return null;

    // Open and fd re-stat: the file must still be the same regular inode the
    // lstat saw. The inode match closes the lstat→open swap window the missing
    // `O_NOFOLLOW` would otherwise leave.
    const file = parent.openFile(io, base, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    const fst = file.stat(io) catch return null;
    if (fst.kind != .file or fst.inode != lst.inode or fst.size > buf.len) return null;

    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const dbg_io = std.Options.debug_io;

fn envSlice(comptime kvs: anytype) std.process.Environ {
    return .{ .block = .{ .slice = kvs } };
}

test "resolvePath returns an explicit, valid MALT_THEMES_FILE verbatim" {
    var buf: [600]u8 = undefined;
    const env = envSlice(&[_:null]?[*:0]const u8{"MALT_THEMES_FILE=/opt/malt/etc/malt/custom.json"});
    try testing.expectEqualStrings("/opt/malt/etc/malt/custom.json", resolvePath(env, &buf).?);
}

test "resolvePath rejects a non-absolute, traversal, or disallowed MALT_THEMES_FILE" {
    var buf: [600]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), resolvePath(envSlice(&[_:null]?[*:0]const u8{"MALT_THEMES_FILE=etc/themes.json"}), &buf)); // relative
    try testing.expectEqual(@as(?[]const u8, null), resolvePath(envSlice(&[_:null]?[*:0]const u8{"MALT_THEMES_FILE=/opt/malt/../etc/themes.json"}), &buf)); // traversal
    try testing.expectEqual(@as(?[]const u8, null), resolvePath(envSlice(&[_:null]?[*:0]const u8{"MALT_THEMES_FILE=/opt/ malt/themes.json"}), &buf)); // space (disallowed byte)
}

test "resolvePath builds the default path under a valid prefix" {
    var buf: [600]u8 = undefined;
    const env = envSlice(&[_:null]?[*:0]const u8{"MALT_PREFIX=/opt/malt"});
    try testing.expectEqualStrings("/opt/malt/etc/malt/themes.json", resolvePath(env, &buf).?);
}

test "resolvePath falls back to /opt/malt when MALT_PREFIX is unset" {
    var buf: [600]u8 = undefined;
    const env = envSlice(&[_:null]?[*:0]const u8{});
    try testing.expectEqualStrings("/opt/malt/etc/malt/themes.json", resolvePath(env, &buf).?);
}

test "resolvePath rejects a malformed MALT_PREFIX" {
    var buf: [600]u8 = undefined;
    const env = envSlice(&[_:null]?[*:0]const u8{"MALT_PREFIX=relative/prefix"});
    try testing.expectEqual(@as(?[]const u8, null), resolvePath(env, &buf));
}

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(dbg_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        try std.Io.Dir.createDirAbsolute(dbg_io, base, .default_dir);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

/// Runtime `MALT_THEMES_FILE=<path>` environment block. The scratch paths are
/// only known at run time, so `envSlice`'s comptime literals cannot be used.
/// Storage lives in the caller's frame for as long as the returned block.
const ThemesEnv = struct {
    buf: [std.fs.max_path_bytes + 32]u8 = undefined,
    entries: [1:null]?[*:0]const u8 = undefined,

    fn env(self: *ThemesEnv, path: []const u8) !std.process.Environ {
        const kv = try std.fmt.bufPrintSentinel(&self.buf, "MALT_THEMES_FILE={s}", .{path}, 0);
        self.entries = .{kv.ptr};
        return .{ .block = .{ .slice = &self.entries } };
    }
};

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(dbg_io, path, .{});
    defer f.close(dbg_io);
    try f.writeStreamingAll(dbg_io, bytes);
}

test "read returns the bytes of a valid regular themes file" {
    var s = try Scratch.init("theme_file_valid");
    defer s.deinit();
    const path = s.p("/themes.json");
    try writeFile(path, "{\"version\":1}");

    var te: ThemesEnv = .{};
    const env = try te.env(path);
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings("{\"version\":1}", read(dbg_io, env, &buf).?);
}

test "read returns null for a missing file (not an error)" {
    var s = try Scratch.init("theme_file_absent");
    defer s.deinit();
    var te: ThemesEnv = .{};
    const env = try te.env(s.p("/absent.json"));
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), read(dbg_io, env, &buf));
}

test "read refuses a symlinked leaf" {
    var s = try Scratch.init("theme_file_symlink");
    defer s.deinit();
    const target = s.p("/real.json");
    const link = s.p("/themes.json");
    try writeFile(target, "{\"version\":1}");
    try std.Io.Dir.symLinkAbsolute(dbg_io, target, link, .{});

    var te: ThemesEnv = .{};
    const env = try te.env(link);
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), read(dbg_io, env, &buf));
}

test "read refuses a file larger than the caller's cap" {
    var s = try Scratch.init("theme_file_oversize");
    defer s.deinit();
    const path = s.p("/themes.json");
    try writeFile(path, "x" ** 64); // 64 bytes

    var te: ThemesEnv = .{};
    const env = try te.env(path);
    var small: [16]u8 = undefined; // cap below the file size
    try testing.expectEqual(@as(?[]const u8, null), read(dbg_io, env, &small));
}

test "read refuses a non-regular file (a directory)" {
    var s = try Scratch.init("theme_file_dir");
    defer s.deinit();
    const dir = s.p("/themes.json");
    try std.Io.Dir.createDirAbsolute(dbg_io, dir, .default_dir);

    var te: ThemesEnv = .{};
    const env = try te.env(dir);
    var buf: [4096]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), read(dbg_io, env, &buf));
}
