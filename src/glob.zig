//! Shell-style glob matching for formula- and tap-supplied patterns:
//! `*`, `?`, and `{a,b}` alternation with nesting.
//!
//! Pure and allocation-free. The pattern is untrusted input, so the two costs
//! it can drive are bounded here rather than at each call site: expansions are
//! capped, and an expansion that outgrows the buffer is dropped.

const std = @import("std");

/// Ceiling on the combinations one pattern may describe. Checked against the
/// pattern itself rather than per candidate name: the cost belongs to the
/// pattern, and a directory walk pays it again for every entry, so a per-name
/// budget bounds each call while leaving the walk unbounded.
///
/// Real globs describe a handful of combinations, so this clears them by orders
/// of magnitude while keeping even a pathological directory to seconds.
pub const max_combinations: u32 = 1024;

/// Longest expanded pattern considered. Bounds recursion depth as a side
/// effect: each level consumes at least one `{}` pair.
const max_pattern_len = 1024;

pub fn match(pattern: []const u8, name: []const u8) bool {
    if (combinations(pattern) > max_combinations) return false;
    // `combinations` counts leaves; the walk also visits the interior nodes
    // leading to them, so the running bound needs room above the ceiling.
    var budget: u32 = max_combinations * 4;
    return matchBudgeted(pattern, name, &budget);
}

/// Combinations `pattern` describes, saturating one past the ceiling. Groups
/// multiply and the alternatives inside a group add, mirroring the shape the
/// matcher would otherwise walk per name.
pub fn combinations(pattern: []const u8) u32 {
    // An over-long pattern is refused whole - the matcher drops each of its
    // expansions anyway - which also keeps this walk shallow.
    if (pattern.len > max_pattern_len) return max_combinations + 1;

    var total: u32 = 1;
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, pattern, from, '{')) |open| {
        const close = findMatchingBrace(pattern, open) orelse break;
        var sum: u32 = 0;
        var alternatives: AlternativeIterator = .{ .rest = pattern[open + 1 .. close] };
        while (alternatives.next()) |alt| sum +|= combinations(alt);
        total = std.math.mul(u32, total, sum) catch return max_combinations + 1;
        if (total > max_combinations) return max_combinations + 1;
        from = close + 1;
    }
    return total;
}

/// Exposed so the bound itself can be exercised without building a pattern
/// large enough to reach it.
pub fn matchBudgeted(pattern: []const u8, name: []const u8, budget: *u32) bool {
    // Out of budget degrades to "no match": callers match filenames and have
    // no error channel to report a give-up on.
    if (budget.* == 0) return false;
    budget.* -= 1;

    const open = std.mem.findScalar(u8, pattern, '{') orelse return wildcardMatch(pattern, name);
    const close = findMatchingBrace(pattern, open) orelse return wildcardMatch(pattern, name);

    const prefix = pattern[0..open];
    const suffix = pattern[close + 1 ..];
    var alternatives: AlternativeIterator = .{ .rest = pattern[open + 1 .. close] };
    while (alternatives.next()) |alt| {
        var buf: [max_pattern_len]u8 = undefined;
        const len = prefix.len + alt.len + suffix.len;
        if (len > buf.len) continue;
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..][0..alt.len], alt);
        @memcpy(buf[prefix.len + alt.len ..][0..suffix.len], suffix);
        if (matchBudgeted(buf[0..len], name, budget)) return true;
    }
    return false;
}

/// Split alternatives on the commas that belong to *this* group. Splitting on
/// every comma tears `{a{b,c},d}` into `a{b`, `c}` and `d`, which matches
/// neither the intended alternatives nor anything else useful.
const AlternativeIterator = struct {
    rest: ?[]const u8,

    fn next(self: *AlternativeIterator) ?[]const u8 {
        const rest = self.rest orelse return null;
        var depth: usize = 0;
        for (rest, 0..) |c, i| switch (c) {
            '{' => depth += 1,
            '}' => depth -|= 1,
            ',' => if (depth == 0) {
                self.rest = rest[i + 1 ..];
                return rest[0..i];
            },
            else => {},
        };
        self.rest = null;
        return rest;
    }
};

