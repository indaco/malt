//! malt — integration tests for the `mt tui` Doctor tab.
//!
//! Inline tests in the leaf modules cover the parse/render/step shapes against
//! literal bytes; this file pins the assembled path against a **recorded**
//! `mt doctor --json` fixture (`scripts/fixtures/`), never live `mt` — proving
//! the parser consumes the real versioned `checks[]` schema and that the
//! selection plus the `f` key map to the exact `mt doctor --fix <class>` token,
//! including the case where a finding's `id` and its `fix_class` deliberately
//! differ (`orphaned_store_entries` → `orphaned_store`).

const std = @import("std");
const testing = std.testing;

const malt = @import("malt");
const doctor_json = malt.tui_json_doctor;
const doctor = malt.tui_tab_doctor;
const test_io = @import("test_io");

fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const io = std.Options.debug_io;
    var dir = try test_io.cwd().openDir(io, "scripts/fixtures", .{});
    defer dir.close(io);
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

test "doctor parser consumes the recorded mt doctor --json fixture" {
    const bytes = try readFixture(testing.allocator, "tui_doctor.json");
    defer testing.allocator.free(bytes);

    var parsed = try doctor_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 4), parsed.items.len);

    // A non-fixable error finding.
    const sqlite = parsed.items[1];
    try testing.expectEqualStrings("sqlite_integrity", sqlite.id);
    try testing.expectEqual(doctor_json.Severity.err, sqlite.severity);
    try testing.expectEqual(false, sqlite.fixable);
    try testing.expectEqual(doctor_json.FixClass.none, sqlite.fix_class);

    // A fixable finding whose id and fix_class differ — the case that proves `f`
    // must send the class, not the id.
    const orphaned = parsed.items[2];
    try testing.expectEqualStrings("orphaned_store_entries", orphaned.id);
    try testing.expectEqual(true, orphaned.fixable);
    try testing.expectEqual(doctor_json.FixClass.orphaned_store, orphaned.fix_class);
}

test "f over the fixture targets the selected fixable finding by its fix_class" {
    const bytes = try readFixture(testing.allocator, "tui_doctor.json");
    defer testing.allocator.free(bytes);
    var parsed = try doctor_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: doctor.State = .{ .items = parsed.items };
    var storage: doctor.Storage = .{};
    defer storage.deinit(testing.allocator);

    // Display order: sqlite (err), orphaned (warn), stale_lock (warn), malt_prefix (ok).
    // Cursor on the orphaned finding; `f` builds a fix mutation over exactly that finding.
    st.chrome.view.selected = 1;
    const sel = doctor.selectedFinding(&st).?;
    try testing.expectEqualStrings("orphaned_store_entries", sel.id); // the descriptive id…
    try testing.expectEqualStrings("orphaned_store", doctor_json.fixClassTag(sel.fix_class)); // …vs the --fix token

    const eff = doctor.step(testing.allocator, "/opt/malt/bin/mt", &st, &storage, .{ .char = .{ .bytes = .{ 'f', 0, 0, 0 }, .len = 1 } });
    defer testing.allocator.free(eff.run_mutation.argv);
    try testing.expectEqualStrings("--fix", eff.run_mutation.argv[2]);
    try testing.expectEqualStrings("orphaned_store", eff.run_mutation.argv[3]); // the fix_class token
}

test "f on a non-fixable finding over the fixture is inert" {
    const bytes = try readFixture(testing.allocator, "tui_doctor.json");
    defer testing.allocator.free(bytes);
    var parsed = try doctor_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: doctor.State = .{ .items = parsed.items };
    var storage: doctor.Storage = .{};
    defer storage.deinit(testing.allocator);
    st.chrome.view.selected = 0; // sqlite_integrity — an error, not fixable
    try testing.expectEqual(false, doctor.selectedFinding(&st).?.fixable);
    try testing.expect(doctor.step(testing.allocator, "/opt/malt/bin/mt", &st, &storage, .{ .char = .{ .bytes = .{ 'f', 0, 0, 0 }, .len = 1 } }) == .none);
}

test "a filter narrows the fix target to a matching finding" {
    const bytes = try readFixture(testing.allocator, "tui_doctor.json");
    defer testing.allocator.free(bytes);
    var parsed = try doctor_json.parse(testing.allocator, bytes);
    defer parsed.deinit();

    var st: doctor.State = .{ .items = parsed.items };
    st.chrome.filter.push("stale"); // only "Stale lock" matches
    st.chrome.view.selected = 0;
    const sel = doctor.selectedFinding(&st).?;
    try testing.expectEqualStrings("stale_lock", sel.id);
    try testing.expectEqualStrings("stale_lock", doctor_json.fixClassTag(sel.fix_class));
}
