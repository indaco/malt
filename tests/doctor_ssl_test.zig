//! `mt doctor` SSL CA bundle check tests.
//!
//! The check is gated on its precondition: it verifies the OpenSSL trust
//! bundle (`<prefix>/etc/openssl@<N>/cert.pem`) only when `ca-certificates`
//! is installed (`<prefix>/opt/ca-certificates`). Each installed OpenSSL
//! major must reach the bundle through its own etc dir. A prefix that never
//! installed `ca-certificates` is a normal state, not a defect — the check
//! stays silent. An installed-but-unlinked bundle is a real
//! misconfiguration and warns.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");

const doctor = malt.doctor;
const output = malt.output;

fn uniquePrefix(suffix: []const u8) ![]const u8 {
    return test_io.uniqueTempPath(testing.allocator, "doctor_ssl", suffix);
}

/// Seed a scratch prefix. `with_ca` links `opt/ca-certificates` (the
/// "installed" signal); `with_cert` lands `etc/openssl@3/cert.pem`.
fn makePrefix(suffix: []const u8, with_ca: bool, with_cert: bool) ![]const u8 {
    const prefix = try uniquePrefix(suffix);
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
    if (with_ca) {
        const opt = try std.fmt.allocPrint(testing.allocator, "{s}/opt/ca-certificates", .{prefix});
        defer testing.allocator.free(opt);
        try test_io.cwd().createDirPath(std.Options.debug_io, opt);
    }
    if (with_cert) {
        const dir = try std.fmt.allocPrint(testing.allocator, "{s}/etc/openssl@3", .{prefix});
        defer testing.allocator.free(dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        const cert = try std.fmt.allocPrint(testing.allocator, "{s}/cert.pem", .{dir});
        defer testing.allocator.free(cert);
        (try test_io.createFileAbsolute(std.Options.debug_io, cert, .{})).close(std.Options.debug_io);
    }
    return prefix;
}

fn ctxFor(prefix: []const u8) doctor.CheckCtx {
    return .{
        .allocator = testing.allocator,
        .prefix = prefix,
        .io = std.Options.debug_io,
        .environ = .empty,
        .mirrors = .{},
        .offline = false,
    };
}

fn sslCheckResult(ctx: doctor.CheckCtx) doctor.CheckResult {
    for (doctor.checks) |c| {
        if (std.mem.eql(u8, c.name, "SSL CA bundle")) return c.run(ctx, c.name);
    }
    @panic("SSL CA bundle check not registered");
}

/// Run the SSL check with stderr captured so a test can assert on the row
/// text (or its absence). Returns the check result; `buf` holds the
/// rendered row bytes.
fn sslRun(ctx: doctor.CheckCtx, buf: *std.ArrayList(u8)) doctor.CheckResult {
    const prior = output.isQuiet();
    output.setQuiet(false);
    defer output.setQuiet(prior);
    output.beginStderrCapture(testing.allocator, buf);
    defer output.endStderrCapture();
    return sslCheckResult(ctx);
}

test "checks table includes the SSL CA bundle check" {
    var found = false;
    for (doctor.checks) |c| {
        if (std.mem.eql(u8, c.name, "SSL CA bundle")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ca-certificates not installed: the check stays silent (no row, no warn)" {
    // The precondition is absent, so a missing cert.pem is expected, not a
    // defect — the check must emit nothing on either stream.
    const prefix = try makePrefix("no_ca", false, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const result = sslRun(ctxFor(prefix), &buf);

    try testing.expectEqual(doctor.CheckResult.ok, result);
    try testing.expectEqualStrings("", buf.items);
}

test "ca-certificates installed + cert.pem present: a clean ok row" {
    const prefix = try makePrefix("linked", true, true);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const result = sslRun(ctxFor(prefix), &buf);

    try testing.expectEqual(doctor.CheckResult.ok, result);
    try testing.expect(std.mem.indexOf(u8, buf.items, "SSL CA bundle") != null);
    // The clean row carries no remediation detail.
    try testing.expect(std.mem.indexOf(u8, buf.items, "isn't linked") == null);
}

test "ca-certificates installed + cert.pem missing: warns about the unlinked bundle" {
    // The keg is on disk but its bundle isn't linked — a genuine
    // misconfiguration that must surface (warn), not a silent ok.
    const prefix = try makePrefix("unlinked", true, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const result = sslRun(ctxFor(prefix), &buf);

    try testing.expectEqual(doctor.CheckResult.warn_status, result);
    try testing.expect(std.mem.indexOf(u8, buf.items, "isn't linked") != null);
}

test "a max-length prefix still verifies the bundle instead of reporting ok" {
    // Every bundle path must fit any prefix the env check admits; one that
    // does not would skip the check and read as a clean row.
    var p = try test_io.LongPrefix.init(testing.allocator, "doctor_ssl", malt.prefix_path.max_prefix_len);
    defer p.deinit(testing.allocator);
    const opt = try std.fmt.allocPrint(testing.allocator, "{s}/opt/ca-certificates", .{p.path});
    defer testing.allocator.free(opt);
    try test_io.cwd().createDirPath(std.Options.debug_io, opt);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.warn_status, sslRun(ctxFor(p.path), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "isn't linked") != null);
}

// Homebrew moves dependents from openssl@3 to openssl@4, so the check
// accepts the bundle of either major and names the keg that is installed.

fn mkdirIn(prefix: []const u8, sub: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, sub });
    defer testing.allocator.free(dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);
}

fn touchIn(prefix: []const u8, sub: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ prefix, sub });
    defer testing.allocator.free(path);
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);
}

