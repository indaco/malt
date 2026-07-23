//! malt — color module
//! Terminal color output (NO_COLOR aware) with light/dark background
//! awareness so load-bearing lines render on both palettes.

const std = @import("std");
const themes = @import("themes.zig");
const theme_registry = @import("theme_registry.zig");
/// Process-wide io + environ seeded once from `main` via `setRuntime`.
/// Defaults stay benign so tests that don't seed see deterministic
/// "no env vars, no terminal probe" output.
var pkg_io: std.Io = std.Options.debug_io;
const builtin = @import("builtin");

/// Literal-colour styles for the few sites that need a specific hue
/// (confirmTyped prompt, warnPlain fallback). Semantic roles live on
/// `SemanticStyle`.
pub const Style = enum {
    reset,
    bold,
    dim,
    /// SGR reverse-video — the TUI selection / active-block highlight attribute.
    /// Centralised here so the leaf has one source, not a literal per tab.
    reverse,
    red,
    green,
    yellow,
    blue,
    cyan,
    white,

    pub fn code(self: Style) []const u8 {
        return switch (self) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .reverse => "\x1b[7m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
        };
    }
};

/// Detected terminal background class.
pub const Background = enum { dark, light, unknown };

/// Semantic role for a styled line. Callers pick a role; the palette
/// resolver picks the actual escape string for the current
/// (background, truecolor) tier. Every output site routes through here
/// so adding a role means updating one table, not every call site.
pub const SemanticStyle = enum {
    info,
    warn,
    success,
    err,
    detail,
    /// softer than warn, distinct from info.
    /// Used by passive notices (e.g. an available self-update).
    notice,

    /// ANSI escape for the current cached palette cell. A named `MALT_THEME`
    /// (when it applies — see `namedThemeApplies`) maps this semantic role onto
    /// the theme's palette so CLI output themes the same as the TUI; otherwise
    /// the background-aware default palette is used unchanged.
    pub fn code(self: SemanticStyle) []const u8 {
        const t = theme();
        const bg = background();
        const tc = truecolorSupported();
        if (activeCustomPalette(bg, tc)) |p| return p.get(semanticToRole(self));
        if (namedThemeApplies(t, bg, tc)) return themes.named(t).?.get(semanticToRole(self));
        return paletteCode(self, bg, tc);
    }
};

/// 8-bit RGB triple — OSC 11 components normalise to the high byte.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// TUI paint role + theme set live in `themes.zig`; re-exported so the TUI leaf
/// reads them through `color` and never imports the theme tables directly.
pub const Role = themes.Role;
pub const Theme = themes.Theme;

/// Atomic-friendly `?bool`: `@atomicLoad`/`@atomicStore` can't touch an
/// optional, so "unresolved" rides its own variant.
const Tri = enum(u8) { unresolved, no, yes };

/// `?bool` → `Tri` for the test setters.
fn triFromOpt(v: ?bool) Tri {
    return if (v) |b| (if (b) .yes else .no) else .unresolved;
}

/// Atomic-friendly `?Background`; `unresolved` keeps `Background` a clean enum.
const BgCache = enum(u8) { unresolved, dark, light, unknown };

fn bgToCache(bg: Background) BgCache {
    return switch (bg) {
        .dark => .dark,
        .light => .light,
        .unknown => .unknown,
    };
}

var color_enabled: Tri = .unresolved;
var emoji_enabled: Tri = .unresolved;
var background_cached: BgCache = .unresolved;
var truecolor_cached: Tri = .unresolved;
// Clean `Theme` plus a sibling resolved-latch, so `Theme` needs no `unresolved`.
// The value is published before the latch, so a resolved read never sees stale.
var theme_cached: Theme = .default;
var theme_resolved: bool = false;

var pkg_environ: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } };

// ─── custom theme registry (loaded once at boot) ─────────────────────
//
// Backing storage for any user-defined themes. Written once by
// `installCustomThemes` and read-only after — no atomics, single-threaded boot.
// `custom_count == 0` means "no custom themes"; the resolver then behaves
// exactly as before. Selection is env-derived (`MALT_THEME`), so it re-resolves
// lazily and `setRuntime` drops it, mirroring `theme_cached`.
var custom_storage: theme_registry.Storage = undefined;
var custom_count: usize = 0;

// Folds resolved-flag + index into one word (two top `usize` reserved) so a
// resolved index is never read torn from its flag.
const AC_UNRESOLVED: usize = std.math.maxInt(usize);
const AC_NONE: usize = std.math.maxInt(usize) - 1;
var active_custom: usize = AC_UNRESOLVED;

/// Seed the io/environ used by env reads and TTY probes. Called by
/// `main` after `AppCtx` is built. Inverse of relying on globals.
///
/// Re-seeding invalidates every env-derived cache: a value resolved against the
/// empty default environ (a boot-time pre-warm before this call) must not stick,
/// or MALT_THEME / COLORTERM / NO_COLOR silently freeze at their unset defaults.
pub fn setRuntime(io: std.Io, environ: std.process.Environ) void {
    pkg_io = io;
    pkg_environ = environ;
    @atomicStore(Tri, &color_enabled, .unresolved, .release);
    @atomicStore(Tri, &emoji_enabled, .unresolved, .release);
    @atomicStore(BgCache, &background_cached, .unresolved, .release);
    bg_probing.store(false, .release); // release the probe latch so the re-seed re-probes
    @atomicStore(Tri, &truecolor_cached, .unresolved, .release);
    // Dropping the latch invalidates the value; the value store itself is moot.
    @atomicStore(bool, &theme_resolved, false, .release);
    // Selection depends on MALT_THEME; the loaded registry itself is file-derived
    // and survives a re-seed, so only the resolved choice is dropped.
    @atomicStore(usize, &active_custom, AC_UNRESOLVED, .release);
}

test "setRuntime re-seeds the theme cache so a pre-seed warm cannot freeze it" {
    // Reproduces the boot hazard: theme() warmed against the empty default
    // environ (before main seeds the real one) must not stick at .default once
    // the environ carrying MALT_THEME arrives — or the TUI never themes.
    const io = std.Options.debug_io;
    const empty: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } };
    const themed: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"MALT_THEME=dracula"} } };

    setRuntime(io, empty);
    try std.testing.expectEqual(Theme.default, theme()); // warmed before the env is known

    setRuntime(io, themed); // the real environ arrives; the stale cache must drop
    try std.testing.expectEqual(Theme.dracula, theme());

    setRuntime(io, empty); // leave module state clean for sibling tests
    setThemeForTest(null);
}

