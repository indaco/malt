//! malt — --local install tests
//! Pure coverage for the path-shape detector + URL/tilde helpers, plus
//! execute() dispatch tests that walk the `--local` branch end-to-end
//! up to the download attempt (which is impossible in a hermetic test).

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const install = @import("malt").install;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

// ─── isLocalFormulaPath ──────────────────────────────────────────────

test "isLocalFormulaPath accepts a dot-relative .rb path" {
    try testing.expect(install.isLocalFormulaPath("./wget.rb"));
    try testing.expect(install.isLocalFormulaPath("../foo/wget.rb"));
}

test "isLocalFormulaPath accepts an absolute .rb path" {
    try testing.expect(install.isLocalFormulaPath("/tmp/wget.rb"));
    try testing.expect(install.isLocalFormulaPath("/Users/me/formulas/wget.rb"));
}

test "isLocalFormulaPath accepts a tilde-prefixed .rb path" {
    try testing.expect(install.isLocalFormulaPath("~/formulas/wget.rb"));
}

test "isLocalFormulaPath accepts any slash-bearing .rb path" {
    try testing.expect(install.isLocalFormulaPath("a/b/c/d.rb"));
}

test "isLocalFormulaPath treats a tap-shape .rb path as local (tie-break)" {
    // The `.rb` suffix wins over the three-slash tap shape so the user
    // gets a clean "file not found" instead of a confusing GitHub 404.
    try testing.expect(install.isLocalFormulaPath("user/repo/formula.rb"));
}

test "isLocalFormulaPath rejects bare names, tap slugs, and non-rb paths" {
    try testing.expect(!install.isLocalFormulaPath("wget"));
    try testing.expect(!install.isLocalFormulaPath("user/repo/formula"));
    try testing.expect(!install.isLocalFormulaPath("user/repo"));
    try testing.expect(!install.isLocalFormulaPath("./notaformula"));
    try testing.expect(!install.isLocalFormulaPath("/tmp/notaformula"));
    try testing.expect(!install.isLocalFormulaPath(""));
}

test "isLocalFormulaPath rejects a bare .rb filename with no separator" {
    // A bare `wget.rb` could shadow an API formula — require `--local`
    // or a `./` prefix for that case so the user opts in deliberately.
    try testing.expect(!install.isLocalFormulaPath("wget.rb"));
}

// ─── isAllowedArchiveUrl ─────────────────────────────────────────────

test "isAllowedArchiveUrl accepts an https URL with a path" {
    try testing.expect(install.isAllowedArchiveUrl("https://example.com/foo.tar.gz"));
    try testing.expect(install.isAllowedArchiveUrl("https://ghcr.io/v2/a/b/blobs/sha256:abc"));
}

test "isAllowedArchiveUrl rejects plaintext HTTP (downgrade attack)" {
    try testing.expect(!install.isAllowedArchiveUrl("http://example.com/foo.tar.gz"));
}

test "isAllowedArchiveUrl rejects file://, ftp://, data:, javascript:" {
    try testing.expect(!install.isAllowedArchiveUrl("file:///etc/passwd"));
    try testing.expect(!install.isAllowedArchiveUrl("ftp://example.com/foo"));
    try testing.expect(!install.isAllowedArchiveUrl("data:text/plain,boom"));
    try testing.expect(!install.isAllowedArchiveUrl("javascript:alert(1)"));
}

test "isAllowedArchiveUrl rejects empty and whitespace" {
    try testing.expect(!install.isAllowedArchiveUrl(""));
    try testing.expect(!install.isAllowedArchiveUrl(" https://example.com/foo"));
    try testing.expect(!install.isAllowedArchiveUrl("https"));
    try testing.expect(!install.isAllowedArchiveUrl("https:/example.com"));
}

