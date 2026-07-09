//! malt — formula post_install source extraction.
//!
//! Pairs DSL parsing (to gate sibling-def inclusion) with the hash-pinned
//! GitHub fetch fallback. Owns the DSL ↔ net dependency so the subprocess
//! driver reaches both only through here — never directly.

const std = @import("std");
const pins = @import("../pins.zig");
const hash_mod = @import("../hash.zig");
const http_client = @import("../../net/client.zig");
const api_mod = @import("../../net/api.zig");
const dsl_lexer = @import("../dsl/lexer.zig");
const dsl_parser = @import("../dsl/parser.zig");

/// Upper bound on a fetched formula .rb blob. The Homebrew-wide 99th
/// percentile is ~40 KiB; 1 MiB is orders of magnitude of headroom
/// without giving a hostile response room to grow.
const max_formula_rb_bytes: usize = 1024 * 1024;

/// Outcome of the GitHub fallback fetch. Distinguishing `body_not_found`
/// (we got source, no parseable post_install) from `fetch_failed`
/// (network, HTTP, hash, or manifest miss) is what lets the resolver
/// surface an actionable tag instead of collapsing onto TapNotFound.
pub const FetchOutcome = union(enum) {
    body: []const u8,
    body_not_found,
    fetch_failed,
};

/// Tagged variant of `fetchPostInstallFromGitHub` that preserves the
/// distinction between a fetch arm that failed and one that succeeded
/// but yielded no extractable body. The subprocess resolver consumes
/// this; the public optional-slice wrapper is what CLI call sites use.
pub fn fetchPostInstallFromGitHubTagged(
    io: std.Io,
    environ: std.process.Environ,
    allocator: std.mem.Allocator,
    name: []const u8,
) FetchOutcome {
    // Reject anything that wouldn't pass the API name allowlist
    // ([a-z0-9@._+-]) — the URL path substitutes the name directly.
    api_mod.validateName(name) catch return .fetch_failed;

    // Fail-closed: no manifest entry, no fetch. The caller decides whether
    // to warn — core stays headless.
    const expected_hash = pins.expectedSha256(name) orelse return .fetch_failed;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://raw.githubusercontent.com/Homebrew/homebrew-core/{s}/Formula/{c}/{s}.rb",
        .{ &pins.homebrew_core_commit_sha, name[0], name },
    ) catch return .fetch_failed;

    var http = http_client.HttpClient.init(io, environ, allocator);
    defer http.deinit();

    var resp = http.get(url) catch return .fetch_failed;
    defer resp.deinit();
    if (resp.status != 200) return .fetch_failed;
    if (resp.body.len == 0 or resp.body.len > max_formula_rb_bytes) return .fetch_failed;

    var actual_hex: [pins.sha256_hex_len]u8 = undefined;
    pins.sha256Hex(resp.body, &actual_hex);
    // Constant-time compare matches every other SHA check in the install
    // / bottle / verify path; no timing oracle today, but the consistency
    // makes the spawn-audit guard's job easier.
    if (!hash_mod.constantTimeEql(u8, actual_hex[0..], expected_hash)) return .fetch_failed;

    if (extractPostInstallFromSource(allocator, resp.body)) |body| {
        return .{ .body = body };
    }
    return .body_not_found;
}

/// Fetch a formula's .rb source from the pinned homebrew-core commit,
/// verify its SHA256 against the embedded manifest, and extract the
/// post_install body.
///
/// This path is the fallback when the homebrew-core tap is not cloned
/// locally. It refuses anything whose hash isn't pre-authorized in
/// `pins_manifest.txt` — a floating-HEAD fetch would give an attacker
/// who controls the raw.githubusercontent.com response (MITM with a
/// valid cert, compromised CDN edge, branch rewrite) a direct path to
/// code execution via `--use-system-ruby`.
///
/// Returns the post_install body or null on any fetch / verify / parse
/// failure. All failures are silent-to-caller; the caller decides
/// whether to warn.
pub fn fetchPostInstallFromGitHub(io: std.Io, environ: std.process.Environ, allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return switch (fetchPostInstallFromGitHubTagged(io, environ, allocator, name)) {
        .body => |b| b,
        .body_not_found, .fetch_failed => null,
    };
}

