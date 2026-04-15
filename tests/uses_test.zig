//! malt — uses command tests
//!
//! Covers the reverse-dep query, the BFS recursive walk, the JSON
//! encoder shape, and the empty-result path. Each test builds a tiny
//! kegs+dependencies graph in a temporary sqlite DB and asserts the
//! caller-observable contract of `collectDependents` / `encodeJson`.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const uses = malt.cli_uses;
const sqlite = malt.sqlite;
const schema = malt.schema;

fn makeDb(tag: []const u8) !sqlite.Database {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/malt_uses_test_{s}.db", .{tag});
    malt.fs_compat.deleteFileAbsolute(path) catch {};
    var db = try sqlite.Database.open(path);
    try schema.initSchema(&db);
    return db;
}

/// Insert a keg row and return its id. Minimises boilerplate in the
/// tests below — the full `install` path would be overkill here since
/// we only exercise the dependencies table.
fn insertKeg(db: *sqlite.Database, name: []const u8) !i64 {
    var stmt = try db.prepare(
        "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)" ++
            " VALUES (?1, ?1, '1.0', ?1, '/tmp/cellar') RETURNING id;",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    _ = try stmt.step();
    return stmt.columnInt(0);
}

fn addDep(db: *sqlite.Database, keg_id: i64, dep_name: []const u8) !void {
    var stmt = try db.prepare(
        "INSERT INTO dependencies (keg_id, dep_name) VALUES (?1, ?2);",
    );
    defer stmt.finalize();
    try stmt.bindInt(1, keg_id);
    try stmt.bindText(2, dep_name);
    _ = try stmt.step();
}

test "collectDependents returns direct dependents, sorted" {
    var db = try makeDb("direct");
    defer db.close();

    // openssl@3 is used by node@20 and wget; icu4c@78 is unrelated.
    const node_id = try insertKeg(&db, "node@20");
    const wget_id = try insertKeg(&db, "wget");
    _ = try insertKeg(&db, "icu4c@78");
    try addDep(&db, node_id, "openssl@3");
    try addDep(&db, wget_id, "openssl@3");

    const hits = try uses.collectDependents(testing.allocator, &db, "openssl@3", false);
    defer uses.freeDependents(testing.allocator, hits);

    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("node@20", hits[0]);
    try testing.expectEqualStrings("wget", hits[1]);
}

test "collectDependents in non-recursive mode ignores transitive links" {
    var db = try makeDb("notrans");
    defer db.close();

    // icu4c <- node <- whisper.  Non-recursive on icu4c should surface
    // only `node`, not `whisper`.
    const node_id = try insertKeg(&db, "node");
    const whisper_id = try insertKeg(&db, "whisper");
    try addDep(&db, node_id, "icu4c");
    try addDep(&db, whisper_id, "node");

    const hits = try uses.collectDependents(testing.allocator, &db, "icu4c", false);
    defer uses.freeDependents(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqualStrings("node", hits[0]);
}

test "collectDependents --recursive walks the transitive closure" {
    var db = try makeDb("recursive");
    defer db.close();

    // Graph: icu4c <- node <- {whisper, tauri}; tauri <- nothing.
    const node_id = try insertKeg(&db, "node");
    const whisper_id = try insertKeg(&db, "whisper");
    const tauri_id = try insertKeg(&db, "tauri");
    try addDep(&db, node_id, "icu4c");
    try addDep(&db, whisper_id, "node");
    try addDep(&db, tauri_id, "node");

    const hits = try uses.collectDependents(testing.allocator, &db, "icu4c", true);
    defer uses.freeDependents(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqualStrings("node", hits[0]);
    try testing.expectEqualStrings("tauri", hits[1]);
    try testing.expectEqualStrings("whisper", hits[2]);
}

test "collectDependents returns empty slice when nothing depends on target" {
    var db = try makeDb("empty");
    defer db.close();

    _ = try insertKeg(&db, "standalone");

    const hits = try uses.collectDependents(testing.allocator, &db, "not-a-real-formula", false);
    defer uses.freeDependents(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 0), hits.len);
}

test "collectDependents tolerates cycles without spinning" {
    // Shouldn't happen in a real malt DB (install refuses cyclic deps)
    // but the BFS must terminate regardless so a corrupt database can
    // never hang the command. `a` depends on `b`, `b` depends on `a`.
    var db = try makeDb("cycle");
    defer db.close();

    const a_id = try insertKeg(&db, "a");
    const b_id = try insertKeg(&db, "b");
    try addDep(&db, a_id, "b");
    try addDep(&db, b_id, "a");

    const hits = try uses.collectDependents(testing.allocator, &db, "a", true);
    defer uses.freeDependents(testing.allocator, hits);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqualStrings("a", hits[0]);
    try testing.expectEqualStrings("b", hits[1]);
}

test "encodeJson shape: target + dependents array" {
    const deps = [_][]const u8{ "node@20", "wget" };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try uses.encodeJson(&aw.writer, "openssl@3", @constCast(deps[0..]));

    try testing.expectEqualStrings(
        "{\"formula\":\"openssl@3\",\"uses\":[\"node@20\",\"wget\"]}\n",
        aw.written(),
    );
}

test "encodeJson handles an empty dependents list" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try uses.encodeJson(&aw.writer, "lonely", &.{});
    try testing.expectEqualStrings("{\"formula\":\"lonely\",\"uses\":[]}\n", aw.written());
}

test "encodeJson escapes special characters in target and dependents" {
    // A formula name containing a literal quote/backslash/newline would
    // produce invalid JSON if the encoder concatenated raw bytes. Real
    // formula names won't carry these, but tap-prefixed names and upstream
    // metadata can — so the encoder must escape unconditionally.
    const deps = [_][]const u8{ "weird\"name", "back\\slash", "with\nnewline" };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try uses.encodeJson(&aw.writer, "tap\"name", @constCast(deps[0..]));

    // The exact expected bytes verify the escape contract precisely.
    try testing.expectEqualStrings(
        "{\"formula\":\"tap\\\"name\",\"uses\":[\"weird\\\"name\",\"back\\\\slash\",\"with\\nnewline\"]}\n",
        aw.written(),
    );

    // And the result must round-trip through a strict JSON parser.
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.trimEnd(u8, aw.written(), "\n"),
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqualStrings("tap\"name", parsed.value.object.get("formula").?.string);
    try testing.expectEqual(@as(usize, 3), parsed.value.object.get("uses").?.array.items.len);
}
