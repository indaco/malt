//! malt — info command
//! Show package info (formulas and casks).

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const cask_mod = @import("../core/cask.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "info")) return;

    // Parse flags and positional args
    var json_mode = false;
    var force_cask = false;
    var force_formula = false;
    var pkg_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--cask")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--formula")) {
            force_formula = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    const name = pkg_name orelse {
        output.err("Usage: mt info <package>", .{});
        return;
    };

    // Open DB
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return;
    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database", .{});
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    // Check formula first (unless --cask)
    var formula_installed = false;
    if (!force_cask) {
        var stmt = db.prepare(
            "SELECT name, version, tap, cellar_path, pinned, installed_at FROM kegs WHERE name = ?1 LIMIT 1;",
        ) catch return;
        defer stmt.finalize();
        stmt.bindText(1, name) catch return;

        formula_installed = stmt.step() catch false;

        if (formula_installed) {
            const stdout = std.fs.File.stdout();
            if (json_mode) {
                try writeJsonInfo(allocator, &db, name, true, &stmt, stdout);
            } else {
                try writeHumanInfo(name, true, &stmt, prefix, stdout);
            }
            return;
        }
    }

    // Check cask (unless --formula)
    if (!force_formula) {
        const cask_installed = cask_mod.lookupInstalled(&db, name);
        if (cask_installed != null) {
            const stdout = std.fs.File.stdout();
            if (json_mode) {
                try writeJsonCaskInfo(allocator, &db, name, stdout);
            } else {
                try writeHumanCaskInfo(&db, name, stdout);
            }
            return;
        }
    }

    // Not installed as either
    const stdout = std.fs.File.stdout();
    if (json_mode) {
        var stmt = db.prepare(
            "SELECT name, version, tap, cellar_path, pinned, installed_at FROM kegs WHERE name = ?1 LIMIT 1;",
        ) catch return;
        defer stmt.finalize();
        try writeJsonInfo(allocator, &db, name, false, &stmt, stdout);
    } else {
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}: not installed\n", .{name}) catch return;
        stdout.writeAll(line) catch {};
    }
}

fn writeHumanInfo(
    name: []const u8,
    installed: bool,
    stmt: *sqlite.Statement,
    prefix: []const u8,
    stdout: std.fs.File,
) !void {
    var buf: [4096]u8 = undefined;

    if (installed) {
        const ver = stmt.columnText(1);
        const tap = stmt.columnText(2);
        const cellar_path = stmt.columnText(3);
        const pinned = stmt.columnBool(4);
        const installed_at = stmt.columnText(5);

        const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "unknown";
        const tap_slice = if (tap) |t| std.mem.sliceTo(t, 0) else "N/A";
        const path_slice = if (cellar_path) |p| std.mem.sliceTo(p, 0) else "N/A";
        const date_slice = if (installed_at) |d| std.mem.sliceTo(d, 0) else "N/A";

        {
            const line = std.fmt.bufPrint(&buf, "{s}: stable {s}\n", .{ name, ver_slice }) catch return;
            stdout.writeAll(line) catch {};
        }
        {
            const line = std.fmt.bufPrint(&buf, "From: {s}\n", .{tap_slice}) catch return;
            stdout.writeAll(line) catch {};
        }
        {
            const line = std.fmt.bufPrint(&buf, "Path: {s}/Cellar/{s}/{s}\n", .{ prefix, name, ver_slice }) catch return;
            stdout.writeAll(line) catch {};
        }
        _ = path_slice;
        if (pinned) {
            stdout.writeAll("Pinned: yes\n") catch {};
        }
        {
            const line = std.fmt.bufPrint(&buf, "Installed: {s}\n", .{date_slice}) catch return;
            stdout.writeAll(line) catch {};
        }
    } else {
        const line = std.fmt.bufPrint(&buf, "{s}: not installed\n", .{name}) catch return;
        stdout.writeAll(line) catch {};
    }
}

