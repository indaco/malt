//! Reader for the launchd plist a formula ships in its own keg, lifting it
//! into the `ServiceSpec` malt renders and registers itself.
//!
//! The bytes come from the bottle, so the scanner is deliberately small and
//! refuse-by-default: an XML plist subset, a fixed key allowlist, and hard
//! caps on size and nesting. Nothing from the file reaches launchd directly;
//! `plist.validate` still gates the spec this produces.

const std = @import("std");
const testing = std.testing;

const plist = @import("plist.zig");
const types = @import("types.zig");

/// Real shipped plists are under 2 KiB.
pub const max_bytes: usize = 64 * 1024;
/// `dict > Sockets > <name> > SecureSocketWithKey` is the deepest accepted shape.
pub const max_depth: usize = 4;
/// Longer than any launchd key, and short enough that a refusal can always
/// name it.
pub const max_key_len: usize = 64;

pub const Error = error{
    OutOfMemory,
    /// Not the XML plist subset malt reads, or over a cap.
    Malformed,
    /// A key malt does not carry into its own plist.
    UnknownKey,
    DuplicateKey,
    /// A known key whose value has a shape malt does not carry.
    BadValue,
    /// The shipped `Label` is absent or not the label the formula declared.
    LabelMismatch,
    NoProgramArguments,
};

/// Names the key behind `UnknownKey`, `DuplicateKey` and `BadValue` so the
/// install warning can say which one.
pub const Diag = struct {
    key: []const u8 = "",
};

/// Lift `bytes` (the keg's `<label>.plist`) into the spec malt registers
/// for `name`. Result strings borrow from `bytes` or are owned by `aa`.
pub fn lift(
    aa: std.mem.Allocator,
    bytes: []const u8,
    name: []const u8,
    label: []const u8,
    prefix: []const u8,
    diag: *Diag,
) Error!plist.ServiceSpec {
    if (bytes.len > max_bytes) return error.Malformed;
    var sc: Scanner = .{ .aa = aa, .src = bytes, .diag = diag };
    const root = try sc.document();
    return toSpec(aa, root, name, label, prefix, diag);
}

// ─── XML plist subset ───────────────────────────────────────────────────

const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    array: []const Value,
    dict: []const Entry,
};

const Entry = struct { key: []const u8, value: Value };