/// Extract post_install body + any sibling `def` blocks at the same indent,
/// concatenated so the DSL sees helpers registered before the body runs.
/// Without this, formulas like ca-certificates/llvm@21 whose post_install
/// calls into private helpers would fall back to `--use-system-ruby`.
pub fn extractPostInstallFromSource(allocator: std.mem.Allocator, source: []const u8) ?[]const u8 {
    const post_install_span = findDefBlock(source, "post_install") orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Siblings first — registered as user methods before the post_install
    // body runs. On parse fail we emit an empty stub under the sibling's
    // name so a dispatcher post_install (ca-certificates, …) resolves to a
    // no-op instead of logging `unknown_method` and tripping hasErrors().
    var pos: usize = 0;
    while (findAnyDefBlockAtIndent(source, pos, post_install_span.indent)) |span| {
        const is_self = std.mem.eql(u8, span.name, "post_install");
        if (!is_self) {
            if (canParseBlock(allocator, source[span.block_start..span.block_end])) {
                out.appendSlice(allocator, source[span.block_start..span.block_end]) catch return null;
                out.append(allocator, '\n') catch return null;
            } else {
                out.appendSlice(allocator, "def ") catch return null;
                out.appendSlice(allocator, span.name) catch return null;
                out.appendSlice(allocator, "\nend\n") catch return null;
            }
        }
        pos = span.block_end;
    }

    // Then the post_install body itself (no `def`/`end` wrapper).
    out.appendSlice(allocator, source[post_install_span.body_start..post_install_span.body_end]) catch return null;

    return out.toOwnedSlice(allocator) catch return null;
}

/// Run the DSL parser over an isolated sibling-def block and report whether
/// it produced zero diagnostics. Used to gate sibling inclusion so a formula
/// whose `def install` or `def macos_post_install` contains Ruby we don't
/// speak yet (keyword args, `Tempfile`, `.scan` regex blocks, …) doesn't
/// wreck the whole post_install extraction.
fn canParseBlock(allocator: std.mem.Allocator, src: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lex = dsl_lexer.Lexer.init(src);
    var p = dsl_parser.Parser.init(arena.allocator(), &lex);
    _ = p.parseBlock() catch return false;
    return p.diagnostics().len == 0;
}

/// Span describing a single `def NAME ... end` block at a known indent.
const DefSpan = struct {
    name: []const u8,
    indent: usize,
    block_start: usize, // column 0 of the `def` line
    block_end: usize, // index AFTER the matching `end` line's newline
    body_start: usize, // index just after the `def` line's newline
    body_end: usize, // `line_start` of the matching `end`
};

/// Find the named def (`def <name>`) at class-body indent and return its span.
fn findDefBlock(source: []const u8, name: []const u8) ?DefSpan {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "def {s}", .{name}) catch return null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, marker)) |idx| {
        const span = defSpanAt(source, idx) orelse {
            pos = idx + marker.len;
            continue;
        };
        if (std.mem.eql(u8, span.name, name)) return span;
        pos = span.block_end;
    }
    return null;
}

/// Return the next `def ... end` block at `indent` starting at or after
/// `pos`. Returns null when no more defs at that indent exist.
fn findAnyDefBlockAtIndent(source: []const u8, start: usize, indent: usize) ?DefSpan {
    var pos = start;
    while (std.mem.indexOfPos(u8, source, pos, "def ")) |idx| {
        const span = defSpanAt(source, idx) orelse {
            pos = idx + 4;
            continue;
        };
        if (span.indent == indent) return span;
        pos = span.block_end;
    }
    return null;
}