fn lookupEnv(name: []const u8) ?[:0]const u8 {
    return std.process.Environ.getPosix(pkg_environ, name);
}

fn isTty(fd: std.posix.fd_t) bool {
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    return file.isTty(pkg_io) catch false;
}

pub fn isColorEnabled() bool {
    switch (@atomicLoad(Tri, &color_enabled, .acquire)) {
        .yes => return true,
        .no => return false,
        .unresolved => {},
    }
    // Check NO_COLOR env var AND whether stderr is a tty
    const no_color = lookupEnv("NO_COLOR");
    const result: Tri = if (no_color == null and isTty(std.posix.STDERR_FILENO)) .yes else .no;
    // Benign double-compute under a race: the value is env-deterministic, so
    // last-writer-wins on identical data — no CAS needed.
    @atomicStore(Tri, &color_enabled, result, .release);
    return result == .yes;
}

pub fn isEmojiEnabled() bool {
    switch (@atomicLoad(Tri, &emoji_enabled, .acquire)) {
        .yes => return true,
        .no => return false,
        .unresolved => {},
    }
    const no_emoji = lookupEnv("MALT_NO_EMOJI");
    const result: Tri = if (no_emoji == null) .yes else .no;
    @atomicStore(Tri, &emoji_enabled, result, .release);
    return result == .yes;
}

/// Test-only override for the color/emoji caches. Pass `null` to let
/// the next `is*Enabled` call recompute from env.
pub fn setForTest(c: ?bool, e: ?bool) void {
    if (!builtin.is_test) return;
    @atomicStore(Tri, &color_enabled, triFromOpt(c), .release);
    @atomicStore(Tri, &emoji_enabled, triFromOpt(e), .release);
}

/// Test-only override for the background cache.
pub fn setBackgroundForTest(bg: ?Background) void {
    if (!builtin.is_test) return;
    @atomicStore(BgCache, &background_cached, if (bg) |v| bgToCache(v) else .unresolved, .release);
    bg_probing.store(false, .release); // clear the latch so a forced/null value never wedges a recompute
}

/// Test-only override for the truecolor cache.
pub fn setTruecolorForTest(v: ?bool) void {
    if (!builtin.is_test) return;
    @atomicStore(Tri, &truecolor_cached, triFromOpt(v), .release);
}

/// Test-only override for the theme cache.
pub fn setThemeForTest(t: ?Theme) void {
    if (!builtin.is_test) return;
    if (t) |v| {
        @atomicStore(Theme, &theme_cached, v, .release);
        @atomicStore(bool, &theme_resolved, true, .release);
    } else {
        @atomicStore(bool, &theme_resolved, false, .release);
    }
}

// ─── atomic sentinel cache guards ────────────────────────────────────
//
// The env/TTY caches are read on first touch from worker threads (a migrate
// worker reaches `isColorEnabled`/`isEmojiEnabled` via `output.warn`), so their
// storage must be atomic-friendly sentinel enums — never `?T`, whose layout is
// not guaranteed atomic. These structural guards fail to build the moment a
// cache reverts to an optional.

fn typeIsEnum(comptime T: type) bool {
    return std.meta.activeTag(@typeInfo(T)) == .@"enum";
}

test "storage: color/emoji caches are atomic sentinel enums, not optionals" {
    try std.testing.expect(typeIsEnum(@TypeOf(color_enabled)));
    try std.testing.expect(typeIsEnum(@TypeOf(emoji_enabled)));
}

// Encodes WHY the atomic rewrite matters: workers reach these accessors through
// `output.warn`, so concurrent first-touch must agree and leave the cache
// resolved. It cannot *prove* race-freedom (TSan is unavailable here) — the
// sentinel storage provides that, pinned by the structural guard above.
test "concurrent first-touch on the enabled caches agrees and resolves" {
    setRuntime(std.Options.debug_io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"NO_COLOR=1"} } });
    defer {
        setForTest(null, null);
        setRuntime(std.Options.debug_io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    }

    const Runner = struct {
        color: bool = false,
        emoji: bool = false,
        fn run(self: *@This()) void {
            self.color = isColorEnabled();
            self.emoji = isEmojiEnabled();
        }
    };
    var runners: [8]Runner = @splat(.{});
    var threads: [8]std.Thread = undefined;
    for (&threads, &runners) |*t, *r| t.* = try std.Thread.spawn(.{}, Runner.run, .{r});
    for (&threads) |t| t.join();

    for (runners) |r| {
        try std.testing.expectEqual(runners[0].color, r.color);
        try std.testing.expectEqual(runners[0].emoji, r.emoji);
    }
    try std.testing.expect(@atomicLoad(Tri, &color_enabled, .acquire) != .unresolved);
    try std.testing.expect(@atomicLoad(Tri, &emoji_enabled, .acquire) != .unresolved);
}

test "storage: the active-custom cache is a single atomic word" {
    // Folded from a `?usize` index + `bool` resolved flag into one word so a
    // resolved index is never observed torn from its resolved state.
    try std.testing.expect(std.meta.activeTag(@typeInfo(@TypeOf(active_custom))) == .int);
}

test "storage: background/truecolor/theme caches are atomic; Theme stays clean" {
    try std.testing.expect(typeIsEnum(@TypeOf(background_cached))); // BgCache, not ?Background
    try std.testing.expect(typeIsEnum(@TypeOf(truecolor_cached))); // Tri, not ?bool
    // Theme stays a clean public enum the TUI switches over exhaustively; the
    // unresolved state rides a sibling latch, never a Theme variant.
    try std.testing.expect(@TypeOf(theme_cached) == Theme);
    try std.testing.expect(!@hasField(Theme, "unresolved"));
    try std.testing.expect(@TypeOf(theme_resolved) == bool);
}

