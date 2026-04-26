//! malt — list command
//! List installed packages.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const color = @import("../ui/color.zig");
const io_mod = @import("../ui/io.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "list")) return;

    // Parse per-command flags. `--json`, `--quiet`/`-q`, `--verbose`/`-v`,
    // and `--dry-run` are stripped by the global parser in `main.zig`
    // before we get here — read them via `output.isJson()` etc.
    var show_formula = false;
    var show_cask = false;
    var show_versions = false;
    var show_pinned = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            show_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            show_cask = true;
        } else if (std.mem.eql(u8, arg, "--versions") or std.mem.eql(u8, arg, "--version")) {
            show_versions = true;
        } else if (std.mem.eql(u8, arg, "--pinned")) {
            show_pinned = true;
        }
    }
    const json_mode = output.isJson();

    // If neither specified, show both
    if (!show_formula and !show_cask) {
        show_formula = true;
        show_cask = true;
    }

    // Open DB
    const prefix = atomic.maltPrefix();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return;
    var db = sqlite.Database.open(db_path) catch {
        // Fresh prefix with no `db/` yet = nothing installed. Treat as
        // empty output (rc=0), same contract as `ls` on an empty dir.
        return;
    };
    defer db.close();
    schema.initSchema(&db) catch return;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = io_mod.stdoutFile().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    // Flush on teardown; stdout closed by a broken pipe is normal shell usage.
    defer stdout.flush() catch {};

    if (json_mode) {
        try writeJsonOutput(allocator, &db, show_formula, show_cask, show_pinned, stdout);
    } else {
        try writeHumanOutput(&db, show_formula, show_cask, show_versions, show_pinned, stdout);
    }
}

/// Pub for tests: assert the exact bytes for the human path without
/// staging a real DB-on-prefix + stdout-capture rig.
///
/// Honours `output.isQuiet()`: under `--quiet` the help text promises
/// "Names only, one per line", so decorations (bullet, version suffix,
/// `[pinned]` tag) are suppressed and each row is a bare name + `\n`.
pub fn writeHumanOutput(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    show_pinned: bool,
    stdout: *std.Io.Writer,
) !void {
    const quiet = output.isQuiet();

    if (show_pinned) {
        try writePinnedHuman(db, show_formula, show_cask, show_versions, quiet, stdout);
        return;
    }

    if (show_formula) {
        var stmt = db.prepare("SELECT name, version, pinned FROM kegs ORDER BY name;") catch return;
        defer stmt.finalize();

        while (stmt.step() catch false) {
            const name = stmt.columnText(0) orelse continue;
            const ver = stmt.columnText(1);
            const pinned = stmt.columnBool(2);
            const name_slice = std.mem.sliceTo(name, 0);

            if (quiet) {
                stdout.writeAll(name_slice) catch return;
                stdout.writeAll("\n") catch return;
                continue;
            }

            writeBulletPrefix(stdout);
            stdout.writeAll(name_slice) catch return;
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
            }
            if (pinned) {
                writeStyledSpan(stdout, color.SemanticStyle.warn.code(), " [pinned]", "", "");
            }
            stdout.writeAll("\n") catch return;
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

            if (quiet) {
                stdout.writeAll(token_slice) catch return;
                stdout.writeAll("\n") catch return;
                continue;
            }

            writeBulletPrefix(stdout);
            stdout.writeAll(token_slice) catch return;
            if (show_versions) {
                const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
                writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
            }
            stdout.writeAll("\n") catch return;
        }
    }
}

/// `--pinned` walks formulas + casks together so the output is a single
/// sorted list across both kinds, with a `[cask]` tag distinguishing
/// cask rows. The `[pinned]` tag is dropped — every row is pinned by
/// definition, so repeating it is noise.
fn writePinnedHuman(
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_versions: bool,
    quiet: bool,
    stdout: *std.Io.Writer,
) !void {
    const sql = pinnedUnionSql(show_formula, show_cask) orelse return;
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();

    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const kind = stmt.columnText(2);
        const name_slice = std.mem.sliceTo(name, 0);
        const is_cask = if (kind) |k| std.mem.eql(u8, std.mem.sliceTo(k, 0), "cask") else false;

        if (quiet) {
            stdout.writeAll(name_slice) catch return;
            stdout.writeAll("\n") catch return;
            continue;
        }

        writeBulletPrefix(stdout);
        stdout.writeAll(name_slice) catch return;
        if (show_versions) {
            const ver_slice = if (ver) |v| std.mem.sliceTo(v, 0) else "?";
            writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", ver_slice, ")");
        }
        if (is_cask) {
            writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " [", "cask", "]");
        }
        stdout.writeAll("\n") catch return;
    }
}

/// Build the SQL that drives the `--pinned` view. The 'formula' / 'cask'
/// literal column tags each row so the caller can render the right marker.
fn pinnedUnionSql(show_formula: bool, show_cask: bool) ?[:0]const u8 {
    if (show_formula and show_cask)
        return "SELECT name, version, 'formula' AS kind FROM kegs WHERE pinned = 1 " ++
            "UNION ALL " ++
            "SELECT token AS name, version, 'cask' AS kind FROM casks WHERE pinned = 1 " ++
            "ORDER BY name;";
    if (show_formula)
        return "SELECT name, version, 'formula' AS kind FROM kegs WHERE pinned = 1 ORDER BY name;";
    if (show_cask)
        return "SELECT token AS name, version, 'cask' AS kind FROM casks WHERE pinned = 1 ORDER BY name;";
    return null;
}