const Scanner = struct {
    aa: std.mem.Allocator,
    src: []const u8,
    diag: *Diag,
    pos: usize = 0,

    /// One `<plist>` holding one `<dict>`, nothing after it.
    fn document(self: *Scanner) Error![]const Entry {
        _ = self.eat("\xEF\xBB\xBF");
        self.skipTrivia();
        try self.expect("<plist");
        self.pos = (std.mem.indexOfScalarPos(u8, self.src, self.pos, '>') orelse return error.Malformed) + 1;
        self.skipTrivia();
        const root: []const Entry = if (self.eat("<dict/>")) &.{} else blk: {
            try self.expect("<dict>");
            break :blk try self.dict(1);
        };
        self.skipTrivia();
        try self.expect("</plist>");
        self.skipTrivia();
        if (self.pos != self.src.len) return error.Malformed;
        return root;
    }

    /// Whitespace, the XML declaration, the DOCTYPE and comments.
    fn skipTrivia(self: *Scanner) void {
        while (true) {
            self.pos = std.mem.indexOfNonePos(u8, self.src, self.pos, " \t\r\n") orelse self.src.len;
            const close: []const u8 = if (self.startsWith("<?")) "?>" else if (self.startsWith("<!--")) "-->" else if (self.startsWith("<!")) ">" else return;
            self.pos = (std.mem.indexOfPos(u8, self.src, self.pos, close) orelse self.src.len) + close.len;
            if (self.pos > self.src.len) self.pos = self.src.len;
        }
    }

    fn startsWith(self: *Scanner, lit: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], lit);
    }

    fn eat(self: *Scanner, lit: []const u8) bool {
        if (!self.startsWith(lit)) return false;
        self.pos += lit.len;
        return true;
    }

    fn expect(self: *Scanner, lit: []const u8) Error!void {
        if (!self.eat(lit)) return error.Malformed;
    }

    /// Body of `<dict>` after its opener, through the closer.
    fn dict(self: *Scanner, depth: usize) Error![]const Entry {
        if (depth > max_depth) return error.Malformed;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipTrivia();
            if (self.eat("</dict>")) break;
            try self.expect("<key>");
            const key = try self.text("</key>");
            if (key.len == 0 or key.len > max_key_len) return error.Malformed;
            // Refused at every depth: a repeat inside EnvironmentVariables
            // or Sockets would render two identical <key>s for launchd.
            for (entries.items) |prev| if (std.mem.eql(u8, prev.key, key)) {
                self.diag.key = key;
                return error.DuplicateKey;
            };
            try entries.append(self.aa, .{ .key = key, .value = try self.value(depth) });
        }
        return entries.toOwnedSlice(self.aa);
    }

    fn value(self: *Scanner, depth: usize) Error!Value {
        self.skipTrivia();
        if (self.eat("<string/>")) return .{ .string = "" };
        if (self.eat("<string>")) return .{ .string = try self.text("</string>") };
        if (self.eat("<true/>")) return .{ .boolean = true };
        if (self.eat("<false/>")) return .{ .boolean = false };
        if (self.eat("<integer>")) {
            const digits = std.mem.trim(u8, try self.text("</integer>"), " \t\r\n");
            return .{ .integer = std.fmt.parseInt(i64, digits, 10) catch return error.Malformed };
        }
        if (self.eat("<dict/>")) return .{ .dict = &.{} };
        if (self.eat("<dict>")) return .{ .dict = try self.dict(depth + 1) };
        if (self.eat("<array/>")) return .{ .array = &.{} };
        if (self.eat("<array>")) {
            if (depth + 1 > max_depth) return error.Malformed;
            var items: std.ArrayList(Value) = .empty;
            while (true) {
                self.skipTrivia();
                if (self.eat("</array>")) break;
                try items.append(self.aa, try self.value(depth + 1));
            }
            return .{ .array = try items.toOwnedSlice(self.aa) };
        }
        return error.Malformed;
    }

    /// Text up to the next tag, which must be `close`. Decodes exactly the
    /// five entities `plist.render` escapes; a borrowed slice when there
    /// are none.
    fn text(self: *Scanner, close: []const u8) Error![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse return error.Malformed;
        const raw = self.src[self.pos..end];
        self.pos = end;
        try self.expect(close);
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;

        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] != '&') {
                try out.append(self.aa, raw[i]);
                continue;
            }
            const ent = for (entities) |ent| {
                if (std.mem.startsWith(u8, raw[i..], ent.text)) break ent;
            } else return error.Malformed;
            try out.append(self.aa, ent.char);
            i += ent.text.len - 1;
        }
        return out.toOwnedSlice(self.aa);
    }
};

const Entity = struct { text: []const u8, char: u8 };
const entities = [_]Entity{
    .{ .text = "&amp;", .char = '&' },
    .{ .text = "&lt;", .char = '<' },
    .{ .text = "&gt;", .char = '>' },
    .{ .text = "&quot;", .char = '"' },
    .{ .text = "&apos;", .char = '\'' },
};

// ─── dict -> ServiceSpec ────────────────────────────────────────────────

const Key = enum {
    label,
    program_arguments,
    working_directory,
    environment_variables,
    standard_out_path,
    standard_error_path,
    run_at_load,
    keep_alive,
    start_interval,
    start_calendar_interval,
    exit_time_out,
    sockets,
    service_ipc,
    enable_transactions,
};

