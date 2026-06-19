//! malt — formula module tests
//! Tests for formula JSON parsing, alias resolution, and bottle selection.

const std = @import("std");
const builtin = @import("builtin");
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

    const bottle = try formula_mod.resolveBottle(&formula);
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

    const result = formula_mod.resolveBottle(&formula);
    try testing.expectError(formula_mod.FormulaError.NoBottleAvailable, result);
}

test "resolveBottle prefers tahoe over sequoia on current arch" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // Bottle map advertises both tahoe and sequoia variants for both arches.
    // Newer-OS preference: tahoe must win on macOS 26 for the current arch.
    const json =
        \\{
        \\  "name": "rust",
        \\  "full_name": "rust",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "license": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "1.0", "head": null },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {
        \\    "stable": {
        \\      "root_url": "https://example.com",
        \\      "files": {
        \\        "arm64_tahoe":   { "cellar": ":any", "url": "u1", "sha256": "arm64_tahoe_sha" },
        \\        "arm64_sequoia": { "cellar": ":any", "url": "u2", "sha256": "arm64_sequoia_sha" },
        \\        "tahoe":         { "cellar": ":any", "url": "u3", "sha256": "tahoe_sha" },
        \\        "sequoia":       { "cellar": ":any", "url": "u4", "sha256": "sequoia_sha" }
        \\      }
        \\    }
        \\  }
        \\}
    ;
    var formula = try formula_mod.parseFormula(alloc, json);
    defer formula.deinit();

    const bottle = try formula_mod.resolveBottle(&formula);

    const expected_sha = switch (builtin.cpu.arch) {
        .aarch64 => "arm64_tahoe_sha",
        .x86_64 => "tahoe_sha",
        else => "arm64_tahoe_sha",
    };
    try testing.expectEqualStrings(expected_sha, bottle.sha256);
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

test "parse formula with realistic Homebrew API service shape" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    // The live API renders paths with a literal `$HOMEBREW_PREFIX` token (kept
    // verbatim here; expansion happens at registration) and encodes keep_alive
    // as an object (`{"always": true}`), not a bare bool.
    const json =
        \\{
        \\  "name": "redis",
        \\  "full_name": "redis",
        \\  "tap": "homebrew/core",
        \\  "desc": "Redis",
        \\  "homepage": "",
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": false,
        \\  "versions": { "stable": "8.0" },
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {},
        \\  "service": {
        \\    "run": ["$HOMEBREW_PREFIX/opt/redis/bin/redis-server", "$HOMEBREW_PREFIX/etc/redis.conf"],
        \\    "run_type": "immediate",
        \\    "keep_alive": { "always": true },
        \\    "working_dir": "$HOMEBREW_PREFIX/var",
        \\    "log_path": "$HOMEBREW_PREFIX/var/log/redis.log"
        \\  }
        \\}
    ;
    var formula = try formula_mod.parseFormula(alloc, json);
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(@as(usize, 2), svc.run.len);
    try testing.expectEqualStrings("$HOMEBREW_PREFIX/opt/redis/bin/redis-server", svc.run[0]);
    // An object keep_alive means "keep this service alive" — not the `false`
    // that a bool-only check would yield.
    try testing.expect(svc.keep_alive);
}

// Wrap a `service` block in an otherwise-minimal formula and parse it, so the
// schedule tests vary only the part under test.
fn parseWithService(alloc: std.mem.Allocator, service_block: []const u8) !formula_mod.Formula {
    const json = try std.fmt.allocPrint(alloc,
        \\{{
        \\  "name": "svc", "full_name": "svc", "tap": "homebrew/core",
        \\  "desc": "", "homepage": "", "revision": 0, "keg_only": false,
        \\  "post_install_defined": false, "versions": {{ "stable": "1.0" }},
        \\  "dependencies": [], "oldnames": [], "bottle": {{}},
        \\  "service": {{ "run": ["/opt/malt/opt/svc/bin/svc"]{s} }}
        \\}}
    , .{service_block});
    return formula_mod.parseFormula(alloc, json);
}

test "parse run_type interval builds an interval schedule" {
    var arena = testArena();
    defer arena.deinit();
    var formula = try parseWithService(arena.allocator(), ", \"run_type\": \"interval\", \"interval\": 300");
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(formula_mod.Schedule{ .interval = 300 }, svc.schedule);
}

test "parse run_type immediate yields immediate schedule" {
    var arena = testArena();
    defer arena.deinit();
    var formula = try parseWithService(arena.allocator(), ", \"run_type\": \"immediate\"");
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(formula_mod.Schedule.immediate, svc.schedule);
}

test "parse absent run_type defaults to immediate" {
    var arena = testArena();
    defer arena.deinit();
    var formula = try parseWithService(arena.allocator(), "");
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(formula_mod.Schedule.immediate, svc.schedule);
}

test "parse run_type cron builds a calendar schedule" {
    var arena = testArena();
    defer arena.deinit();
    var formula = try parseWithService(arena.allocator(), ", \"run_type\": \"cron\", \"cron\": \"30 4 * * *\"");
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    switch (svc.schedule) {
        .calendar => |entries| {
            try testing.expectEqual(@as(usize, 1), entries.len);
            try testing.expectEqual(@as(?u8, 30), entries[0].minute);
            try testing.expectEqual(@as(?u8, 4), entries[0].hour);
        },
        else => return error.TestExpectedCalendarSchedule,
    }
}