fn writeJsonInfo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    installed: bool,
    stmt: *sqlite.Statement,
    stdout: std.fs.File,
) !void {
    _ = db;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\"name\":\"");
    try w.writeAll(name);
    try w.writeAll("\",\"type\":\"formula\",\"installed\":");
    try w.writeAll(if (installed) "true" else "false");

    if (installed) {
        const ver = stmt.columnText(1);
        const tap = stmt.columnText(2);
        const pinned = stmt.columnBool(4);
        const installed_at = stmt.columnText(5);

        try w.writeAll(",\"version\":\"");
        try w.writeAll(if (ver) |v| std.mem.sliceTo(v, 0) else "");
        try w.writeAll("\",\"tap\":\"");
        try w.writeAll(if (tap) |t| std.mem.sliceTo(t, 0) else "");
        try w.writeAll("\",\"pinned\":");
        try w.writeAll(if (pinned) "true" else "false");
        try w.writeAll(",\"installed_at\":\"");
        try w.writeAll(if (installed_at) |d| std.mem.sliceTo(d, 0) else "");
        try w.writeAll("\"");
    }

    try w.writeAll("}\n");
    stdout.writeAll(buf.items) catch {};
}

fn writeHumanCaskInfo(
    db: *sqlite.Database,
    name: []const u8,
    stdout: std.fs.File,
) !void {
    var stmt = db.prepare(
        "SELECT token, name, version, url, sha256, app_path, auto_updates, installed_at FROM casks WHERE token = ?1 LIMIT 1;",
    ) catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;

    const found = stmt.step() catch false;
    if (!found) return;

    var buf: [4096]u8 = undefined;

    const token = if (stmt.columnText(0)) |t| std.mem.sliceTo(t, 0) else name;
    const cask_name = if (stmt.columnText(1)) |n| std.mem.sliceTo(n, 0) else name;
    const ver = if (stmt.columnText(2)) |v| std.mem.sliceTo(v, 0) else "unknown";
    const url = if (stmt.columnText(3)) |u| std.mem.sliceTo(u, 0) else "N/A";
    const app_path = if (stmt.columnText(5)) |p| std.mem.sliceTo(p, 0) else "N/A";
    const auto_updates = stmt.columnBool(6);
    const installed_at = if (stmt.columnText(7)) |d| std.mem.sliceTo(d, 0) else "N/A";

    {
        const line = std.fmt.bufPrint(&buf, "{s}: {s} (cask)\n", .{ token, ver }) catch return;
        stdout.writeAll(line) catch {};
    }
    {
        const line = std.fmt.bufPrint(&buf, "Name: {s}\n", .{cask_name}) catch return;
        stdout.writeAll(line) catch {};
    }
    {
        const line = std.fmt.bufPrint(&buf, "URL: {s}\n", .{url}) catch return;
        stdout.writeAll(line) catch {};
    }
    {
        const line = std.fmt.bufPrint(&buf, "App: {s}\n", .{app_path}) catch return;
        stdout.writeAll(line) catch {};
    }
    if (auto_updates) {
        stdout.writeAll("Auto-updates: yes\n") catch {};
    }
    {
        const line = std.fmt.bufPrint(&buf, "Installed: {s}\n", .{installed_at}) catch return;
        stdout.writeAll(line) catch {};
    }
}

fn writeJsonCaskInfo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    stdout: std.fs.File,
) !void {
    var stmt = db.prepare(
        "SELECT token, name, version, url, sha256, app_path, auto_updates, installed_at FROM casks WHERE token = ?1 LIMIT 1;",
    ) catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;

    const found = stmt.step() catch false;
    if (!found) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    const token = if (stmt.columnText(0)) |t| std.mem.sliceTo(t, 0) else name;
    const cask_name = if (stmt.columnText(1)) |n| std.mem.sliceTo(n, 0) else name;
    const ver = if (stmt.columnText(2)) |v| std.mem.sliceTo(v, 0) else "";
    const url = if (stmt.columnText(3)) |u| std.mem.sliceTo(u, 0) else "";
    const app_path = if (stmt.columnText(5)) |p| std.mem.sliceTo(p, 0) else "";
    const auto_updates = stmt.columnBool(6);
    const installed_at = if (stmt.columnText(7)) |d| std.mem.sliceTo(d, 0) else "";

    try w.writeAll("{\"name\":\"");
    try w.writeAll(token);
    try w.writeAll("\",\"type\":\"cask\",\"installed\":true,\"version\":\"");
    try w.writeAll(ver);
    try w.writeAll("\",\"full_name\":\"");
    try w.writeAll(cask_name);
    try w.writeAll("\",\"url\":\"");
    try w.writeAll(url);
    try w.writeAll("\",\"app_path\":\"");
    try w.writeAll(app_path);
    try w.writeAll("\",\"auto_updates\":");
    try w.writeAll(if (auto_updates) "true" else "false");
    try w.writeAll(",\"installed_at\":\"");
    try w.writeAll(installed_at);
    try w.writeAll("\"}\n");
    stdout.writeAll(buf.items) catch {};
}