/// If `idx` points at the `d` of a `def` that starts a line, build its
/// DefSpan. Returns null if the context isn't a real top-of-line def.
fn defSpanAt(source: []const u8, idx: usize) ?DefSpan {
    // Must be at line start (optionally preceded by spaces).
    const line_start = if (idx == 0)
        0
    else if (std.mem.findScalarLast(u8, source[0..idx], '\n')) |nl|
        nl + 1
    else
        0;

    // Verify the gap between line_start and idx is only spaces.
    for (source[line_start..idx]) |c| if (c != ' ') return null;
    const indent = idx - line_start;

    // Skip `def ` + optional leading whitespace to the name.
    var name_start = idx + 4; // after "def "
    while (name_start < source.len and source[name_start] == ' ') name_start += 1;

    // Ruby method names: letters, digits, `_`, optional trailing `?`/`!`/`=`.
    var ne = name_start;
    while (ne < source.len) : (ne += 1) {
        const c = source[ne];
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        break;
    }
    if (ne < source.len and (source[ne] == '?' or source[ne] == '!' or source[ne] == '=')) {
        ne += 1;
    }
    if (ne == name_start) return null;

    const body_start = std.mem.findScalarPos(u8, source, idx, '\n') orelse return null;
    const matching_end = findMatchingEnd(source, body_start + 1, indent) orelse return null;

    return .{
        .name = source[name_start..ne],
        .indent = indent,
        .block_start = line_start,
        .block_end = matching_end.block_end,
        .body_start = body_start + 1,
        .body_end = matching_end.end_line_start,
    };
}

/// Locate the matching `end` line at exactly `indent` columns. Returns both
/// the index AFTER the end line's newline and the index of the end line's
/// first character so callers can slice both the block and its body.
fn findMatchingEnd(source: []const u8, start: usize, indent: usize) ?struct {
    end_line_start: usize,
    block_end: usize,
} {
    var pos = start;
    while (pos < source.len) {
        const line_start = pos;
        const line_end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;

        var line_indent: usize = 0;
        var scan = line_start;
        while (scan < line_end and source[scan] == ' ') : (scan += 1) line_indent += 1;

        if (line_indent == indent and
            line_end - scan >= 3 and
            std.mem.eql(u8, source[scan..@min(scan + 3, line_end)], "end") and
            (scan + 3 >= line_end or source[scan + 3] == ' ' or source[scan + 3] == '\n'))
        {
            const block_end = if (line_end < source.len) line_end + 1 else source.len;
            return .{ .end_line_start = line_start, .block_end = block_end };
        }

        pos = if (line_end < source.len) line_end + 1 else source.len;
    }
    return null;
}

/// True when the source declares a declarative `post_install_steps do`
/// block. Detection only — the steps grammar (keyword args, symbols) is
/// outside the DSL, so callers surface a loud skip instead of extracting
/// a body from it.
pub fn hasPostInstallStepsBlock(source: []const u8) bool {
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        const marker = "post_install_steps";
        if (!std.mem.startsWith(u8, t, marker)) continue;
        // Word boundary: `post_install_steps` then whitespace (`do` follows).
        if (t.len > marker.len and (t[marker.len] == ' ' or t[marker.len] == '\t')) return true;
    }
    return false;
}

/// File-IO twin of `hasPostInstallStepsBlock`, mirroring
/// `extractPostInstallBody`'s read contract. False on any IO failure —
/// the caller only uses it to decide whether a skip deserves a warning.
pub fn rbHasPostInstallSteps(io: std.Io, allocator: std.mem.Allocator, rb_path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, rb_path, .{}) catch return false;
    defer file.close(io);

    const st = file.stat(io) catch return false;
    const size: usize = @intCast(@min(@as(u64, max_formula_rb_bytes), st.size));
    const source = allocator.alloc(u8, size) catch return false;
    defer allocator.free(source);
    const n = file.readPositionalAll(io, source, 0) catch return false;

    return hasPostInstallStepsBlock(source[0..n]);
}