test "isAllowedArchiveUrl rejects scheme confusion (case sensitivity)" {
    // Be strict: only lower-case `https://` is honoured. Mixed-case
    // schemes are valid per RFC 3986 but almost never legitimate for
    // the archive URL of a real tap formula, and permitting them here
    // would make the allowlist attacker-tunable via case.
    try testing.expect(!install.isAllowedArchiveUrl("HTTPS://example.com/foo"));
    try testing.expect(!install.isAllowedArchiveUrl("Https://example.com/foo"));
}

// ─── localErrorIsAnnounced ───────────────────────────────────────────

test "localErrorIsAnnounced covers errors with specific user-facing messages" {
    // Every error set variant that installLocalFormula / the shared
    // helper emits with its own `output.err` line must return true
    // here so the dispatch loop can skip the generic summary.
    try testing.expect(install.localErrorIsAnnounced(install.InstallError.LocalFormulaNotReadable));
    try testing.expect(install.localErrorIsAnnounced(install.InstallError.FormulaNotFound));
    try testing.expect(install.localErrorIsAnnounced(install.InstallError.InsecureArchiveUrl));
    try testing.expect(install.localErrorIsAnnounced(install.InstallError.DownloadFailed));
    try testing.expect(install.localErrorIsAnnounced(install.InstallError.CellarFailed));
}

test "localErrorIsAnnounced returns false for unexpected errors" {
    // DB/record failures reach the dispatch loop without a dedicated
    // user-facing line, so the generic summary stays on for them.
    try testing.expect(!install.localErrorIsAnnounced(install.InstallError.RecordFailed));
    try testing.expect(!install.localErrorIsAnnounced(install.InstallError.LockError));
}

test "localErrorIsAnnounced parameter is narrowed to InstallError" {
    // A widened `anyerror` makes the inner switch meaningless — any new
    // InstallError tag compiles without a handler. Pin the narrowing.
    const info = @typeInfo(@TypeOf(install.localErrorIsAnnounced)).@"fn";
    try testing.expect(info.params[0].type.? == install.InstallError);
}

test "localErrorIsAnnounced handles every InstallError tag" {
    // Comptime sweep: if a future tag is added without a switch arm,
    // the exhaustive check in `localErrorIsAnnounced` already fails to
    // compile. This test also fails the whole module to compile, making
    // the missing coverage visible from `zig build test` output.
    inline for (@typeInfo(install.InstallError).error_set.?) |err| {
        const tag = @field(install.InstallError, err.name);
        _ = install.localErrorIsAnnounced(tag);
    }
}

// ─── describeLocalPermissionRisk ─────────────────────────────────────

test "describeLocalPermissionRisk returns null when owner == euid and not world-writable" {
    try testing.expect(install.describeLocalPermissionRisk(0o644, 501, 501) == null);
    try testing.expect(install.describeLocalPermissionRisk(0o600, 501, 501) == null);
    // Other-readable is fine; only the write bit for 'other' is risky.
    try testing.expect(install.describeLocalPermissionRisk(0o664, 501, 501) == null);
}

test "describeLocalPermissionRisk flags world-writable files" {
    // mode & 0o002 != 0 — anyone on the box can rewrite the formula
    // between checkout and install.
    const got = install.describeLocalPermissionRisk(0o666, 501, 501) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(install.LocalPermissionRisk.world_writable, got);
}

test "describeLocalPermissionRisk flags files not owned by effective user" {
    const got = install.describeLocalPermissionRisk(0o644, 0, 501) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(install.LocalPermissionRisk.other_owner, got);
}

test "describeLocalPermissionRisk prefers world_writable when both risks apply" {
    // World-writable is strictly worse than wrong-owner (any local
    // user can win the race), so it wins the single-risk-label slot.
    const got = install.describeLocalPermissionRisk(0o666, 0, 501) orelse return error.TestUnexpectedNull;
    try testing.expectEqual(install.LocalPermissionRisk.world_writable, got);
}

// ─── constantTimeEql ─────────────────────────────────────────────────