test "setRuntime drops the enabled/truecolor/background caches so a new environ recomputes" {
    const io = std.Options.debug_io;
    // MALT_THEME as a bg keyword forces the background without an OSC 11 TTY probe.
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "MALT_THEME=light", "COLORTERM=truecolor" } } });
    defer {
        setForTest(null, null);
        setTruecolorForTest(null);
        setBackgroundForTest(null);
        setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    }

    _ = isColorEnabled(); // prime the color cache (its env recompute is TTY-gated, unobservable here)
    try std.testing.expect(isEmojiEnabled());
    try std.testing.expect(truecolorSupported());
    try std.testing.expectEqual(Background.light, background());
    try std.testing.expect(@atomicLoad(Tri, &color_enabled, .acquire) != .unresolved);

    // New environ flips each derived value; a frozen cache would keep the old one.
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "MALT_THEME=dark", "MALT_NO_EMOJI=1" } } });
    try std.testing.expect(@atomicLoad(Tri, &color_enabled, .acquire) == .unresolved); // the cache was dropped
    try std.testing.expect(!isEmojiEnabled()); // MALT_NO_EMOJI now set
    try std.testing.expect(!truecolorSupported()); // COLORTERM now gone
    try std.testing.expectEqual(Background.dark, background()); // MALT_THEME flipped
}

test "background/truecolor/theme resolve cold — the deleted boot warm is not needed" {
    const io = std.Options.debug_io;
    // Exactly the state main.zig used to warm, now resolved lazily on first touch.
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "MALT_THEME=light", "COLORTERM=truecolor" } } });
    defer setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    try std.testing.expectEqual(Background.light, background());
    try std.testing.expect(truecolorSupported());
    try std.testing.expectEqual(Theme.default, theme());
}

test "test setters round-trip; null recomputes from env" {
    const io = std.Options.debug_io;
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "MALT_THEME=light", "COLORTERM=truecolor" } } });
    defer {
        setForTest(null, null);
        setBackgroundForTest(null);
        setTruecolorForTest(null);
        setThemeForTest(null);
        setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    }

    // Forced values are observed verbatim.
    setForTest(true, false);
    try std.testing.expect(isColorEnabled());
    try std.testing.expect(!isEmojiEnabled());
    setBackgroundForTest(.dark);
    try std.testing.expectEqual(Background.dark, background());
    setTruecolorForTest(false);
    try std.testing.expect(!truecolorSupported());
    setThemeForTest(.nord);
    try std.testing.expectEqual(Theme.nord, theme());

    // `null` restores the recompute sentinel; the next call reads env again.
    setForTest(null, null);
    try std.testing.expect(isEmojiEnabled()); // MALT_NO_EMOJI unset ⇒ flips back on
    setBackgroundForTest(null);
    try std.testing.expectEqual(Background.light, background()); // MALT_THEME=light
    setTruecolorForTest(null);
    try std.testing.expect(truecolorSupported()); // COLORTERM=truecolor
    setThemeForTest(null);
    try std.testing.expectEqual(Theme.default, theme()); // "light" is a bg keyword ⇒ default theme
}

test "background() runs the OSC 11 probe at most once under concurrent first-touch" {
    // The probe toggles raw mode on the shared stdin and consumes the terminal's
    // single OSC 11 response — concurrent probes corrupt each other. Pin the
    // by-construction guarantee: exactly one thread runs the detector even when N
    // race in cold. Non-TTY here, so a counting detector stands in for the probe.
    const io = std.Options.debug_io;
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    const Probe = struct {
        var runs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn detect() Background {
            _ = runs.fetchAdd(1, .monotonic);
            // Hold the resolve open so every racing thread reliably observes an
            // unresolved cache first — without serialisation all N enter here.
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
            return .dark;
        }
        fn touch() void {
            _ = background();
        }
    };
    Probe.runs.store(0, .monotonic);
    setDetectBackgroundForTest(&Probe.detect);
    defer {
        setDetectBackgroundForTest(null);
        setBackgroundForTest(null);
        setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    }

    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Probe.touch, .{});
    for (&threads) |t| t.join();

    try std.testing.expectEqual(Background.dark, background());
    try std.testing.expectEqual(@as(u32, 1), Probe.runs.load(.monotonic));
}

test "setBackgroundForTest(null) clears the probe latch so a resolve can recompute" {
    const io = std.Options.debug_io;
    // MALT_THEME as a bg keyword resolves without a TTY probe, so it claims the latch.
    setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"MALT_THEME=light"} } });
    defer {
        setBackgroundForTest(null);
        setRuntime(io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    }
    try std.testing.expectEqual(Background.light, background());
    try std.testing.expect(bg_probing.load(.acquire)); // latch claimed
    // Dropping the cache must drop the latch too, or the next resolve would wedge.
    setBackgroundForTest(null);
    try std.testing.expect(!bg_probing.load(.acquire));
    try std.testing.expectEqual(Background.light, background()); // recomputes, no wedge
}

test "concurrent roleCode first-touch agrees (fold + theme latch on a cold cache)" {
    // The realistic worker path — coloured output → roleCode → activeCustomIndex
    // (the fold) and theme(). seedCustom leaves both unresolved, so N threads race.
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, custom_ocean_src));
    defer resetCustom();

    const Runner = struct {
        code: []const u8 = "",
        fn run(self: *@This()) void {
            self.code = roleCode(.accent);
        }
    };
    var runners: [8]Runner = @splat(.{});
    var threads: [8]std.Thread = undefined;
    for (&threads, &runners) |*t, *r| t.* = try std.Thread.spawn(.{}, Runner.run, .{r});
    for (&threads) |t| t.join();

    for (runners) |r| try std.testing.expectEqualStrings(runners[0].code, r.code);
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", runners[0].code); // ocean accent
    try std.testing.expect(@atomicLoad(usize, &active_custom, .acquire) != AC_UNRESOLVED);
}

test "the active-custom fold resolves, drops on re-seed, and drops on clear" {
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, custom_ocean_src));
    defer resetCustom();

    // Resolved ⇒ a real registry index is visible in the one word (never torn).
    try std.testing.expect(activeCustomIndex() != null);
    try std.testing.expect(@atomicLoad(usize, &active_custom, .acquire) < AC_NONE);

    // Re-seed drops the resolution back to the unresolved sentinel.
    setRuntime(std.Options.debug_io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    try std.testing.expectEqual(AC_UNRESOLVED, @atomicLoad(usize, &active_custom, .acquire));
    // Registry survives the re-seed, so an unset selector recomputes the file default.
    try std.testing.expect(activeCustomIndex() != null);

    // Clearing the registry drops it; the accessor then resolves to the "none" sentinel.
    clearCustomForTest();
    try std.testing.expectEqual(AC_UNRESOLVED, @atomicLoad(usize, &active_custom, .acquire));
    try std.testing.expectEqual(@as(?usize, null), activeCustomIndex());
    try std.testing.expectEqual(AC_NONE, @atomicLoad(usize, &active_custom, .acquire));
}

