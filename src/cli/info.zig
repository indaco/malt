//! malt — info command
//! Show package info (formulas and casks).

const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const io_mod = @import("../ui/io.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const formula_mod = @import("../core/formula.zig");
const cask_mod = @import("../core/cask.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "info")) return;

    // Parse flags and positional args. Note: `--json` and `--quiet`
    // are consumed by the global arg parser in `main.zig` and stored
    // on the `output` module — they never appear in `args` here,
    // which is why this loop does not scan for them.
    var force_cask = false;
    var force_formula = false;
    var pkg_name: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--cask")) {
            force_cask = true;
        } else if (std.mem.eql(u8, arg, "--formula")) {
            force_formula = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (pkg_name == null) pkg_name = arg;
        }
    }

    const json_mode = output.isJson();

    const name = pkg_name orelse {
        output.err("Usage: mt info <package>", .{});
        return error.Aborted;
    };

    // Open DB (optional). On a fresh machine the prefix's `db/` dir
    // may not exist yet — SQLite's OPEN_CREATE creates the file but
    // not intermediate directories, so the first-ever open fails.
    // `info` is purely informational: if we can't read local state
    // we fall through to the "not installed" output rather than
    // erroring, which matches what a populated DB would report for
    // a package that has never been installed.
    const prefix = atomic.maltPrefix();
    var db_opt: ?sqlite.Database = openDb(prefix);
    defer if (db_opt) |*d| d.close();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw = std.Io.File.stdout().writer(io_mod.ctx(), &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_fw.interface;
    defer stdout.flush() catch {};

    if (db_opt) |*db| {
        schema.initSchema(db) catch {};
        if (!force_cask and try emitInstalledFormula(allocator, db, name, prefix, stdout, json_mode)) return;
        if (!force_formula and try emitInstalledCask(allocator, db, name, stdout, json_mode)) return;
    }

    // Not locally installed — fall back to Homebrew API metadata so
    // the output matches `brew info`'s discovery UX (description,
    // homepage, version, dependencies) instead of just "not
    // installed". We only reach this path when the local DB lookup
    // missed or the DB was absent entirely.
    if (try emitApiMetadata(allocator, name, stdout, json_mode, force_cask, force_formula)) return;

    try emitNotFound(allocator, name, stdout, json_mode);
}

/// If `name` is an installed formula, write its info row and return
/// true (caller stops). Returns false when the lookup misses so the
/// caller can try the cask path.
fn emitInstalledFormula(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    prefix: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
) !bool {
    var stmt = db.prepare(
        "SELECT name, version, tap, cellar_path, pinned, installed_at FROM kegs WHERE name = ?1 LIMIT 1;",
    ) catch return false;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return false;

    const installed = stmt.step() catch false;
    if (!installed) return false;

    if (json_mode) {
        try writeJsonInfo(allocator, db, name, true, &stmt, stdout);
    } else {
        try writeHumanInfo(name, true, &stmt, prefix, stdout);
    }
    return true;
}

/// Cask counterpart to `emitInstalledFormula`.
fn emitInstalledCask(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
) !bool {
    if (cask_mod.lookupInstalled(db, name) == null) return false;
    if (json_mode) {
        try writeJsonCaskInfo(allocator, db, name, stdout);
    } else {
        try writeHumanCaskInfo(db, name, stdout);
    }
    return true;
}

/// Terminal output for a package the user asked about that is
/// neither installed locally nor known to the Homebrew API.
fn emitNotFound(
    allocator: std.mem.Allocator,
    name: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
) !void {
    if (json_mode) {
        try writeJsonNotInstalled(allocator, name, stdout);
        return;
    }
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}: not installed\n", .{name}) catch return;
    stdout.writeAll(line) catch return;
}

/// Fetch Homebrew API metadata for a not-locally-installed package and
/// emit it. Tries formula first (unless `--cask`), then cask (unless
/// `--formula`). Returns true on any hit so the caller knows to stop.
/// Silently returns false on network / parse failures — offline machines
/// should still fall through cleanly to the "not installed" shape.
fn emitApiMetadata(
    allocator: std.mem.Allocator,
    name: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
    force_cask: bool,
    force_formula: bool,
) !bool {
    const cache_dir = atomic.maltCacheDir(allocator) catch return false;
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    if (!force_cask) {
        if (try emitApiFormula(allocator, &api, name, stdout, json_mode)) return true;
    }
    if (!force_formula) {
        if (try emitApiCask(allocator, &api, name, stdout, json_mode)) return true;
    }
    return false;
}

