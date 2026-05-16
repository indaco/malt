//! malt — backup command
//! Dumps the list of currently installed formulae and casks to a plain-text
//! file that `malt restore` can consume to reproduce the environment on
//! another machine.
//!
//! File format (one entry per line):
//!
//!   # comments start with a '#' and are ignored
//!   formula git
//!   formula wget
//!   cask firefox
//!   cask slack
//!
//! An optional `@<version>` suffix is written when `--versions` is passed and
//! honoured by `malt restore`.

const std = @import("std");
const AppCtx = @import("../app_ctx.zig").AppCtx;
const sqlite = @import("../db/sqlite.zig");
const schema = @import("../db/schema.zig");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const help = @import("help.zig");

pub const Kind = enum { formula, cask };

/// A parsed backup entry. For entries produced by `parseBackup`, `name` and
/// `version` are slices into the input text and live as long as that text.
pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    version: []const u8,
};

pub const Error = error{
    InvalidArgs,
    DatabaseError,
    OpenFileFailed,
    WriteFailed,
};

pub fn execute(ctx: *const AppCtx, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "backup")) return;

    var output_path: ?[]const u8 = null;
    var include_versions = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) {
                output.err("--output requires a path argument", .{});
                return Error.InvalidArgs;
            }
            i += 1;
            output_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            output_path = arg["--output=".len..];
        } else if (std.mem.eql(u8, arg, "--versions")) {
            include_versions = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else {
            output.err("Unknown argument for backup: {s}", .{arg});
            return Error.InvalidArgs;
        }
    }

    // ── Open the database ────────────────────────────────────────────────
    const prefix = atomic.maltPrefixOrAbort();
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch
        return Error.DatabaseError;

    var db = sqlite.Database.open(db_path) catch {
        output.err("Failed to open database at {s}", .{db_path});
        return Error.DatabaseError;
    };
    defer db.close();
    // Schema is idempotent; backup's SELECTs surface a real DB error if one exists.
    schema.initSchema(&db) catch {};

    // ── Serialize into an in-memory buffer ───────────────────────────────
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (output.isJson()) return executeJson(ctx, allocator, &db, output_path);

    try writeHeader(w);
    var count: usize = 0;

    // Directly-installed formulae only — dependencies are pulled transitively
    // by `malt install` during restore.
    const formulae_sql =
        "SELECT name, version FROM kegs " ++
        "WHERE install_reason = 'direct' " ++
        "ORDER BY name;";
    var fstmt = db.prepare(formulae_sql) catch null;
    if (fstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const name = std.mem.sliceTo(name_ptr, 0);
            const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
            try writeEntry(w, .formula, name, version, include_versions);
            count += 1;
        }
    }

    // Tap is read alongside token + version so the line written for
    // a third-party-tap cask carries the fully-qualified slug
    // `<user>/<repo>/<token>`. Bare tokens 404 against the core API
    // on restore; the qualified form routes through
    // `installTapFormula` and re-installs from the owning tap.
    var cstmt = db.prepare("SELECT token, version, tap FROM casks ORDER BY token;") catch null;
    if (cstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const tap_ptr = s.columnText(2);
            const token = std.mem.sliceTo(name_ptr, 0);
            const version = if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "";
            const tap = if (tap_ptr) |p| std.mem.sliceTo(p, 0) else "";

            // Qualify only for third-party taps. `homebrew/cask` is the
            // core API path and stays bare so legacy backups parse the
            // same way.
            if (tap.len > 0 and !std.mem.eql(u8, tap, "homebrew/cask")) {
                var qual_buf: [256]u8 = undefined;
                const qualified = std.fmt.bufPrint(&qual_buf, "{s}/{s}", .{ tap, token }) catch {
                    // Tap label too long for the qualified-name buffer —
                    // fall back to the bare token so the entry isn't lost.
                    try writeEntry(w, .cask, token, version, include_versions);
                    count += 1;
                    continue;
                };
                try writeEntry(w, .cask, qualified, version, include_versions);
            } else {
                try writeEntry(w, .cask, token, version, include_versions);
            }
            count += 1;
        }
    }

    const bytes = aw.written();

    // ── Resolve destination and write ────────────────────────────────────
    if (output_path) |p| {
        if (std.mem.eql(u8, p, "-")) {
            output.writeStdoutAll(bytes);
            return;
        }
        try writeToPath(ctx, p, bytes);
        output.success("Backup written to {s} ({d} packages)", .{ p, count });
        return;
    }

    const default_path = try defaultBackupPath(ctx, allocator);
    defer allocator.free(default_path);
    try writeToPath(ctx, default_path, bytes);
    output.success("Backup written to {s} ({d} packages)", .{ default_path, count });
}

