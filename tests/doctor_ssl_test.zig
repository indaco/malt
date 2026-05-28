//! `mt doctor` SSL CA bundle check tests.
//!
//! The check is informational: it flags a missing
//! `<prefix>/etc/openssl@3/cert.pem` with a remediation hint but never
//! bumps doctor's exit code — a fresh prefix without ca-certificates is
//! a normal state, not a defect.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");

const doctor = malt.doctor;
const output = malt.output;

fn uniquePrefix(suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        testing.allocator,
        "/tmp/malt_doctor_ssl_{d}_{s}",
        .{ test_io.nanoTimestamp(std.Options.debug_io), suffix },
    );
}

fn makePrefix(suffix: []const u8, with_cert: bool) ![]u8 {
    const prefix = try uniquePrefix(suffix);
    try test_io.cwd().createDirPath(std.Options.debug_io, prefix);
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

// The pure `formatSslCertDetail` formatter is unit-tested inline in
// `doctor.zig`; this file covers the fs-backed check behaviour.

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

test "SSL CA bundle check returns ok when cert.pem is present" {
    const prefix = try makePrefix("present", true);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try testing.expectEqual(doctor.CheckResult.ok, sslCheckResult(ctxFor(prefix)));
}

test "SSL CA bundle check stays ok (informational) when cert.pem is absent" {
    // Quiet the verbose-remediation stderr so the assert reads clean.
    output.setQuiet(true);
    defer output.setQuiet(false);
    const prefix = try makePrefix("absent", false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try testing.expectEqual(doctor.CheckResult.ok, sslCheckResult(ctxFor(prefix)));
}

test "SSL CA bundle check is ok under --verbose when cert.pem is absent" {
    const prior = output.isVerbose();
    output.setVerbose(true);
    defer output.setVerbose(prior);
    output.setQuiet(true);
    defer output.setQuiet(false);
    const prefix = try makePrefix("verbose_absent", false);
    defer testing.allocator.free(prefix);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, prefix) catch {};
    try testing.expectEqual(doctor.CheckResult.ok, sslCheckResult(ctxFor(prefix)));
}