test "an openssl@4-only prefix with its bundle linked is a clean ok row" {
    const prefix = try makePrefix("v4_linked", true, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");
    try mkdirIn(prefix, "/etc/openssl@4");
    try touchIn(prefix, "/etc/openssl@4/cert.pem");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.ok, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "isn't linked") == null);
}

test "openssl@4 installed with no bundle: the warning names openssl@4" {
    // Naming openssl@3 here would send the user to fix a keg that is not
    // installed.
    const prefix = try makePrefix("v4_unlinked", true, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@4");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.warn_status, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "openssl@4's cert.pem isn't linked") != null);
}

test "openssl@3 installed with no bundle: the warning names openssl@3" {
    const prefix = try makePrefix("v3_unlinked", true, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.warn_status, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "openssl@3's cert.pem isn't linked") != null);
}

test "both majors installed, only openssl@3 linked: warns about openssl@4" {
    // An upgraded prefix keeps its openssl@3 link while a new closure pulls
    // in openssl@4. Its binaries read their own etc dir, so the openssl@3
    // bundle does not cover them.
    const prefix = try makePrefix("both_v4_unlinked", true, true);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try mkdirIn(prefix, "/opt/openssl@4");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.warn_status, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "openssl@4's cert.pem isn't linked") != null);
}

test "both majors installed and linked: a clean ok row" {
    const prefix = try makePrefix("both_linked", true, true);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try mkdirIn(prefix, "/opt/openssl@4");
    try mkdirIn(prefix, "/etc/openssl@4");
    try touchIn(prefix, "/etc/openssl@4/cert.pem");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.ok, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "isn't linked") == null);
}

test "both majors installed, only openssl@4 linked: warns about openssl@3" {
    // The per-major rule in the other direction: the openssl@4 bundle does
    // not cover openssl@3 binaries either.
    const prefix = try makePrefix("both_v3_unlinked", true, false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try mkdirIn(prefix, "/opt/openssl@3");
    try mkdirIn(prefix, "/opt/openssl@4");
    try mkdirIn(prefix, "/etc/openssl@4");
    try touchIn(prefix, "/etc/openssl@4/cert.pem");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqual(doctor.CheckResult.warn_status, sslRun(ctxFor(prefix), &buf));
    try testing.expect(std.mem.indexOf(u8, buf.items, "openssl@3's cert.pem isn't linked") != null);
}