/// `--json` path: gather direct formulas + casks (with their `tap`
/// field) and emit `{formulas:[...],casks:[...]}` to stdout, or to
/// `--output <path>`. Plain-text contract is untouched so `mt restore`
/// keeps parsing the human form.
fn executeJson(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    output_path: ?[]const u8,
) Error!void {
    // Arena owns every per-row dupe — one `deinit` reclaims them all and
    // keeps the gather loop free of per-field errdefer plumbing.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var formulas: std.ArrayList(JsonFormula) = .empty;
    var casks: std.ArrayList(JsonCask) = .empty;

    var fstmt = db.prepare(
        "SELECT name, version FROM kegs " ++
            "WHERE install_reason = 'direct' " ++
            "ORDER BY name;",
    ) catch null;
    if (fstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const name = a.dupe(u8, std.mem.sliceTo(name_ptr, 0)) catch return Error.WriteFailed;
            const version = a.dupe(u8, if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "") catch
                return Error.WriteFailed;
            formulas.append(a, .{ .name = name, .version = version }) catch
                return Error.WriteFailed;
        }
    }

    var cstmt = db.prepare("SELECT token, version, tap FROM casks ORDER BY token;") catch null;
    if (cstmt) |*s| {
        defer s.finalize();
        while (s.step() catch false) {
            const name_ptr = s.columnText(0) orelse continue;
            const ver_ptr = s.columnText(1);
            const tap_ptr = s.columnText(2);
            const name = a.dupe(u8, std.mem.sliceTo(name_ptr, 0)) catch return Error.WriteFailed;
            const version = a.dupe(u8, if (ver_ptr) |p| std.mem.sliceTo(p, 0) else "") catch
                return Error.WriteFailed;
            const tap = a.dupe(u8, if (tap_ptr) |p| std.mem.sliceTo(p, 0) else "") catch
                return Error.WriteFailed;
            casks.append(a, .{ .name = name, .version = version, .tap = tap }) catch
                return Error.WriteFailed;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeBackupJson(&aw.writer, formulas.items, casks.items) catch return Error.WriteFailed;
    const bytes = aw.written();

    if (output_path) |p| {
        if (std.mem.eql(u8, p, "-")) {
            output.writeStdoutAll(bytes);
            return;
        }
        try writeToPath(ctx, p, bytes);
        return;
    }
    output.writeStdoutAll(bytes);
}

fn writeToPath(ctx: *const AppCtx, path: []const u8, bytes: []const u8) Error!void {
    // Create parent directories when the user supplied a nested path.
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            if (std.fs.path.isAbsolute(dir)) {
                std.Io.Dir.createDirAbsolute(ctx.io, dir, .default_dir) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => {},
                };
            } else {
                // Parent may already exist; the subsequent createFile reports real errors.
                std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
            }
        }
    }

    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(ctx.io, path, .{ .truncate = true }) catch {
            output.err("Failed to create {s}", .{path});
            return Error.OpenFileFailed;
        }
    else
        std.Io.Dir.cwd().createFile(ctx.io, path, .{ .truncate = true }) catch {
            output.err("Failed to create {s}", .{path});
            return Error.OpenFileFailed;
        };
    defer file.close(ctx.io);
    file.writeStreamingAll(ctx.io, bytes) catch return Error.WriteFailed;
}

/// Plain-data view of one formula row for the `--json` writer.
pub const JsonFormula = struct {
    name: []const u8,
    version: []const u8,
};

