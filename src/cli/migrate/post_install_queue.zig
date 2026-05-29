//! malt — deferred post_install queue for `mt migrate`.
//!
//! Per-keg `post_install` hooks must not fire until *all* kegs in the
//! migration have been materialised AND linked into the prefix's
//! `opt/<name>/` runtime tree. fc-cache (fontconfig) loads
//! `opt/gettext/lib/libintl.8.dylib`; under `--parallel`, fontconfig's
//! own keg can finish before gettext's worker links its `opt/gettext/`
//! symlink, which produces a dyld load failure that fc-cache silently
//! swallows (exit 0) — leaving the user with a `post_install completed`
//! line but no regenerated cache.
//!
//! The queue collects post_install requests during migration and the
//! orchestrator drains it after every keg's migration (and `linkOpt`)
//! has completed. Drain order is enqueue order; since all `opt/`
//! symlinks are in place by drain time, dependency-order doesn't
//! matter for correctness.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const post_install_mod = @import("../install/post_install.zig");
const install_sink_mod = @import("../install/sink.zig");

/// Two queueable shapes share the same FIFO and drain so order across
/// bottle and tap kegs is preserved (fc-cache races care about
/// link-time order, not source-of-truth shape).
pub const Task = union(enum) {
    bottle: BottlePayload,
    tap: TapPayload,
};

pub const BottlePayload = struct {
    name: []u8,
    pkg_version: []u8,
    formula_json: []u8,
};

pub const TapPayload = struct {
    name: []u8,
    pkg_version: []u8,
    /// Body extracted from the tap's `<name>.rb`; the homebrew-core
    /// locator never sees this path, so we resolve at queue time.
    post_install_src: []u8,
};

/// Thread-safe queue: parallel workers `add`, the main thread `drain`s
/// once all workers have joined. Strings are owned by the queue's
/// allocator so they outlive per-worker arenas.
pub const Queue = struct {
    tasks: std.ArrayList(Task) = .empty,
    mu: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Queue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Queue) void {
        for (self.tasks.items) |t| switch (t) {
            .bottle => |b| {
                self.allocator.free(b.name);
                self.allocator.free(b.pkg_version);
                self.allocator.free(b.formula_json);
            },
            .tap => |tp| {
                self.allocator.free(tp.name);
                self.allocator.free(tp.pkg_version);
                self.allocator.free(tp.post_install_src);
            },
        };
        self.tasks.deinit(self.allocator);
    }

    /// Enqueue a bottle-path post_install request. Dupes inputs into
    /// the queue's allocator so the caller's arena is free to die.
    pub fn add(
        self: *Queue,
        io: std.Io,
        name: []const u8,
        pkg_version: []const u8,
        formula_json: []const u8,
    ) !void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_ver = try self.allocator.dupe(u8, pkg_version);
        errdefer self.allocator.free(owned_ver);
        const owned_json = try self.allocator.dupe(u8, formula_json);
        errdefer self.allocator.free(owned_json);

        try self.tasks.append(self.allocator, .{ .bottle = .{
            .name = owned_name,
            .pkg_version = owned_ver,
            .formula_json = owned_json,
        } });
    }

    /// Enqueue a tap-fallback post_install request. Caller owns the
    /// pre-extracted body until this returns; the queue dupes it.
    pub fn addTap(
        self: *Queue,
        io: std.Io,
        name: []const u8,
        pkg_version: []const u8,
        post_install_src: []const u8,
    ) !void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_ver = try self.allocator.dupe(u8, pkg_version);
        errdefer self.allocator.free(owned_ver);
        const owned_src = try self.allocator.dupe(u8, post_install_src);
        errdefer self.allocator.free(owned_src);

        try self.tasks.append(self.allocator, .{ .tap = .{
            .name = owned_name,
            .pkg_version = owned_ver,
            .post_install_src = owned_src,
        } });
    }

    /// Run every queued post_install through the install module's
    /// `drive`/`driveTap`. Single-threaded; called once after migration
    /// finishes so every `opt/<name>/` symlink is in place before any
    /// hook fires.
    pub fn drain(
        self: *Queue,
        ctx: *const AppCtx,
        prefix: []const u8,
        use_system_ruby_scope: []const []const u8,
    ) void {
        for (self.tasks.items) |t| switch (t) {
            .bottle => |b| post_install_mod.drive(
                ctx,
                self.allocator,
                b.name,
                b.pkg_version,
                b.formula_json,
                prefix,
                use_system_ruby_scope,
                null,
                install_sink_mod.terminal,
            ),
            .tap => |tp| post_install_mod.driveTap(
                ctx,
                self.allocator,
                tp.name,
                tp.pkg_version,
                tp.post_install_src,
                prefix,
                use_system_ruby_scope,
                install_sink_mod.terminal,
            ),
        };
    }

    /// Snapshot of queued task count — `pub` so tests can pin enqueue
    /// behaviour without reaching into private fields.
    pub fn len(self: *Queue) usize {
        return self.tasks.items.len;
    }
};

