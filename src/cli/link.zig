//! malt — link / unlink commands
//! Manage symlinks for installed kegs.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const linker_mod = @import("../core/linker.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn executeLink(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "link")) return;

    var isolate = false;
    var all_flag = false;
    var overwrite = false;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--isolate")) {
            isolate = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            all_flag = true;
        } else if (std.mem.eql(u8, arg, "--overwrite") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            overwrite = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (name == null) name = arg;
        }
    }

    if (isolate) {
        return executeLinkIsolate(ctx, allocator, name, all_flag);
    }

    const target_name = name orelse {
        output.err("Usage: mt link <formula>", .{});
        output.info("Create symlinks for an installed keg in the prefix (bin/, lib/, etc.)", .{});
        output.info("Use 'mt link --isolate <name>' to remove bin/sbin links and mark a dep isolated.", .{});
        return error.Aborted;
    };

    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    // Schema is idempotent; existing DB with current shape is the common case.
    schema.initSchema(&db) catch {};

    // Look up the keg
    var stmt = db.prepare("SELECT id, version, cellar_path FROM kegs WHERE name = ?1 LIMIT 1;") catch {
        output.err("Database query failed", .{});
        return error.Aborted;
    };
    defer stmt.finalize();
    stmt.bindText(1, target_name) catch return;

    const has_row = stmt.step() catch false;
    if (!has_row) {
        output.err("{s} is not installed", .{target_name});
        return error.Aborted;
    }

    const keg_id = stmt.columnInt(0);
    const cellar_path_raw = stmt.columnText(2) orelse {
        output.err("No cellar path recorded for {s}", .{target_name});
        return error.Aborted;
    };
    const cellar_path = std.mem.sliceTo(cellar_path_raw, 0);

    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    // Check for conflicts unless --overwrite
    if (!overwrite) {
        const conflicts = linker.checkConflicts(cellar_path, false) catch &.{};
        defer {
            // checkConflicts hands back an owned slice plus dupe'd
            // link_path / existing_keg strings; the empty-slice fallback
            // costs nothing to "free", so the loop is unconditional.
            for (conflicts) |c| {
                allocator.free(c.link_path);
                allocator.free(c.existing_keg);
            }
            if (conflicts.len > 0) allocator.free(conflicts);
        }
        if (conflicts.len > 0) {
            output.err("{s}: {d} symlink conflict(s):", .{ target_name, conflicts.len });
            for (conflicts) |c| {
                output.err("  {s} already linked by {s}", .{ c.link_path, c.existing_keg });
            }
            output.info("Use --overwrite to replace existing links.", .{});
            return error.Aborted;
        }
    }

    linker.link(cellar_path, target_name, keg_id, false) catch {
        output.err("Failed to create symlinks for {s}", .{target_name});
        return error.Aborted;
    };

    // Also create the version from DB for opt link
    var ver_stmt = db.prepare("SELECT version FROM kegs WHERE id = ?1;") catch return;
    defer ver_stmt.finalize();
    ver_stmt.bindInt(1, keg_id) catch return;
    if (ver_stmt.step() catch false) {
        if (ver_stmt.columnText(0)) |v| {
            // opt/ link is a convenience pointer; primary link.link already succeeded.
            linker.linkOpt(target_name, std.mem.sliceTo(v, 0)) catch {};
        }
    }

    // A full link materialises bin/sbin, so the row's `bin_isolated`
    // must agree with the filesystem; clear it unconditionally. Best-
    // effort: the FS work already succeeded, so on a DB write error
    // we still print success and let `mt doctor` self-heal — bailing
    // here would swallow the user-visible outcome.
    clearBinIsolated(&db, keg_id);

    output.success("{s} linked", .{target_name});
}

fn clearBinIsolated(db: *sqlite.Database, keg_id: i64) void {
    var stmt = db.prepare("UPDATE kegs SET bin_isolated = 0 WHERE id = ?1;") catch return;
    defer stmt.finalize();
    stmt.bindInt(1, keg_id) catch return;
    _ = stmt.step() catch {};
}

