//! malt — shellenv command tests

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const shellenv = malt.shellenv;
const ca_bundle = malt.ca_bundle;
const test_io = @import("test_io");

const v3_cert = "/opt/malt/etc/openssl@3/cert.pem";

test "parseShell recognises the three supported shells" {
    try testing.expectEqual(shellenv.Shell.bash, shellenv.parseShell("bash").?);
    try testing.expectEqual(shellenv.Shell.zsh, shellenv.parseShell("zsh").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.parseShell("fish").?);
}

test "parseShell returns null for unknown shells" {
    try testing.expect(shellenv.parseShell("tcsh") == null);
    try testing.expect(shellenv.parseShell("ksh") == null);
    try testing.expect(shellenv.parseShell("") == null);
    try testing.expect(shellenv.parseShell("Bash") == null);
}

test "detectFromShellPath maps common $SHELL values to a shell" {
    try testing.expectEqual(shellenv.Shell.bash, shellenv.detectFromShellPath("/bin/bash").?);
    try testing.expectEqual(shellenv.Shell.zsh, shellenv.detectFromShellPath("/bin/zsh").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.detectFromShellPath("/usr/local/bin/fish").?);
    try testing.expectEqual(shellenv.Shell.fish, shellenv.detectFromShellPath("/opt/homebrew/bin/fish").?);
}

test "detectFromShellPath returns null for missing or unknown shells" {
    try testing.expect(shellenv.detectFromShellPath(null) == null);
    try testing.expect(shellenv.detectFromShellPath("") == null);
    try testing.expect(shellenv.detectFromShellPath("/bin/tcsh") == null);
    try testing.expect(shellenv.detectFromShellPath("/usr/bin/sh") == null);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected output to contain '{s}', got:\n{s}\n", .{ needle, haystack });
        return error.MissingSubstring;
    }
}

test "render bash exports brew-compatible env so third-party scripts keep working" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt", null);
    defer testing.allocator.free(out);

    try expectContains(out, "export HOMEBREW_PREFIX=\"/opt/malt\"");
    try expectContains(out, "export HOMEBREW_CELLAR=\"/opt/malt/Cellar\"");
    try expectContains(out, "export HOMEBREW_REPOSITORY=\"/opt/malt\"");
    try expectContains(out, "export PATH=");
    try expectContains(out, "/opt/malt/bin");
    try expectContains(out, "/opt/malt/sbin");
    try expectContains(out, "export MANPATH=");
    try expectContains(out, "/opt/malt/share/man");
    try expectContains(out, "export INFOPATH=");
    try expectContains(out, "/opt/malt/share/info");
}

test "render bash and zsh emit byte-identical output (single shared arm)" {
    const bash = try shellenv.render(testing.allocator, .bash, "/opt/malt", null);
    defer testing.allocator.free(bash);
    const zsh = try shellenv.render(testing.allocator, .zsh, "/opt/malt", null);
    defer testing.allocator.free(zsh);
    try testing.expectEqualStrings(bash, zsh);
}

test "render bash prepends malt's bin before \\$PATH so its binaries win" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt", null);
    defer testing.allocator.free(out);
    // Binary order matters: an `append` would let the existing PATH shadow
    // malt-installed tools.
    try expectContains(out, "PATH=\"/opt/malt/bin:/opt/malt/sbin");
    // POSIX-safe expansion: empty PATH must stay empty, not become ":".
    try expectContains(out, "${PATH+:$PATH}");
}

test "render bash terminates every line with `;\\n` so eval sees full statements" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt", null);
    defer testing.allocator.free(out);
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.endsWith(u8, out, ";\n"));
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try testing.expect(std.mem.endsWith(u8, line, ";"));
    }
}