/// Every launchd key malt carries or knowingly ignores. `Program`,
/// `MachServices`, `UserName`, ... are refused by absence.
const keys = std.StaticStringMap(Key).initComptime(.{
    .{ "Label", .label },
    .{ "ProgramArguments", .program_arguments },
    .{ "WorkingDirectory", .working_directory },
    .{ "EnvironmentVariables", .environment_variables },
    .{ "StandardOutPath", .standard_out_path },
    .{ "StandardErrorPath", .standard_error_path },
    .{ "RunAtLoad", .run_at_load },
    .{ "KeepAlive", .keep_alive },
    .{ "StartInterval", .start_interval },
    .{ "StartCalendarInterval", .start_calendar_interval },
    .{ "ExitTimeOut", .exit_time_out },
    .{ "Sockets", .sockets },
    .{ "ServiceIPC", .service_ipc },
    .{ "EnableTransactions", .enable_transactions },
});

const CalField = enum { minute, hour, day, weekday, month };
const cal_fields = std.StaticStringMap(CalField).initComptime(.{
    .{ "Minute", .minute },
    .{ "Hour", .hour },
    .{ "Day", .day },
    .{ "Weekday", .weekday },
    .{ "Month", .month },
});

fn toSpec(
    aa: std.mem.Allocator,
    root: []const Entry,
    name: []const u8,
    label: []const u8,
    prefix: []const u8,
    diag: *Diag,
) Error!plist.ServiceSpec {
    var plist_label: ?[]const u8 = null;
    var program_args: []const []const u8 = &.{};
    var spec: plist.ServiceSpec = .{
        .label = try std.fmt.allocPrint(aa, "com.malt.{s}", .{name}),
        .program_args = &.{},
        // Real shipped plists log under /tmp; malt logs every service it
        // owns under var/log, and `validate` would refuse /tmp anyway.
        .stdout_path = try std.fmt.allocPrint(aa, "{s}/var/log/{s}.out", .{ prefix, name }),
        .stderr_path = try std.fmt.allocPrint(aa, "{s}/var/log/{s}.err", .{ prefix, name }),
    };

    for (root) |e| {
        diag.key = e.key;
        switch (keys.get(e.key) orelse return error.UnknownKey) {
            .label => plist_label = try string(e.value),
            .program_arguments => program_args = try stringArray(aa, e.value),
            .working_directory => spec.working_dir = try string(e.value),
            .environment_variables => spec.env = try envPairs(aa, e.value),
            // Accepted for shape only; malt keeps its own log paths and
            // derives RunAtLoad from the schedule. The two IPC flags are
            // legacy no-ops for launchd itself.
            .standard_out_path, .standard_error_path => _ = try string(e.value),
            .run_at_load, .service_ipc, .enable_transactions => _ = try boolean(e.value),
            // The API rule: any directive dict keeps the job alive; only a
            // literal false turns it off.
            .keep_alive => spec.keep_alive = switch (e.value) {
                .boolean => |b| b,
                .dict => true,
                else => return error.BadValue,
            },
            .start_interval => {
                if (spec.schedule != .immediate) return error.BadValue;
                spec.schedule = .{ .interval = try integer(u32, e.value) };
            },
            .start_calendar_interval => {
                if (spec.schedule != .immediate) return error.BadValue;
                spec.schedule = .{ .calendar = try calendar(aa, e.value) };
            },
            .exit_time_out => spec.stop_timeout = try integer(u32, e.value),
            .sockets => spec.sockets = try sockets(aa, e.value),
        }
    }
    diag.key = "";

    if (!std.mem.eql(u8, plist_label orelse return error.LabelMismatch, label)) return error.LabelMismatch;
    if (program_args.len == 0) return error.NoProgramArguments;
    spec.program_args = program_args;
    return spec;
}

fn string(v: Value) Error![]const u8 {
    return if (v == .string) v.string else error.BadValue;
}

fn boolean(v: Value) Error!bool {
    return if (v == .boolean) v.boolean else error.BadValue;
}

fn integer(comptime T: type, v: Value) Error!T {
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.BadValue,
        else => error.BadValue,
    };
}

fn stringArray(aa: std.mem.Allocator, v: Value) Error![]const []const u8 {
    const items = switch (v) {
        .array => |a| a,
        else => return error.BadValue,
    };
    const out = try aa.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try string(item);
    return out;
}