/// `mt link --isolate <name|--all>` — remove bin/sbin links and mark
/// the dep keg as isolated. Refuses on `install_reason='direct'`
/// kegs: a user can't accidentally hide a top-level package from
/// PATH via this verb; they'd have to uninstall first.
fn executeLinkIsolate(ctx: *const AppCtx, allocator: std.mem.Allocator, name: ?[]const u8, all_flag: bool) !void {
    if (name == null and !all_flag) {
        output.err("Usage: mt link --isolate <name>  or  mt link --isolate --all", .{});
        return error.Aborted;
    }
    if (name != null and all_flag) {
        output.err("--isolate accepts either <name> or --all, not both", .{});
        return error.Aborted;
    }

    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch {};

    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    if (all_flag) {
        var sel = db.prepare(
            "SELECT id, name FROM kegs WHERE install_reason='dependency' AND bin_isolated=0 ORDER BY name;",
        ) catch return error.Aborted;
        defer sel.finalize();

        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| allocator.free(n);
            names.deinit(allocator);
        }
        var ids: std.ArrayList(i64) = .empty;
        defer ids.deinit(allocator);

        while (sel.step() catch false) {
            const id = sel.columnInt(0);
            const nm = sel.columnText(1) orelse continue;
            const owned = allocator.dupe(u8, std.mem.sliceTo(nm, 0)) catch continue;
            names.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
            ids.append(allocator, id) catch continue;
        }

        if (names.items.len == 0) {
            output.info("No dependency kegs with linked bin/sbin to isolate.", .{});
            return;
        }

        for (names.items, ids.items) |n, id| {
            isolateOne(ctx, &db, &linker, n, id) catch {
                output.warn("could not isolate {s}", .{n});
                continue;
            };
            output.success("{s} isolated", .{n});
        }
        return;
    }

    const target = name.?;
    var sel = db.prepare("SELECT id, install_reason FROM kegs WHERE name = ?1 LIMIT 1;") catch return error.Aborted;
    defer sel.finalize();
    sel.bindText(1, target) catch return error.Aborted;

    const has = sel.step() catch false;
    if (!has) {
        output.err("{s} is not installed", .{target});
        return error.Aborted;
    }
    const keg_id = sel.columnInt(0);
    const reason_ptr = sel.columnText(1) orelse "direct";
    const reason = std.mem.sliceTo(reason_ptr, 0);
    if (!std.mem.eql(u8, reason, "dependency")) {
        output.err("{s} is a direct install — refusing to isolate. Uninstall first if you want it hidden from PATH.", .{target});
        return error.Aborted;
    }

    try isolateOne(ctx, &db, &linker, target, keg_id);
    output.success("{s} isolated: bin/sbin links removed", .{target});
}

/// Delete every bin/sbin row + filesystem symlink for one keg, then
/// stamp the row as isolated. Filesystem first so a crash leaves the
/// DB as the recoverable source of truth — matches `Linker.unlink`'s
/// posture.
fn isolateOne(
    ctx: *const AppCtx,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    name: []const u8,
    keg_id: i64,
) !void {
    _ = name;
    _ = linker;

    var sel = try db.prepare(
        "SELECT link_path FROM links WHERE keg_id = ?1 AND (link_path LIKE '%/bin/%' OR link_path LIKE '%/sbin/%');",
    );
    defer sel.finalize();
    try sel.bindInt(1, keg_id);
    while (try sel.step()) {
        const p = sel.columnText(0) orelse continue;
        std.Io.Dir.cwd().deleteFile(ctx.io, std.mem.sliceTo(p, 0)) catch {};
    }

    var del = try db.prepare(
        "DELETE FROM links WHERE keg_id = ?1 AND (link_path LIKE '%/bin/%' OR link_path LIKE '%/sbin/%');",
    );
    defer del.finalize();
    try del.bindInt(1, keg_id);
    _ = try del.step();

    var upd = try db.prepare("UPDATE kegs SET bin_isolated = 1 WHERE id = ?1;");
    defer upd.finalize();
    try upd.bindInt(1, keg_id);
    _ = try upd.step();
}

pub fn executeUnlink(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "unlink")) return;

    if (args.len == 0) {
        output.err("Usage: mt unlink <formula>", .{});
        output.info("Remove symlinks for an installed keg from the prefix.", .{});
        output.info("The keg remains installed in the Cellar.", .{});
        return error.Aborted;
    }

    const name = args[0];
    const prefix = atomic.maltPrefixOrAbort();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    // Schema is idempotent; existing DB with current shape is the common case.
    schema.initSchema(&db) catch {};

    // Look up the keg
    var stmt = db.prepare("SELECT id FROM kegs WHERE name = ?1 LIMIT 1;") catch {
        output.err("Database query failed", .{});
        return error.Aborted;
    };
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;

    const has_row = stmt.step() catch false;
    if (!has_row) {
        output.err("{s} is not installed", .{name});
        return error.Aborted;
    }

    const keg_id = stmt.columnInt(0);

    var linker = linker_mod.Linker.init(ctx.io, allocator, &db, prefix);

    linker.unlink(keg_id) catch {
        output.err("Failed to remove symlinks for {s}", .{name});
        return error.Aborted;
    };

    // Also remove opt/ symlink
    var opt_buf: [512]u8 = undefined;
    const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch return;
    std.Io.Dir.cwd().deleteFile(ctx.io, opt_path) catch {}; // opt/ link absent on never-linked kegs

    output.success("{s} unlinked (keg remains installed)", .{name});
}