/// Plain-data view of one cask row for the `--json` writer. `tap` is the
/// owning tap label (`""` for a core-API cask). The bare token stays in
/// `name` — consumers can re-qualify themselves; the plain-text writer
/// keeps doing the qualification because `mt restore` parses bare names.
pub const JsonCask = struct {
    name: []const u8,
    version: []const u8,
    tap: []const u8,
};

/// Emit `{ "formulas":[...], "casks":[...] }\n` for `mt backup --json`.
/// Both arrays are always present so consumers don't branch on absence.
pub fn writeBackupJson(
    w: *std.Io.Writer,
    formulas: []const JsonFormula,
    casks: []const JsonCask,
) !void {
    try w.writeAll("{\"formulas\":[");
    for (formulas, 0..) |f, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, f.name);
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, f.version);
        try w.writeAll("}");
    }
    try w.writeAll("],\"casks\":[");
    for (casks, 0..) |c, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, c.name);
        try w.writeAll(",\"version\":");
        try output.jsonStr(w, c.version);
        try w.writeAll(",\"tap\":");
        try output.jsonStr(w, c.tap);
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

/// Write the canonical header block at the top of a backup file.
pub fn writeHeader(w: *std.Io.Writer) !void {
    try w.writeAll("# malt backup\n");
    try w.writeAll("# Generated by `malt backup`. Restore with `malt restore <file>`.\n");
    try w.writeAll("# Format: one entry per line — `formula <name>` or `cask <token>`.\n");
    try w.writeAll("# Lines starting with `#` are comments and are ignored on restore.\n");
    try w.writeAll("\n");
}

/// Serialize a single entry to `w` in the canonical format.
pub fn writeEntry(w: *std.Io.Writer, kind: Kind, name: []const u8, version: []const u8, include_versions: bool) !void {
    const prefix: []const u8 = switch (kind) {
        .formula => "formula ",
        .cask => "cask ",
    };
    try w.writeAll(prefix);
    try w.writeAll(name);
    if (include_versions and version.len > 0) {
        try w.writeAll("@");
        try w.writeAll(version);
    }
    try w.writeAll("\n");
}

/// Parse a single line. Returns null for blank lines, comments, and any line
/// that does not match the canonical `<kind> <name>[@<version>]` shape.
/// The returned `name` and `version` slices point into `line`.
pub fn parseLine(line: []const u8) ?Entry {
    var s = std.mem.trim(u8, line, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') return null;

    var kind: Kind = undefined;
    if (std.mem.startsWith(u8, s, "formula ")) {
        kind = .formula;
        s = std.mem.trim(u8, s["formula ".len..], " \t\r\n");
    } else if (std.mem.startsWith(u8, s, "cask ")) {
        kind = .cask;
        s = std.mem.trim(u8, s["cask ".len..], " \t\r\n");
    } else {
        return null;
    }
    if (s.len == 0) return null;

    var name = s;
    var version: []const u8 = "";
    if (std.mem.findScalar(u8, s, '@')) |idx| {
        name = s[0..idx];
        version = s[idx + 1 ..];
    }
    if (name.len == 0) return null;
    return .{ .kind = kind, .name = name, .version = version };
}

/// Parse an entire backup file into a freshly-allocated slice of entries.
/// The entries reference slices inside `text`, which must outlive them.
/// Callers own the returned slice and must free it via `allocator.free`.
pub fn parseBackup(allocator: std.mem.Allocator, text: []const u8) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer list.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (parseLine(line)) |entry| {
            try list.append(allocator, entry);
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Compute a default backup filename of the form
/// `malt-backup-YYYY-MM-DDTHH-MM-SS.txt` in the current working directory.
/// The timestamp uses UTC so two backups taken at the same wall-clock moment
/// collide deterministically across time zones.
pub fn defaultBackupPath(ctx: *const AppCtx, allocator: std.mem.Allocator) ![]u8 {
    const secs = std.Io.Clock.real.now(ctx.io).toSeconds();
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = @intCast(@max(secs, 0)),
    };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const day_of_month: u16 = @as(u16, month_day.day_index) + 1;
    return std.fmt.allocPrint(
        allocator,
        "malt-backup-{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}.txt",
        .{
            year_day.year,
            month_day.month.numeric(),
            day_of_month,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}