fn envPairs(aa: std.mem.Allocator, v: Value) Error![]const plist.EnvPair {
    const entries = switch (v) {
        .dict => |d| d,
        else => return error.BadValue,
    };
    const out = try aa.alloc(plist.EnvPair, entries.len);
    for (entries, 0..) |e, i| out[i] = .{ .key = e.key, .value = try string(e.value) };
    return out;
}

/// One calendar dict or an array of them, each holding only the five
/// launchd fields as integers (range is `validate`'s job).
fn calendar(aa: std.mem.Allocator, v: Value) Error![]const types.CalendarInterval {
    const dicts: []const Value = switch (v) {
        .dict => &.{v},
        .array => |a| a,
        else => return error.BadValue,
    };
    const out = try aa.alloc(types.CalendarInterval, dicts.len);
    for (dicts, 0..) |d, i| {
        const entries = switch (d) {
            .dict => |es| es,
            else => return error.BadValue,
        };
        var ci: types.CalendarInterval = .{};
        for (entries) |e| {
            const n = try integer(u8, e.value);
            switch (cal_fields.get(e.key) orelse return error.BadValue) {
                .minute => ci.minute = n,
                .hour => ci.hour = n,
                .day => ci.day = n,
                .weekday => ci.weekday = n,
                .month => ci.month = n,
            }
        }
        out[i] = ci;
    }
    return out;
}

/// `Sockets/<name>/SecureSocketWithKey/<env key>` and nothing else: every
/// other socket key (`SockPathName`, `SockServiceName`, ...) names a path
/// or port malt would have to confine.
fn sockets(aa: std.mem.Allocator, v: Value) Error![]const plist.Socket {
    const entries = switch (v) {
        .dict => |d| d,
        else => return error.BadValue,
    };
    if (entries.len == 0) return error.BadValue;
    const out = try aa.alloc(plist.Socket, entries.len);
    for (entries, 0..) |e, i| {
        const inner = switch (e.value) {
            .dict => |d| d,
            else => return error.BadValue,
        };
        if (inner.len != 1 or !std.mem.eql(u8, inner[0].key, "SecureSocketWithKey")) return error.BadValue;
        out[i] = .{ .name = e.key, .env_key = try string(inner[0].value) };
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────────────

const head =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<!-- a comment block, as dbus ships -->
    \\<plist version="1.0">
    \\<dict>
    \\  <key>Label</key>
    \\  <string>org.example.svcd</string>
    \\  <key>ProgramArguments</key>
    \\  <array>
    \\    <string>/opt/malt/opt/svcd/bin/svcd</string>
    \\    <string>--nofork</string>
    \\  </array>
    \\
;
const tail =
    \\</dict>
    \\</plist>
    \\
;

fn liftFixture(aa: std.mem.Allocator, extra: []const u8, diag: *Diag) Error!plist.ServiceSpec {
    const bytes = try std.mem.concat(aa, u8, &.{ head, extra, tail });
    return lift(aa, bytes, "svcd", "org.example.svcd", "/opt/malt", diag);
}

test "lift maps every accepted key onto the spec and keeps malt's own label and log paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const spec = try liftFixture(arena.allocator(),
        \\  <key>WorkingDirectory</key>
        \\  <string>/opt/malt/var/svcd</string>
        \\  <key>EnvironmentVariables</key>
        \\  <dict>
        \\    <key>PATH</key>
        \\    <string>/opt/malt/bin:/usr/bin</string>
        \\    <key>FOO</key>
        \\    <string>a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;</string>
        \\  </dict>
        \\  <key>StandardOutPath</key>
        \\  <string>/tmp/svcd.out</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>/tmp/svcd.err</string>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <false/>
        \\  <key>StartInterval</key>
        \\  <integer>300</integer>
        \\  <key>ExitTimeOut</key>
        \\  <integer>45</integer>
        \\  <key>ServiceIPC</key>
        \\  <true/>
        \\  <key>EnableTransactions</key>
        \\  <true/>
        \\  <key>Sockets</key>
        \\  <dict>
        \\    <key>unix_domain_listener</key>
        \\    <dict>
        \\      <key>SecureSocketWithKey</key>
        \\      <string>SVCD_SOCKET</string>
        \\    </dict>
        \\  </dict>
        \\
    , &diag);
    try testing.expectEqualStrings("com.malt.svcd", spec.label);
    try testing.expectEqual(@as(usize, 2), spec.program_args.len);
    try testing.expectEqualStrings("/opt/malt/opt/svcd/bin/svcd", spec.program_args[0]);
    try testing.expectEqualStrings("--nofork", spec.program_args[1]);
    try testing.expectEqualStrings("/opt/malt/var/svcd", spec.working_dir.?);
    try testing.expectEqual(@as(usize, 2), spec.env.len);
    try testing.expectEqualStrings("PATH", spec.env[0].key);
    try testing.expectEqualStrings("/opt/malt/bin:/usr/bin", spec.env[0].value);
    try testing.expectEqualStrings("a & b <c> \"d\" 'e'", spec.env[1].value);
    // Shipped log paths point at /tmp; malt logs every service under var/log.
    try testing.expectEqualStrings("/opt/malt/var/log/svcd.out", spec.stdout_path);
    try testing.expectEqualStrings("/opt/malt/var/log/svcd.err", spec.stderr_path);
    try testing.expect(!spec.keep_alive);
    try testing.expectEqual(@as(u32, 300), spec.schedule.interval);
    try testing.expectEqual(@as(?u32, 45), spec.stop_timeout);
    try testing.expectEqual(@as(usize, 1), spec.sockets.len);
    try testing.expectEqualStrings("unix_domain_listener", spec.sockets[0].name);
    try testing.expectEqualStrings("SVCD_SOCKET", spec.sockets[0].env_key);
}

