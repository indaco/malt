//! malt — uses command
//! Show installed packages that depend on a given formula.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const color = @import("../ui/color.zig");
const cli_info = @import("info.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "uses")) return;

    // Parse flags. `--json` is consumed by the global parser and read
    // off the `output` module, mirroring the pattern in `info`.
    var recursive = false;
    var target: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--recursive") or std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (target == null) target = arg;
        }
    }

    const name = target orelse {
        output.err("Usage: mt uses <formula>", .{});
        return error.Aborted;
    };

    const json_mode = output.isJson();

    const prefix = atomic.maltPrefix();
    var db_opt: ?sqlite.Database = cli_info.openDb(prefix);
    defer if (db_opt) |*d| d.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    defer stdout.flush() catch {};

    // Without a local DB nothing is installed, so nothing can "use"
    // anything. Emit an empty result in the shape each mode expects
    // rather than erroring — same graceful-degradation contract as
    // `mt info` on a fresh prefix.
    var dependents: [][]const u8 = &.{};
    defer freeDependents(allocator, dependents);

    if (db_opt) |*db| {
        schema.initSchema(db) catch {};
        dependents = collectDependents(allocator, db, name, recursive) catch &.{};
    }

    if (json_mode) {
        try writeJson(allocator, stdout, name, dependents);
    } else {
        try writeHuman(stdout, name, dependents);
    }
}

/// Walk the dependencies table to collect every installed keg that
/// directly (or transitively, if `recursive`) depends on `target`.
/// The returned slice is caller-owned; each element is an
/// `allocator.dupe`'d copy of the keg name, so the caller must free
/// both the slice and every entry.
pub fn collectDependents(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    target: []const u8,
    recursive: bool,
) ![][]const u8 {
    var names: std.StringHashMap(void) = .init(allocator);
    defer names.deinit();

    // Frontier borrows: root from caller's `target`, rest from
    // `names`-owned keys. One dupe per unique name, not two.
    var frontier: std.ArrayList([]const u8) = .empty;
    defer frontier.deinit(allocator);
    try frontier.append(allocator, target);

    // Peak ~2× max-in-flight: compact live tail to front once half-consumed.
    var head: usize = 0;
    while (head < frontier.items.len) {
        if (head > 0 and head * 2 >= frontier.items.len) {
            const live = frontier.items[head..];
            std.mem.copyForwards([]const u8, frontier.items[0..live.len], live);
            frontier.items.len = live.len;
            head = 0;
        }
        const current = frontier.items[head];
        head += 1;

        var stmt = db.prepare(
            "SELECT k.name FROM kegs k " ++
                "JOIN dependencies d ON d.keg_id = k.id " ++
                "WHERE d.dep_name = ?1 ORDER BY k.name;",
        ) catch continue;
        defer stmt.finalize();
        stmt.bindText(1, current) catch continue;

        while (stmt.step() catch false) {
            const raw = stmt.columnText(0) orelse continue;
            const dep = std.mem.sliceTo(raw, 0);
            if (names.contains(dep)) continue;

            const owned = try allocator.dupe(u8, dep);
            {
                // Scoped so the errdefer only covers the put itself;
                // past here `owned` is borrowed by `names`.
                errdefer allocator.free(owned);
                try names.put(owned, {});
            }
            if (recursive) try frontier.append(allocator, owned);
        }
    }

    // Sort the keys for deterministic output — both CLI readability
    // and test assertions depend on it. StringHashMap iteration
    // order is unspecified.
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeDependents(allocator, out.items);
    try out.ensureTotalCapacity(allocator, names.count());
    var it = names.keyIterator();
    while (it.next()) |k| try out.append(allocator, k.*);
    std.mem.sort([]const u8, out.items, {}, lessThanSlice);
    return out.toOwnedSlice(allocator);
}

fn lessThanSlice(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Free a slice produced by `collectDependents`: both the outer slice
/// and every name it holds.
pub fn freeDependents(allocator: std.mem.Allocator, deps: [][]const u8) void {
    for (deps) |d| allocator.free(d);
    allocator.free(deps);
}

pub fn writeHuman(stdout: *std.Io.Writer, target: []const u8, dependents: [][]const u8) !void {
    if (dependents.len == 0) {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buf,
            "No installed formula uses {s}.\n",
            .{target},
        ) catch return;
        stdout.writeAll(line) catch return;
        return;
    }
    const use_color = color.isColorEnabled();
    for (dependents) |d| {
        if (use_color) stdout.writeAll(color.Style.cyan.code()) catch return;
        stdout.writeAll("  \xe2\x96\xb8 ") catch return;
        if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
        stdout.writeAll(d) catch return;
        stdout.writeAll("\n") catch return;
    }
}

pub fn writeJson(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    target: []const u8,
    dependents: [][]const u8,
) !void {
    _ = allocator;
    try encodeJson(stdout, target, dependents);
}

/// Pure encoder: emits `{"formula":"<target>","uses":["a","b"]}\n`.
/// Exposed for tests so the output shape can be asserted without a
/// live file descriptor.
pub fn encodeJson(w: anytype, target: []const u8, dependents: [][]const u8) !void {
    try w.writeAll("{\"formula\":");
    try output.jsonStr(w, target);
    try w.writeAll(",\"uses\":[");
    for (dependents, 0..) |d, i| {
        if (i != 0) try w.writeAll(",");
        try output.jsonStr(w, d);
    }
    try w.writeAll("]}\n");
}