/// Serialises the one-shot OSC 11 probe: it drives the shared stdin into raw mode
/// and reads the terminal's single response, so concurrent probes corrupt each
/// other — unlike the benign integer caches. One thread probes; racers wait.
var bg_probing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Cached background accessor. Detection runs at most once per process.
pub fn background() Background {
    switch (@atomicLoad(BgCache, &background_cached, .acquire)) {
        .dark => return .dark,
        .light => return .light,
        .unknown => return .unknown,
        .unresolved => {},
    }
    // Only the latch winner runs the probe; losers spin-yield for its store.
    if (bg_probing.cmpxchgStrong(false, true, .acquire, .monotonic) == null) {
        const resolved = detectBackground();
        @atomicStore(BgCache, &background_cached, bgToCache(resolved), .release);
        return resolved;
    }
    while (true) {
        switch (@atomicLoad(BgCache, &background_cached, .acquire)) {
            .dark => return .dark,
            .light => return .light,
            .unknown => return .unknown,
            .unresolved => std.Thread.yield() catch {}, // transient; re-poll for the winner
        }
    }
}

/// Test-only detector swap so a concurrency test can count resolve-path entries
/// (the real probe needs a TTY). Comptime-gated — free in release.
var detect_override: ?*const fn () Background = null;

/// Test-only: swap the background detector. Pass `null` to restore the real chain.
pub fn setDetectBackgroundForTest(f: ?*const fn () Background) void {
    if (!builtin.is_test) return;
    detect_override = f;
}

/// Chain: MALT_THEME env → OSC 11 query → COLORFGBG env → .unknown.
fn detectBackground() Background {
    if (builtin.is_test) {
        if (detect_override) |f| return f();
    }
    if (themeFromEnv(lookupEnv("MALT_THEME"))) |forced| return forced;
    if (queryOsc11Background()) |bg| return bg;
    if (lookupEnv("COLORFGBG")) |v| {
        const parsed = parseColorFgBg(v);
        if (parsed != .unknown) return parsed;
    }
    return .unknown;
}

/// W3C relative luminance threshold. Pure — no I/O.
pub fn classifyLuminance(rgb: Rgb) Background {
    const r = @as(f64, @floatFromInt(rgb.r)) / 255.0;
    const g = @as(f64, @floatFromInt(rgb.g)) / 255.0;
    const b = @as(f64, @floatFromInt(rgb.b)) / 255.0;
    const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    return if (y >= 0.5) .light else .dark;
}

/// Parse an OSC 11 response `ESC ] 11 ; rgb:R/G/B ST|BEL`.
pub fn parseOsc11Response(bytes: []const u8) ?Rgb {
    const osc = "\x1b]11;";
    if (!std.mem.startsWith(u8, bytes, osc)) return null;
    var rest = bytes[osc.len..];

    // Strip the terminator (BEL 0x07 or ST ESC\\).
    if (std.mem.indexOfScalar(u8, rest, 0x07)) |p| {
        rest = rest[0..p];
    } else if (std.mem.indexOf(u8, rest, "\x1b\\")) |p| {
        rest = rest[0..p];
    } else return null;

    const prefix = "rgb:";
    if (!std.mem.startsWith(u8, rest, prefix)) return null;
    rest = rest[prefix.len..];

    // Three `/`-separated hex components.
    var it = std.mem.splitScalar(u8, rest, '/');
    const r_hex = it.next() orelse return null;
    const g_hex = it.next() orelse return null;
    const b_hex = it.next() orelse return null;
    if (it.next() != null) return null;

    return Rgb{
        .r = highByte(r_hex) orelse return null,
        .g = highByte(g_hex) orelse return null,
        .b = highByte(b_hex) orelse return null,
    };
}

/// Top 8 bits of a 1-to-4-digit hex channel, xterm-style.
fn highByte(hex: []const u8) ?u8 {
    if (hex.len == 0 or hex.len > 4) return null;
    const digit = std.fmt.parseUnsigned(u16, hex, 16) catch return null;
    const shift: u4 = @intCast(16 - @as(u5, @intCast(hex.len * 4)));
    return @intCast((digit << shift) >> 8);
}

/// Classify a `COLORFGBG=fg;bg` or `fg;default;bg` value.
/// rxvt convention: bg ∈ {0..6, 8} dark, {7, 9..15} light.
pub fn parseColorFgBg(s: []const u8) Background {
    if (s.len == 0) return .unknown;
    var it = std.mem.splitScalar(u8, s, ';');
    var last: ?[]const u8 = null;
    var count: u8 = 0;
    while (it.next()) |field| {
        last = field;
        count += 1;
    }
    if (count != 2 and count != 3) return .unknown;
    const bg = last orelse return .unknown;
    if (std.mem.eql(u8, bg, "default")) return .unknown;
    const n = std.fmt.parseUnsigned(u8, bg, 10) catch return .unknown;
    return switch (n) {
        0...6, 8 => .dark,
        7, 9...15 => .light,
        else => .unknown,
    };
}

/// MALT_THEME={light|dark|auto}, case-insensitive. Null lets
/// detection continue down the chain.
pub fn themeFromEnv(value: ?[]const u8) ?Background {
    const raw = value orelse return null;
    if (std.ascii.eqlIgnoreCase(raw, "light")) return .light;
    if (std.ascii.eqlIgnoreCase(raw, "dark")) return .dark;
    return null; // "auto" or garbage ⇒ keep detecting
}

// ─── OSC 11 I/O ──────────────────────────────────────────────────────

