//! malt — font-cask leaf
//! Self-contained font-artifact parsing, destination policy, name
//! sanitization, file placement, and manifest I/O. `cask.zig` only
//! dispatches here; this module imports `std` alone so the security-
//! sensitive path handling lives in one auditable leaf.

const std = @import("std");
const confined_source = @import("../fs/confined_source.zig");

/// One placed font: the archive-relative `source` to copy and the cask's
/// optional `target` whose *basename* is honoured as a rename hint. The
/// `target` directory is never trusted.
pub const FontEntry = struct {
    source: []const u8,
    target: ?[]const u8,
};

/// Collect every `font` stanza across *all* artifact objects. Homebrew
/// font casks ship one `{"font":[src],"target":?}` object per file, so
/// the first-match parser used for `app`/`binary` is structurally wrong
/// here. Returns null when the cask carries no font artifact. Slices in
/// the result borrow `obj`'s arena; the caller owns the returned array.
pub fn collectFontArtifacts(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !?[]FontEntry {
    const artifacts = switch (obj.get("artifacts") orelse return null) {
        .array => |a| a,
        else => return null,
    };

    var entries: std.ArrayList(FontEntry) = .empty;
    errdefer entries.deinit(alloc);

    for (artifacts.items) |item| {
        const art = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const fonts = switch (art.get("font") orelse continue) {
            .array => |a| a,
            else => continue,
        };
        const target: ?[]const u8 = switch (art.get("target") orelse std.json.Value.null) {
            .string => |s| s,
            else => null,
        };
        for (fonts.items) |src| switch (src) {
            .string => |s| try entries.append(alloc, .{ .source = s, .target = target }),
            else => {},
        };
    }

    if (entries.items.len == 0) {
        entries.deinit(alloc);
        return null;
    }
    return try entries.toOwnedSlice(alloc);
}

/// Resolve the safe destination filename for a font entry, or null to
/// reject it. The `source` is copied from inside the extraction root, so
/// an absolute path or a `..` hop is a read-traversal and is rejected.
/// The `target` directory is never trusted — only `basename(target)` is
/// used as a rename hint, falling back to `basename(source)`. The
/// returned name is always a single path component.
pub fn sanitizeFontName(source: []const u8, target: ?[]const u8) ?[]const u8 {
    if (isUnsafeSource(source)) return null;
    if (target) |t| if (basenameValid(t)) |name| return name;
    return basenameValid(source);
}

/// A source escapes the extraction root if it is absolute or hops up
/// with a `..` component; either would copy a file we never extracted.
fn isUnsafeSource(source: []const u8) bool {
    if (source.len == 0 or source[0] == '/') return true;
    var it = std.mem.splitScalar(u8, source, '/');
    while (it.next()) |comp| if (std.mem.eql(u8, comp, "..")) return true;
    return false;
}

/// The trailing path component, rejected if it is empty, `.`, `..`, or
/// (defensively) still holds a separator.
fn basenameValid(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;
    if (std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;
    if (std.mem.indexOfScalar(u8, base, '/') != null) return null;
    return base;
}

/// Pure resolver for "where do font files go?", mirroring
/// `resolveAppDir`'s prefix/HOME policy:
///   1. Non-default prefix → `<prefix>/Fonts` (sandbox/test isolation;
///      macOS won't register it — the caller warns).
///   2. Default prefix + `HOME` → `<HOME>/Library/Fonts` (user-scoped,
///      no sudo — the registered location).
///   3. No HOME → `/Library/Fonts` literal so a misconfigured host
///      fails loudly rather than writing somewhere unexpected.
/// Returns a slice of `out` or a compile-time literal.
pub fn resolveFontsDir(prefix: []const u8, env_home: ?[]const u8, out: []u8) []const u8 {
    if (!isDefaultPrefix(prefix)) {
        return std.fmt.bufPrint(out, "{s}/Fonts", .{prefix}) catch "/Library/Fonts";
    }
    if (env_home) |home| {
        const slice = std.mem.sliceTo(home, 0);
        return std.fmt.bufPrint(out, "{s}/Library/Fonts", .{slice}) catch "/Library/Fonts";
    }
    return "/Library/Fonts";
}

/// True iff `prefix` is a well-known default root. Duplicated from
/// `cask.zig` rather than imported so the leaf depends on `std` alone;
/// fold back if a shared prefix predicate ever exists.
fn isDefaultPrefix(prefix: []const u8) bool {
    const trimmed = if (prefix.len > 0 and prefix[prefix.len - 1] == '/')
        prefix[0 .. prefix.len - 1]
    else
        prefix;
    return std.mem.eql(u8, trimmed, "/opt/malt") or
        std.mem.eql(u8, trimmed, "/opt/homebrew");
}

/// Copy each entry's sanitized file from `extract_root` into
/// `fonts_dir`, returning the manifest bytes: the placed absolute
/// destination paths, newline-joined. Entries whose source fails
/// sanitization (absolute / `..` / empty) are skipped — they are
/// attacker-influenced and never trusted. The caller owns the result.
pub fn placeFonts(
    io: std.Io,
    alloc: std.mem.Allocator,
    extract_root: []const u8,
    fonts_dir: []const u8,
    entries: []const FontEntry,
) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, fonts_dir);

    var manifest: std.ArrayList(u8) = .empty;
    errdefer manifest.deinit(alloc);

    for (entries) |entry| {
        const name = sanitizeFontName(entry.source, entry.target) orelse continue;

        // Source declares its own archive-relative path; sanitization
        // already proved it stays within the extraction root.
        const src = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ extract_root, entry.source });
        defer alloc.free(src);
        const dest = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ fonts_dir, name });
        defer alloc.free(dest);

        var source = try confined_source.openFile(io, alloc, extract_root, src, .read_only);
        defer source.deinit(io);
        try source.copyToAbsolute(io, dest);

        if (manifest.items.len != 0) try manifest.append(alloc, '\n');
        try manifest.appendSlice(alloc, dest);
    }

    return manifest.toOwnedSlice(alloc);
}

