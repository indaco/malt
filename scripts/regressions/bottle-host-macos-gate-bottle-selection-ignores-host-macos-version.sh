#!/usr/bin/env bash
# Regression: an older macOS host was poured a bottle built for a newer one,
# so install exited 0 with binaries that would not launch.
#
# Fixed host versions keep the verdict the same on every machine: host 14
# must refuse a {tahoe, sequoia} map, 15 must take sequoia, 27 golden_gate.
# The src/ symlink keeps formula.zig's relative imports inside the module root.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ln -s "$ROOT/src" "$TMP/src"

cat >"$TMP/gate.zig" <<'ZIG'
const std = @import("std");
const builtin = @import("builtin");
const f = @import("src/core/formula.zig");

fn tag(comptime codename: []const u8) []const u8 {
    return if (builtin.cpu.arch == .aarch64) "arm64_" ++ codename else codename;
}

fn entry(comptime codename: []const u8, comptime sha_char: []const u8) []const u8 {
    return "\"" ++ tag(codename) ++ "\":{\"cellar\":\":any\",\"url\":\"u\",\"sha256\":\"" ++ sha_char ** 64 ++ "\"}";
}

fn fixture(comptime files: []const u8) []const u8 {
    return "{\"name\":\"gate\",\"versions\":{\"stable\":\"1.0\"},\"bottle\":{\"stable\":{\"files\":{" ++ files ++ "}}}}";
}

const newer_only = fixture(entry("tahoe", "a") ++ "," ++ entry("sequoia", "b"));
const with_golden_gate = fixture(entry("golden_gate", "c") ++ "," ++ entry("tahoe", "a"));

test "bottle gate: host 14 refuses a map of newer bottles" {
    var formula = try f.parseFormula(std.testing.allocator, newer_only);
    defer formula.deinit();
    try std.testing.expectError(error.NoBottleAvailable, f.resolveBottleFor(&formula, 14));
}

test "bottle gate: host 15 takes sequoia, not tahoe" {
    var formula = try f.parseFormula(std.testing.allocator, newer_only);
    defer formula.deinit();
    try std.testing.expectEqualStrings("b" ** 64, (try f.resolveBottleFor(&formula, 15)).sha256);
}

test "bottle gate: host 27 takes golden_gate" {
    var formula = try f.parseFormula(std.testing.allocator, with_golden_gate);
    defer formula.deinit();
    try std.testing.expectEqualStrings("c" ** 64, (try f.resolveBottleFor(&formula, 27)).sha256);
}
ZIG

if ! zig test "$TMP/gate.zig" --test-filter "bottle gate" >"$TMP/log" 2>&1; then
  echo "FAIL: bottle selection ignores the host macOS major" >&2
  tail -20 "$TMP/log" >&2
  exit 1
fi
echo "ok: bottle selection honours the host macOS major"