/// Ask the terminal for its background colour via OSC 11 and classify
/// the response. TTY-only; bounded by a 100 ms poll so a silent
/// terminal never stalls malt.
fn queryOsc11Background() ?Background {
    if (!isTty(std.posix.STDIN_FILENO)) return null;
    if (!isTty(std.posix.STDERR_FILENO)) return null;

    const stdin_fd = std.posix.STDIN_FILENO;
    const stderr_fd = std.posix.STDERR_FILENO;

    // Raw mode: response bytes must reach our read, not the shell prompt.
    const saved = std.posix.tcgetattr(stdin_fd) catch return null;
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(stdin_fd, .FLUSH, raw) catch return null;
    // Restore cooked mode; if this fails the TTY is already broken and
    // there is no recovery we can sensibly do from inside defer.
    defer std.posix.tcsetattr(stdin_fd, .FLUSH, saved) catch {};

    const query = "\x1b]11;?\x1b\\";
    // Route the query through pkg_io like the response read below, so both sides
    // share one io path instead of a stray raw libc write.
    const stderr_file: std.Io.File = .{ .handle = stderr_fd, .flags = .{ .nonblocking = false } };
    stderr_file.writeStreamingAll(pkg_io, query) catch return null;

    var pfd = [_]std.posix.pollfd{.{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&pfd, 100) catch return null;
    if (ready == 0) return null;

    var buf: [64]u8 = undefined;
    const stdin_file: std.Io.File = .{ .handle = stdin_fd, .flags = .{ .nonblocking = false } };
    const n = stdin_file.readStreaming(pkg_io, &.{buf[0..]}) catch return null;
    if (n == 0) return null;
    const rgb = parseOsc11Response(buf[0..n]) orelse return null;
    return classifyLuminance(rgb);
}

// ─── Semantic palette ────────────────────────────────────────────────
//
// Four palette cells: (dark|light) × (truecolor|basic).
// Truecolor hues come from the Tailwind scale, picked to hit WCAG AA
// against the intended background. Basic variants fall back to the
// 8/16-colour escape codes every terminal handles.

const Palette = struct {
    info: []const u8,
    warn: []const u8,
    success: []const u8,
    err: []const u8,
    detail: []const u8,
    notice: []const u8,
};

// Dark + truecolor — Tailwind sky-300 / amber-400 / green-400 / red-400 / slate-400 / violet-400.
const dark_truecolor: Palette = .{
    .info = "\x1b[38;2;125;211;252m",
    .warn = "\x1b[38;2;251;191;36m",
    .success = "\x1b[38;2;74;222;128m",
    .err = "\x1b[38;2;248;113;113m",
    .detail = "\x1b[38;2;148;163;184m",
    .notice = "\x1b[38;2;167;139;250m",
};

// Light + truecolor — Tailwind sky-600 / amber-700 / green-700 / red-700 / slate-400 / violet-700.
// Yellow shifts to orange (amber-700) because only orange hits AA on white.
// Detail uses slate-400 like the dark palette so meta info recedes under the
// default-foreground body text instead of upstaging it in dark slate.
// Notice uses violet-700 — darker step keeps WCAG AA contrast.
const light_truecolor: Palette = .{
    .info = "\x1b[38;2;2;132;199m",
    .warn = "\x1b[38;2;180;83;9m",
    .success = "\x1b[38;2;21;128;61m",
    .err = "\x1b[38;2;185;28;28m",
    .detail = "\x1b[38;2;148;163;184m",
    .notice = "\x1b[38;2;109;40;217m",
};

// Dark + basic — legacy ANSI 8-colour palette malt has always used.
// Notice picks magenta — distinct from yellow warn here.
const dark_basic: Palette = .{
    .info = "\x1b[36m",
    .warn = "\x1b[33m",
    .success = "\x1b[32m",
    .err = "\x1b[31m",
    .detail = "\x1b[2m",
    .notice = "\x1b[35m",
};

// Light + basic — swap hues that wash out on white: cyan→blue,
// yellow→magenta. Detail reuses the dark-basic faint code so both basic
// palettes render meta info identically — dropping into the default
// foreground on terminals that ignore SGR 2.
// Notice picks cyan so it stays distinct from warn's magenta on the one
// palette where the same hue would otherwise collapse the two roles.
const light_basic: Palette = .{
    .info = "\x1b[34m",
    .warn = "\x1b[35m",
    .success = "\x1b[32m",
    .err = "\x1b[31m",
    .detail = "\x1b[2m",
    .notice = "\x1b[36m",
};

/// Pure palette lookup. Exposed so tests pin every cell.
pub fn paletteCode(role: SemanticStyle, bg: Background, truecolor: bool) []const u8 {
    const p: *const Palette = switch (bg) {
        .light => if (truecolor) &light_truecolor else &light_basic,
        // Unknown falls through to dark — the long-standing default.
        .dark, .unknown => if (truecolor) &dark_truecolor else &dark_basic,
    };
    return switch (role) {
        .info => p.info,
        .warn => p.warn,
        .success => p.success,
        .err => p.err,
        .detail => p.detail,
        .notice => p.notice,
    };
}

/// Pure classifier — returns true when the value advertises truecolor.
pub fn truecolorFromEnv(value: ?[]const u8) bool {
    const v = value orelse return false;
    return std.mem.eql(u8, v, "truecolor") or std.mem.eql(u8, v, "24bit");
}

/// Cached truecolor-support accessor. Reads $COLORTERM once.
pub fn truecolorSupported() bool {
    switch (@atomicLoad(Tri, &truecolor_cached, .acquire)) {
        .yes => return true,
        .no => return false,
        .unresolved => {},
    }
    const result: Tri = if (truecolorFromEnv(lookupEnv("COLORTERM"))) .yes else .no;
    @atomicStore(Tri, &truecolor_cached, result, .release);
    return result == .yes;
}

// Pin every notice cell across the (bg, truecolor) matrix. Sister tests for
// the existing roles live in tests/ui_color_theme_test.zig — kept there so
// changes to the broader palette stay reviewable as one diff.
test "paletteCode: notice — dark + truecolor is violet-400" {
    try std.testing.expectEqualStrings(
        "\x1b[38;2;167;139;250m",
        paletteCode(.notice, .dark, true),
    );
}

test "paletteCode: notice — light + truecolor is violet-700 (WCAG AA on white)" {
    try std.testing.expectEqualStrings(
        "\x1b[38;2;109;40;217m",
        paletteCode(.notice, .light, true),
    );
}

test "paletteCode: notice — dark + basic is magenta (distinct from yellow warn)" {
    try std.testing.expectEqualStrings("\x1b[35m", paletteCode(.notice, .dark, false));
}

// Light + basic must avoid warn's magenta — on a NO_COLOR-y / no-emoji
// terminal the glyph alone already carries the distinction, but as soon
// as basic colour is on the two lines have to land on different hues.
test "paletteCode: notice — light + basic uses cyan, distinct from warn-magenta" {
    try std.testing.expectEqualStrings("\x1b[36m", paletteCode(.notice, .light, false));
    try std.testing.expect(!std.mem.eql(
        u8,
        paletteCode(.notice, .light, false),
        paletteCode(.warn, .light, false),
    ));
}

// ─── TUI theme palette ───────────────────────────────────────────────
//
// `MALT_THEME` doubles as the TUI theme selector. `light`/`dark`/`auto`/
// `default` (and unknown values) resolve to `.default`, whose colours come from
// the background-aware tiers above; named themes carry their own truecolor RGB
// and degrade to the `.default` basic cell on terminals without truecolor.

/// Cached theme accessor. Resolves `MALT_THEME` on first touch, then serves the
/// atomic cache — race-free by construction, independent of boot ordering.
pub fn theme() Theme {
    if (@atomicLoad(bool, &theme_resolved, .acquire)) return @atomicLoad(Theme, &theme_cached, .acquire);
    const resolved = resolveThemeFromEnv(lookupEnv("MALT_THEME"));
    @atomicStore(Theme, &theme_cached, resolved, .release);
    @atomicStore(bool, &theme_resolved, true, .release);
    return resolved;
}

/// Pure: env value → theme. Lowercases into a bounded stack buffer (theme names
/// are short); anything unrecognised or over-long falls back to `.default`.
pub fn resolveThemeFromEnv(value: ?[]const u8) Theme {
    const raw = value orelse return .default;
    var buf: [32]u8 = undefined;
    if (raw.len == 0 or raw.len > buf.len) return .default;
    const lower = std.ascii.lowerString(buf[0..raw.len], raw);
    return themes.from_env.get(lower) orelse .default;
}

/// Outcome of a custom-theme load attempt. The caller (boot) maps `.rejected`
/// to a single user-facing notice; `color` itself stays free of any output
/// dependency so the `cli/tui → color` direction is preserved.
pub const InstallResult = enum { absent, loaded, rejected };

/// Install user-defined themes from an already-read, already-hardened byte
/// slice (null = no file present). Strict all-or-nothing: a malformed file is
/// rejected whole and the built-ins are kept. Read-only after this returns.
pub fn installCustomThemes(allocator: std.mem.Allocator, bytes: ?[]const u8) InstallResult {
    custom_count = 0;
    @atomicStore(usize, &active_custom, AC_UNRESOLVED, .release); // re-resolve against the new registry
    const b = bytes orelse return .absent;
    theme_registry.populate(allocator, b, &custom_storage) catch return .rejected;
    custom_count = custom_storage.registry.count;
    return .loaded;
}

/// Lazily-resolved index of the active custom theme, or null when none applies.
/// Cached like `theme()`; recomputed after a `setRuntime`/`installCustomThemes`.
fn activeCustomIndex() ?usize {
    const cached = @atomicLoad(usize, &active_custom, .acquire);
    if (cached != AC_UNRESOLVED) return if (cached == AC_NONE) null else cached;
    const resolved: usize = if (custom_count == 0)
        AC_NONE
    else if (resolveActiveCustom(lookupEnv("MALT_THEME"))) |i| i else AC_NONE;
    @atomicStore(usize, &active_custom, resolved, .release);
    return if (resolved == AC_NONE) null else resolved;
}

/// Precedence: a built-in named via `MALT_THEME` always wins (a custom theme can
/// never shadow `dracula`); else an explicit `MALT_THEME` naming a custom theme
/// selects it; else (unset or unrecognised selector) the file's `default`
/// marker. Only called when `custom_count > 0`, so `default_index` is valid.
fn resolveActiveCustom(raw: ?[:0]const u8) ?usize {
    if (raw) |r| {
        if (isBuiltinSelector(r)) return null;
        if (theme_registry.resolveByName(&custom_storage, r)) |i| return i;
        // An unrecognised selector falls through to the file default.
    }
    return custom_storage.registry.default_index;
}

/// True when `raw` names a built-in theme (or a reserved background value) the
/// static `from_env` map already owns — the no-shadow guard.
fn isBuiltinSelector(raw: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (raw.len == 0 or raw.len > buf.len) return false;
    const lower = std.ascii.lowerString(buf[0..raw.len], raw);
    return themes.from_env.get(lower) != null;
}

/// The active custom theme's palette when one is selected *and* applies under
/// the current tier — truecolor gate (wholesale, but a 256-index-only theme
/// needs no truecolor) and the polarity gate. Null ⇒ fall back to the built-in
/// resolver. Shared by the CLI (`SemanticStyle.code`) and TUI (`roleCode`) so
/// the two surfaces never disagree about when a custom theme is in effect.
fn activeCustomPalette(bg: Background, truecolor: bool) ?*const themes.NamedPalette {
    const i = activeCustomIndex() orelse return null;
    if (!truecolor and custom_storage.requires_truecolor[i]) return null;
    const t = &custom_storage.registry.themes[i];
    if (customPolarityConflicts(t.polarity, bg)) return null;
    return &t.palette;
}

/// Test-only reset of the custom registry between unit tests.
pub fn clearCustomForTest() void {
    if (!builtin.is_test) return;
    custom_count = 0;
    @atomicStore(usize, &active_custom, AC_UNRESOLVED, .release);
}

/// The escape for a role under the active (theme, background, tier). A selected
/// custom theme wins when it applies; otherwise the built-in resolver decides.
pub fn roleCode(role: Role) []const u8 {
    const bg = background();
    const tc = truecolorSupported();
    if (activeCustomPalette(bg, tc)) |p| return p.get(role);
    return resolveRole(theme(), role, bg, tc);
}

/// The `accent` the TUI emits immediately before `Style.reverse`, so reverse-video
/// renders it as the selection background. Resolves exactly like `roleCode(.accent)`
/// — the same accent the tab bar paints the active tab with — so the selection and
/// the active tab always carry one colour, including under the background-aware
/// `.default` palette and on a basic terminal.
pub fn selectionAccent() []const u8 {
    return roleCode(.accent);
}

/// Secondary accent — a blue with no cell in the existing semantic palette.
const Secondary = struct { dark_tc: []const u8, light_tc: []const u8, basic: []const u8 };
const secondary_blue: Secondary = .{
    .dark_tc = "\x1b[38;2;96;165;250m", // Tailwind blue-400
    .light_tc = "\x1b[38;2;29;78;216m", // Tailwind blue-700
    .basic = "\x1b[34m",
};

/// Pure role resolver. A named theme uses its RGB when it applies; otherwise
/// (basic terminal, polarity mismatch, or `.default`) it falls back to the
/// background-aware default palette.
pub fn resolveRole(t: Theme, role: Role, bg: Background, truecolor: bool) []const u8 {
    if (namedThemeApplies(t, bg, truecolor)) return themes.named(t).?.get(role);
    return defaultRoleCode(role, bg, truecolor);
}

/// A named theme applies only on a truecolor terminal whose detected background
/// does not contradict its polarity. The one predicate shared by the CLI
/// (`SemanticStyle.code`) and the TUI (`resolveRole`) so the two surfaces never
/// disagree about when a theme is in effect. False ⇒ fall back to `.default`.
fn namedThemeApplies(t: Theme, bg: Background, truecolor: bool) bool {
    return themes.named(t) != null and truecolor and !polarityConflicts(t, bg);
}

/// True only when the *detected* background is the opposite polarity to the
/// theme. `.unknown` never conflicts — an explicit MALT_THEME is overridden only
/// on positive evidence the theme would be illegible.
fn polarityConflicts(t: Theme, bg: Background) bool {
    const p = themes.polarity(t) orelse return false;
    return customPolarityConflicts(p, bg);
}

/// Core polarity gate over an explicit polarity. Built-in `.default` has no
/// polarity (handled above); custom themes always carry one, so they call here
/// directly. `.unknown` never conflicts — a theme is overridden only on positive
/// evidence its background is the wrong polarity.
fn customPolarityConflicts(p: themes.Polarity, bg: Background) bool {
    return switch (bg) {
        .light => p == .dark,
        .dark => p == .light,
        .unknown => false,
    };
}

/// Map a CLI semantic role onto the TUI paint role a named theme carries, so a
/// theme selected via MALT_THEME colours CLI output too. Consulted only on the
/// named-theme path; under `.default` the CLI keeps its own `notice`/`detail`
/// cells via `paletteCode`.
fn semanticToRole(role: SemanticStyle) Role {
    return switch (role) {
        .info => .accent,
        .notice => .secondary,
        .success => .success,
        .warn => .warning,
        .err => .danger,
        .detail => .muted,
    };
}

/// `.default` theme: map each role onto the existing background-aware cells,
/// plus the one new `secondary` blue.
fn defaultRoleCode(role: Role, bg: Background, truecolor: bool) []const u8 {
    const p: *const Palette = switch (bg) {
        .light => if (truecolor) &light_truecolor else &light_basic,
        .dark, .unknown => if (truecolor) &dark_truecolor else &dark_basic,
    };
    return switch (role) {
        .accent => p.info,
        .success => p.success,
        .warning => p.warn,
        .danger => p.err,
        .muted => p.detail,
        // secondary has no cell in `Palette`, so `p` is unused here.
        .secondary => switch (bg) {
            .light => if (truecolor) secondary_blue.light_tc else secondary_blue.basic,
            .dark, .unknown => if (truecolor) secondary_blue.dark_tc else secondary_blue.basic,
        },
    };
}

// ─── alignment predicate tests ───────────────────────────────────────
//
// These pin the one predicate the CLI and TUI share, so a regression that
// silently re-splits the two surfaces is caught here rather than by eye.

test "semanticToRole pairs each CLI role with a theme paint role" {
    // info/notice have no semantic twin in a named palette, so they borrow the
    // decorative accent/secondary; the other four pair by meaning.
    try std.testing.expectEqual(Role.accent, semanticToRole(.info));
    try std.testing.expectEqual(Role.secondary, semanticToRole(.notice));
    try std.testing.expectEqual(Role.success, semanticToRole(.success));
    try std.testing.expectEqual(Role.warning, semanticToRole(.warn));
    try std.testing.expectEqual(Role.danger, semanticToRole(.err));
    try std.testing.expectEqual(Role.muted, semanticToRole(.detail));
}

test "polarityConflicts fires only on a detected opposite background" {
    // dracula is dark: clashes with a light terminal, agrees with dark, and gets
    // the benefit of the doubt on unknown (we never override on a guess).
    try std.testing.expect(polarityConflicts(.dracula, .light));
    try std.testing.expect(!polarityConflicts(.dracula, .dark));
    try std.testing.expect(!polarityConflicts(.dracula, .unknown));
    // catppuccin-latte is light: the mirror image.
    try std.testing.expect(polarityConflicts(.catppuccin_latte, .dark));
    try std.testing.expect(!polarityConflicts(.catppuccin_latte, .light));
    try std.testing.expect(!polarityConflicts(.catppuccin_latte, .unknown));
    // .default has no polarity, so it never conflicts on any background.
    try std.testing.expect(!polarityConflicts(.default, .light));
    try std.testing.expect(!polarityConflicts(.default, .dark));
}

test "namedThemeApplies requires named + truecolor + no polarity conflict" {
    // All three conditions must hold; failing any one falls back to .default.
    try std.testing.expect(namedThemeApplies(.dracula, .dark, true));
    try std.testing.expect(namedThemeApplies(.dracula, .unknown, true));
    try std.testing.expect(!namedThemeApplies(.dracula, .light, true)); // polarity conflict
    try std.testing.expect(!namedThemeApplies(.dracula, .dark, false)); // basic terminal
    try std.testing.expect(!namedThemeApplies(.default, .dark, true)); // .default is never "named"
}

// ─── custom theme resolver wiring ────────────────────────────────────

const custom_ocean_src =
    \\{"version":1,"default":"ocean","themes":{
    \\  "ocean":{"polarity":"dark","accent":"#bd93f9","secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
    \\}}
;

/// Seed environ + force the (truecolor, background) tier, install a custom
/// registry, and return to a clean slate via `defer` in the caller. `theme()`
/// is left to resolve from `MALT_THEME` so the no-shadow path is exercised
/// realistically.
fn seedCustom(comptime malt_theme: ?[]const u8, tc: bool, bg: Background, src: ?[]const u8) InstallResult {
    const io = std.Options.debug_io;
    const slice = if (malt_theme) |v|
        &[_:null]?[*:0]const u8{"MALT_THEME=" ++ v}
    else
        &[_:null]?[*:0]const u8{};
    setRuntime(io, .{ .block = .{ .slice = slice } });
    setTruecolorForTest(tc);
    setBackgroundForTest(bg);
    return installCustomThemes(std.testing.allocator, src);
}

fn resetCustom() void {
    clearCustomForTest();
    setRuntime(std.Options.debug_io, .{ .block = .{ .slice = &[_:null]?[*:0]const u8{} } });
    setThemeForTest(null);
    setTruecolorForTest(null);
    setBackgroundForTest(null);
}

test "a selected custom theme paints the TUI role via the resolver" {
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, custom_ocean_src));
    defer resetCustom();
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", roleCode(.accent));
}