/// Emit the leading cyan bullet + space, honouring `NO_COLOR`.
fn writeBulletPrefix(stdout: *std.Io.Writer) void {
    if (color.isColorEnabled()) {
        stdout.writeAll(color.SemanticStyle.info.code()) catch return;
        stdout.writeAll("  ▸ ") catch return;
        stdout.writeAll(color.Style.reset.code()) catch return;
    } else {
        stdout.writeAll("  ▸ ") catch return;
    }
}

/// Emit `open + body + close`, wrapping the whole thing in `style` / reset
/// when colour is enabled. `open` or `close` may be empty.
fn writeStyledSpan(
    stdout: *std.Io.Writer,
    style_code: []const u8,
    open: []const u8,
    body: []const u8,
    close: []const u8,
) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(style_code) catch return;
    stdout.writeAll(open) catch return;
    stdout.writeAll(body) catch return;
    stdout.writeAll(close) catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
}

fn writeJsonOutput(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    stdout: *std.Io.Writer,
) !void {
    _ = allocator;
    const start_ts = fs_compat.milliTimestamp();
    try buildListJson(db, stdout, show_formula, show_cask, show_pinned, start_ts);
}

/// Build the `{ "installed": [...], "formulae": [...], "casks": [...], "time_ms": N }`
/// payload into `w`. Kept `pub` so tests can assert on the exact bytes without
/// going through a real file. On per-section SQLite failures we emit an empty
/// array for that section rather than truncating the whole document.
pub fn buildListJson(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_formula: bool,
    show_cask: bool,
    show_pinned: bool,
    start_ts: i64,
) !void {
    try w.writeAll("{\"installed\":[");
    var first = true;
    if (show_pinned) {
        try writePinnedInstalled(db, w, show_formula, show_cask, &first);
    } else {
        if (show_formula) try writeFormulaRows(db, w, false, .installed, &first);
        if (show_cask) try writeCaskRows(db, w, false, .installed, &first);
    }
    try w.writeAll("]");

    if (show_formula) {
        try w.writeAll(",\"formulae\":[");
        var legacy_first = true;
        try writeFormulaRows(db, w, show_pinned, .legacy, &legacy_first);
        try w.writeAll("]");
    }

    if (show_cask) {
        try w.writeAll(",\"casks\":[");
        var legacy_first = true;
        try writeCaskRows(db, w, show_pinned, .legacy, &legacy_first);
        try w.writeAll("]");
    }

    try output.jsonTimeSuffix(w, start_ts);
    try w.writeAll("}\n");
}

/// `installed` array under `--pinned`: one sorted run across formulas
/// and casks, each row carrying the `pinned: true` flag for parity with
/// the formula-only shape callers already consume.
fn writePinnedInstalled(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_formula: bool,
    show_cask: bool,
    first: *bool,
) !void {
    const sql = pinnedUnionSql(show_formula, show_cask) orelse return;
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();

    while (stmt.step() catch false) {
        const name = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const kind = stmt.columnText(2);
        const is_cask = if (kind) |k| std.mem.eql(u8, std.mem.sliceTo(k, 0), "cask") else false;

        if (!first.*) try w.writeAll(",");
        first.* = false;
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, std.mem.sliceTo(name, 0));
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, if (ver) |v| std.mem.sliceTo(v, 0) else "");
        if (is_cask) {
            try w.writeAll(",\"type\":\"cask\",\"pinned\":true}");
        } else {
            try w.writeAll(",\"type\":\"formula\",\"pinned\":true}");
        }
    }
}

const RowShape = enum { installed, legacy };

fn writeFormulaRows(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_pinned: bool,
    shape: RowShape,
    first: *bool,
) !void {
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
        if (!first.*) try w.writeAll(",");
        first.* = false;
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, std.mem.sliceTo(name, 0));
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, if (ver) |v| std.mem.sliceTo(v, 0) else "");
        switch (shape) {
            .installed => {
                try w.writeAll(",\"type\":\"formula\",\"pinned\":");
                try w.writeAll(if (pinned) "true" else "false");
                try w.writeAll("}");
            },
            .legacy => {
                try w.writeAll(",\"pinned\":");
                try w.writeAll(if (pinned) "true" else "false");
                try w.writeAll("}");
            },
        }
    }
}

fn writeCaskRows(
    db: *sqlite.Database,
    w: *std.Io.Writer,
    show_pinned: bool,
    shape: RowShape,
    first: *bool,
) !void {
    const sql: [:0]const u8 = if (show_pinned)
        "SELECT token, version FROM casks WHERE pinned = 1 ORDER BY token;"
    else
        "SELECT token, version FROM casks ORDER BY token;";
    var stmt = db.prepare(sql) catch return;
    defer stmt.finalize();

    while (stmt.step() catch false) {
        const token = stmt.columnText(0) orelse continue;
        const ver = stmt.columnText(1);
        const ver_str: []const u8 = if (ver) |v| std.mem.sliceTo(v, 0) else "";
        if (!first.*) try w.writeAll(",");
        first.* = false;
        switch (shape) {
            .installed => {
                try w.writeAll("{\"name\":");
                try output.jsonStr(w, std.mem.sliceTo(token, 0));
                try w.writeAll(",\"version\":");
                try output.jsonStr(w, ver_str);
                try w.writeAll(",\"type\":\"cask\"}");
            },
            .legacy => {
                try w.writeAll("{\"token\":");
                try output.jsonStr(w, std.mem.sliceTo(token, 0));
                try w.writeAll(",\"version\":");
                try output.jsonStr(w, ver_str);
                try w.writeAll("}");
            },
        }
    }
}