test "render fish uses set -gx and avoids POSIX export syntax" {
    const out = try shellenv.render(testing.allocator, .fish, "/opt/malt", null);
    defer testing.allocator.free(out);

    try expectContains(out, "set -gx HOMEBREW_PREFIX \"/opt/malt\"");
    try expectContains(out, "set -gx HOMEBREW_CELLAR \"/opt/malt/Cellar\"");
    try expectContains(out, "set -gx HOMEBREW_REPOSITORY \"/opt/malt\"");
    try expectContains(out, "set -gx PATH \"/opt/malt/bin\" \"/opt/malt/sbin\" $PATH");
    try expectContains(out, "set -gx MANPATH \"/opt/malt/share/man\" $MANPATH");
    try expectContains(out, "set -gx INFOPATH \"/opt/malt/share/info\" $INFOPATH");
    // POSIX `export` and bash brace-expansion are syntax errors in fish.
    try testing.expect(std.mem.indexOf(u8, out, "export ") == null);
    try testing.expect(std.mem.indexOf(u8, out, "${") == null);
}

test "render emits SSL_CERT_FILE only when the CA bundle is present" {
    // Present: a single export line pointing at the canonical bundle.
    const with = try shellenv.render(testing.allocator, .bash, "/opt/malt", v3_cert);
    defer testing.allocator.free(with);
    try expectContains(with, "export SSL_CERT_FILE=\"/opt/malt/etc/openssl@3/cert.pem\";");

    // An openssl@4 prefix exports its own bundle path, not the openssl@3 one.
    const v4 = try shellenv.render(testing.allocator, .bash, "/opt/malt", "/opt/malt/etc/openssl@4/cert.pem");
    defer testing.allocator.free(v4);
    try expectContains(v4, "export SSL_CERT_FILE=\"/opt/malt/etc/openssl@4/cert.pem\";");

    // Absent: nothing — the var must never name a missing file.
    const without = try shellenv.render(testing.allocator, .bash, "/opt/malt", null);
    defer testing.allocator.free(without);
    try testing.expect(std.mem.indexOf(u8, without, "SSL_CERT_FILE") == null);
}

test "render bash SSL_CERT_FILE line is terminated and follows INFOPATH" {
    const out = try shellenv.render(testing.allocator, .bash, "/opt/malt", v3_cert);
    defer testing.allocator.free(out);
    // Must keep the `;\n` line-termination contract eval relies on.
    try testing.expect(std.mem.endsWith(u8, out, ";\n"));
    // Ordering: SSL_CERT_FILE comes after the brew-compatible block.
    const info = std.mem.indexOf(u8, out, "INFOPATH").?;
    const ssl = std.mem.indexOf(u8, out, "SSL_CERT_FILE").?;
    try testing.expect(ssl > info);
}

test "render fish uses set -gx for SSL_CERT_FILE when present" {
    const out = try shellenv.render(testing.allocator, .fish, "/opt/malt", v3_cert);
    defer testing.allocator.free(out);
    try expectContains(out, "set -gx SSL_CERT_FILE \"/opt/malt/etc/openssl@3/cert.pem\";");
    // No POSIX export / brace-expansion sneaks in via the new line.
    try testing.expect(std.mem.indexOf(u8, out, "export ") == null);
}

test "render bash and zsh stay byte-identical with SSL_CERT_FILE present" {
    const bash = try shellenv.render(testing.allocator, .bash, "/opt/malt", v3_cert);
    defer testing.allocator.free(bash);
    const zsh = try shellenv.render(testing.allocator, .zsh, "/opt/malt", v3_cert);
    defer testing.allocator.free(zsh);
    try testing.expectEqualStrings(bash, zsh);
}

test "render with SSL_CERT_FILE present survives a tiny budget without corruption" {
    // The new write path must also fail cleanly to OutOfMemory.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        struct {
            fn run(a: std.mem.Allocator) !void {
                const out = try shellenv.render(a, .bash, "/opt/malt", v3_cert);
                a.free(out);
            }
        }.run,
        .{},
    );
}

test "render honors a non-default prefix" {
    const out = try shellenv.render(testing.allocator, .bash, "/usr/local", null);
    defer testing.allocator.free(out);

    try expectContains(out, "export HOMEBREW_PREFIX=\"/usr/local\"");
    try expectContains(out, "/usr/local/bin");
    try testing.expect(std.mem.indexOf(u8, out, "/opt/malt") == null);
}

test "render surfaces allocator failure rather than swallowing it" {
    try testing.expectError(
        error.OutOfMemory,
        shellenv.render(testing.failing_allocator, .bash, "/opt/malt", null),
    );
}