/// Filename of the per-version font manifest inside
/// `Caskroom/<token>/<version>/`. The leaf owns this name so `cask.zig`
/// never hardcodes the Caskroom layout.
pub const MANIFEST_NAME = ".malt-fonts";

/// Persist the newline-joined destination paths to `path`, creating the
/// parent directory as needed.
pub fn writeManifest(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Read a manifest back as owned bytes. A missing manifest reads as
/// empty so uninstall can treat a manually nuked Caskroom as "nothing
/// left to unlink". The caller owns the returned slice.
pub fn readManifest(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return alloc.alloc(u8, 0),
        else => return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try alloc.alloc(u8, stat.size);
    errdefer alloc.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

const testing = std.testing;
const dbg_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(dbg_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

fn putFile(io: std.Io, path: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn expectFile(io: std.Io, path: []const u8, body: []const u8) !void {
    const got = try readManifest(io, testing.allocator, path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
}

test "placeFonts copies nested and bare sources and manifests their dest paths" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_place");
    defer s.deinit();

    const root = s.p("/extract");
    const fonts = s.p("/fonts");
    try putFile(io, s.p("/extract/ttf/FiraCode-Bold.ttf"), "BOLD");
    try putFile(io, s.p("/extract/HackNerdFont-Regular.ttf"), "HACK");

    const entries = [_]FontEntry{
        .{ .source = "ttf/FiraCode-Bold.ttf", .target = "/$HOME/Library/Fonts/FiraCode-Bold.ttf" },
        .{ .source = "HackNerdFont-Regular.ttf", .target = null },
    };
    const manifest = try placeFonts(io, testing.allocator, root, fonts, &entries);
    defer testing.allocator.free(manifest);

    const expected = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/FiraCode-Bold.ttf\n{s}/HackNerdFont-Regular.ttf",
        .{ fonts, fonts },
    );
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, manifest);
    try expectFile(io, s.p("/fonts/FiraCode-Bold.ttf"), "BOLD");
    try expectFile(io, s.p("/fonts/HackNerdFont-Regular.ttf"), "HACK");
}

test "placeFonts refuses a source symlink outside the extraction root" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_source_symlink");
    defer s.deinit();

    const root = s.p("/extract");
    const fonts = s.p("/fonts");
    const victim = s.p("/private-font");
    const link = s.p("/extract/leak.ttf");
    try putFile(io, victim, "PRIVATE FONT DATA");
    try std.Io.Dir.cwd().createDirPath(io, root);
    try std.Io.Dir.symLinkAbsolute(io, victim, link, .{});

    const result = placeFonts(io, testing.allocator, root, fonts, &.{.{
        .source = "leak.ttf",
        .target = null,
    }});
    if (result) |manifest| testing.allocator.free(manifest) else |_| {}

    try testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(io, s.p("/fonts/leak.ttf"), .{}),
    );
}