/// Extract the post_install method body + sibling helpers from a formula
/// .rb source file. Thin file-IO wrapper around `extractPostInstallFromSource`
/// so the parsing contract lives in one place.
pub fn extractPostInstallBody(io: std.Io, allocator: std.mem.Allocator, rb_path: []const u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, rb_path, .{}) catch return null;
    defer file.close(io);

    const st = file.stat(io) catch return null;
    const size: usize = @intCast(@min(@as(u64, max_formula_rb_bytes), st.size));
    const source = allocator.alloc(u8, size) catch return null;
    defer allocator.free(source);
    const n = file.readPositionalAll(io, source, 0) catch return null;

    return extractPostInstallFromSource(allocator, source[0..n]);
}

// --- tests ---------------------------------------------------------------
// Inline because these are unit tests for pure extraction logic. Filesystem
// fixtures use `std.Io` directly; the fetch tests pass `.empty` environ and
// short-circuit before any network I/O — the lib test root can't reach the
// test-only `test_io` shim.

const testing = std.testing;

fn testIo() std.Io {
    return std.Options.debug_io;
}

fn uniqueDir(io: std.Io, suffix: []const u8) ![]u8 {
    var rand: [8]u8 = undefined;
    io.random(&rand);
    const hex = std.fmt.bytesToHex(rand, .lower);
    const p = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_ruby_source_{s}_{s}",
        .{ hex[0..], suffix },
    );
    try std.Io.Dir.cwd().createDirPath(io, p);
    return p;
}

test "extractPostInstallFromSource handles an in-memory Ruby body" {
    const src =
        \\class Hello < Formula
        \\  def post_install
        \\    mkdir_p "etc"
        \\  end
        \\end
        \\
    ;
    const body = extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc\"") != null);
}

test "extractPostInstallFromSource returns null when no post_install exists" {
    const src = "class X < Formula\n  url \"x\"\nend\n";
    try testing.expect(extractPostInstallFromSource(testing.allocator, src) == null);
}

test "extractPostInstallFromSource handles post_install at the top level (no indent)" {
    const src =
        \\def post_install
        \\touch "foo"
        \\end
        \\
    ;
    const body = extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"foo\"") != null);
}

test "extractPostInstallFromSource prepends sibling defs so helpers resolve" {
    const src =
        \\class Foo < Formula
        \\  def helper
        \\    ohai "helped"
        \\  end
        \\
        \\  def post_install
        \\    helper
        \\  end
        \\end
        \\
    ;
    const body = extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);

    // Sibling def appears before post_install body content.
    const idx_sibling = std.mem.indexOf(u8, body.?, "def helper") orelse return error.TestUnexpectedResult;
    const idx_call = std.mem.indexOf(u8, body.?, "  helper\n") orelse return error.TestUnexpectedResult;
    try testing.expect(idx_sibling < idx_call);
    // `def post_install` itself is NOT repeated in the body — only its body.
    try testing.expect(std.mem.indexOf(u8, body.?, "def post_install") == null);
}

test "extractPostInstallFromSource collects multiple sibling defs in file order" {
    // Same shape as ca-certificates.rb — two mac/linux helpers plus the
    // dispatcher post_install. All three must register before the body runs.
    const src =
        \\class Certs < Formula
        \\  def macos_post_install
        \\    ohai "mac"
        \\  end
        \\
        \\  def linux_post_install
        \\    ohai "linux"
        \\  end
        \\
        \\  def post_install
        \\    if OS.mac?
        \\      macos_post_install
        \\    else
        \\      linux_post_install
        \\    end
        \\  end
        \\end
    ;
    const body = extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "def macos_post_install") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "def linux_post_install") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "if OS.mac?") != null);
}

test "extractPostInstallFromSource skips nested defs inside post_install body" {
    // A `def` nested inside the post_install body stays in the body; it is
    // NOT promoted to a sibling (the indent match ensures this). No double
    // occurrences.
    const src =
        \\class X < Formula
        \\  def post_install
        \\    ohai "hi"
        \\  end
        \\end
    ;
    const body = extractPostInstallFromSource(testing.allocator, src);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, body.?, "def post_install"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body.?, "ohai \"hi\""));
}

