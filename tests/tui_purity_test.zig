//! Pin test: `src/tui/` is a leaf. Every `@import` in it must resolve only to
//! `std`, `ui/color.zig`, or `ui/term_sanitize.zig` — never `cli/*`, `core/*`,
//! `db/*`, `net/*`, `main.zig`, or `app_ctx.zig`. The TUI pressure-tests the
//! `--json` contract instead of reaching across module boundaries.

const std = @import("std");
const testing = std.testing;

const test_io = @import("test_io");

const scanned_root = "src/tui";
const import_prefix = "@import(\"";

test "src/tui/* imports only std + the allowed ui helpers" {
    const io = std.Options.debug_io;

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    try scanRoot(io, scanned_root, &failures);

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.TuiLeafViolated;
    }
}

fn scanRoot(io: std.Io, root: []const u8, failures: *std.ArrayList([]const u8)) !void {
    var dir = try test_io.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const content = try testing.allocator.alloc(u8, @intCast(stat.size));
        defer testing.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        try scanContent(root, entry.path, content, failures);
    }
}

fn scanContent(
    root: []const u8,
    rel_path: []const u8,
    content: []const u8,
    failures: *std.ArrayList([]const u8),
) !void {
    // The importing file's directory, repo-relative, so an import resolves the
    // same way the compiler sees it (`src/tui/json/list.zig` → `src/tui/json`).
    var dir_buf: [256]u8 = undefined;
    const importer_dir = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |slash|
        std.fmt.bufPrint(&dir_buf, "{s}/{s}", .{ root, rel_path[0..slash] }) catch root
    else
        root;

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, import_prefix)) |start| {
        const path_start = start + import_prefix.len;
        const end = std.mem.indexOfScalarPos(u8, content, path_start, '"') orelse break;
        const import_path = content[path_start..end];
        cursor = end + 1;

        if (!importAllowed(importer_dir, import_path)) {
            const msg = try std.fmt.allocPrint(
                testing.allocator,
                "{s}/{s} imports forbidden \"{s}\"",
                .{ root, rel_path, import_path },
            );
            try failures.append(testing.allocator, msg);
        }
    }
}

/// The leaf whitelist. `std` is the only bare import; otherwise the path is
/// resolved against `importer_dir` (repo-relative) and allowed iff it lands
/// inside the leaf root, or is exactly one of the two read-only ui helpers.
/// Resolving against the importer's dir is what makes subdirectories
/// (`src/tui/json/`) safe — a `../../ui/color.zig` from there is the helper, a
/// `../../cli/list.zig` is an outward reach.
fn importAllowed(importer_dir: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, path, "std")) return true;
    var buf: [256]u8 = undefined;
    const resolved = resolvePosix(&buf, importer_dir, path) orelse return false;
    // Inside the leaf root → intra-leaf composition, always allowed.
    if (std.mem.startsWith(u8, resolved, scanned_root ++ "/")) return true;
    // Otherwise only the read-only ui helpers may be reached.
    return std.mem.eql(u8, resolved, "src/ui/color.zig") or
        std.mem.eql(u8, resolved, "src/ui/term_sanitize.zig") or
        std.mem.eql(u8, resolved, "src/ui/termsize.zig") or
        std.mem.eql(u8, resolved, "src/ui/term_restore.zig") or
        std.mem.eql(u8, resolved, "src/ui/spinner_frames.zig");
}

/// Normalise `rel` against `base` into a repo-relative POSIX path, collapsing
/// `.`/`..` segments. Returns null only if the buffer is too small (paths here
/// are short). `..` past the root just empties the accumulator.
fn resolvePosix(buf: []u8, base: []const u8, rel: []const u8) ?[]const u8 {
    if (base.len > buf.len) return null;
    @memcpy(buf[0..base.len], base);
    var len: usize = base.len;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            len = if (std.mem.lastIndexOfScalar(u8, buf[0..len], '/')) |slash| slash else 0;
            continue;
        }
        if (len + 1 + seg.len > buf.len) return null;
        if (len != 0) {
            buf[len] = '/';
            len += 1;
        }
        @memcpy(buf[len..][0..seg.len], seg);
        len += seg.len;
    }
    return buf[0..len];
}

// `importAllowed` resolves an import *relative to the importing file's directory*
// so the leaf rule survives subdirectories (`src/tui/json/`). The single-arg
// `isAllowedImport` can't see the importer's dir, so a `json/list.zig` import
// reads as an outward `/` reach; the resolver settles it correctly.

test "importAllowed permits std and intra-leaf siblings at the root" {
    try testing.expect(importAllowed("src/tui", "std"));
    try testing.expect(importAllowed("src/tui", "scroll_list.zig"));
    try testing.expect(importAllowed("src/tui", "tab.zig"));
}

test "importAllowed permits a subdirectory sibling and the ui helpers from a subdir" {
    try testing.expect(importAllowed("src/tui", "json/list.zig")); // root → subdir
    try testing.expect(importAllowed("src/tui/json", "list.zig")); // within the subdir
    try testing.expect(importAllowed("src/tui/json", "../../ui/color.zig"));
    try testing.expect(importAllowed("src/tui/json", "../../ui/term_sanitize.zig"));
}

test "importAllowed permits the shared termsize leaf" {
    try testing.expect(importAllowed("src/tui", "../ui/termsize.zig"));
    try testing.expect(importAllowed("src/tui/json", "../../ui/termsize.zig"));
}

test "importAllowed permits the shared term_restore leaf" {
    try testing.expect(importAllowed("src/tui", "../ui/term_restore.zig"));
    try testing.expect(importAllowed("src/tui/json", "../../ui/term_restore.zig"));
}

test "importAllowed permits the shared spinner_frames leaf" {
    try testing.expect(importAllowed("src/tui", "../ui/spinner_frames.zig"));
    try testing.expect(importAllowed("src/tui/json", "../../ui/spinner_frames.zig"));
}

test "importAllowed rejects an outward reach from any depth" {
    try testing.expect(!importAllowed("src/tui", "../cli/list.zig"));
    try testing.expect(!importAllowed("src/tui", "../core/store.zig"));
    try testing.expect(!importAllowed("src/tui", "../app_ctx.zig"));
    try testing.expect(!importAllowed("src/tui", "../ui/output.zig")); // not whitelisted
    try testing.expect(!importAllowed("src/tui/json", "../../cli/list.zig"));
}