test "parse run_type cron with a missing or malformed expression is a hard error" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();
    // A missing `cron` string never silently falls back to immediate.
    try testing.expectError(error.CronMalformed, parseWithService(alloc, ", \"run_type\": \"cron\""));
    // Bounds and unsupported tokens surface the parser's specific errors.
    try testing.expectError(error.CronOutOfRange, parseWithService(alloc, ", \"run_type\": \"cron\", \"cron\": \"99 0 * * *\""));
    try testing.expectError(error.CronUnsupported, parseWithService(alloc, ", \"run_type\": \"cron\", \"cron\": \"@daily\""));
}

test "parse unknown run_type is a hard error" {
    var arena = testArena();
    defer arena.deinit();
    try testing.expectError(
        error.UnknownRunType,
        parseWithService(arena.allocator(), ", \"run_type\": \"sometimes\""),
    );
}

test "parse interval run_type with a malformed interval is a hard error" {
    var arena = testArena();
    defer arena.deinit();
    const malformed = [_][]const u8{
        ", \"run_type\": \"interval\"", // missing interval
        ", \"run_type\": \"interval\", \"interval\": \"300\"", // non-numeric
        ", \"run_type\": \"interval\", \"interval\": 0", // zero, out of range
        ", \"run_type\": \"interval\", \"interval\": -5", // negative
        ", \"run_type\": \"interval\", \"interval\": 31536001", // one past the cap
    };
    for (malformed) |block| {
        try testing.expectError(error.InvalidInterval, parseWithService(arena.allocator(), block));
    }
}

test "parse interval at the cap is accepted" {
    var arena = testArena();
    defer arena.deinit();
    // max_interval_secs == 365 days in seconds; the boundary must parse, not reject.
    var formula = try parseWithService(arena.allocator(), ", \"run_type\": \"interval\", \"interval\": 31536000");
    defer formula.deinit();
    const svc = formula.service orelse return error.TestExpectedSomething;
    try testing.expectEqual(formula_mod.Schedule{ .interval = 31_536_000 }, svc.schedule);
}

test "formula without service block has null service" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var formula = try formula_mod.parseFormula(alloc, minimal_json);
    defer formula.deinit();
    try testing.expect(formula.service == null);
}

// ─── pkgVersion / Formula.pkg_version ────────────────────────────────
//
// Homebrew's canonical on-disk name for a keg is `<version>_<revision>`
// when revision > 0, else `<version>`. Bottles are built against that
// path and their Mach-O LC_LOAD_DYLIB entries bake it in, so dropping
// the `_N` suffix breaks dyld at runtime (see issue #77: pcre2 10.47_1
// installed as `pcre2/10.47` → `dyld: Library not loaded`).

test "pkgVersion returns the plain version when revision is zero" {
    var buf: [64]u8 = undefined;
    const got = try formula_mod.pkgVersion(&buf, "1.24.5", 0);
    try testing.expectEqualStrings("1.24.5", got);
}

test "pkgVersion appends _<revision> when revision > 0" {
    var buf: [64]u8 = undefined;
    const got = try formula_mod.pkgVersion(&buf, "10.47", 1);
    try testing.expectEqualStrings("10.47_1", got);
    const got2 = try formula_mod.pkgVersion(&buf, "3.6.2", 3);
    try testing.expectEqualStrings("3.6.2_3", got2);
}

test "pkgVersion treats negative revision as zero (defensive)" {
    // Homebrew never ships negative revisions; be safe rather than
    // emitting `10.47_-1` if upstream JSON ever goes wrong.
    var buf: [64]u8 = undefined;
    const got = try formula_mod.pkgVersion(&buf, "10.47", -1);
    try testing.expectEqualStrings("10.47", got);
}

test "pkgVersion returns NoSpaceLeft on a buffer too small to hold the result" {
    // bufPrint-style contract: overflow surfaces as NoSpaceLeft so
    // callers handle it the same way they handle every other path
    // formatter in malt.
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formula_mod.pkgVersion(&small, "10.47", 1));
}

test "parseFormula populates pkg_version with the _<revision> suffix" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    const json =
        \\{
        \\  "name": "pcre2", "full_name": "pcre2", "tap": "homebrew/core",
        \\  "desc": "", "homepage": "", "revision": 1,
        \\  "versions": {"stable": "10.47"},
        \\  "dependencies": [], "oldnames": [],
        \\  "keg_only": false, "post_install_defined": false,
        \\  "bottle": {"stable": {"root_url": "", "files": {}}}
        \\}
    ;
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();
    try testing.expectEqualStrings("10.47", f.version);
    try testing.expectEqual(@as(i64, 1), f.revision);
    try testing.expectEqualStrings("10.47_1", f.pkg_version);
}

test "parseFormula's pkg_version equals version when revision is zero" {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var f = try formula_mod.parseFormula(alloc, minimal_json);
    defer f.deinit();
    try testing.expectEqualStrings("1.24.5", f.version);
    try testing.expectEqualStrings("1.24.5", f.pkg_version);
}
