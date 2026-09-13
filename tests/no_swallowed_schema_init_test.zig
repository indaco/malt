//! Pin test: no `cli/*` file may swallow a `schema.initSchema` failure.
//!
//! `initSchema` is the gate that refuses a DB written by a newer malt. A
//! `catch {}` / `catch return` at an open site turns that refusal into
//! empty output, a green doctor, or a write against a newer shape — the
//! user then reads "nothing installed" or "DB corrupt". Every handler must
//! name the error: route it through `schema_report`, match
//! `SchemaTooNew`, or print `@errorName`.

const std = @import("std");
const testing = std.testing;

const test_io = @import("test_io");

const scanned_root = "src/cli";
const call = "initSchema(";
/// A handler that mentions any of these has looked at the error.
const naming_tokens = [_][]const u8{ "schema_report", "SchemaTooNew", "@errorName", "refuseUnusableDb" };

test "every initSchema catch under cli/ names the error" {
    const io = std.Options.debug_io;

    var failures: std.ArrayList([]const u8) = .empty;
    defer {
        for (failures.items) |s| testing.allocator.free(s);
        failures.deinit(testing.allocator);
    }

    var dir = try test_io.cwd().openDir(io, scanned_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        const file = try dir.openFile(io, entry.path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const content = try testing.allocator.alloc(u8, @intCast(stat.size));
        defer testing.allocator.free(content);
        _ = try file.readPositionalAll(io, content, 0);

        try scanContent(entry.path, content, &failures);
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("{s}\n", .{f});
        return error.SchemaInitFailureSwallowed;
    }
}

fn scanContent(rel_path: []const u8, content: []const u8, failures: *std.ArrayList([]const u8)) !void {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, call)) |start| {
        cursor = start + call.len;
        const handler = catchHandler(content, cursor) orelse continue;
        if (!namesError(handler)) {
            const line = 1 + std.mem.count(u8, content[0..start], "\n");
            const msg = try std.fmt.allocPrint(
                testing.allocator,
                "{s}/{s}:{d} swallows initSchema: `{s}`",
                .{ scanned_root, rel_path, line, handler },
            );
            try failures.append(testing.allocator, msg);
        }
    }
}

/// From just past `initSchema(`, skip the argument list; if the call is
/// followed by `catch`, return the handler text up to the statement's `;`
/// (brace/paren aware). `null` when the call is not `catch`-handled.
fn catchHandler(content: []const u8, after_paren: usize) ?[]const u8 {
    var depth: usize = 1;
    var i = after_paren;
    while (i < content.len and depth > 0) : (i += 1) {
        switch (content[i]) {
            '(' => depth += 1,
            ')' => depth -= 1,
            else => {},
        }
    }
    while (i < content.len and (content[i] == ' ' or content[i] == '\n')) i += 1;
    if (!std.mem.startsWith(u8, content[i..], "catch")) return null;

    const handler_start = i;
    depth = 0;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '{', '(' => depth += 1,
            '}', ')' => depth -= 1,
            ';' => if (depth == 0) return content[handler_start..i],
            else => {},
        }
    }
    return content[handler_start..];
}

fn namesError(handler: []const u8) bool {
    for (naming_tokens) |tok| if (std.mem.indexOf(u8, handler, tok) != null) return true;
    return false;
}

test "catchHandler: try-form calls are not handlers" {
    const src = "    try schema.initSchema(&db);\n";
    try testing.expect(catchHandler(src, std.mem.indexOf(u8, src, call).? + call.len) == null);
}

test "namesError rejects the handler shapes that hid the gate" {
    const swallowed = [_][]const u8{
        "    schema.initSchema(&db) catch {};\n",
        "    schema.initSchema(&db) catch return;\n",
        "    schema.initSchema(&db) catch return error.Aborted;\n",
        "    schema.initSchema(&db) catch {\n        sink.err(\"Failed to initialize database schema\", .{});\n        return InstallError.DatabaseError;\n    };\n",
    };
    for (swallowed) |src| {
        const h = catchHandler(src, std.mem.indexOf(u8, src, call).? + call.len).?;
        try testing.expect(!namesError(h));
    }
}

test "namesError accepts handlers that look at the error" {
    const named = [_][]const u8{
        "    schema.initSchema(&db) catch |e| {\n        schema_report.reportInitFailure(&db, e, prefix);\n        return error.Aborted;\n    };\n",
        "    schema.initSchema(&db) catch |e| if (e == error.SchemaTooNew) return null;\n",
        "    schema.initSchema(&db) catch |e| {\n        output.err(\"x ({s})\", .{@errorName(e)});\n        return false;\n    };\n",
    };
    for (named) |src| {
        const h = catchHandler(src, std.mem.indexOf(u8, src, call).? + call.len).?;
        try testing.expect(namesError(h));
    }
}