fn emitApiFormula(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    name: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
) !bool {
    const body = api.fetchFormula(name) catch return false;
    defer allocator.free(body);

    var f = formula_mod.parseFormula(allocator, body) catch return false;
    defer f.deinit();

    if (json_mode) try writeApiFormulaJson(allocator, &f, stdout) else try writeApiFormulaHuman(&f, stdout);
    return true;
}

fn emitApiCask(
    allocator: std.mem.Allocator,
    api: *api_mod.BrewApi,
    name: []const u8,
    stdout: *std.Io.Writer,
    json_mode: bool,
) !bool {
    const body = api.fetchCask(name) catch return false;
    defer allocator.free(body);

    var c = cask_mod.parseCask(allocator, body) catch return false;
    defer c.deinit();

    if (json_mode) try writeApiCaskJson(allocator, &c, stdout) else try writeApiCaskHuman(&c, stdout);
    return true;
}

fn writeApiFormulaHuman(f: *const formula_mod.Formula, stdout: *std.Io.Writer) !void {
    var buf: [4096]u8 = undefined;
    try encodeApiFormulaHuman(stdout, &buf, f, output.isQuiet());
}

fn writeApiCaskHuman(c: *const cask_mod.Cask, stdout: *std.Io.Writer) !void {
    var buf: [4096]u8 = undefined;
    try encodeApiCaskHuman(stdout, &buf, c, output.isQuiet());
}

fn writeApiFormulaJson(
    allocator: std.mem.Allocator,
    f: *const formula_mod.Formula,
    stdout: *std.Io.Writer,
) !void {
    _ = allocator;
    try encodeApiFormulaJson(stdout, f);
}

fn writeApiCaskJson(
    allocator: std.mem.Allocator,
    c: *const cask_mod.Cask,
    stdout: *std.Io.Writer,
) !void {
    _ = allocator;
    try encodeApiCaskJson(stdout, c);
}

// --- pure encoders (testable) -----------------------------------------------
//
// The four `encode*` fns below are the isolated pieces that turn a
// parsed `Formula` / `Cask` into bytes. They take any writer target
// — `std.fs.File` in the CLI, `ArrayList` in tests — so the emission
// shape (install hint wording, JSON keys, line order) can be asserted
// without touching the filesystem.

pub fn encodeApiFormulaHuman(
    w: anytype,
    scratch: []u8,
    f: *const formula_mod.Formula,
    quiet: bool,
) !void {
    try writeLine(w, scratch, "{s}: stable {s}\n", .{ f.name, f.version });
    if (f.desc.len != 0) try writeLine(w, scratch, "{s}\n", .{f.desc});
    if (f.homepage.len != 0) try writeLine(w, scratch, "{s}\n", .{f.homepage});
    try encodeInstallHint(w, scratch, f.name, quiet);
    if (f.tap.len != 0) try writeLine(w, scratch, "From: {s}\n", .{f.tap});
    if (f.dependencies.len != 0) {
        w.writeAll("Dependencies: ") catch {};
        for (f.dependencies, 0..) |dep, i| {
            if (i != 0) w.writeAll(", ") catch {};
            w.writeAll(dep) catch {};
        }
        w.writeAll("\n") catch {};
    }
}

pub fn encodeApiCaskHuman(
    w: anytype,
    scratch: []u8,
    c: *const cask_mod.Cask,
    quiet: bool,
) !void {
    try writeLine(w, scratch, "{s}: {s} (cask)\n", .{ c.token, c.version });
    if (c.name.len != 0) try writeLine(w, scratch, "Name: {s}\n", .{c.name});
    if (c.desc.len != 0) try writeLine(w, scratch, "{s}\n", .{c.desc});
    if (c.homepage.len != 0) try writeLine(w, scratch, "{s}\n", .{c.homepage});
    try encodeInstallHint(w, scratch, c.token, quiet);
    if (c.url.len != 0) try writeLine(w, scratch, "URL: {s}\n", .{c.url});
}