test "render with a tiny budget eventually returns OutOfMemory, not corruption" {
    // Exercises every partial-write path through `Writer.Allocating`.
    try testing.checkAllAllocationFailures(
        testing.allocator,
        struct {
            fn run(a: std.mem.Allocator) !void {
                const out = try shellenv.render(a, .fish, "/opt/malt", null);
                a.free(out);
            }
        }.run,
        .{},
    );
}

// --- CA bundle lookup -------------------------------------------------
//
// Homebrew moves dependents from openssl@3 to openssl@4 over time, so a
// prefix can hold either major, or both. Each one reads its own
// `etc/<keg>/cert.pem`.

/// Scratch prefix with `etc/<keg>/cert.pem` for each keg in `kegs`.
fn certPrefix(tag: []const u8, kegs: []const []const u8) ![]const u8 {
    const prefix = try test_io.uniqueTempPath(testing.allocator, "shellenv_cert", tag);
    errdefer testing.allocator.free(prefix);
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    for (kegs) |keg| {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/{s}", .{ prefix, keg });
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        const cert = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
        defer testing.allocator.free(cert);
        (try test_io.createFileAbsolute(std.Options.debug_io, cert, .{})).close(std.Options.debug_io);
    }
    return prefix;
}

fn expectFound(prefix: []const u8, keg: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) orelse
        return error.CertNotFound;
    const want = try std.fmt.allocPrint(testing.allocator, "{s}/etc/{s}/cert.pem", .{ prefix, keg });
    defer testing.allocator.free(want);
    try testing.expectEqualStrings(want, got);
}

test "findCertFile finds the bundle of an openssl@4-only prefix" {
    const prefix = try certPrefix("v4", &.{"openssl@4"});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try expectFound(prefix, "openssl@4");
}

test "findCertFile finds the bundle of an openssl@3-only prefix" {
    const prefix = try certPrefix("v3", &.{"openssl@3"});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try expectFound(prefix, "openssl@3");
}

test "findCertFile prefers openssl@4 when both majors are present" {
    const prefix = try certPrefix("both", &.{ "openssl@3", "openssl@4" });
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try expectFound(prefix, "openssl@4");
}

test "findCertFile returns null when no openssl keg has a bundle" {
    const prefix = try certPrefix("none", &.{});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile skips a dangling openssl@4 link and falls back to openssl@3" {
    // SSL_CERT_FILE must never name a missing file, so a link that does
    // not resolve does not count as a bundle.
    const prefix = try certPrefix("dangling", &.{"openssl@3"});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/openssl@4", .{prefix});
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
    defer testing.allocator.free(link);
    const gone = try std.fmt.allocPrint(testing.allocator, "{s}/gone.pem", .{prefix});
    defer testing.allocator.free(gone);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, gone, link, .{});
    try expectFound(prefix, "openssl@3");
}

/// `mkdir -p <prefix><sub>`.
fn mkdirIn(prefix: []const u8, sub: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, sub });
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
}

const LeftoverTarget = enum { etc_relative, opt_relative, etc_absolute };

/// `etc/<keg>/cert.pem` as a link into ca-certificates, the shape a removed
/// major leaves behind. ca-certificates is installed and holds the bundle in
/// both `etc` and `opt`.
fn linkedLeftoverTo(tag: []const u8, keg: []const u8, kind: LeftoverTarget) ![]const u8 {
    const prefix = try certPrefix(tag, &.{"ca-certificates"});
    errdefer testing.allocator.free(prefix);
    try mkdirIn(prefix, "/opt/ca-certificates");
    try touchIn(prefix, "/opt/ca-certificates/cert.pem");
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/{s}", .{ prefix, keg });
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
    defer testing.allocator.free(link);
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}/etc/ca-certificates/cert.pem", .{prefix});
    defer testing.allocator.free(abs);
    const target = switch (kind) {
        .etc_relative => "../ca-certificates/cert.pem",
        .opt_relative => "../../opt/ca-certificates/cert.pem",
        .etc_absolute => abs,
    };
    try test_io.cwd().symLink(std.Options.debug_io, target, link, .{});
    return prefix;
}