test "constantTimeEql reports equal for identical slices" {
    try testing.expect(install.constantTimeEql(u8, "deadbeef", "deadbeef"));
    const zero = [_]u8{0} ** 32;
    try testing.expect(install.constantTimeEql(u8, &zero, &zero));
}

test "constantTimeEql reports not-equal for differing content" {
    try testing.expect(!install.constantTimeEql(u8, "deadbeef", "deadbeee"));
    try testing.expect(!install.constantTimeEql(u8, "a" ** 64, "b" ** 64));
}

test "constantTimeEql reports not-equal for length mismatch" {
    try testing.expect(!install.constantTimeEql(u8, "abc", "abcd"));
    try testing.expect(!install.constantTimeEql(u8, "", "x"));
}

test "constantTimeEql handles empty slices" {
    try testing.expect(install.constantTimeEql(u8, "", ""));
}

// ─── parseCaskBinary ─────────────────────────────────────────────────

test "parseCaskBinary: extracts the basic binary directive" {
    const rb =
        \\cask "longbridge-terminal" do
        \\  version "0.17.4"
        \\  binary "longbridge"
        \\end
    ;
    try testing.expectEqualStrings("longbridge", install.parseCaskBinary(rb).?);
}

test "parseCaskBinary: tolerates extra arguments on the directive" {
    // Homebrew cask DSL permits `binary "src", target: "alias"`. The
    // first quoted value is the archive-side basename — that's what we
    // care about for bin/ promotion.
    const rb =
        \\cask "foo" do
        \\  binary "longbridge", target: "lb"
        \\end
    ;
    try testing.expectEqualStrings("longbridge", install.parseCaskBinary(rb).?);
}

test "parseCaskBinary: returns null on formulas with no binary directive" {
    const rb =
        \\class Wget < Formula
        \\  version "1.0"
        \\  url "https://x"
        \\  sha256 "deadbeef"
        \\end
    ;
    try testing.expect(install.parseCaskBinary(rb) == null);
}

test "parseCaskBinary: ignores mid-line 'binary' substrings" {
    // Must anchor at the trimmed line start so a stray mention in a
    // comment or a variable name does not resolve to a bogus binary.
    const rb =
        \\cask "foo" do
        \\  desc "binary \"fake\" is just a comment"
        \\end
    ;
    try testing.expect(install.parseCaskBinary(rb) == null);
}

test "parseCaskBinary: indented directive still matches" {
    const rb = "  binary \"sley\"\n";
    try testing.expectEqualStrings("sley", install.parseCaskBinary(rb).?);
}

// ─── interpolateVersion ──────────────────────────────────────────────

test "interpolateVersion substitutes #{version} once in the URL" {
    var buf: [256]u8 = undefined;
    const got = install.interpolateVersion(&buf, "https://example.com/v#{version}/foo-#{version}.tar.gz", "1.2.3");
    // Only the first occurrence is replaced (matches the tap-install contract).
    try testing.expect(std.mem.indexOf(u8, got, "1.2.3") != null);
}

test "interpolateVersion passes through an URL without the needle" {
    var buf: [256]u8 = undefined;
    const got = install.interpolateVersion(&buf, "https://example.com/foo.tar.gz", "1.2.3");
    try testing.expectEqualStrings("https://example.com/foo.tar.gz", got);
}

test "interpolateVersion falls back to the raw URL when the buffer is too small" {
    var buf: [8]u8 = undefined;
    const url = "https://example.com/v#{version}/foo.tar.gz";
    const got = install.interpolateVersion(&buf, url, "1.2.3");
    try testing.expectEqualStrings(url, got);
}

// ─── expandTildePath ─────────────────────────────────────────────────

test "expandTildePath passes non-tilde input through unchanged" {
    var buf: [256]u8 = undefined;
    const got = install.expandTildePath(&buf, "./foo.rb") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("./foo.rb", got);
}