test "lift defaults a plist with only Label and ProgramArguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const spec = try liftFixture(arena.allocator(), "", &diag);
    try testing.expect(spec.working_dir == null);
    try testing.expectEqual(@as(usize, 0), spec.env.len);
    try testing.expectEqual(@as(usize, 0), spec.sockets.len);
    try testing.expect(spec.keep_alive);
    try testing.expect(spec.schedule == .immediate);
    try testing.expect(spec.stop_timeout == null);
}

test "lift reads KeepAlive the way the API path does: true unless literally false" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const directive = try liftFixture(arena.allocator(),
        \\  <key>KeepAlive</key>
        \\  <dict>
        \\    <key>SuccessfulExit</key>
        \\    <false/>
        \\  </dict>
        \\
    , &diag);
    try testing.expect(directive.keep_alive);
    const plain = try liftFixture(arena.allocator(), "  <key>KeepAlive</key>\n  <true/>\n", &diag);
    try testing.expect(plain.keep_alive);
}

test "lift reads StartCalendarInterval as one dict or an array of dicts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const one = try liftFixture(arena.allocator(),
        \\  <key>StartCalendarInterval</key>
        \\  <dict>
        \\    <key>Hour</key>
        \\    <integer>4</integer>
        \\    <key>Minute</key>
        \\    <integer>30</integer>
        \\  </dict>
        \\
    , &diag);
    try testing.expectEqual(@as(usize, 1), one.schedule.calendar.len);
    try testing.expectEqual(@as(?u8, 4), one.schedule.calendar[0].hour);
    try testing.expectEqual(@as(?u8, 30), one.schedule.calendar[0].minute);
    try testing.expect(one.schedule.calendar[0].day == null);

    const many = try liftFixture(arena.allocator(),
        \\  <key>StartCalendarInterval</key>
        \\  <array>
        \\    <dict><key>Weekday</key><integer>1</integer></dict>
        \\    <dict><key>Day</key><integer>15</integer><key>Month</key><integer>6</integer></dict>
        \\  </array>
        \\
    , &diag);
    try testing.expectEqual(@as(usize, 2), many.schedule.calendar.len);
    try testing.expectEqual(@as(?u8, 1), many.schedule.calendar[0].weekday);
    try testing.expectEqual(@as(?u8, 15), many.schedule.calendar[1].day);
    try testing.expectEqual(@as(?u8, 6), many.schedule.calendar[1].month);

    // A field outside u8 cannot be a launchd calendar value.
    try testing.expectError(error.BadValue, liftFixture(arena.allocator(),
        \\  <key>StartCalendarInterval</key>
        \\  <dict><key>Hour</key><integer>300</integer></dict>
        \\
    , &diag));
    try testing.expectEqualStrings("StartCalendarInterval", diag.key);
}