test "the CLI semantic seam carries the custom palette too" {
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, custom_ocean_src));
    defer resetCustom();
    // semanticToRole(.info) == .accent; ocean accent is #bd93f9.
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", SemanticStyle.info.code());
}

test "a custom theme named like a built-in never shadows it" {
    const src =
        \\{"version":1,"default":"dracula","themes":{
        \\  "dracula":{"polarity":"dark","accent":"#000000","secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
        \\}}
    ;
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("dracula", true, .unknown, src));
    defer resetCustom();
    // The built-in dracula accent wins; the custom "#000000" is unreachable by name.
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", roleCode(.accent));
}

test "MALT_THEME selects a custom theme over the file default; unset uses the file default" {
    const src =
        \\{"version":1,"default":"sand","themes":{
        \\  "ocean":{"polarity":"dark","accent":"#bd93f9","secondary":2,"success":3,"warning":4,"danger":5,"muted":6},
        \\  "sand":{"polarity":"dark","accent":"#50fa7b","secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
        \\}}
    ;
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, src));
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", roleCode(.accent)); // explicit ocean wins
    resetCustom();

    try std.testing.expectEqual(InstallResult.loaded, seedCustom(null, true, .unknown, src));
    defer resetCustom();
    try std.testing.expectEqualStrings("\x1b[38;2;80;250;123m", roleCode(.accent)); // unset ⇒ file default sand
}