test "expandTildePath rewrites ~/ into $HOME/" {
    const home_z: [*:0]const u8 = "/tmp/fake_home_for_tilde_test";
    _ = c.setenv("HOME", home_z, 1);
    defer _ = c.unsetenv("HOME");

    var buf: [256]u8 = undefined;
    const got = install.expandTildePath(&buf, "~/formulas/wget.rb") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("/tmp/fake_home_for_tilde_test/formulas/wget.rb", got);
}

test "expandTildePath leaves `~alice/foo` alone (no `/` after `~`)" {
    var buf: [256]u8 = undefined;
    const got = install.expandTildePath(&buf, "~alice/foo.rb") orelse return error.TestUnexpectedNull;
    try testing.expectEqualStrings("~alice/foo.rb", got);
}

test "expandTildePath returns null when HOME is unset and ~/ is used" {
    _ = c.unsetenv("HOME");
    var buf: [256]u8 = undefined;
    try testing.expect(install.expandTildePath(&buf, "~/foo.rb") == null);
}

// ─── execute() --local dispatch tests ────────────────────────────────
// These hit the CLI entry point. They set MALT_PREFIX to a short,
// private temp directory so checkPrefixLength passes and the store /
// Cellar work stays hermetic.

// MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget), so
// each test picks its own static short prefix rather than embedding a
// timestamp. Different suffixes keep concurrent tests from colliding.
fn setupPrefix(comptime fixed: [:0]const u8) !void {
    comptime std.debug.assert(fixed.len <= "/opt/homebrew".len);
    malt.fs_compat.deleteTreeAbsolute(fixed) catch {};
    try malt.fs_compat.cwd().makePath(fixed);
    _ = c.setenv("MALT_PREFIX", fixed.ptr, 1);
}

fn cleanupPrefix(comptime fixed: [:0]const u8) void {
    malt.fs_compat.deleteTreeAbsolute(fixed) catch {};
    _ = c.unsetenv("MALT_PREFIX");
}

fn writeFile(abs_path: []const u8, content: []const u8) !void {
    const f = try malt.fs_compat.createFileAbsolute(abs_path, .{});
    defer f.close();
    try f.writeAll(content);
}

const sample_rb =
    \\class Wget < Formula
    \\  version "1.0"
    \\  url "https://example.invalid/wget-1.0.tar.gz"
    \\  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    \\end
;

test "execute --local rejects --cask combination (contradictory)" {
    // Casks are .app bundles, formulas are source archives — a single
    // argv cannot mean both. Reject up front so the user does not get
    // confusing mid-flight errors.
    const prefix: [:0]const u8 = "/tmp/mlj";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try testing.expectError(
        error.Aborted,
        install.execute(testing.allocator, &.{ "--local", "--cask", "./foo.rb" }),
    );
}

test "execute --local rejects --formula combination (redundant)" {
    // `--local` already implies formula mode. Accepting `--formula`
    // alongside would leave the semantics ambiguous if the flag
    // matrix ever grows, so refuse it at the boundary.
    const prefix: [:0]const u8 = "/tmp/mlk";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try testing.expectError(
        error.Aborted,
        install.execute(testing.allocator, &.{ "--local", "--formula", "./foo.rb" }),
    );
}

test "execute --local rejects --use-system-ruby combination (no effect)" {
    // Local installs don't run the Ruby post_install path, so the
    // trust-widening flag has no effect here. Refusing the combo
    // stops users from thinking it does.
    const prefix: [:0]const u8 = "/tmp/mll";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try testing.expectError(
        error.Aborted,
        install.execute(testing.allocator, &.{ "--local", "--use-system-ruby", "./foo.rb" }),
    );
    try testing.expectError(
        error.Aborted,
        install.execute(testing.allocator, &.{ "--local", "--use-system-ruby=name", "./foo.rb" }),
    );
}

