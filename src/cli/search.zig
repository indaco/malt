//! malt — search command
//! Search formulas and casks.

const std = @import("std");
const atomic = @import("../fs/atomic.zig");
const output = @import("../ui/output.zig");
const color = @import("../ui/color.zig");
const api_mod = @import("../net/api.zig");
const client_mod = @import("../net/client.zig");
const help = @import("help.zig");

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (help.showIfRequested(args, "search")) return;

    // Parse flags and positional args
    var search_formula = false;
    var search_cask = false;
    var query: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--formula") or std.mem.eql(u8, arg, "--formulae")) {
            search_formula = true;
        } else if (std.mem.eql(u8, arg, "--cask") or std.mem.eql(u8, arg, "--casks")) {
            search_cask = true;
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

    // --json is consumed by the global arg parser; check output module
    const json_mode = output.isJson();

    const cache_dir = atomic.maltCacheDir(allocator) catch {
        output.err("Failed to determine cache directory", .{});
        return;
    };
    defer allocator.free(cache_dir);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    var api = api_mod.BrewApi.init(allocator, &http, cache_dir);

    const stdout = std.fs.File.stdout();

    // Track whether anything was found (for "not found" messages)
    var found_formula = false;
    var found_cask = false;

    // Search formulas
    if (search_formula) {
        const json_bytes = api.fetchFormula(search_query) catch null;
        if (json_bytes) |bytes| {
            defer allocator.free(bytes);
            found_formula = true;
        }
    }

    // Search casks
    if (search_cask) {
        const json_bytes = api.fetchCask(search_query) catch null;
        if (json_bytes) |bytes| {
            defer allocator.free(bytes);
            found_cask = true;
        }
    }

    // Output results
    if (json_mode) {
        var out_buf: std.ArrayList(u8) = .empty;
        defer out_buf.deinit(allocator);
        const w = out_buf.writer(allocator);

        try w.writeAll("{");
        if (search_formula) {
            try w.writeAll("\"formulae\":[");
            if (found_formula) {
                try w.writeAll("{\"name\":\"");
                try w.writeAll(search_query);
                try w.writeAll("\"}");
            }
            try w.writeAll("]");
        }
        if (search_cask) {
            if (search_formula) try w.writeAll(",");
            try w.writeAll("\"casks\":[");
            if (found_cask) {
                try w.writeAll("{\"token\":\"");
                try w.writeAll(search_query);
                try w.writeAll("\"}");
            }
            try w.writeAll("]");
        }
        try w.writeAll("}\n");
        stdout.writeAll(out_buf.items) catch {};
    } else {
        if (found_formula) writeResult(stdout, search_query, "formula");
        if (found_cask) writeResult(stdout, search_query, "cask");

        if (!found_formula and !found_cask and !output.isQuiet()) {
            output.info("No results found for \"{s}\"", .{search_query});
        }
    }
}

/// Write a single search result with the same ▸ prefix style used by `list`.
fn writeResult(stdout: std.fs.File, name: []const u8, kind: []const u8) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(color.Style.cyan.code()) catch {};
    stdout.writeAll("  \xe2\x96\xb8 ") catch {};
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
    stdout.writeAll(name) catch {};
    if (use_color) stdout.writeAll(color.Style.dim.code()) catch {};
    stdout.writeAll(" (") catch {};
    stdout.writeAll(kind) catch {};
    stdout.writeAll(")") catch {};
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch {};
    stdout.writeAll("\n") catch {};
}
