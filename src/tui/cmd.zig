//! Sink leaf: the TUI's effect vocabulary as data. A pure `update` returns a
//! `Cmd`; one domain-agnostic interpreter performs it and routes the result back
//! as a `Msg`. Both the interpreter and every `*_tab.zig` import this *downward*
//! (like `ctx.zig`), so a tab names an effect without importing the runner
//! (`spawn`) or reaching up into `app.zig` — the property a file-level
//! `grep spawn <tab>.zig` check pins. It imports only `std`, the six `json/*`
//! parse-result types (for the `Parsed` union), and `tab_bar.zig` — never a tab
//! and never `app.zig`.

const std = @import("std");
const tab_bar = @import("tab_bar.zig");
const doctor_json = @import("json/doctor.zig");
const info_json = @import("json/info.zig");
const list_json = @import("json/list.zig");
const outdated_json = @import("json/outdated.zig");
const search_json = @import("json/search.zig");
const services_json = @import("json/services.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;

/// Routing key echoed from a `Cmd` into its result `Msg`: which tab's `update`
/// consumes the result. It is the tab enum because a background read may complete
/// after the user switched tabs, so the result must be pinned to its owning tab
/// regardless of the active one — the same role `ctx.TabFetch.tab` plays today.
pub const MsgTag = tab_bar.Tab;

/// Comptime union of the six tab parse-result types. Chosen over an `anyopaque`
/// handle so a `Parsed` crossing the `Cmd`/`Msg` boundary keeps its static type:
/// the type safety the tab-state table relies on is preserved and the sole
/// audited `@ptrCast` (`ctx.Banner.appendSink`) stays the only one. The active
/// member names the parser that produced it.
pub const Parsed = union(enum) {
    doctor: doctor_json.Parsed,
    info: info_json.Parsed,
    list: list_json.Parsed,
    outdated: outdated_json.Parsed,
    search: search_json.Parsed,
    services: services_json.Parsed,

    /// Free the active member's arena. Exhaustive over the union so a new parser
    /// type must add its arm here — a member can never leak by omission.
    pub fn deinit(self: Parsed) void {
        switch (self) {
            inline else => |parsed| parsed.deinit(),
        }
    }
};

/// The parser a `Cmd.read` carries: captured child stdout → a tagged `Parsed`.
/// `anyerror` widens each tab parser's own error set so one field type spans all
/// six; the payload is unified by `parserFor`, which is why the interpreter needs
/// no per-tab knowledge.
pub const ParseFn = *const fn (Allocator, []const u8) anyerror!Parsed;

/// Wrap a tab's real parser (`&<tab>_json.parse`) into a `ParseFn` that tags the
/// result with `member`. Comptime and allocation-free: `@unionInit` checks the
/// parser's return type against the named union member at compile time, so this
/// is fully type-safe with no `@ptrCast`. A bare `&<tab>_json.parse` cannot bind
/// to a union-returning fn pointer in Zig (the error-union payloads differ), so
/// this one-line adapter is the type-safe substitute the comptime union needs.
pub fn parserFor(
    comptime member: @typeInfo(Parsed).@"union".tag_type.?,
    comptime parse: anytype,
) ParseFn {
    return &struct {
        fn wrapped(allocator: Allocator, bytes: []const u8) anyerror!Parsed {
            return @unionInit(Parsed, @tagName(member), try parse(allocator, bytes));
        }
    }.wrapped;
}

/// A delegated effect as data. The pure `update` returns one; the interpreter
/// performs it and routes the result back as a `Msg`. Because a tab builds these
/// without importing the runner, each `*_tab.zig` stays provably pure.
pub const Cmd = union(enum) {
    /// No effect — a state change with no I/O (e.g. search's basket toggles).
    none,
    /// A `mt … --json` read; the carried parser turns its stdout into `Parsed`.
    read: Read,
    /// A self-classifying inline mutation (`mt …`). The interpreter drains the
    /// background-fetch pool before running it (the single-writer invariant).
    run_mutation: Mutation,
    /// Independent passes run in order — upgrade's `--formula` then `--cask`.
    batch: []const Cmd,

    /// How the interpreter drives a read: a non-blocking background child the
    /// loop drains, a blocking capture, or a blocking capture that ticks a
    /// spinner between poll timeouts.
    pub const Mode = enum { blocking, polled, background };

    pub const Read = struct {
        argv: []const []const u8,
        /// Highest child exit still a successful read — Doctor's severity exit
        /// (≤2) is not a failure; the others require a clean 0.
        max_ok_exit: u8 = 0,
        /// An exit-0 empty document (a fresh prefix with no db) is not a fault.
        allow_empty: bool = false,
        mode: Mode,
        parse: ParseFn,
        tag: MsgTag,
    };

    pub const Mutation = struct {
        argv: []const []const u8,
        /// Highest child exit still a success — e.g. `mt doctor --fix`'s severity.
        max_ok_exit: u8 = 0,
        tag: MsgTag,
    };
};

/// A result flowing back from the interpreter into a tab's `update`.
pub const Msg = union(enum) {
    /// A read completed: the parsed document, typed by its union member.
    loaded: Parsed,
    /// A mutation completed with this child exit code. 0 is success; a tolerated
    /// non-zero (Doctor's severity, the cask app-running refusal) is the owning
    /// tab's to interpret.
    mutated: u8,
};

// ── tests (written first; the decls above are added to make them pass) ───────

test "Parsed preserves the active member's tag round-trip" {
    const p = try services_json.parse(testing.allocator, "{\"services\":[]}");
    const boxed: Parsed = .{ .services = p };
    defer boxed.deinit();
    try testing.expect(boxed == .services);
    try testing.expectEqual(@as(usize, 0), boxed.services.items.len);
}

test "Parsed union members are exactly the six tab parse-result types" {
    comptime {
        try testing.expectEqual(doctor_json.Parsed, @FieldType(Parsed, "doctor"));
        try testing.expectEqual(info_json.Parsed, @FieldType(Parsed, "info"));
        try testing.expectEqual(list_json.Parsed, @FieldType(Parsed, "list"));
        try testing.expectEqual(outdated_json.Parsed, @FieldType(Parsed, "outdated"));
        try testing.expectEqual(search_json.Parsed, @FieldType(Parsed, "search"));
        try testing.expectEqual(services_json.Parsed, @FieldType(Parsed, "services"));
    }
}

test "parserFor wraps a real tab parser and tags its result" {
    const parse: ParseFn = parserFor(.services, services_json.parse);
    const boxed = try parse(testing.allocator, "{\"services\":[]}");
    defer boxed.deinit();
    try testing.expect(boxed == .services);
}

test "parserFor propagates the parser's error instead of swallowing it" {
    // The adapter must not hide a parse failure behind the `anyerror` widening:
    // a malformed document has to surface, or the interpreter would route a
    // bogus empty `Parsed` back to the tab.
    const parse: ParseFn = parserFor(.services, services_json.parse);
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
}

test "every tab parser is assignable through parserFor with no cast" {
    // Compile-time proof the comptime union covers all six with no erasure: each
    // `&<tab>_json.parse` yields a `ParseFn` (would fail to compile otherwise).
    comptime {
        const all = [_]ParseFn{
            parserFor(.doctor, doctor_json.parse),
            parserFor(.info, info_json.parse),
            parserFor(.list, list_json.parse),
            parserFor(.outdated, outdated_json.parse),
            parserFor(.search, search_json.parse),
            parserFor(.services, services_json.parse),
        };
        try testing.expectEqual(@as(usize, 6), all.len);
    }
}

test "Cmd covers the read modes and the mutation/batch surface" {
    const none: Cmd = .none;
    try testing.expect(none == .none);

    // Background/blocking/polled reads, doctor's severity tolerance, empty-ok.
    const bg: Cmd = .{ .read = .{
        .argv = &.{ "mt", "outdated", "--json" },
        .mode = .background,
        .parse = parserFor(.outdated, outdated_json.parse),
        .tag = .outdated,
    } };
    try testing.expect(bg.read.mode == .background);
    try testing.expectEqual(@as(u8, 0), bg.read.max_ok_exit);
    try testing.expect(!bg.read.allow_empty);

    const doctor_read: Cmd = .{ .read = .{
        .argv = &.{ "mt", "doctor", "--json" },
        .max_ok_exit = 2,
        .allow_empty = true,
        .mode = .polled,
        .parse = parserFor(.doctor, doctor_json.parse),
        .tag = .doctor,
    } };
    try testing.expectEqual(@as(u8, 2), doctor_read.read.max_ok_exit);
    try testing.expect(doctor_read.read.mode == .polled);

    // A tolerant/status mutation carries its own exit tolerance and route.
    const fix: Cmd = .{ .run_mutation = .{
        .argv = &.{ "mt", "doctor", "--fix", "stale_lock" },
        .max_ok_exit = 2,
        .tag = .doctor,
    } };
    try testing.expectEqual(@as(u8, 2), fix.run_mutation.max_ok_exit);

    // Upgrade's two-pass batch: one formula pass, one cask pass.
    const passes = [_]Cmd{
        .{ .run_mutation = .{ .argv = &.{ "mt", "upgrade", "--formula", "jq" }, .tag = .outdated } },
        .{ .run_mutation = .{ .argv = &.{ "mt", "upgrade", "--cask", "docker" }, .tag = .outdated } },
    };
    const batch: Cmd = .{ .batch = &passes };
    try testing.expectEqual(@as(usize, 2), batch.batch.len);
    try testing.expect(batch.batch[0].run_mutation.tag == .outdated);
}

test "Msg delivers a loaded Parsed and a mutation exit code" {
    const p = try services_json.parse(testing.allocator, "{\"services\":[]}");
    const loaded: Msg = .{ .loaded = .{ .services = p } };
    defer switch (loaded) {
        .loaded => |parsed| parsed.deinit(),
        .mutated => {},
    };
    try testing.expect(loaded == .loaded);

    const mutated: Msg = .{ .mutated = 3 }; // cask "app is running" refusal code
    try testing.expectEqual(@as(u8, 3), mutated.mutated);
}

test "MsgTag routes a result back to a tab, mirroring TabFetch.tab" {
    // The routing key is the tab enum: a completed background read is pinned to
    // its owning tab regardless of which tab is active when it lands.
    try testing.expectEqual(tab_bar.Tab, MsgTag);
    const tag: MsgTag = .search;
    try testing.expect(tag == .search);
}