test "Queue.add dupes inputs and survives caller-arena destruction" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const name = try aa.dupe(u8, "fontconfig");
        const ver = try aa.dupe(u8, "2.17.1");
        const json = try aa.dupe(u8, "{\"name\":\"fontconfig\"}");
        try q.add(std.Options.debug_io, name, ver, json);
    }

    try std.testing.expectEqual(@as(usize, 1), q.len());
    const t = q.tasks.items[0].bottle;
    try std.testing.expectEqualStrings("fontconfig", t.name);
    try std.testing.expectEqualStrings("2.17.1", t.pkg_version);
    try std.testing.expectEqualStrings("{\"name\":\"fontconfig\"}", t.formula_json);
}

test "Queue.addTap dupes inputs and tags the task as tap-sourced" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    try q.addTap(std.Options.debug_io, "glow", "0.2.2", "bin.install \"glow\"\n");

    try std.testing.expectEqual(@as(usize, 1), q.len());
    const t = q.tasks.items[0].tap;
    try std.testing.expectEqualStrings("glow", t.name);
    try std.testing.expectEqualStrings("0.2.2", t.pkg_version);
    try std.testing.expectEqualStrings("bin.install \"glow\"\n", t.post_install_src);
}

test "Queue.add preserves enqueue order across multiple tasks" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    try q.add(std.Options.debug_io, "first", "1.0", "{}");
    try q.add(std.Options.debug_io, "second", "2.0", "{}");
    try q.add(std.Options.debug_io, "third", "3.0", "{}");

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqualStrings("first", q.tasks.items[0].bottle.name);
    try std.testing.expectEqualStrings("second", q.tasks.items[1].bottle.name);
    try std.testing.expectEqualStrings("third", q.tasks.items[2].bottle.name);
}

test "Queue interleaves bottle and tap tasks in enqueue order" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    try q.add(std.Options.debug_io, "first", "1.0", "{}");
    try q.addTap(std.Options.debug_io, "second", "2.0", "src");
    try q.add(std.Options.debug_io, "third", "3.0", "{}");

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqualStrings("first", q.tasks.items[0].bottle.name);
    try std.testing.expectEqualStrings("second", q.tasks.items[1].tap.name);
    try std.testing.expectEqualStrings("third", q.tasks.items[2].bottle.name);
}

test "Queue.add serialises concurrent producers without losing tasks" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    const Worker = struct {
        const tasks_per_thread: usize = 32;
        fn run(queue: *Queue, thread_id: usize) void {
            var buf: [64]u8 = undefined;
            var i: usize = 0;
            while (i < tasks_per_thread) : (i += 1) {
                const name = std.fmt.bufPrint(&buf, "t{d}-{d}", .{ thread_id, i }) catch return;
                queue.add(std.Options.debug_io, name, "0", "{}") catch return;
            }
        }
    };

    const thread_count: usize = 4;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*th, idx| {
        th.* = try std.Thread.spawn(.{}, Worker.run, .{ &q, idx });
    }
    for (&threads) |th| th.join();

    try std.testing.expectEqual(thread_count * Worker.tasks_per_thread, q.len());
}