test "placeFonts skips unsafe entries and omits them from the manifest" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_place_unsafe");
    defer s.deinit();

    const root = s.p("/extract");
    const fonts = s.p("/fonts");
    try putFile(io, s.p("/extract/Good.ttf"), "GOOD");

    const entries = [_]FontEntry{
        .{ .source = "../../evil", .target = null },
        .{ .source = "Good.ttf", .target = null },
    };
    const manifest = try placeFonts(io, testing.allocator, root, fonts, &entries);
    defer testing.allocator.free(manifest);

    const expected = s.p("/fonts/Good.ttf");
    try testing.expectEqualStrings(expected, manifest);
    try expectFile(io, expected, "GOOD");
}

test "placeFonts on an empty entry list yields an empty manifest" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_place_empty");
    defer s.deinit();

    const manifest = try placeFonts(io, testing.allocator, s.p("/extract"), s.p("/fonts"), &.{});
    defer testing.allocator.free(manifest);
    try testing.expectEqual(@as(usize, 0), manifest.len);
}

test "placeFonts fails loud when a sanitized source is missing on disk" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_place_missing");
    defer s.deinit();

    const entries = [_]FontEntry{.{ .source = "Absent.ttf", .target = null }};
    try testing.expectError(error.FileNotFound, placeFonts(io, testing.allocator, s.p("/extract"), s.p("/fonts"), &entries));
}

test "manifest round-trips the placed-path list" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("cask_font_manifest");
    defer s.deinit();

    const path = s.p("/Caskroom/font-x/1.0/" ++ MANIFEST_NAME);
    const body = "/Users/x/Library/Fonts/A.ttf\n/Users/x/Library/Fonts/B.ttf";
    try writeManifest(io, path, body);

    const got = try readManifest(io, testing.allocator, path);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(body, got);
}

test "readManifest returns empty for a missing manifest" {
    // The scratch base is deliberately never created: the path must be absent.
    var s = try Scratch.init("cask_font_absent_xyz");
    defer s.deinit();
    const got = try readManifest(std.Options.debug_io, testing.allocator, s.p("/" ++ MANIFEST_NAME));
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "resolveFontsDir uses ~/Library/Fonts under a default prefix" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/Users/x/Library/Fonts", resolveFontsDir("/opt/malt", "/Users/x", &buf));
}

test "resolveFontsDir uses <prefix>/Fonts under a non-default prefix" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/tmp/sandbox/Fonts", resolveFontsDir("/tmp/sandbox", "/Users/x", &buf));
}

test "resolveFontsDir falls back to /Library/Fonts when HOME is missing" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/Library/Fonts", resolveFontsDir("/opt/malt", null, &buf));
}

fn objFromJson(parsed: *std.json.Parsed(std.json.Value), json: []const u8) std.json.ObjectMap {
    // Test fixtures are compile-time-constant valid JSON; a parse failure is a
    // test bug, not a runtime path.
    parsed.* = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch unreachable;
    return parsed.value.object;
}

test "sanitizeFontName rejects traversal and absolute sources" {
    try testing.expect(sanitizeFontName("../../evil", null) == null);
    try testing.expect(sanitizeFontName("/etc/passwd", null) == null);
    try testing.expect(sanitizeFontName("a/../../evil", null) == null);
    try testing.expect(sanitizeFontName("", null) == null);
}

test "sanitizeFontName reduces bare and nested sources to a basename" {
    try testing.expectEqualStrings("HackNerdFont-Regular.ttf", sanitizeFontName("HackNerdFont-Regular.ttf", null).?);
    try testing.expectEqualStrings("FiraCode-Bold.ttf", sanitizeFontName("ttf/FiraCode-Bold.ttf", null).?);
}

test "sanitizeFontName prefers the target basename as a rename hint" {
    // The target directory ($HOME/Library/Fonts) is untrusted; only its
    // basename renames the file. A safe source still gates acceptance.
    const name = sanitizeFontName("ttf/FiraCode-Bold.ttf", "/$HOME/Library/Fonts/Renamed.ttf").?;
    try testing.expectEqualStrings("Renamed.ttf", name);
}