test "extractPostInstallBody returns null when the file has no post_install" {
    const io = testIo();
    const tap = try uniqueDir(io, "no_postinstall");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, rb, .{});
        try f.writeStreamingAll(io, "class Hello < Formula\n  url \"x\"\nend\n");
        f.close(io);
    }
    try testing.expect(extractPostInstallBody(io, testing.allocator, rb) == null);
}

test "extractPostInstallBody returns null for a missing file" {
    try testing.expect(extractPostInstallBody(testIo(), testing.allocator, "/tmp/malt_ruby_missing_xyz.rb") == null);
}

test "extractPostInstallBody captures the body between def post_install and matching end" {
    const io = testIo();
    const tap = try uniqueDir(io, "with_postinstall");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/hello.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, rb, .{});
        try f.writeStreamingAll(io,
            \\class Hello < Formula
            \\  def post_install
            \\    mkdir_p "etc/hello"
            \\    touch "etc/hello/config"
            \\  end
            \\end
            \\
        );
        f.close(io);
    }
    const body = extractPostInstallBody(io, testing.allocator, rb);
    try testing.expect(body != null);
    defer testing.allocator.free(body.?);
    try testing.expect(std.mem.indexOf(u8, body.?, "mkdir_p \"etc/hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, body.?, "touch \"etc/hello/config\"") != null);
}

test "hasPostInstallStepsBlock detects a declarative steps block" {
    // Steps-migrated formulas have no `def post_install`; detection is what
    // lets the tap arm warn instead of silently dropping the hook.
    try testing.expect(hasPostInstallStepsBlock(
        \\class Glow < Formula
        \\  post_install_steps do
        \\    gdk_pixbuf_query_loaders
        \\  end
        \\end
        \\
    ));
    try testing.expect(!hasPostInstallStepsBlock(
        \\class Old < Formula
        \\  def post_install
        \\    ohai "hi"
        \\  end
        \\end
        \\
    ));
    // Commented-out blocks and prefix-sharing identifiers must not count.
    try testing.expect(!hasPostInstallStepsBlock("  # post_install_steps do\n"));
    try testing.expect(!hasPostInstallStepsBlock("post_install_steps_helper do\n"));
}

test "rbHasPostInstallSteps reads the block from a formula .rb on disk" {
    const io = testIo();
    const tap = try uniqueDir(io, "steps_only");
    defer testing.allocator.free(tap);
    defer std.Io.Dir.cwd().deleteTree(io, tap) catch {};
    const rb = try std.fmt.allocPrint(testing.allocator, "{s}/glow.rb", .{tap});
    defer testing.allocator.free(rb);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, rb, .{});
        try f.writeStreamingAll(io,
            \\class Glow < Formula
            \\  post_install_steps do
            \\    gdk_pixbuf_query_loaders
            \\  end
            \\end
            \\
        );
        f.close(io);
    }
    try testing.expect(rbHasPostInstallSteps(io, testing.allocator, rb));
    try testing.expect(!rbHasPostInstallSteps(io, testing.allocator, "/tmp/malt_ruby_missing_xyz.rb"));
}

test "fetchPostInstallFromGitHub returns null for an empty name" {
    // Empty name fails the allowlist before any network I/O.
    try testing.expect(fetchPostInstallFromGitHub(testIo(), .empty, testing.allocator, "") == null);
}

test "fetchPostInstallFromGitHub keeps its ?[]const u8 contract for CLI callers" {
    // doctor + install rely on the optional-slice signature; the tagged
    // variant is internal. An unknown name short-circuits before any
    // network I/O via the manifest miss.
    try testing.expect(fetchPostInstallFromGitHub(
        testIo(),
        .empty,
        testing.allocator,
        "__malt_d10_unknown_formula__",
    ) == null);
}
