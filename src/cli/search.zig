//! malt — search command
//! Search formulas and casks.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "search")) return;

    // Parse flags and positional args
    var search_formula = false;
    var search_cask = false;
    var json_mode = false;
    var query: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            search_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            search_cask = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_mode = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            output.setQuiet(true);
        } else if (arg.len > 0 and arg[0] != '-') {
            if (query == null) query = arg;
        }
    }

    const search_query = query orelse {
        output.err("Usage: mt search <query>", .{});
        return;
    };

    // If neither specified, search both
    if (!search_formula and !search_cask) {
        search_formula = true;
        search_cask = true;
    }

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return;
    };
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const stdout = std.fs.File.stdout();
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(allocator);
    const w = out_buf.writer(allocator);

    if (json_mode) {
        try w.writeAll("{");
    }

    // Search formulas
    if (search_formula) {
        if (json_mode) try w.writeAll("\"formulae\":[");

        const json_bytes = api.fetchFormula(search_query) catch null;
        if (json_bytes) |bytes| {
            defer allocator.free(bytes);
            // If we got a direct match, show it
            if (json_mode) {
                try w.writeAll("{\"name\":\"");
                try w.writeAll(search_query);
                try w.writeAll("\"}");
            } else {
                var line_buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s}\n", .{search_query}) catch "";
                stdout.writeAll(line) catch {};
            }
        } else {
            // No direct match — formula API only supports exact lookups
            if (!json_mode and !output.isQuiet()) {
                output.info("No formulae found for \"{s}\"", .{search_query});
            }
        }

        if (json_mode) try w.writeAll("]");
    }

    // Search casks
    if (search_cask) {
        if (json_mode) {
            if (search_formula) try w.writeAll(",");
            try w.writeAll("\"casks\":[");
        }

        const json_bytes = api.fetchCask(search_query) catch null;
        if (json_bytes) |bytes| {
            defer allocator.free(bytes);
            if (json_mode) {
                try w.writeAll("{\"token\":\"");
                try w.writeAll(search_query);
                try w.writeAll("\"}");
            } else {
                var line_buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "{s} (cask)\n", .{search_query}) catch "";
                stdout.writeAll(line) catch {};
            }
        } else {
            if (!json_mode and !output.isQuiet()) {
                output.info("No casks found for \"{s}\"", .{search_query});
            }
        }

        if (json_mode) try w.writeAll("]");
    }

    if (json_mode) {
        try w.writeAll("}\n");
        stdout.writeAll(out_buf.items) catch {};
    }
}