pub fn encodeApiFormulaJson(w: anytype, f: *const formula_mod.Formula) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, f.name);
    try w.writeAll(",\"type\":\"formula\",\"installed\":false,\"version\":");
    try output.jsonStr(w, f.version);
    try w.writeAll(",\"desc\":");
    try output.jsonStr(w, f.desc);
    try w.writeAll(",\"homepage\":");
    try output.jsonStr(w, f.homepage);
    try w.writeAll(",\"tap\":");
    try output.jsonStr(w, f.tap);
    try w.writeAll(",\"dependencies\":[");
    for (f.dependencies, 0..) |dep, i| {
        if (i != 0) try w.writeAll(",");
        try output.jsonStr(w, dep);
    }
    try w.writeAll("]}\n");
}

pub fn encodeApiCaskJson(w: anytype, c: *const cask_mod.Cask) !void {
    try w.writeAll("{\"name\":");
    try output.jsonStr(w, c.token);
    try w.writeAll(",\"type\":\"cask\",\"installed\":false,\"version\":");
    try output.jsonStr(w, c.version);
    try w.writeAll(",\"full_name\":");
    try output.jsonStr(w, c.name);
    try w.writeAll(",\"desc\":");
    try output.jsonStr(w, c.desc);
    try w.writeAll(",\"homepage\":");
    try output.jsonStr(w, c.homepage);
    try w.writeAll(",\"url\":");
    try output.jsonStr(w, c.url);
    try w.writeAll("}\n");
}

/// Emit the "Not installed" line and (unless `quiet`) a runnable
/// install hint. Only triggered on the API-metadata path, where we
/// know the package actually exists upstream — suggesting `malt
/// install` for something the Homebrew API doesn't recognise would
/// just lead the user in a loop. Both `malt` and its short alias
/// `mt` are surfaced so readers of this line learn the alias exists
/// without having to consult --help.
pub fn encodeInstallHint(
    w: anytype,
    scratch: []u8,
    name: []const u8,
    quiet: bool,
) !void {
    if (quiet) {
        try w.writeAll("Not installed\n");
        return;
    }
    writeLine(
        w,
        scratch,
        "Not installed. Run: malt install {s}  (or: mt install {s})\n",
        .{ name, name },
    ) catch {
        try w.writeAll("Not installed\n");
    };
}

/// Convenience: format a line into `scratch` and write it to `w`.
/// Same safety profile as the existing `bufPrint` + `writeAll`
/// pattern used elsewhere in this file — avoids duplicating the
/// 4 KiB stack buffer at every call site.
fn writeLine(w: anytype, scratch: []u8, comptime fmt: []const u8, args: anytype) !void {
    const line = std.fmt.bufPrint(scratch, fmt, args) catch return;
    try w.writeAll(line);
}

/// Open the malt database if present. Returns `null` for any failure
/// (missing parent directory, permission error, corrupt file) so the
/// caller can degrade to a stateless response instead of bailing.
pub fn openDb(prefix: []const u8) ?sqlite.Database {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrint(&db_path_buf, "{s}/db/malt.db", .{prefix}) catch return null;
    return sqlite.Database.open(db_path) catch null;
}

/// Minimal JSON shape for the "no installed record" case. Mirrors the
/// `installed=false` branch of `writeJsonInfo` without needing a live
/// sqlite statement — used when the DB is missing or the package has
/// simply never been installed.
fn writeJsonNotInstalled(
    allocator: std.mem.Allocator,
    name: []const u8,
    stdout: *std.Io.Writer,
) !void {
    _ = allocator;
    try stdout.writeAll("{\"name\":");
    try output.jsonStr(stdout, name);
    try stdout.writeAll(",\"type\":\"formula\",\"installed\":false}\n");
}

fn writeHumanInfo(
    name: []const u8,
    installed: bool,
    stmt: *sqlite.Statement,
    prefix: []const u8,
    stdout: *std.Io.Writer,
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
            stdout.writeAll(line) catch return;
        }
        {
            const line = std.fmt.bufPrint(&buf, "From: {s}\n", .{tap_slice}) catch return;
            stdout.writeAll(line) catch return;
        }
        {
            const line = std.fmt.bufPrint(&buf, "Path: {s}/Cellar/{s}/{s}\n", .{ prefix, name, ver_slice }) catch return;
            stdout.writeAll(line) catch return;
        }
        _ = path_slice;
        if (pinned) {
            stdout.writeAll("Pinned: yes\n") catch return;
        }
        {
            const line = std.fmt.bufPrint(&buf, "Installed: {s}\n", .{date_slice}) catch return;
            stdout.writeAll(line) catch return;
        }
    } else {
        const line = std.fmt.bufPrint(&buf, "{s}: not installed\n", .{name}) catch return;
        stdout.writeAll(line) catch return;
    }
}

