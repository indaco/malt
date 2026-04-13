//! malt — bundle manifest tests

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const manifest = malt.bundle_manifest;

test "parse minimal JSON" {
    const json =
        \\{"name": "tiny", "version": 1, "formulas": [{"name": "wget"}]}
    ;
    var m = try manifest.parseJson(testing.allocator, json);
    defer m.deinit();

    try testing.expectEqualStrings("tiny", m.name);
    try testing.expectEqual(@as(u32, 1), m.version);
    try testing.expectEqual(@as(usize, 1), m.formulas.len);
    try testing.expectEqualStrings("wget", m.formulas[0].name);
}

test "parse full JSON with all member kinds" {
    const json =
        \\{
        \\  "name": "devtools",
        \\  "version": 1,
        \\  "taps": ["homebrew/cask-fonts"],
        \\  "formulas": [{"name": "wget"}, {"name": "jq", "version": "1.7"}],
        \\  "casks": [{"name": "ghostty"}],
        \\  "services": [{"name": "postgresql@16", "auto_start": true}]
        \\}
    ;
    var m = try manifest.parseJson(testing.allocator, json);
    defer m.deinit();

    try testing.expectEqualStrings("devtools", m.name);
    try testing.expectEqual(@as(usize, 1), m.taps.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", m.taps[0]);
    try testing.expectEqual(@as(usize, 2), m.formulas.len);
    try testing.expectEqualStrings("jq", m.formulas[1].name);
    try testing.expectEqualStrings("1.7", m.formulas[1].version.?);
    try testing.expectEqual(@as(usize, 1), m.casks.len);
    try testing.expectEqualStrings("ghostty", m.casks[0].name);
    try testing.expectEqual(@as(usize, 1), m.services.len);
    try testing.expect(m.services[0].auto_start);
}

test "reject version mismatch" {
    const json =
        \\{"name": "x", "version": 2}
    ;
    try testing.expectError(manifest.ManifestError.UnsupportedVersion, manifest.parseJson(testing.allocator, json));
}

test "reject malformed json" {
    const json = "not json at all";
    try testing.expectError(manifest.ManifestError.MalformedJson, manifest.parseJson(testing.allocator, json));
}

test "round-trip parse emit parse" {
    const json =
        \\{"name": "rt", "version": 1, "formulas": [{"name": "wget"}], "casks": [{"name": "ghostty"}]}
    ;
    var m1 = try manifest.parseJson(testing.allocator, json);
    defer m1.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try manifest.emitJson(m1, buf.writer(testing.allocator));

    var m2 = try manifest.parseJson(testing.allocator, buf.items);
    defer m2.deinit();

    try testing.expectEqualStrings(m1.name, m2.name);
    try testing.expectEqual(m1.formulas.len, m2.formulas.len);
    try testing.expectEqualStrings(m1.formulas[0].name, m2.formulas[0].name);
    try testing.expectEqual(m1.casks.len, m2.casks.len);
}
