//! malt — formula module tests
//! Tests for formula JSON parsing, alias resolution, and bottle selection.

const std = @import("std");
const testing = std.testing;
const formula_mod = @import("malt").formula;

// Formula.deinit() doesn't free derived allocations (bottle_files, deps, oldnames).
// Use an arena to avoid false-positive leak reports from testing.allocator.
fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

const minimal_json =
    \\{
    \\  "name": "wget",
    \\  "full_name": "wget",
    \\  "tap": "homebrew/core",
    \\  "desc": "Internet file retriever",
    \\  "homepage": "https://www.gnu.org/software/wget/",
    \\  "license": "GPL-3.0-or-later",
    \\  "revision": 0,
    \\  "keg_only": false,
    \\  "post_install_defined": false,
    \\  "versions": { "stable": "1.24.5", "head": null },
    \\  "dependencies": ["openssl@3", "libidn2"],
    \\  "oldnames": ["wgetold"],
    \\  "bottle": {
    \\    "stable": {
    \\      "root_url": "https://ghcr.io/v2/homebrew/core/wget/blobs",
    \\      "files": {
    \\        "arm64_sequoia": { "cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:abc123", "sha256": "abc123" },
    \\        "x86_64": { "cellar": ":any", "url": "https://ghcr.io/v2/homebrew/core/wget/blobs/sha256:def456", "sha256": "def456" }
    \\      }
    \\    }
    \\  }
    \\}
;

test "parse minimal formula JSON" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var formula = try formula_mod.parseFormula(alloc, minimal_json);
    defer formula.deinit();

    try testing.expectEqualStrings("wget", formula.name);
    try testing.expectEqualStrings("wget", formula.full_name);
    try testing.expectEqualStrings("1.24.5", formula.version);
    try testing.expectEqualStrings("homebrew/core", formula.tap);
    try testing.expect(!formula.keg_only);
    try testing.expect(!formula.post_install_defined);
    try testing.expectEqual(@as(usize, 2), formula.dependencies.len);
    try testing.expectEqualStrings("openssl@3", formula.dependencies[0]);
    try testing.expectEqualStrings("libidn2", formula.dependencies[1]);
}

test "resolve bottle for current platform" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var formula = try formula_mod.parseFormula(alloc, minimal_json);
    defer formula.deinit();

    const bottle = try formula_mod.resolveBottle(alloc, &formula);
    try testing.expect(bottle.sha256.len > 0);
    try testing.expect(bottle.url.len > 0);
}

test "resolve formula alias" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const canonical = try formula_mod.resolveAlias(alloc, "wgetold", minimal_json);
    try testing.expect(canonical != null);
    try testing.expectEqualStrings("wget", canonical.?);
}

test "alias returns null for non-matching name" {
    var arena = testArena();
    defer arena.deinit();

    const result = try formula_mod.resolveAlias(arena.allocator(), "curl", minimal_json);
    try testing.expect(result == null);
}

test "handle missing bottle for platform" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "name": "test",
        \\  "full_name": "test",
        \\  "tap": "",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0" },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": { "stable": { "files": { "linux_x86_64": { "url": "x", "sha256": "y", "cellar": "z" } } } }
        \\}
    ;
    var formula = try formula_mod.parseFormula(alloc, json);
    defer formula.deinit();

    const result = formula_mod.resolveBottle(alloc, &formula);
    try testing.expectError(formula_mod.FormulaError.NoBottleAvailable, result);
}

test "parse formula with post_install_defined true" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "name": "node",
        \\  "full_name": "node",
        \\  "tap": "homebrew/core",
        \\  "desc": "Node.js",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": true,
        \\  "versions": { "stable": "22.0" },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {}
        \\}
    ;
    var formula = try formula_mod.parseFormula(alloc, json);
    defer formula.deinit();
    try testing.expect(formula.post_install_defined);
}

test "parse formula with service block" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "name": "postgresql@16",
        \\  "full_name": "postgresql@16",
        \\  "tap": "homebrew/core",
        \\  "desc": "Postgres",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "16.4" },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {},
        \\  "service": {
        \\    "run": ["/opt/malt/opt/postgresql@16/bin/postgres", "-D", "/opt/malt/var/postgresql@16"],
        \\    "working_dir": "/opt/malt/var/postgresql@16",
        \\    "log_path": "/opt/malt/var/log/postgresql@16.log",
        \\    "error_log_path": "/opt/malt/var/log/postgresql@16.err",
        \\    "keep_alive": true,
        \\    "run_at_load": true
        \\  }
        \\}
    ;
    var formula = try formula_mod.parseFormula(alloc, json);
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(@as(usize, 3), svc.run.len);
    try testing.expectEqualStrings("/opt/malt/opt/postgresql@16/bin/postgres", svc.run[0]);
    try testing.expectEqualStrings("/opt/malt/var/postgresql@16", svc.working_dir.?);
    try testing.expect(svc.keep_alive);
}

test "formula without service block has null service" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var formula = try formula_mod.parseFormula(alloc, minimal_json);
    defer formula.deinit();
    try testing.expect(formula.service == null);
}