test "sanitizeFontName falls back to the source basename when the target has none" {
    // A target whose basename is `.`/`..`/empty is no rename hint at all.
    try testing.expectEqualStrings("A.ttf", sanitizeFontName("ttf/A.ttf", ".").?);
    try testing.expectEqualStrings("A.ttf", sanitizeFontName("ttf/A.ttf", "..").?);
    try testing.expectEqualStrings("A.ttf", sanitizeFontName("ttf/A.ttf", "").?);
}

test "collectFontArtifacts collects nested and bare sources across all stanzas" {
    const json =
        \\{"artifacts":[
        \\  {"font":["ttf/FiraCode-Bold.ttf"],"target":"/$HOME/Library/Fonts/FiraCode-Bold.ttf"},
        \\  {"font":["HackNerdFont-Regular.ttf"]}
        \\]}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const obj = objFromJson(&parsed, json);
    defer parsed.deinit();

    const entries = (try collectFontArtifacts(testing.allocator, obj)).?;
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("ttf/FiraCode-Bold.ttf", entries[0].source);
    try testing.expectEqualStrings("/$HOME/Library/Fonts/FiraCode-Bold.ttf", entries[0].target.?);
    try testing.expectEqualStrings("HackNerdFont-Regular.ttf", entries[1].source);
    try testing.expect(entries[1].target == null);
}

test "collectFontArtifacts returns null when artifacts is absent or not an array" {
    var p1: std.json.Parsed(std.json.Value) = undefined;
    const no_key = objFromJson(&p1, "{\"token\":\"x\"}");
    defer p1.deinit();
    try testing.expect((try collectFontArtifacts(testing.allocator, no_key)) == null);

    var p2: std.json.Parsed(std.json.Value) = undefined;
    const wrong_type = objFromJson(&p2, "{\"artifacts\":\"oops\"}");
    defer p2.deinit();
    try testing.expect((try collectFontArtifacts(testing.allocator, wrong_type)) == null);
}

test "collectFontArtifacts ignores non-string font elements and keeps the sibling target" {
    // Guards against the binary-style in-array `{target}` form crashing the
    // string-only collector; the sibling `target` key still wins.
    const json =
        \\{"artifacts":[{"font":["A.ttf",{"target":"ignored"}],"target":"/x/A.ttf"}]}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const obj = objFromJson(&parsed, json);
    defer parsed.deinit();

    const entries = (try collectFontArtifacts(testing.allocator, obj)).?;
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("A.ttf", entries[0].source);
    try testing.expectEqualStrings("/x/A.ttf", entries[0].target.?);
}

fn collectUnderOom(alloc: std.mem.Allocator, obj: std.json.ObjectMap) !void {
    if (try collectFontArtifacts(alloc, obj)) |entries| alloc.free(entries);
}

test "collectFontArtifacts frees its partial list on allocation failure" {
    const json =
        \\{"artifacts":[{"font":["A.ttf"]},{"font":["B.ttf"]},{"font":["C.ttf"]}]}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const obj = objFromJson(&parsed, json);
    defer parsed.deinit();

    try testing.checkAllAllocationFailures(testing.allocator, collectUnderOom, .{obj});
}

test "collectFontArtifacts returns null when no font stanza is present" {
    const json =
        \\{"artifacts":[{"app":["Foo.app"]}]}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const obj = objFromJson(&parsed, json);
    defer parsed.deinit();

    try testing.expect((try collectFontArtifacts(testing.allocator, obj)) == null);
}

test "collectFontArtifacts ignores non-font artifacts in a mixed cask" {
    const json =
        \\{"artifacts":[
        \\  {"app":["Foo.app"]},
        \\  {"font":["A.ttf"]},
        \\  {"uninstall":[{"quit":"com.x"}]},
        \\  {"font":["B.ttf"]}
        \\]}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const obj = objFromJson(&parsed, json);
    defer parsed.deinit();

    const entries = (try collectFontArtifacts(testing.allocator, obj)).?;
    defer testing.allocator.free(entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("A.ttf", entries[0].source);
    try testing.expectEqualStrings("B.ttf", entries[1].source);
}