test "lift refuses every launchd key outside the allowlist and names it" {
    // `Program` stays refused: malt only renders ProgramArguments.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_][]const u8{ "MachServices", "UserName", "LaunchOnlyOnce", "Program", "ProcessType", "Umask" }) |key| {
        var diag: Diag = .{};
        const extra = try std.fmt.allocPrint(aa, "  <key>{s}</key>\n  <string>x</string>\n", .{key});
        try testing.expectError(error.UnknownKey, liftFixture(aa, extra, &diag));
        try testing.expectEqualStrings(key, diag.key);
    }
}

test "lift refuses a socket that is not the SecureSocketWithKey shape" {
    // Any other socket key (SockPathName, SockServiceName, ...) names a
    // path or port malt would have to confine; only the launchd-owned
    // secure socket is carried.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_][]const u8{
        "  <key>Sockets</key>\n  <dict><key>l</key><dict><key>SockPathName</key><string>/tmp/s</string></dict></dict>\n",
        "  <key>Sockets</key>\n  <dict><key>l</key><dict><key>SecureSocketWithKey</key><string>K</string><key>SockType</key><string>stream</string></dict></dict>\n",
        "  <key>Sockets</key>\n  <dict><key>l</key><string>K</string></dict>\n",
        "  <key>Sockets</key>\n  <dict/>\n",
        "  <key>Sockets</key>\n  <string>K</string>\n",
    }) |extra| {
        var diag: Diag = .{};
        try testing.expectError(error.BadValue, liftFixture(aa, extra, &diag));
        try testing.expectEqualStrings("Sockets", diag.key);
    }
}

test "lift refuses a value whose shape the key does not take" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const cases = [_]struct { extra: []const u8, key: []const u8 }{
        .{ .extra = "  <key>WorkingDirectory</key>\n  <true/>\n", .key = "WorkingDirectory" },
        .{ .extra = "  <key>EnvironmentVariables</key>\n  <dict><key>A</key><integer>1</integer></dict>\n", .key = "EnvironmentVariables" },
        .{ .extra = "  <key>StartInterval</key>\n  <integer>-5</integer>\n", .key = "StartInterval" },
        .{ .extra = "  <key>StartInterval</key>\n  <integer>4294967296</integer>\n", .key = "StartInterval" },
        .{ .extra = "  <key>ExitTimeOut</key>\n  <string>45</string>\n", .key = "ExitTimeOut" },
        .{ .extra = "  <key>RunAtLoad</key>\n  <string>yes</string>\n", .key = "RunAtLoad" },
        .{ .extra = "  <key>StartCalendarInterval</key>\n  <integer>4</integer>\n", .key = "StartCalendarInterval" },
        .{ .extra = "  <key>StartCalendarInterval</key>\n  <dict><key>Second</key><integer>4</integer></dict>\n", .key = "StartCalendarInterval" },
    };
    for (cases) |case| {
        var diag: Diag = .{};
        try testing.expectError(error.BadValue, liftFixture(aa, case.extra, &diag));
        try testing.expectEqualStrings(case.key, diag.key);
    }
}