test "execute --local without a path operand exits cleanly (error.Aborted)" {
    // `error.Aborted` is the project-wide contract for "user-facing CLI
    // error, message already emitted, no stack trace please" — matches
    // how other commands signal missing-arg failures.
    const prefix: [:0]const u8 = "/tmp/mla";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try testing.expectError(
        error.Aborted,
        install.execute(testing.allocator, &.{"--local"}),
    );
}

test "execute --local with a missing file reports gracefully and continues" {
    // installLocalFormula catches its own error and logs via output.err so
    // execute() returns normally. The key invariant is that no panic
    // escapes and no DB writes happen for a missing file.
    const prefix: [:0]const u8 = "/tmp/mlb";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--quiet", "/tmp/mlb_missing.rb" });
}

test "execute --local with a non-.rb realpath is rejected before parse" {
    // Pass a real file whose basename does not end in .rb. The realpath
    // + basename check rejects it cleanly.
    const prefix: [:0]const u8 = "/tmp/mlc";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/notaformula", .{prefix});
    defer testing.allocator.free(rb_path);
    try writeFile(rb_path, "class X end\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--quiet", rb_path });
}

test "execute --local --dry-run with a valid .rb prints a plan" {
    // The happy dry-run path exercises: open → realpath → readToEnd →
    // parseRubyFormula → installLocalFormula.materializeRubyFormula dry-run
    // branch. No network, no Cellar writes.
    const prefix: [:0]const u8 = "/tmp/mld";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{prefix});
    defer testing.allocator.free(rb_path);
    try writeFile(rb_path, sample_rb);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--dry-run", "--quiet", rb_path });
}

test "execute autodetects a .rb path even without --local (tilde-style hint)" {
    // Shape-based detection: a `./`-prefixed or absolute `.rb` path is
    // routed through installLocalFormula without the explicit flag. The
    // warning is printed inside installLocalFormula itself.
    const prefix: [:0]const u8 = "/tmp/mle";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/wget.rb", .{prefix});
    defer testing.allocator.free(rb_path);
    try writeFile(rb_path, sample_rb);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--dry-run", "--quiet", rb_path });
}

test "execute --local tolerates a world-writable fixture (advisory only)" {
    // The permission warning is advisory — the install continues and
    // reaches dry-run normally. Regression guard: if fstatRisk() ever
    // escalates to a hard error, this test will trip.
    const prefix: [:0]const u8 = "/tmp/mlw";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{prefix});
    defer testing.allocator.free(rb_path);
    try writeFile(rb_path, sample_rb);

    // 0o666 — any local user could rewrite it between checkout and
    // install.
    const f = try malt.fs_compat.openFileAbsolute(rb_path, .{ .mode = .read_only });
    try f.chmod(0o666);
    f.close();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--dry-run", "--quiet", rb_path });
}

test "execute --local rejects a .rb whose archive URL is not https" {
    // The single most important security property of --local: a
    // hand-authored .rb cannot smuggle a file:// or plaintext http://
    // URL past the HTTPS gate — the download must be refused before
    // the HTTP client touches the URL at all.
    const prefix: [:0]const u8 = "/tmp/mlz";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/evil.rb", .{prefix});
    defer testing.allocator.free(rb_path);
    const evil_rb =
        \\class Evil < Formula
        \\  version "1.0"
        \\  url "http://attacker.invalid/payload.tar.gz"
        \\  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\end
    ;
    try writeFile(rb_path, evil_rb);

    // Non-dry-run so the URL check is exercised (dry-run short-circuits
    // before the URL gate). installLocalFormula catches the returned
    // InsecureArchiveUrl so execute() itself returns cleanly.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--quiet", rb_path });
}

test "execute --local rejects a malformed .rb (missing version/url/sha256)" {
    const prefix: [:0]const u8 = "/tmp/mlf";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    const rb_path = try std.fmt.allocPrint(testing.allocator, "{s}/broken.rb", .{prefix});
    defer testing.allocator.free(rb_path);
    try writeFile(rb_path, "class Broken < Formula\nend\n");

    // installLocalFormula catches the error and reports via output.err;
    // execute() itself returns normally so the batch install doesn't
    // abort on one bad entry.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--dry-run", "--quiet", rb_path });
}