/// Closing brace for the group opening at `start`, skipping nested groups.
/// Taking the first `}` instead would cut a nested group in half.
fn findMatchingBrace(pattern: []const u8, start: usize) ?usize {
    std.debug.assert(pattern[start] == '{');
    var depth: usize = 0;
    for (pattern[start..], start..) |c, i| switch (c) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return null;
}

/// `*` and `?` matching, iterative with a single backtrack point. The natural
/// recursive form re-explores every suffix: on `*a*a*a...` it runs to billions
/// of calls where this one takes hundreds.
fn wildcardMatch(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star: ?usize = null;
    var star_ni: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == name[ni] or pattern[pi] == '?')) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star = pi;
            star_ni = ni;
            pi += 1;
        } else if (star) |s| {
            pi = s + 1;
            star_ni += 1;
            ni = star_ni;
        } else return false;
    }
    while (pi < pattern.len and pattern[pi] == '*') : (pi += 1) {}
    return pi == pattern.len;
}

test "matches literals and wildcards" {
    try std.testing.expect(match("literal", "literal"));
    try std.testing.expect(!match("literal", "literals"));
    try std.testing.expect(match("*.h", "stdio.h"));
    try std.testing.expect(!match("*.h", "stdio.c"));
    try std.testing.expect(match("lib?.a", "libz.a"));
    try std.testing.expect(!match("lib?.a", "libzz.a"));
    try std.testing.expect(match("*", "anything"));
    // A leading wildcard must not swallow the anchor that follows it.
    try std.testing.expect(match("*.1", "npm.1"));
    try std.testing.expect(!match("*.1", "npm.5"));
}

test "matches a flat alternation" {
    try std.testing.expect(match("*.{h,hpp,hxx}", "vec.hpp"));
    try std.testing.expect(!match("*.{h,hpp,hxx}", "vec.cpp"));
    try std.testing.expect(match("{bin,sbin}/*", "bin/tool"));
    try std.testing.expect(match("a{b,c}d{e,f}", "acdf"));
    try std.testing.expect(!match("a{b,c}d{e,f}", "axdf"));
    try std.testing.expect(match("{npm,npx,package-}*", "npm.1"));
    try std.testing.expect(match("{npm,npx,package-}*", "package-json.5"));
    try std.testing.expect(!match("{npm,npx,package-}*", "unrelated.1"));
}

test "matches a nested alternation" {
    // Splitting on every comma would offer `a{b`, `c}` and `d` here, so every
    // branch but the last would be unmatchable.
    try std.testing.expect(match("{a{b,c},d}", "ab"));
    try std.testing.expect(match("{a{b,c},d}", "ac"));
    try std.testing.expect(match("{a{b,c},d}", "d"));
    try std.testing.expect(!match("{a{b,c},d}", "a"));
    try std.testing.expect(!match("{a{b,c},d}", "ad"));
    try std.testing.expect(match("lib{foo{32,64},bar}.a", "libfoo64.a"));
    try std.testing.expect(match("lib{foo{32,64},bar}.a", "libbar.a"));
    try std.testing.expect(!match("lib{foo{32,64},bar}.a", "libfoo.a"));
}

test "matches empty patterns and empty names" {
    try std.testing.expect(match("", ""));
    try std.testing.expect(!match("", "x"));
    try std.testing.expect(match("*", ""));
    try std.testing.expect(!match("?", ""));
    try std.testing.expect(match("{a,}", "a"));
    try std.testing.expect(match("{a,}", ""));
}

