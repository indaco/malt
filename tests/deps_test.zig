//! malt — dependency resolution tests
//! Tests for dependency structures (resolve requires network; unit tests here).

const std = @import("std");
const testing = std.testing;
const formula_mod = @import("malt").formula;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "formula dependencies parsed from JSON" {
    var arena = testArena();
    defer arena.deinit();

    const json =
        \\{
        \\  "name": "wget",
        \\  "full_name": "wget",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": ["openssl@3", "libidn2", "gettext"],
        \\  "oldnames": []
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), json);
    defer formula.deinit();

    try testing.expectEqual(@as(usize, 3), formula.dependencies.len);
    try testing.expectEqualStrings("openssl@3", formula.dependencies[0]);
    try testing.expectEqualStrings("libidn2", formula.dependencies[1]);
    try testing.expectEqualStrings("gettext", formula.dependencies[2]);
}

test "formula with empty dependencies" {
    var arena = testArena();
    defer arena.deinit();

    const json =
        \\{
        \\  "name": "hello",
        \\  "full_name": "hello",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": [],
        \\  "oldnames": []
        \\}
    ;
    var formula = try formula_mod.parseFormula(arena.allocator(), json);
    defer formula.deinit();
    try testing.expectEqual(@as(usize, 0), formula.dependencies.len);
}
