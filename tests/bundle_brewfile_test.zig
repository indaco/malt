//! malt — Brewfile parser/emitter tests

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const brewfile = malt.bundle_brewfile;
const brewfile_emit = malt.bundle_brewfile_emit;

test "parse minimal Brewfile" {
    const txt = "brew \"wget\"\n";
    var m = try brewfile.parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("wget", m.formulas[0].name);
}

test "parse with hash options" {
    const txt =
        \\tap "homebrew/cask-fonts"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
        \\brew "postgresql@16", restart_service: true
    ;
    var m = try brewfile.parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.taps.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", m.taps[0]);
    try testing.expectEqual(@as(usize, 3), m.formulas.len);
    try testing.expectEqualStrings("jq", m.formulas[1].name);
    try testing.expectEqualStrings("1.7", m.formulas[1].version.?);
    try testing.expect(m.formulas[2].restart_service);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
    try testing.expectEqualStrings("ghostty", m.casks[0].name);
}

test "parse with comments and blank lines" {
    const txt =
        \\# comment line
        \\
        \\brew "wget"  # trailing comment
        \\# another comment
        \\cask "ghostty"
    ;
    var m = try brewfile.parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
}

test "unknown directive warns but does not fail" {
    const txt = "brew \"wget\"\nwhalebrew \"foo/bar\"\nbrew \"jq\"\n";
    var m = try brewfile.parse(testing.allocator, txt, null);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 2), m.formulas.len);
    try testing.expectEqualStrings("wget", m.formulas[0].name);
    try testing.expectEqualStrings("jq", m.formulas[1].name);
}

test "unknown directive records a warning in diagnostics" {
    // Core routes the skipped directive through the caller's diagnostics
    // rather than the UI layer, so the parser stays headless.
    const txt = "brew \"wget\"\nwhalebrew \"foo/bar\"\n";
    var diag = brewfile.Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var m = try brewfile.parse(testing.allocator, txt, &diag);
    defer m.deinit();

    try testing.expectEqual(@as(usize, 1), diag.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, diag.warnings.items[0], "whalebrew") != null);
}

test "conditionals rejected" {
    const txt = "brew \"wget\" if OS.mac?\n";
    try testing.expectError(
        brewfile.BrewfileError.ConditionalsUnsupported,
        brewfile.parse(testing.allocator, txt, null),
    );
}

test "blocks rejected" {
    const txt = "brew \"wget\" do\n  link\nend\n";
    try testing.expectError(
        brewfile.BrewfileError.BlocksUnsupported,
        brewfile.parse(testing.allocator, txt, null),
    );
}

test "round trip emit then parse" {
    const original =
        \\tap "homebrew/cask-fonts"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
    ;
    var m1 = try brewfile.parse(testing.allocator, original, null);
    defer m1.deinit();

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try brewfile_emit.emit(m1, &aw.writer);

    var m2 = try brewfile.parse(testing.allocator, aw.written(), null);
    defer m2.deinit();

    try testing.expectEqual(m1.taps.len, m2.taps.len);
    try testing.expectEqual(m1.formulas.len, m2.formulas.len);
    try testing.expectEqual(m1.casks.len, m2.casks.len);
    try testing.expectEqualStrings(m1.formulas[1].version.?, m2.formulas[1].version.?);
}