test "a 256-index custom theme paints without truecolor; a hex one degrades whole" {
    const c256 =
        \\{"version":1,"default":"x","themes":{
        \\  "x":{"polarity":"dark","accent":40,"secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
        \\}}
    ;
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("x", false, .unknown, c256)); // truecolor off
    try std.testing.expectEqualStrings("\x1b[38;5;40m", roleCode(.accent));
    resetCustom();

    const chex =
        \\{"version":1,"default":"x","themes":{
        \\  "x":{"polarity":"dark","accent":"#bd93f9","secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
        \\}}
    ;
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("x", false, .unknown, chex)); // truecolor off
    defer resetCustom();
    // requires truecolor ⇒ wholesale fall back to the default tier.
    try std.testing.expectEqualStrings(resolveRole(.default, .accent, .unknown, false), roleCode(.accent));
}

test "a light custom theme degrades to default on a detected dark terminal" {
    const src =
        \\{"version":1,"default":"day","themes":{
        \\  "day":{"polarity":"light","accent":"#bd93f9","secondary":2,"success":3,"warning":4,"danger":5,"muted":6}
        \\}}
    ;
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("day", true, .dark, src));
    defer resetCustom();
    // light polarity vs detected dark ⇒ conflict ⇒ default tier.
    try std.testing.expectEqualStrings(resolveRole(.default, .accent, .dark, true), roleCode(.accent));
}