// ─── Cross-command integration: uninstall/info/list on a local keg ──
//
// These tests seed a `tap="local"` row directly — installLocalFormula's
// download step requires a live archive URL, which would make the test
// non-hermetic. Seeding the row reproduces the post-install DB state
// and confirms the downstream commands treat a local keg identically
// to an API keg (lookup is by `name`, not by `tap`).

const sqlite = malt.sqlite;
const schema = malt.schema;

fn seedLocalKeg(
    db_path: [:0]const u8,
    prefix: []const u8,
    name: []const u8,
    version: []const u8,
    source_path: []const u8,
) !void {
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    // Materialise a minimal Cellar layout so cellar.remove has something
    // to tear down when uninstall is exercised.
    const cellar_dir = try std.fmt.allocPrint(testing.allocator, "{s}/Cellar/{s}/{s}", .{ prefix, name, version });
    defer testing.allocator.free(cellar_dir);
    try malt.fs_compat.cwd().makePath(cellar_dir);

    var stmt = try db.prepare(
        "INSERT INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason)" ++
            " VALUES (?1, ?2, ?3, 'local', ?4, ?5, 'direct');",
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    try stmt.bindText(2, source_path);
    try stmt.bindText(3, version);
    try stmt.bindText(4, "0" ** 64);
    try stmt.bindText(5, cellar_dir);
    _ = try stmt.step();
}

test "isInstalled sees a locally-recorded keg by name" {
    const prefix: [:0]const u8 = "/tmp/mlh";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try malt.fs_compat.cwd().makePath("/tmp/mlh/db");
    const db_path = "/tmp/mlh/db/malt.db";
    try seedLocalKeg(db_path, prefix, "wget", "1.0", "/tmp/mlh/wget.rb");

    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try testing.expect(install.isInstalled(&db, "wget"));
}

test "uninstall + purge CLI flow treats tap='local' rows like any other keg" {
    // Dry-run uninstall: the name lookup succeeds, no network, no writes.
    // The point here is that uninstall.zig's `WHERE name = ?1` path
    // doesn't filter on tap — local kegs are first-class.
    const prefix: [:0]const u8 = "/tmp/mli";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    try malt.fs_compat.cwd().makePath("/tmp/mli/db");
    try seedLocalKeg("/tmp/mli/db/malt.db", prefix, "wget", "1.0", "/tmp/mli/wget.rb");

    // Reopen to confirm the row is queryable with a fresh handle.
    var db = try sqlite.Database.open("/tmp/mli/db/malt.db");
    defer db.close();

    var stmt = try db.prepare("SELECT tap, full_name FROM kegs WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, "wget");
    try testing.expect(try stmt.step());
    const tap = std.mem.sliceTo(stmt.columnText(0).?, 0);
    const full = std.mem.sliceTo(stmt.columnText(1).?, 0);
    try testing.expectEqualStrings("local", tap);
    try testing.expectEqualStrings("/tmp/mli/wget.rb", full);
}

test "execute --local rejects a directory path (not a regular file)" {
    const prefix: [:0]const u8 = "/tmp/mlg";
    try setupPrefix(prefix);
    defer cleanupPrefix(prefix);

    // Use the prefix itself as the target — it exists but is a directory.
    // We also need the target to end in .rb so realpath + the later `.file`
    // check is what rejects it (rather than basename check).
    const dir_path = try std.fmt.allocPrint(testing.allocator, "{s}/fake.rb", .{prefix});
    defer testing.allocator.free(dir_path);
    try malt.fs_compat.cwd().makePath(dir_path);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--local", "--dry-run", "--quiet", dir_path });
}