fn writeJsonInfo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    installed: bool,
    stmt: *sqlite.Statement,
    stdout: *std.Io.Writer,
) !void {
    _ = db;
    _ = allocator;

    try stdout.writeAll("{\"name\":");
    try output.jsonStr(stdout, name);
    try stdout.writeAll(",\"type\":\"formula\",\"installed\":");
    try stdout.writeAll(if (installed) "true" else "false");

    if (installed) {
        const ver = stmt.columnText(1);
        const tap = stmt.columnText(2);
        const pinned = stmt.columnBool(4);
        const installed_at = stmt.columnText(5);

        try stdout.writeAll(",\"version\":");
        try output.jsonStr(stdout, if (ver) |v| std.mem.sliceTo(v, 0) else "");
        try stdout.writeAll(",\"tap\":");
        try output.jsonStr(stdout, if (tap) |t| std.mem.sliceTo(t, 0) else "");
        try stdout.writeAll(",\"pinned\":");
        try stdout.writeAll(if (pinned) "true" else "false");
        try stdout.writeAll(",\"installed_at\":");
        try output.jsonStr(stdout, if (installed_at) |d| std.mem.sliceTo(d, 0) else "");
    }

    try stdout.writeAll("}\n");
}

fn writeHumanCaskInfo(
    db: *sqlite.Database,
    name: []const u8,
    stdout: *std.Io.Writer,
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
        stdout.writeAll(line) catch return;
    }
    {
        const line = std.fmt.bufPrint(&buf, "Name: {s}\n", .{cask_name}) catch return;
        stdout.writeAll(line) catch return;
    }
    {
        const line = std.fmt.bufPrint(&buf, "URL: {s}\n", .{url}) catch return;
        stdout.writeAll(line) catch return;
    }
    {
        const line = std.fmt.bufPrint(&buf, "App: {s}\n", .{app_path}) catch return;
        stdout.writeAll(line) catch return;
    }
    if (auto_updates) {
        stdout.writeAll("Auto-updates: yes\n") catch return;
    }
    {
        const line = std.fmt.bufPrint(&buf, "Installed: {s}\n", .{installed_at}) catch return;
        stdout.writeAll(line) catch return;
    }
}

fn writeJsonCaskInfo(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    name: []const u8,
    stdout: *std.Io.Writer,
) !void {
    var stmt = db.prepare(
        "SELECT token, name, version, url, sha256, app_path, auto_updates, installed_at FROM casks WHERE token = ?1 LIMIT 1;",
    ) catch return;
    defer stmt.finalize();
    stmt.bindText(1, name) catch return;

    const found = stmt.step() catch false;
    if (!found) return;

    _ = allocator;

    const token = if (stmt.columnText(0)) |t| std.mem.sliceTo(t, 0) else name;
    const cask_name = if (stmt.columnText(1)) |n| std.mem.sliceTo(n, 0) else name;
    const ver = if (stmt.columnText(2)) |v| std.mem.sliceTo(v, 0) else "";
    const url = if (stmt.columnText(3)) |u| std.mem.sliceTo(u, 0) else "";
    const app_path = if (stmt.columnText(5)) |p| std.mem.sliceTo(p, 0) else "";
    const auto_updates = stmt.columnBool(6);
    const installed_at = if (stmt.columnText(7)) |d| std.mem.sliceTo(d, 0) else "";

    try stdout.writeAll("{\"name\":");
    try output.jsonStr(stdout, token);
    try stdout.writeAll(",\"type\":\"cask\",\"installed\":true,\"version\":");
    try output.jsonStr(stdout, ver);
    try stdout.writeAll(",\"full_name\":");
    try output.jsonStr(stdout, cask_name);
    try stdout.writeAll(",\"url\":");
    try output.jsonStr(stdout, url);
    try stdout.writeAll(",\"app_path\":");
    try output.jsonStr(stdout, app_path);
    try stdout.writeAll(",\"auto_updates\":");
    try stdout.writeAll(if (auto_updates) "true" else "false");
    try stdout.writeAll(",\"installed_at\":");
    try output.jsonStr(stdout, installed_at);
    try stdout.writeAll("}\n");
}
