//! malt — outdated command
//! List outdated packages.

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
    if (help.showIfRequested(args, "outdated")) return;

    var json_mode = false;
    var cask_only = false;
    var formula_only = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "--cask")) {
            cask_only = true;
        } else if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            formula_only = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        }
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

    // Set up API client
    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return;
    };
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const stdout = std.fs.File.stdout();

    // Check outdated formulas (unless --cask)
    if (!cask_only) {
        var stmt = db.prepare("SELECT name, version FROM kegs ORDER BY name;") catch return;
        defer stmt.finalize();

        if (json_mode) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            const w = buf.writer(allocator);
            try w.writeAll("[");

            var first = true;
            while (stmt.step() catch false) {
                const name_ptr = stmt.columnText(0) orelse continue;
                const ver_ptr = stmt.columnText(1);
                const name_slice = std.mem.sliceTo(name_ptr, 0);
                const ver_slice = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";

                const latest = getLatestVersion(allocator, &api, name_slice) orelse continue;
                defer allocator.free(latest);

                if (!std.mem.eql(u8, ver_slice, latest)) {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"name\":");
                    try output.jsonStr(w, name_slice);
                    try w.writeAll(",\"installed\":");
                    try output.jsonStr(w, ver_slice);
                    try w.writeAll(",\"latest\":");
                    try output.jsonStr(w, latest);
                    try w.writeAll(",\"type\":\"formula\"}");
                }
            }

            try w.writeAll("]\n");
            stdout.writeAll(buf.items) catch {};
        } else {
            var found_any = false;
            while (stmt.step() catch false) {
                const name_ptr = stmt.columnText(0) orelse continue;
                const ver_ptr = stmt.columnText(1);
                const name_slice = std.mem.sliceTo(name_ptr, 0);
                const ver_slice = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";

                const latest = getLatestVersion(allocator, &api, name_slice) orelse continue;
                defer allocator.free(latest);

                if (!std.mem.eql(u8, ver_slice, latest)) {
                    found_any = true;
                    var line_buf: [512]u8 = undefined;
                    const line = std.fmt.bufPrint(&line_buf, "{s} ({s}) < {s}\n", .{ name_slice, ver_slice, latest }) catch continue;
                    stdout.writeAll(line) catch {};
                }
            }

            if (!found_any and !output.isQuiet()) {
                output.info("All formulas are up to date.", .{});
            }
        }
    }

    // Check outdated casks (unless --formula)
    if (!formula_only) {
        try checkOutdatedCasks(allocator, &db, &api, json_mode);
    }
}

fn checkOutdatedCasks(allocator: std.mem.Allocator, db: *sqlite.Database, api: *api_mod.BrewApi, json_mode: bool) !void {
    var stmt = db.prepare("SELECT token, version FROM casks ORDER BY token;") catch |e| {
        output.err("Failed to query casks: {s}", .{@errorName(e)});
        return e;
    };
    defer stmt.finalize();

    const stdout = std.fs.File.stdout();
    var found_any = false;

    while (stmt.step() catch false) {
        const token_ptr = stmt.columnText(0) orelse continue;
        const ver_ptr = stmt.columnText(1);
        const token = std.mem.sliceTo(token_ptr, 0);
        const installed_ver = if (ver_ptr) |v| std.mem.sliceTo(v, 0) else "0";

        const cask_json = api.fetchCask(token) catch continue;
        defer allocator.free(cask_json);

        var cask = cask_mod.parseCask(allocator, cask_json) catch continue;
        defer cask.deinit();

        if (!std.mem.eql(u8, installed_ver, cask.version)) {
            found_any = true;
            if (json_mode) {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                const w = buf.writer(allocator);
                w.writeAll("{\"name\":") catch continue;
                output.jsonStr(w, token) catch continue;
                w.writeAll(",\"installed\":") catch continue;
                output.jsonStr(w, installed_ver) catch continue;
                w.writeAll(",\"latest\":") catch continue;
                output.jsonStr(w, cask.version) catch continue;
                w.writeAll(",\"type\":\"cask\"}\n") catch continue;
                stdout.writeAll(buf.items) catch {};
            } else {
                var buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} ({s}) < {s} [cask]\n", .{ token, installed_ver, cask.version }) catch continue;
                stdout.writeAll(line) catch {};
            }
        }
    }

    if (!found_any and !output.isQuiet()) {
        output.info("All casks are up to date.", .{});
    }
}

fn getLatestVersion(allocator: std.mem.Allocator, api: *api_mod.BrewApi, name: []const u8) ?[]const u8 {
    const json_bytes = api.fetchFormula(name) catch return null;
    defer allocator.free(json_bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch return null;
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Try versions.stable first
    if (obj.get("versions")) |versions_val| {
        switch (versions_val) {
            .object => |versions_obj| {
                if (versions_obj.get("stable")) |stable_val| {
                    switch (stable_val) {
                        .string => |s| return allocator.dupe(u8, s) catch null,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return null;
}