test "lift requires ProgramArguments to be a non-empty array of strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};
    const no_args =
        \\<plist version="1.0"><dict><key>Label</key><string>org.example.svcd</string></dict></plist>
    ;
    try testing.expectError(error.NoProgramArguments, lift(aa, no_args, "svcd", "org.example.svcd", "/opt/malt", &diag));
    const empty =
        \\<plist version="1.0"><dict><key>Label</key><string>org.example.svcd</string><key>ProgramArguments</key><array/></dict></plist>
    ;
    try testing.expectError(error.NoProgramArguments, lift(aa, empty, "svcd", "org.example.svcd", "/opt/malt", &diag));
    const mixed =
        \\<plist version="1.0"><dict><key>Label</key><string>org.example.svcd</string><key>ProgramArguments</key><array><string>/x</string><integer>1</integer></array></dict></plist>
    ;
    try testing.expectError(error.BadValue, lift(aa, mixed, "svcd", "org.example.svcd", "/opt/malt", &diag));
    try testing.expectEqualStrings("ProgramArguments", diag.key);
}

test "lift refuses a Label that is absent or differs from the declared name" {
    // The formula's `name macos:` is the only datum naming the file; a
    // plist whose Label disagrees is not the one the formula declared.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};
    const other =
        \\<plist version="1.0"><dict><key>Label</key><string>org.example.other</string><key>ProgramArguments</key><array><string>/x</string></array></dict></plist>
    ;
    try testing.expectError(error.LabelMismatch, lift(aa, other, "svcd", "org.example.svcd", "/opt/malt", &diag));
    const none =
        \\<plist version="1.0"><dict><key>ProgramArguments</key><array><string>/x</string></array></dict></plist>
    ;
    try testing.expectError(error.LabelMismatch, lift(aa, none, "svcd", "org.example.svcd", "/opt/malt", &diag));
}

test "lift refuses a repeated key at any depth" {
    // A duplicate inside EnvironmentVariables or Sockets would render two
    // identical <key>s into the plist malt hands launchd.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try testing.expectError(error.DuplicateKey, liftFixture(arena.allocator(),
        \\  <key>Label</key>
        \\  <string>org.example.svcd</string>
        \\
    , &diag));
    try testing.expectEqualStrings("Label", diag.key);
    try testing.expectError(error.DuplicateKey, liftFixture(arena.allocator(),
        \\  <key>EnvironmentVariables</key>
        \\  <dict><key>FOO</key><string>a</string><key>FOO</key><string>b</string></dict>
        \\
    , &diag));
    try testing.expectEqualStrings("FOO", diag.key);
    try testing.expectError(error.DuplicateKey, liftFixture(arena.allocator(),
        \\  <key>Sockets</key>
        \\  <dict><key>l</key><dict><key>SecureSocketWithKey</key><string>A</string></dict><key>l</key><dict><key>SecureSocketWithKey</key><string>B</string></dict></dict>
        \\
    , &diag));
    try testing.expectEqualStrings("l", diag.key);
}

test "lift keeps every socket in order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    const spec = try liftFixture(arena.allocator(),
        \\  <key>Sockets</key>
        \\  <dict>
        \\    <key>first</key><dict><key>SecureSocketWithKey</key><string>ONE</string></dict>
        \\    <key>second</key><dict><key>SecureSocketWithKey</key><string>TWO</string></dict>
        \\  </dict>
        \\
    , &diag);
    try testing.expectEqual(@as(usize, 2), spec.sockets.len);
    try testing.expectEqualStrings("first", spec.sockets[0].name);
    try testing.expectEqualStrings("TWO", spec.sockets[1].env_key);
}

test "lift reads CRLF line endings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};
    const lf = try std.mem.concat(aa, u8, &.{ head, tail });
    const crlf = try std.mem.replaceOwned(u8, aa, lf, "\n", "\r\n");
    const spec = try lift(aa, crlf, "svcd", "org.example.svcd", "/opt/malt", &diag);
    try testing.expectEqualStrings("--nofork", spec.program_args[1]);
}

