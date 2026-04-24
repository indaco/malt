//! malt — link / unlink commands
//! Manage symlinks for installed kegs.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const linker_mod = @import("../core/linker.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub fn executeLink(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "link")) return;

    if (args.len == 0) {
        output.err("Usage: mt link <formula>", .{});
        output.info("Create symlinks for an installed keg in the prefix (bin/, lib/, etc.)", .{});
        return error.Aborted;
    }

    const name = args[0];
    var overwrite = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--overwrite") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) overwrite = true;
    }

    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
    schema.initSchema(&db) catch {};

    // Look up the keg
    var stmt = db.prepare("SELECT id, version, cellar_path FROM kegs WHERE name = ?1 LIMIT 1;") catch {
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
    const cellar_path_raw = stmt.columnText(2) orelse {
        output.err("No cellar path recorded for {s}", .{name});
        return error.Aborted;
    };
    const cellar_path = std.mem.sliceTo(cellar_path_raw, 0);
    var linker = linker_mod.Linker.init(allocator, &db, prefix);

    // Check for conflicts unless --overwrite
    if (!overwrite) {
        const conflicts = linker.checkConflicts(cellar_path) catch &.{};
        if (conflicts.len > 0) {
            output.err("{s}: {d} symlink conflict(s):", .{ name, conflicts.len });
            for (conflicts) |c| {
                output.err("  {s} already linked by {s}", .{ c.link_path, c.existing_keg });
            }
            output.info("Use --overwrite to replace existing links.", .{});
            return error.Aborted;
        }
    }

    linker.link(cellar_path, name, keg_id) catch {
        output.err("Failed to create symlinks for {s}", .{name});
        return error.Aborted;
    };

    // Also create the version from DB for opt link
    var ver_stmt = db.prepare("SELECT version FROM kegs WHERE id = ?1;") catch return;
    defer ver_stmt.finalize();
    ver_stmt.bindInt(1, keg_id) catch return;
    if (ver_stmt.step() catch false) {
        if (ver_stmt.columnText(0)) |v| {
            linker.linkOpt(name, std.mem.sliceTo(v, 0)) catch {};
        }
    }

    output.success("{s} linked", .{name});
}

pub fn executeUnlink(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "unlink")) return;

    if (args.len == 0) {
        output.err("Usage: mt unlink <formula>", .{});
        output.info("Remove symlinks for an installed keg from the prefix.", .{});
        output.info("The keg remains installed in the Cellar.", .{});
        return error.Aborted;
    }

    const name = args[0];
    const prefix = atomic.maltPrefix();

    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return error.Aborted;
    };
    defer db.close();
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
    var linker = linker_mod.Linker.init(allocator, &db, prefix);

    linker.unlink(keg_id) catch {
        output.err("Failed to remove symlinks for {s}", .{name});
        return error.Aborted;
    };

    // Also remove opt/ symlink
    var opt_buf: [512]u8 = undefined;
    const opt_path = std.fmt.bufPrint(&opt_buf, "{s}/opt/{s}", .{ prefix, name }) catch return;
    fs_compat.cwd().deleteFile(opt_path) catch {}; // intentional: may not exist

    output.success("{s} unlinked (keg remains installed)", .{name});
}