fn linkedLeftover(tag: []const u8, keg: []const u8) ![]const u8 {
    return linkedLeftoverTo(tag, keg, .etc_relative);
}

fn touchIn(prefix: []const u8, sub: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, sub });
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
}

test "findCertFile prefers the installed major bundle over a stray one" {
    // The installed major's bundle wins over a stray one.
    const prefix = try certPrefix("stray_v4", &.{ "openssl@3", "openssl@4" });
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try expectFound(prefix, "openssl@3");
}

test "findCertFile falls back to a leftover bundle when the installed major has none" {
    // SSL_CERT_FILE is read by every major, so a resolving bundle beats none.
    const prefix = try linkedLeftover("leftover_v3", "openssl@3");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try expectFound(prefix, "openssl@3");
}

test "findCertFile falls back to a leftover openssl@4 bundle for an installed openssl@3" {
    const prefix = try linkedLeftover("leftover_v4", "openssl@4");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try expectFound(prefix, "openssl@4");
}

test "findCertFile accepts a leftover link into opt/ca-certificates" {
    const prefix = try linkedLeftoverTo("leftover_opt", "openssl@3", .opt_relative);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try expectFound(prefix, "openssl@3");
}

test "findCertFile accepts an absolute leftover link" {
    // The linker writes absolute targets.
    const prefix = try linkedLeftoverTo("leftover_abs", "openssl@3", .etc_absolute);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try expectFound(prefix, "openssl@3");
}

test "findCertFile follows a leftover link when the prefix has a trailing slash" {
    const prefix = try linkedLeftover("leftover_slash", "openssl@3");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    const slashed = try std.fmt.allocPrint(testing.allocator, "{s}/", .{prefix});
    defer testing.allocator.free(slashed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, slashed) != null);
}

test "findCertFile ignores a leftover link once ca-certificates is uninstalled" {
    // The orphaned bundle is stale and doctor draws no SSL row for it.
    const prefix = try linkedLeftover("leftover_orphan", "openssl@3");
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    const opt = try std.fmt.allocPrint(testing.allocator, "{s}/opt/ca-certificates", .{prefix});
    defer testing.allocator.free(opt);
    try test_io.deleteTreeAbsolute(std.Options.debug_io, opt);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile ignores a plain-file leftover bundle" {
    // A copied file can hold stale roots that doctor never checks.
    const prefix = try certPrefix("leftover_plain", &.{"openssl@3"});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile ignores a leftover link that leaves ca-certificates" {
    const prefix = try certPrefix("leftover_outside", &.{});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try mkdirIn(prefix, "/etc/openssl@3");
    const other = try std.fmt.allocPrint(testing.allocator, "{s}/other.pem", .{prefix});
    defer testing.allocator.free(other);
    (try test_io.createFileAbsolute(std.Options.debug_io, other, .{})).close(std.Options.debug_io);
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/etc/openssl@3/cert.pem", .{prefix});
    defer testing.allocator.free(link);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, other, link, .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile exports nothing when the only leftover bundle dangles" {
    const prefix = try certPrefix("leftover_dangling", &.{});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try mkdirIn(prefix, "/etc/openssl@3");
    const link = try std.fmt.allocPrint(testing.allocator, "{s}/etc/openssl@3/cert.pem", .{prefix});
    defer testing.allocator.free(link);
    const gone = try std.fmt.allocPrint(testing.allocator, "{s}/gone.pem", .{prefix});
    defer testing.allocator.free(gone);
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, gone, link, .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile exports nothing when no installed or leftover bundle resolves" {
    const prefix = try certPrefix("no_bundle", &.{});
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(ca_bundle.findCertFile(std.Options.debug_io, &buf, prefix) == null);
}

test "findCertFile prefers openssl@4 among installed majors" {
    // The "both majors are present" test has no opt/ dirs, so it never
    // reaches the installed-major loop that a real prefix goes through.
    const prefix = try certPrefix("both_installed", &.{ "openssl@3", "openssl@4" });
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try mkdirIn(prefix, "/opt/openssl@4");
    try expectFound(prefix, "openssl@4");
}