test "lift accepts a UTF-8 byte order mark" {
    // CFPropertyList and launchd both read a BOM-prefixed plist.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};
    const bytes = try std.mem.concat(aa, u8, &.{ "\xEF\xBB\xBF", head, tail });
    const spec = try lift(aa, bytes, "svcd", "org.example.svcd", "/opt/malt", &diag);
    try testing.expectEqualStrings("--nofork", spec.program_args[1]);
}

test "lift round-trips every character render escapes" {
    // The decoder mirrors `plist.render`'s writer; a drift on either side
    // would corrupt a re-lifted value.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const raw = "a&b<c>d\"e'f";
    var aw: std.Io.Writer.Allocating = .init(aa);
    try plist.render(.{
        .label = "org.example.svcd",
        .program_args = &.{"/opt/malt/opt/svcd/bin/svcd"},
        .env = &.{.{ .key = "K", .value = raw }},
        .stdout_path = "/x",
        .stderr_path = "/x",
    }, &aw.writer);
    var diag: Diag = .{};
    const spec = try lift(aa, aw.written(), "svcd", "org.example.svcd", "/opt/malt", &diag);
    try testing.expectEqualStrings(raw, spec.env[0].value);
}

test "lift refuses entities beyond the five the writer emits" {
    // Numeric and named entities past that set would need a real XML
    // decoder; refusing keeps the scanner a mirror of `render`.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var diag: Diag = .{};
    try testing.expectError(error.Malformed, liftFixture(arena.allocator(),
        \\  <key>WorkingDirectory</key>
        \\  <string>/opt/malt/var/a&#47;b</string>
        \\
    , &diag));
    try testing.expectError(error.Malformed, liftFixture(arena.allocator(),
        \\  <key>WorkingDirectory</key>
        \\  <string>/opt/malt/var/a&nbsp;b</string>
        \\
    , &diag));
}

test "lift refuses input over the size and nesting caps" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};

    const pad = try aa.alloc(u8, max_bytes);
    @memset(pad, ' ');
    const big = try std.mem.concat(aa, u8, &.{ head, pad, tail });
    try testing.expectError(error.Malformed, lift(aa, big, "svcd", "org.example.svcd", "/opt/malt", &diag));

    // KeepAlive takes any dict, so the depth cap is the only thing that
    // stops a nest here.
    try testing.expectError(error.Malformed, liftFixture(aa,
        \\  <key>KeepAlive</key>
        \\  <dict><key>a</key><dict><key>b</key><dict><key>c</key><dict><key>d</key><true/></dict></dict></dict></dict>
        \\
    , &diag));
    // Three levels under the root dict is exactly the Sockets shape.
    _ = try liftFixture(aa,
        \\  <key>KeepAlive</key>
        \\  <dict><key>a</key><dict><key>b</key><dict><key>c</key><true/></dict></dict></dict>
        \\
    , &diag);
}

test "lift refuses anything that is not one plist dict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var diag: Diag = .{};
    for ([_][]const u8{
        "",
        "not xml at all",
        "<plist version=\"1.0\"><array/></plist>",
        "<plist version=\"1.0\"><dict><key>Label</key></dict></plist>",
        "<plist version=\"1.0\"><dict><string>x</string></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Label</key><string>x</string></dict></plist>trailing",
        "<plist version=\"1.0\"><dict><key>Label</key><string>x</string>",
        "<plist version=\"1.0\"><dict><key>Label</key><string>x</string></dict></plist><plist/>",
        "<plist version=\"1.0\"><dict><key>Label</key><string><![CDATA[x]]></string></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Label</key><string>x</key></dict></plist>",
        "<plist version=\"1.0\"><dict><key></key><string>x</string></dict></plist>",
        "<plist version=\"1.0\"><dict><key>Label</key><string ID=\"1\">x</string></dict></plist>",
        "<plist version=\"1.0\"><dict><key>" ++ "K" ** (max_key_len + 1) ++ "</key><string>x</string></dict></plist>",
    }) |bytes| {
        try testing.expectError(error.Malformed, lift(aa, bytes, "svcd", "x", "/opt/malt", &diag));
    }
}