test "a wide pattern still matches its last combination" {
    // The ceiling is a give-up, not an error, so it has to clear real patterns
    // by a wide margin. This shape is already far past anything a formula ships
    // and the combination explored last still matches.
    var pattern: [3 * 21]u8 = undefined;
    for (0..3) |i| @memcpy(pattern[i * 21 ..][0..21], "{a,b,c,d,e,f,g,h,i,j}");

    try std.testing.expect(match(&pattern, "aaa"));
    try std.testing.expect(match(&pattern, "jjj"));
    try std.testing.expect(!match(&pattern, "jjk"));
}

test "a pattern past the ceiling is refused whole, not part-way" {
    // Refusing per pattern rather than per name keeps a directory walk from
    // paying the cost once per entry, and makes the give-up all-or-nothing
    // instead of a partial result that depends on iteration order.
    var pattern: [4 * 21]u8 = undefined;
    for (0..4) |i| @memcpy(pattern[i * 21 ..][0..21], "{a,b,c,d,e,f,g,h,i,j}");

    try std.testing.expect(combinations(&pattern) > max_combinations);
    try std.testing.expect(!match(&pattern, "aaaa"));
    try std.testing.expect(!match(&pattern, "jjjj"));
}

test "combinations counts groups as products and alternatives as sums" {
    try std.testing.expectEqual(@as(u32, 1), combinations("*.h"));
    try std.testing.expectEqual(@as(u32, 3), combinations("*.{h,hpp,hxx}"));
    try std.testing.expectEqual(@as(u32, 4), combinations("{a,b}{c,d}"));
    try std.testing.expectEqual(@as(u32, 3), combinations("{a{b,c},d}"));
    try std.testing.expect(combinations("a{b") == 1);
}

test "an unterminated group is matched literally" {
    try std.testing.expect(match("a{b", "a{b"));
    try std.testing.expect(!match("a{b", "ab"));
}

test "repeated wildcards cost steps, not combinations" {
    // A recursive star matcher re-explores every suffix and needs billions of
    // calls for this pattern; the single backtrack point keeps it to hundreds.
    var pattern: [12 * 2 + 1]u8 = undefined;
    for (0..12) |i| @memcpy(pattern[i * 2 ..][0..2], "*a");
    pattern[24] = 'b';
    const name = "a" ** 60;

    try std.testing.expect(!match(&pattern, name));
    try std.testing.expect(match("*a*a*b", "aaaaaaab"));
}

test "alternation cannot be driven into an unbounded expansion" {
    // Each group doubles the work, so a pattern this short already costs 2^31
    // expansions unbounded - a hang, not a crash, since depth stays shallow.
    var pattern: [30 * 5]u8 = undefined;
    for (0..30) |i| @memcpy(pattern[i * 5 ..][0..5], "{a,b}");
    try std.testing.expect(!match(&pattern, "no-such-name"));
}

test "an exhausted budget refuses instead of exploring" {
    var spent: u32 = 3;
    try std.testing.expect(!matchBudgeted("{a,b}{a,b}{a,b}{a,b}", "abab", &spent));

    var ample: u32 = max_combinations;
    try std.testing.expect(matchBudgeted("{a,b}{a,b}{a,b}{a,b}", "abab", &ample));
}

test "a deeply nested pattern is walked, not just dropped" {
    // The sibling test below stops at the first expansion because it does not
    // fit; this one fits at every level, so it exercises the recursive path all
    // the way down rather than asserting depth safety by comment alone.
    var pattern: [800]u8 = undefined;
    @memset(pattern[0..400], '{');
    @memset(pattern[400..], '}');

    try std.testing.expectEqual(@as(u32, 1), combinations(&pattern));
    try std.testing.expect(match(&pattern, ""));
    try std.testing.expect(!match(&pattern, "x"));
}

test "an expansion longer than the buffer is dropped, not truncated" {
    // Deep nesting expands to something too long to hold; the group is skipped
    // rather than silently matched against a cut-off pattern.
    var pattern: [1200]u8 = undefined;
    @memset(pattern[0..600], '{');
    @memset(pattern[600..], '}');
    try std.testing.expect(!match(&pattern, "anything"));
}