test "a rejected file keeps the built-in default output" {
    try std.testing.expectEqual(InstallResult.rejected, seedCustom("whatever", true, .unknown, "{\"version\":9}"));
    defer resetCustom();
    try std.testing.expectEqualStrings(resolveRole(.default, .accent, .unknown, true), roleCode(.accent));
}

test "no themes file leaves the resolver untouched" {
    try std.testing.expectEqual(InstallResult.absent, seedCustom(null, true, .unknown, null));
    defer resetCustom();
    try std.testing.expectEqualStrings(resolveRole(.default, .accent, .unknown, true), roleCode(.accent));
}

// ─── selectionAccent (TUI selection highlight) ───────────────────────
//
// The accent emitted before reverse-video so the highlight follows the theme.
// It must equal the active-tab accent (`roleCode(.accent)`) on every tier, so
// the selection and the active tab never carry mismatched colours.

test "selectionAccent matches the active-tab accent under .default" {
    clearCustomForTest();
    setThemeForTest(.default);
    setTruecolorForTest(true);
    setBackgroundForTest(.unknown);
    defer {
        setThemeForTest(null);
        setTruecolorForTest(null);
        setBackgroundForTest(null);
    }
    // The default palette has an accent; the selection must use it, not plain
    // reverse, so it reads the same as the tab bar's active block.
    try std.testing.expectEqualStrings(roleCode(.accent), selectionAccent());
    try std.testing.expect(selectionAccent().len != 0);
}

test "selectionAccent carries a named theme's accent when it applies" {
    clearCustomForTest();
    setThemeForTest(.dracula);
    setTruecolorForTest(true);
    setBackgroundForTest(.unknown);
    defer {
        setThemeForTest(null);
        setTruecolorForTest(null);
        setBackgroundForTest(null);
    }
    // The same accent the rest of the TUI paints; reverse-video makes it the bg.
    try std.testing.expectEqualStrings(themes.named(.dracula).?.get(.accent), selectionAccent());
    try std.testing.expect(selectionAccent().len != 0);
}

test "selectionAccent falls back to the default accent on a basic terminal" {
    clearCustomForTest();
    setThemeForTest(.dracula);
    setTruecolorForTest(false);
    setBackgroundForTest(.unknown);
    defer {
        setThemeForTest(null);
        setTruecolorForTest(null);
        setBackgroundForTest(null);
    }
    // A named theme needs truecolor, so it doesn't apply here; the selection
    // follows the same default accent the tab bar uses, never plain reverse.
    try std.testing.expectEqualStrings(roleCode(.accent), selectionAccent());
}

test "selectionAccent carries an active custom theme's accent" {
    try std.testing.expectEqual(InstallResult.loaded, seedCustom("ocean", true, .unknown, custom_ocean_src));
    defer resetCustom();
    try std.testing.expectEqualStrings("\x1b[38;2;189;147;249m", selectionAccent());
}
