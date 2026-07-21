//! `mt doctor` SSL CA bundle check tests.
//!
//! The check is gated on its precondition: it verifies the OpenSSL trust
//! bundle (`<prefix>/etc/openssl@3/cert.pem`) only when `ca-certificates`
//! is installed (`<prefix>/opt/ca-certificates`). A prefix that never
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
