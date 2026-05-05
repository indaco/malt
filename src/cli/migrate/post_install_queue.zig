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
const post_install_mod = @import("../install/post_install.zig");
const AppCtx = @import("../../app_ctx.zig").AppCtx;

pub const Task = struct {
    name: []u8,
    pkg_version: []u8,
    formula_json: []u8,
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
        for (self.tasks.items) |t| {
            self.allocator.free(t.name);
            self.allocator.free(t.pkg_version);
            self.allocator.free(t.formula_json);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Enqueue a post_install request. Dupes inputs into the queue's
    /// allocator so the caller's arena is free to die. Thread-safe.
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

        try self.tasks.append(self.allocator, .{
            .name = owned_name,
            .pkg_version = owned_ver,
            .formula_json = owned_json,
        });
    }

    /// Run every queued post_install through the install module's
    /// `drive`. Single-threaded; called once after migration finishes.
    pub fn drain(
        self: *Queue,
        ctx: *const AppCtx,
        prefix: []const u8,
        use_system_ruby_scope: []const []const u8,
    ) void {
        for (self.tasks.items) |t| {
            post_install_mod.drive(
                ctx,
                self.allocator,
                t.name,
                t.pkg_version,
                t.formula_json,
                prefix,
                use_system_ruby_scope,
            );
        }
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
    try std.testing.expectEqualStrings("fontconfig", q.tasks.items[0].name);
    try std.testing.expectEqualStrings("2.17.1", q.tasks.items[0].pkg_version);
    try std.testing.expectEqualStrings("{\"name\":\"fontconfig\"}", q.tasks.items[0].formula_json);
}

test "Queue.add preserves enqueue order across multiple tasks" {
    const a = std.testing.allocator;
    var q = Queue.init(a);
    defer q.deinit();

    try q.add(std.Options.debug_io, "first", "1.0", "{}");
    try q.add(std.Options.debug_io, "second", "2.0", "{}");
    try q.add(std.Options.debug_io, "third", "3.0", "{}");

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqualStrings("first", q.tasks.items[0].name);
    try std.testing.expectEqualStrings("second", q.tasks.items[1].name);
    try std.testing.expectEqualStrings("third", q.tasks.items[2].name);
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
