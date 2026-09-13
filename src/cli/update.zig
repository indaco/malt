//! malt — update command
//! Wipe the metadata cache (default) or refresh the outdated snapshot (`--check`).

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const atomic = @import("../fs/atomic.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const schema_report = @import("schema_report.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const outdated_mod = @import("outdated.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const UpdateError = error{ Aborted, SchemaTooNew } || std.mem.Allocator.Error;

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) UpdateError!void {
    if (help.showIfRequested(ctx, args, "update")) return;

    var check_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        }
    }

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return error.Aborted;
    };
    defer allocator.free(cache_dir);

    if (check_only) {
        // Offline mode means no network — refusing here is the kind
        // "we can't do this, but you knew that" message the task doc
        // calls for, ahead of any HTTP attempt that would fail anyway.
        if (ctx.offline) {
            output.err("offline mode: `mt update --check` requires network access.", .{});
            return error.Aborted;
        }
        refreshSnapshot(ctx, allocator, cache_dir) catch |e| switch (e) {
            // Already reported at the source; keep the code so `main` maps it.
            error.SchemaTooNew, error.Aborted => |known| return known,
            else => {
                reportCheckFailure(e);
                return error.Aborted;
            },
        };
        output.info("Outdated snapshot refreshed.", .{});
        return;
    }

    // Stays sub-100ms: wipe API cache + invalidate snapshot; the next
    // `mt outdated` recomputes against the new world.
    var api_buf: [512]u8 = undefined;
    if (std.fmt.bufPrint(&api_buf, "{s}/api", .{cache_dir})) |api_path| {
        std.Io.Dir.cwd().deleteTree(ctx.io, api_path) catch {};
    } else |_| {}

    invalidateSnapshot(ctx, allocator, cache_dir);

    output.info("Cache cleared. Metadata will be re-fetched on next operation.", .{});
}

/// Best-effort: deleting is safe because the next read recomputes; worst
/// case is one extra audit. Note the snapshot has two readers and only one
/// filters through the live DB — `mt outdated` intersects, the TUI's warm
/// read parses raw — so a leftover snapshot is *not* self-correcting for
/// the TUI. Deletion here sidesteps that; producers that keep the file must
/// reconcile it themselves.
fn invalidateSnapshot(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8) void {
    const path = outdated_mod.snapshotPath(allocator, cache_dir) catch return;
    defer allocator.free(path);
    std.Io.Dir.deleteFileAbsolute(ctx.io, path) catch {};
}

/// An unverified audit is an expected outcome (offline upstream), not an
/// internal failure, so it gets the same words `mt outdated` uses.
fn reportCheckFailure(e: anyerror) void {
    switch (e) {
        error.AuditIncomplete => output.err(outdated_mod.audit_incomplete_msg, .{}),
        else => output.err("Failed to refresh outdated snapshot: {s}", .{@errorName(e)}),
    }
}

fn refreshSnapshot(ctx: *const AppCtx, allocator: std.mem.Allocator, cache_dir: []const u8) !void {
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return error.Aborted;

    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix: write an empty snapshot so readers get instant "all clear".
        try outdated_mod.writeSnapshotEntries(ctx, allocator, cache_dir, &.{}, &.{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch |e| return schema_report.abortInitFailure(&db, e, prefix);

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;
    var api = api_mod.BrewApi.init(ctx.io, allocator, &http, cache_dir);
    api.base_url = ctx.mirrors.api_base;
    api.offline = ctx.offline;

    try outdated_mod.refreshSnapshot(ctx, allocator, &db, &api, cache_dir, null);
}

test "reportCheckFailure names an unverified audit in plain words, other errors by name" {
    var err_buf: std.ArrayList(u8) = .empty;
    defer err_buf.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &err_buf);
    defer output.endStderrCapture();

    reportCheckFailure(error.AuditIncomplete);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.items, "Could not verify every package") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.items, "AuditIncomplete") == null);

    err_buf.clearRetainingCapacity();
    reportCheckFailure(error.ConnectionRefused);
    try std.testing.expect(std.mem.indexOf(u8, err_buf.items, "ConnectionRefused") != null);
}
