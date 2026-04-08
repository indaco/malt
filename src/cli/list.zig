//! malt — list command
//! List installed packages.

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const color = @import("../ui/color.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "list")) return;

    // Parse flags
    var show_formula = false;
    var show_cask = false;
    var show_versions = false;
    var show_pinned = false;
    var json_mode = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            show_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            show_cask = true;
        } else if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "--version")) {
            show_versions = true;
        } else if (std.mem.eql(u8, arg, "--pinned")) {
            show_pinned = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        }
    }

    // If neither specified, show both
    if (!show_formula and !show_cask) {
        show_formula = true;
        show_cask = true;
    }

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

    const stdout = std.fs.File.stdout();

    if (json_mode) {
        try writeJsonOutput(allocator, &db, show_formula, show_cask, show_pinned, stdout);
    } else {
        try writeHumanOutput(&db, show_formula, show_cask, show_versions, show_pinned, stdout);
    }
}

fn writeHumanOutput(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    stdout: std.fs.File,
) !void {
    if (show_formula) {
        const sql = if (show_pinned)
            "SELECT name, version, pinned FROM kegs WHERE pinned = 1 ORDER BY name;"
        else
            "SELECT name, version, pinned FROM kegs ORDER BY name;";

        var stmt = db.prepare(sql) catch return;
        defer stmt.finalize();

        while (stmt.step() catch false) {
            const name = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const pinned = stmt.columnBool(2);
            const name_slice = std.mem.sliceTo(name, 0);

            if (color.isColorEnabled()) {
                stdout.writeAll(color.Style.cyan.code()) catch {};
                stdout.writeAll("  ▸ ") catch {};
                stdout.writeAll(color.Style.reset.code()) catch {};
            } else {
                stdout.writeAll("  ▸ ") catch {};
            }
            stdout.writeAll(name_slice) catch {};
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                const use_color = color.isColorEnabled();
                if (use_color) stdout.writeAll(color.Style.dim.code()) catch {};
                stdout.writeAll(" (") catch {};
                stdout.writeAll(ver_slice) catch {};
                stdout.writeAll(")") catch {};
                if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
            }
            if (pinned) {
                const use_color = color.isColorEnabled();
                if (use_color) stdout.writeAll(color.Style.yellow.code()) catch {};
                stdout.writeAll(" [pinned]") catch {};
                if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
            }
            stdout.writeAll("\n") catch {};
        }
    }

    if (show_cask) {
        const sql = "SELECT token, version FROM casks ORDER BY token;";
        var stmt = db.prepare(sql) catch return;
        defer stmt.finalize();

        while (stmt.step() catch false) {
            const token = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const token_slice = std.mem.sliceTo(token, 0);

            if (color.isColorEnabled()) {
                stdout.writeAll(color.Style.cyan.code()) catch {};
                stdout.writeAll("  ▸ ") catch {};
                stdout.writeAll(color.Style.reset.code()) catch {};
            } else {
                stdout.writeAll("  ▸ ") catch {};
            }
            stdout.writeAll(token_slice) catch {};
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                const use_color = color.isColorEnabled();
                if (use_color) stdout.writeAll(color.Style.dim.code()) catch {};
                stdout.writeAll(" (") catch {};
                stdout.writeAll(ver_slice) catch {};
                stdout.writeAll(")") catch {};
                if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
            }
            stdout.writeAll("\n") catch {};
        }
    }
}

fn writeJsonOutput(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    stdout: std.fs.File,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{");

    if (show_formula) {
        try w.writeAll("\"formulae\":[");
        const sql = if (show_pinned)
            "SELECT name, version, pinned FROM kegs WHERE pinned = 1 ORDER BY name;"
        else
            "SELECT name, version, pinned FROM kegs ORDER BY name;";

        var stmt = db.prepare(sql) catch {
            try w.writeAll("]");
            if (show_cask) try w.writeAll(",\"casks\":[]");
            try w.writeAll("}\n");
            stdout.writeAll(buf.items) catch {};
            return;
        };
        defer stmt.finalize();

        var first = true;
        while (stmt.step() catch false) {
            const name = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const pinned = stmt.columnBool(2);
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"name\":\"");
            try w.writeAll(std.mem.sliceTo(name, 0));
            try w.writeAll("\",\"version\":\"");
            try w.writeAll(if (ver) |v| std.mem.sliceTo(v, 0) else "");
            try w.writeAll("\",\"pinned\":");
            try w.writeAll(if (pinned) "true" else "false");
            try w.writeAll("}");
        }
        try w.writeAll("]");
    }

    if (show_cask) {
        if (show_formula) try w.writeAll(",");
        try w.writeAll("\"casks\":[");
        var stmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch {
            try w.writeAll("]}\n");
            stdout.writeAll(buf.items) catch {};
            return;
        };
        defer stmt.finalize();

        var first = true;
        while (stmt.step() catch false) {
            const token = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("{\"token\":\"");
            try w.writeAll(std.mem.sliceTo(token, 0));
            try w.writeAll("\",\"version\":\"");
            try w.writeAll(if (ver) |v| std.mem.sliceTo(v, 0) else "");
            try w.writeAll("\"}");
        }
        try w.writeAll("]");
    }

    try w.writeAll("}\n");
    stdout.writeAll(buf.items) catch {};
}
