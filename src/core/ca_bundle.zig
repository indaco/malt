//! malt — native build of the merged CA trust bundle.
//!
//! `ca-certificates` ships a `post-install` script that merges the live
//! macOS keychains with the Mozilla roots it carries. It is correct, and it
//! forks `openssl` and `security` once per certificate — roughly 800
//! processes, ~5 s — which lands on every cold install whose closure reaches
//! `openssl@3`. Everything but the trust evaluation is certificate parsing
//! and hashing that `std.crypto` does in-process in milliseconds.
//!
//! This builds the same bundle natively. The contract is the trusted set:
//! `scripts/regressions/native-ca-bundle-matches-upstream.sh` runs the real
//! script on the real machine and fails if the two disagree about which
//! certificates to trust. Anything this builder cannot classify with
//! certainty aborts it, so the script runs rather than a subtly-wrong trust
//! store being written, and substitution only happens for a script whose
//! bytes it recognises.
//!
//! Byte layout is not part of the contract, and cannot be: macOS ships
//! LibreSSL as `/usr/bin/openssl`, whose `-checkend` misreads a validity
//! encoded as GeneralizedTime. The script therefore drops such a certificate
//! from the keychain pass and recovers it from the Mozilla bundle further
//! down. The set is unchanged; the ordering is not. malt reads the date
//! correctly rather than reproducing that.

const std = @import("std");

const Certificate = std.crypto.Certificate;
const der = Certificate.der;
const Sha256 = std.crypto.hash.sha2.Sha256;

const child = @import("child.zig");
const atomic = @import("../fs/atomic.zig");
const sandbox = @import("dsl/sandbox.zig");

pub const BuildError = error{
    /// A certificate needs one of openssl's fallback CA rules that this
    /// builder does not implement. Never guess about a trust store.
    Unclassifiable,
    KeychainUnreadable,
    /// The trust store could not be asked about a certificate. Treating that
    /// as a rejection would quietly drop a root.
    TrustEvaluationFailed,
    /// A certificate did not fit the fixed decode buffers. Dropping it would
    /// quietly shrink the trust store, so the whole attempt is abandoned.
    CertificateTooLarge,
    OutOfMemory,
};

/// Trust purpose to evaluate a keychain certificate under, matching the
/// `-p` values upstream's script passes.
pub const Purpose = enum {
    ssl,
    basic,

    pub fn flag(self: Purpose) []const u8 {
        return @tagName(self);
    }
};

/// One input the bundle merges, in the order upstream visits them.
pub const Source = struct {
    pem: []const u8,
    /// Keychain sources are filtered on expiry, CA-ness and trust; the
    /// shipped Mozilla bundle is taken as-is, exactly as upstream does.
    purpose: ?Purpose = null,
};

/// Confines the `security` children to the same sandbox profile the shipped
/// script ran under, so replacing the script does not quietly widen what its
/// work is allowed to touch.
pub const Fence = struct {
    keg_path: []const u8,
    prefix: []const u8,
};

/// Trust evaluation outcome. `undetermined` exists so a verifier that could
/// not reach an answer is never mistaken for one that answered "no" - that
/// mistake silently drops a root from the trust store.
pub const Verdict = enum { trusted, rejected, undetermined };

/// Injected so unit tests can drive classification without the machine's
/// real trust store. Production wiring forks `security verify-cert`.
pub const Verifier = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (ctx: ?*anyopaque, pem: []const u8, purpose: Purpose) Verdict,
};

const Fingerprint = [Sha256.digest_length]u8;

/// Assemble the bundle from already-read sources. Caller owns the result.
pub fn buildFrom(
    gpa: std.mem.Allocator,
    sources: []const Source,
    verifier: Verifier,
    now_sec: i64,
) BuildError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(Fingerprint, void) = .empty;
    defer seen.deinit(gpa);

    var blocks: std.ArrayList([]const u8) = .empty;
    defer blocks.deinit(gpa);

    for (sources) |source| {
        blocks.clearRetainingCapacity();
        var it: PemIter = .{ .src = source.pem };
        while (it.next()) |block| try blocks.append(gpa, block);

        var order: std.ArrayList(usize) = .empty;
        defer order.deinit(gpa);
        try visitOrder(gpa, blocks.items.len, &order);

        for (order.items) |i| {
            const block = blocks.items[i];
            var der_buf: [max_der_bytes]u8 = undefined;
            const der_bytes = derFromPem(&der_buf, block) catch |e| switch (e) {
                error.Malformed => continue,
                error.CertificateTooLarge => return error.CertificateTooLarge,
            };
            // Upstream's openssl drops what it cannot parse; so does this.
            if (!wellFormedCertificate(der_bytes)) continue;
            const cert: Certificate = .{ .buffer = der_bytes, .index = 0 };
            // Dropping a certificate the script would have kept means a
            // trust store missing a root, so an unparsable one ends the
            // native attempt instead.
            const parsed = Certificate.parse(cert) catch return error.Unclassifiable;

            if (source.purpose) |purpose| {
                if (now_sec > parsed.validity.not_after) continue;
                switch (try classify(cert)) {
                    .not_ca => continue,
                    .ca => {},
                }
                switch (verifier.call(verifier.ctx, block, purpose)) {
                    .rejected => continue,
                    .undetermined => return error.TrustEvaluationFailed,
                    .trusted => {},
                }
            }

            var fp: Fingerprint = undefined;
            Sha256.hash(der_bytes, &fp, .{});
            if ((try seen.getOrPut(gpa, fp)).found_existing) continue;
            try out.appendSlice(gpa, block);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Whether this builder would treat `pem_block` as a CA fit for the trust
/// store — the verdict upstream gets from `openssl x509 -purpose`. Public so
/// the equivalence test can hold the two against every certificate on the
/// machine, which is the comparison that decides whether a native trust store
/// is safe to write.
pub fn wouldTrustAsCa(pem_block: []const u8) BuildError!bool {
    var buf: [max_der_bytes]u8 = undefined;
    const der_bytes = derFromPem(&buf, pem_block) catch |e| switch (e) {
        error.Malformed => return false,
        error.CertificateTooLarge => return error.CertificateTooLarge,
    };
    if (!wellFormedCertificate(der_bytes)) return false;
    const cert: Certificate = .{ .buffer = der_bytes, .index = 0 };
    _ = Certificate.parse(cert) catch return error.Unclassifiable;
    return (try classify(cert)) == .ca;
}

/// Split `pem` into its certificate blocks. Public for the same reason.
pub fn eachCertificate(pem: []const u8) PemIter {
    return .{ .src = pem };
}

/// Read one keychain's certificates as PEM. Public so tests can drive the
/// same dump the builder uses.
pub fn dumpKeychain(io: std.Io, gpa: std.mem.Allocator, path: []const u8) BuildError![]u8 {
    return readKeychain(io, gpa, path, null);
}

pub const system_keychain = "/Library/Keychains/System.keychain";
pub const root_keychain = "/System/Library/Keychains/SystemRootCertificates.keychain";

/// Read both macOS keychains and build the bundle against `mozilla_pem`.
pub fn build(
    io: std.Io,
    gpa: std.mem.Allocator,
    mozilla_pem: []const u8,
    now_sec: i64,
    fence: ?Fence,
) BuildError![]u8 {
    const system = try readKeychain(io, gpa, system_keychain, fence);
    defer gpa.free(system);
    const roots = try readKeychain(io, gpa, root_keychain, fence);
    defer gpa.free(roots);

    const dir = atomic.createTempDir(io, gpa, "ca-verify") catch return error.KeychainUnreadable;
    defer {
        atomic.cleanupTempDir(io, dir);
        gpa.free(dir);
    }
    var fork_verifier: ForkVerifier = .{ .io = io, .gpa = gpa, .dir = dir, .fence = fence };
    return buildFrom(gpa, &.{
        .{ .pem = system, .purpose = .ssl },
        .{ .pem = roots, .purpose = .basic },
        .{ .pem = mozilla_pem },
    }, fork_verifier.verifier(), now_sec);
}

/// SHA-256 of the `ca-certificates` `libexec/post-install` this builder was
/// verified against. Recognising the script by content, not by formula name,
/// means any upstream edit falls back to running it — correct, just slower —
/// until the equivalence test is re-run and this digest updated.
pub const known_script_sha256 = "0d382c7231f5f0378947729c5815f7fb8f6c12c16396172513109b13bd59b900";

/// Whether `path` is that script.
pub fn isKnownScript(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer f.close(io);
    var hasher = Sha256.init(.{});
    var buf: [16 * 1024]u8 = undefined;
    var reader = f.reader(io, &.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buf) catch return false;
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: Fingerprint = undefined;
    hasher.final(&digest);
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch return false;
    return std.mem.eql(u8, &hex, known_script_sha256);
}

// --- internals -------------------------------------------------------

/// Upstream splits each bundle into `1.pem`, `2.pem`, … and then iterates
/// `dir/*.pem`, so its visit order is the shell's lexicographic glob, not
/// certificate order. Reproducing it is not required for correctness — the
/// contract is the trusted set — but it keeps the two outputs a few bytes
/// apart instead of wholly reordered, which is what makes the equivalence
/// test's byte comparison a usable signal.
fn visitOrder(gpa: std.mem.Allocator, count: usize, out: *std.ArrayList(usize)) !void {
    try out.ensureTotalCapacity(gpa, count);
    for (0..count) |i| out.appendAssumeCapacity(i);
    std.mem.sort(usize, out.items, {}, struct {
        fn lessThan(_: void, a: usize, b: usize) bool {
            var ba: [24]u8 = undefined;
            var bb: [24]u8 = undefined;
            const sa = std.fmt.bufPrint(&ba, "{d}", .{a + 1}) catch unreachable;
            const sb = std.fmt.bufPrint(&bb, "{d}", .{b + 1}) catch unreachable;
            return std.mem.lessThan(u8, sa, sb);
        }
    }.lessThan);
}

pub const PemIter = struct {
    src: []const u8,
    i: usize = 0,

    /// One BEGIN..END block, newline-terminated, as upstream's splitter emits.
    pub fn next(self: *PemIter) ?[]const u8 {
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        const s = std.mem.indexOfPos(u8, self.src, self.i, begin) orelse return null;
        const e = std.mem.indexOfPos(u8, self.src, s, end) orelse return null;
        var stop = e + end.len;
        if (stop < self.src.len and self.src[stop] == '\n') stop += 1;
        self.i = stop;
        return self.src[s..stop];
    }
};

/// Decode a PEM block's base64 body into `buf`.
///
/// `error.Malformed` means the block is not decodable, which upstream also
/// drops (its openssl call fails). `error.CertificateTooLarge` is different:
/// upstream has no size limit, so a certificate that outgrows these buffers
/// must abandon the native path rather than silently vanish from the bundle.
fn derFromPem(buf: []u8, pem_block: []const u8) error{ Malformed, CertificateTooLarge }![]u8 {
    var b64_buf: [max_base64_bytes]u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, pem_block, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (t.len == 0 or std.mem.startsWith(u8, t, "-----")) continue;
        if (n + t.len > b64_buf.len) return error.CertificateTooLarge;
        @memcpy(b64_buf[n..][0..t.len], t);
        n += t.len;
    }
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(b64_buf[0..n]) catch return error.Malformed;
    if (size > buf.len) return error.CertificateTooLarge;
    dec.decode(buf[0..size], b64_buf[0..n]) catch return error.Malformed;
    return buf[0..size];
}

/// Roomy next to a real root (1-2 KB DER), and bounded so one bad input
/// cannot make the builder allocate without limit.
const max_der_bytes = 16 * 1024;
const max_base64_bytes = max_der_bytes * 4 / 3 + 64;

/// One TLV header, with every declared extent already checked against the
/// buffer. `std`'s DER reader trusts declared lengths and indexes straight
/// past the end of a malformed certificate, so nothing reaches it unchecked.
const Header = struct {
    content_start: usize,
    content_end: usize,
    constructed: bool,
};

fn readHeader(bytes: []const u8, pos: usize) ?Header {
    if (pos + 1 >= bytes.len) return null;
    const tag = bytes[pos];
    // Multi-byte tag numbers do not occur in X.509; refuse rather than model.
    if (tag & 0x1F == 0x1F) return null;

    const first = bytes[pos + 1];
    var content_start = pos + 2;
    var len: usize = first;
    if (first >= 0x80) {
        const count: usize = first & 0x7F;
        // Zero means indefinite length, which DER forbids.
        if (count == 0 or count > 4 or content_start + count > bytes.len) return null;
        len = 0;
        for (bytes[content_start..][0..count]) |b| len = (len << 8) | b;
        content_start += count;
    }
    const content_end = std.math.add(usize, content_start, len) catch return null;
    if (content_end > bytes.len) return null;
    return .{
        .content_start = content_start,
        .content_end = content_end,
        .constructed = tag & 0x20 != 0,
    };
}

/// `der.Element.parse` with the bounds check `std` does not do.
fn checkedElement(bytes: []const u8, pos: usize) !der.Element {
    _ = readHeader(bytes, pos) orelse return error.MalformedDer;
    return der.Element.parse(bytes, std.math.cast(u32, pos) orelse return error.MalformedDer);
}

/// Every nested TLV's declared length must stay inside its parent. Checking
/// only the outer SEQUENCE is not enough: a truncated certificate whose outer
/// length is patched to match still crashes the parser from within.
fn derStructureOk(bytes: []const u8, depth: u8) bool {
    if (depth == 0) return false;
    var pos: usize = 0;
    while (pos < bytes.len) {
        const h = readHeader(bytes, pos) orelse return false;
        if (h.constructed and !derStructureOk(bytes[h.content_start..h.content_end], depth - 1))
            return false;
        pos = h.content_end;
    }
    return true;
}

/// Whether `bytes` is exactly one well-formed DER certificate envelope.
fn wellFormedCertificate(bytes: []const u8) bool {
    const h = readHeader(bytes, 0) orelse return false;
    if (!h.constructed or h.content_end != bytes.len) return false;
    return derStructureOk(bytes[h.content_start..h.content_end], 32);
}

const Class = enum { ca, not_ca };

const oid_basic_constraints = [_]u8{ 0x55, 0x1D, 0x13 };
const oid_key_usage = [_]u8{ 0x55, 0x1D, 0x0F };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1D, 0x25 };
// The three usages openssl accepts for a TLS server purpose: serverAuth and
// the two Server Gated Crypto OIDs. `anyExtendedKeyUsage` is not among them.
const oid_server_auth = [_]u8{ 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01 };
const oid_ns_sgc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x86, 0xF8, 0x42, 0x04, 0x01 };
const oid_ms_sgc = [_]u8{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x0A, 0x03, 0x03 };

/// openssl's `-purpose` "SSL server CA" verdict. An extendedKeyUsage that
/// names no server usage rejects the certificate outright, before the CA
/// question is even asked; then keyUsage must permit certificate signing and
/// basicConstraints must assert CA. Certificates without basicConstraints
/// reach openssl's Netscape/self-signed fallbacks, which this does not
/// implement — those abort the build rather than get a guess.
fn classify(cert: Certificate) BuildError!Class {
    const exts = readExtensions(cert) catch return error.Unclassifiable;
    if (exts.ext_key_usage_present and !exts.allows_server_auth) return .not_ca;
    if (exts.key_usage_present and !exts.key_cert_sign) return .not_ca;
    if (!exts.basic_constraints_present) return error.Unclassifiable;
    return if (exts.is_ca) .ca else .not_ca;
}

const Extensions = struct {
    basic_constraints_present: bool = false,
    is_ca: bool = false,
    key_usage_present: bool = false,
    key_cert_sign: bool = false,
    ext_key_usage_present: bool = false,
    allows_server_auth: bool = false,
};

fn readExtensions(cert: Certificate) !Extensions {
    var out: Extensions = .{};
    const bytes = cert.buffer;
    const certificate = try checkedElement(bytes, cert.index);
    const tbs = try checkedElement(bytes, certificate.slice.start);
    const version_elem = try checkedElement(bytes, tbs.slice.start);
    // Context-specific [0] marks an explicit version; without one the
    // certificate is v1 and carries no extensions at all.
    if (@as(u8, @bitCast(version_elem.identifier)) != 0xa0) return out;

    // TBSCertificate (RFC 5280 4.1.2): version, serialNumber, signature,
    // issuer, validity, subject, subjectPublicKeyInfo, then [3] extensions.
    const serial = try checkedElement(bytes, version_elem.slice.end);
    const tbs_sig = try checkedElement(bytes, serial.slice.end);
    const issuer = try checkedElement(bytes, tbs_sig.slice.end);
    const validity = try checkedElement(bytes, issuer.slice.end);
    const subject = try checkedElement(bytes, validity.slice.end);
    const pub_key_info = try checkedElement(bytes, subject.slice.end);
    if (pub_key_info.slice.end >= tbs.slice.end) return out;

    const outer = try checkedElement(bytes, pub_key_info.slice.end);
    if (outer.identifier.tag != .bitstring) return out;
    const extensions = try checkedElement(bytes, outer.slice.start);

    var i = extensions.slice.start;
    while (i < extensions.slice.end) {
        const extension = try checkedElement(bytes, i);
        i = extension.slice.end;
        const oid = try checkedElement(bytes, extension.slice.start);
        const critical = try checkedElement(bytes, oid.slice.end);
        const payload = if (critical.identifier.tag != .boolean)
            critical
        else
            try checkedElement(bytes, critical.slice.end);
        const oid_bytes = bytes[oid.slice.start..oid.slice.end];

        if (std.mem.eql(u8, oid_bytes, &oid_basic_constraints)) {
            out.basic_constraints_present = true;
            const constraints = try checkedElement(bytes, payload.slice.start);
            if (constraints.slice.start < constraints.slice.end) {
                const ca = try checkedElement(bytes, constraints.slice.start);
                if (ca.identifier.tag == .boolean) out.is_ca = bytes[ca.slice.start] != 0;
            }
        } else if (std.mem.eql(u8, oid_bytes, &oid_ext_key_usage)) {
            out.ext_key_usage_present = true;
            const usages = try checkedElement(bytes, payload.slice.start);
            var u = usages.slice.start;
            while (u < usages.slice.end) {
                const usage = try checkedElement(bytes, u);
                u = usage.slice.end;
                const id = bytes[usage.slice.start..usage.slice.end];
                if (std.mem.eql(u8, id, &oid_server_auth) or
                    std.mem.eql(u8, id, &oid_ns_sgc) or
                    std.mem.eql(u8, id, &oid_ms_sgc)) out.allows_server_auth = true;
            }
        } else if (std.mem.eql(u8, oid_bytes, &oid_key_usage)) {
            out.key_usage_present = true;
            const bits = try checkedElement(bytes, payload.slice.start);
            const data = bytes[bits.slice.start..bits.slice.end];
            // BIT STRING content leads with the unused-bit count; keyCertSign
            // is bit 5, i.e. 0x04 of the first data byte.
            if (data.len >= 2) out.key_cert_sign = (data[1] & 0x04) != 0;
        }
    }
    return out;
}

/// The system roots already dump ~240 KB, close to the shared diagnostic cap,
/// and macOS only adds roots over time. Ask for room and refuse a dump that
/// still hit the ceiling: a truncated keychain is a trust store missing roots.
const keychain_dump_cap = 16 * 1024 * 1024;

fn readKeychain(io: std.Io, gpa: std.mem.Allocator, path: []const u8, fence: ?Fence) BuildError![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const argv = fenced(arena.allocator(), fence, &.{
        "/usr/bin/security", "find-certificate", "-a", "-p", path,
    }) orelse return error.KeychainUnreadable;

    var report = child.runCapped(io, gpa, argv, keychain_dump_cap) catch
        return error.KeychainUnreadable;
    defer report.deinit(gpa);
    if (report.code != 0 or report.truncated) return error.KeychainUnreadable;
    return gpa.dupe(u8, report.stdout) catch error.OutOfMemory;
}

/// Wrap `argv` in the sandbox when a fence is supplied. Null means the
/// profile could not be built, which fails the call rather than spawning
/// unconfined.
fn fenced(a: std.mem.Allocator, fence: ?Fence, argv: []const []const u8) ?[]const []const u8 {
    const f = fence orelse return argv;
    return sandbox.fenceArgv(a, argv, f.keg_path, f.prefix, .{}) catch null;
}

/// Production verifier: one `security verify-cert` per candidate. This is the
/// whole remaining cost, and what an in-process trust evaluation would remove.
const ForkVerifier = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    /// Randomly named, inside the malt prefix rather than shared /tmp, so a
    /// local attacker cannot pre-place a symlink on the path malt writes.
    dir: []const u8,
    fence: ?Fence,

    fn verifier(self: *ForkVerifier) Verifier {
        return .{ .ctx = self, .call = call };
    }

    fn call(ctx: ?*anyopaque, pem: []const u8, purpose: Purpose) Verdict {
        const self: *ForkVerifier = @ptrCast(@alignCast(ctx));
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.pem", .{
            self.dir, verify_seq.fetchAdd(1, .monotonic),
        }) catch return .undetermined;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = pem }) catch
            return .undetermined;
        defer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const argv = fenced(arena.allocator(), self.fence, &.{
            "/usr/bin/security", "verify-cert", "-l", "-L",
            "-c",                path,          "-p", purpose.flag(),
            "-R",                "offline",
        }) orelse return .undetermined;

        // Only a clean run answers the question. A spawn or wait failure -
        // fd exhaustion during a wide parallel install, say - is not a "no".
        var report = child.run(self.io, self.gpa, argv) catch return .undetermined;
        defer report.deinit(self.gpa);
        return if (report.code == 0) .trusted else .rejected;
    }
};

/// Distinguishes the temp files concurrent hooks hand to `verify-cert`.
var verify_seq: std.atomic.Value(u32) = .init(0);

// --- tests -----------------------------------------------------------

const testing = std.testing;

fn allowAll(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
    return .trusted;
}
fn denyAll(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
    return .rejected;
}
fn undetermined(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
    return .undetermined;
}

test "a fenced child is wrapped in sandbox-exec, never spawned bare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = fenced(arena.allocator(), .{
        .keg_path = "/tmp/malt-fence-test/Cellar/probe/1.0",
        .prefix = "/tmp/malt-fence-test",
    }, &.{ "/usr/bin/security", "verify-cert" }).?;

    try testing.expectEqualStrings("/usr/bin/sandbox-exec", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expect(std.mem.indexOf(u8, argv[2], "(deny default)") != null);
    // The original command survives intact behind the wrapper.
    try testing.expectEqualStrings("/usr/bin/security", argv[3]);
    try testing.expectEqualStrings("verify-cert", argv[4]);
}

test "no fence leaves argv untouched, for callers with no keg to confine to" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = fenced(arena.allocator(), null, &.{"/usr/bin/security"}).?;
    try testing.expectEqual(@as(usize, 1), argv.len);
    try testing.expectEqualStrings("/usr/bin/security", argv[0]);
}

test "a keg path the profile cannot confine fails the call, it does not run bare" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // A relative keg path cannot be turned into a subpath rule.
    try testing.expect(fenced(arena.allocator(), .{
        .keg_path = "relative/keg",
        .prefix = "also/relative",
    }, &.{"/usr/bin/security"}) == null);
}

test "upstream's lexicographic glob order is reproduced, not numeric order" {
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(testing.allocator);
    try visitOrder(testing.allocator, 12, &order);
    // 1, 10, 11, 12, 2, 3, ... — the shell's order for 1.pem…12.pem.
    const want = [_]usize{ 0, 9, 10, 11, 1, 2, 3, 4, 5, 6, 7, 8 };
    try testing.expectEqualSlices(usize, &want, order.items);
}

test "a single-certificate bundle needs no reordering" {
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(testing.allocator);
    try visitOrder(testing.allocator, 1, &order);
    try testing.expectEqualSlices(usize, &.{0}, order.items);
}

test "PEM iteration yields whole newline-terminated blocks" {
    const src =
        "junk\n-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n" ++
        "-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----\n";
    var it: PemIter = .{ .src = src };
    try testing.expectEqualStrings(
        "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n",
        it.next().?,
    );
    try testing.expectEqualStrings(
        "-----BEGIN CERTIFICATE-----\nBBBB\n-----END CERTIFICATE-----\n",
        it.next().?,
    );
    try testing.expect(it.next() == null);
}

test "an unterminated PEM block is not yielded" {
    var it: PemIter = .{ .src = "-----BEGIN CERTIFICATE-----\nAAAA\n" };
    try testing.expect(it.next() == null);
}

test "base64 that decodes but is not a DER envelope is rejected before parsing" {
    var buf: [64]u8 = undefined;
    const bytes = try derFromPem(&buf, "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n");
    try testing.expectEqualStrings("ABC", bytes);
    // std's DER reader would read past this buffer and panic.
    try testing.expect(!wellFormedCertificate(bytes));
}

test "a truncated certificate is rejected rather than read past" {
    // A SEQUENCE header promising 66 bytes with only 1 present.
    try testing.expect(!wellFormedCertificate(&.{ 0x30, 0x42, 0xAA }));
    // Long-form length promising far more than the buffer holds.
    try testing.expect(!wellFormedCertificate(&.{ 0x30, 0x82, 0x10, 0x00, 0xAA }));
    // A header with no length byte at all.
    try testing.expect(!wellFormedCertificate(&.{0x30}));
    // Primitive at the top: a certificate is a constructed SEQUENCE.
    try testing.expect(!wellFormedCertificate(&.{ 0x02, 0x01, 0x00 }));
    // Indefinite length is not DER.
    try testing.expect(!wellFormedCertificate(&.{ 0x30, 0x80, 0x00, 0x00 }));
}

test "a well-formed short-form envelope is accepted" {
    try testing.expect(wellFormedCertificate(&.{ 0x30, 0x03, 0x02, 0x01, 0x00 }));
}

// The outer length alone is not enough: patching it to match a truncated
// buffer leaves an inner element still claiming its original size, which
// crashed std's parser from the inside.
test "a nested length overrunning its parent is rejected, not handed to the parser" {
    var buf: [max_der_bytes]u8 = undefined;
    const full = try derFromPem(&buf, ca_pem);
    try testing.expect(wellFormedCertificate(full));

    // Every truncation point, with the outer SEQUENCE length patched so an
    // outer-only check would wave it through.
    var cut: usize = 1;
    while (cut < full.len - 8) : (cut += 7) {
        var probe: [max_der_bytes]u8 = undefined;
        const n = full.len - cut;
        @memcpy(probe[0..n], full[0..n]);
        const body = n - 4;
        probe[2] = @intCast(body >> 8);
        probe[3] = @intCast(body & 0xFF);
        // Must be refused; reaching Certificate.parse here aborts the process.
        try testing.expect(!wellFormedCertificate(probe[0..n]));
    }
}

test "every prefix of a real certificate is refused without crashing" {
    var buf: [max_der_bytes]u8 = undefined;
    const full = try derFromPem(&buf, ca_pem);
    for (1..full.len) |n| {
        if (wellFormedCertificate(full[0..n])) {
            // Only the whole thing may validate.
            try testing.expectEqual(full.len, n);
        }
    }
}

test "trailing bytes after the envelope disqualify the block" {
    var buf: [max_der_bytes + 8]u8 = undefined;
    const bytes = try derFromPem(buf[0..max_der_bytes], ca_pem);
    try testing.expect(wellFormedCertificate(bytes));

    // Anything appended past the SEQUENCE means this is not one certificate.
    const padded = buf[0 .. bytes.len + 1];
    padded[bytes.len] = 0xAA;
    try testing.expect(!wellFormedCertificate(padded));
}

test "a body too large to decode aborts rather than silently shrinking the store" {
    var buf: [4]u8 = undefined;
    const block = "-----BEGIN CERTIFICATE-----\nQUJDREVGR0hJSktMTU5PUFFSUw==\n-----END CERTIFICATE-----\n";
    try testing.expectError(error.CertificateTooLarge, derFromPem(&buf, block));
}

test "a body longer than the base64 window aborts too" {
    var buf: [max_der_bytes]u8 = undefined;
    var big: [max_base64_bytes + 128]u8 = undefined;
    @memset(&big, 'A');
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "-----BEGIN CERTIFICATE-----\n");
    try list.appendSlice(testing.allocator, &big);
    try list.appendSlice(testing.allocator, "\n-----END CERTIFICATE-----\n");
    try testing.expectError(error.CertificateTooLarge, derFromPem(&buf, list.items));
}

test "malformed base64 is dropped, matching what upstream's openssl call does" {
    var buf: [64]u8 = undefined;
    const block = "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n";
    try testing.expectError(error.Malformed, derFromPem(&buf, block));
}

test "an oversized certificate stops the whole build, it is never just skipped" {
    // One good certificate and one that cannot be decoded into the buffers:
    // the good one must not be emitted on its own.
    var oversized: std.ArrayList(u8) = .empty;
    defer oversized.deinit(testing.allocator);
    try oversized.appendSlice(testing.allocator, ca_pem);
    try oversized.appendSlice(testing.allocator, "\n-----BEGIN CERTIFICATE-----\n");
    try oversized.appendNTimes(testing.allocator, 'A', max_base64_bytes + 8);
    try oversized.appendSlice(testing.allocator, "\n-----END CERTIFICATE-----\n");

    try testing.expectError(error.CertificateTooLarge, buildFrom(
        testing.allocator,
        &.{.{ .pem = oversized.items }},
        .{ .call = allowAll },
        now_valid,
    ));
}

// Real certificates, so classification is tested against DER that
// `/usr/bin/openssl` (LibreSSL, what upstream's script calls) agrees on:
// `ca` is "SSL server CA : Yes", the other two are "No".
const ca_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIC1DCCAbygAwIBAgIJAPz61kc8iO+UMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNV
    \\BAMMDG1hbHQtdGVzdC1jYTAeFw0yNjA4MjQxMTQzMjNaFw00NjA4MTkxMTQzMjNa
    \\MBcxFTATBgNVBAMMDG1hbHQtdGVzdC1jYTCCASIwDQYJKoZIhvcNAQEBBQADggEP
    \\ADCCAQoCggEBAM69E8AyDsaXXMhqUWrx2Nzgy2WmGN+6S1fzR/bXX3M+IlaBTt1B
    \\z/6XXPME7uqUXOR87YaPT4WcTBLmoeOHKJ1f6x9V4nZQm3t8/00VHuUdq4fPOnKw
    \\fUuUsR/TIcZdBQF748GIWNSqMIERWA+Sxo0XmJvSfPfWh7bdUustCLCyyu3pSmgr
    \\MIGFAPc/nkvKPiViMmliQGxwGfb4TuionhSS+4HssHnrM9cC4CLLlB09UfRZe40X
    \\TPYOhQ6cgsIWocHZvbv7VgryT7BWLqmZhQct+YnH3ZxonLiLV2SdV2vsjNU/vqsg
    \\GrE06JyX3AWgTWOlRz603FYy/VGhbWE6nZUCAwEAAaMjMCEwDwYDVR0TAQH/BAUw
    \\AwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBAFh6snavN/0A
    \\LSEE17F362N0gWvUAoFVzP0y9Wgc9EW1yBMjSiNiy2l9O/W5CcuDoanmxJiwAEHC
    \\XTrQ/nCGwh0WrYXW/aGNx3ovenPn/Rul1bC6/wTAuXCTap0yuZ7EokDNSBXrciHl
    \\teQm/5952qNqvM4IXuaR7Rk7QPHtBJAO3eaN+jd4XrhKZVVB87AjzC3dLD4/LxNX
    \\q5bLgdJ+qf+9zqmb0J3joHTxS8BLCt2YbgsNMcaCNz4lzgiSMvAa3LUVZuYgWCt+
    \\NkGOagII41CYYQm7GvUWziZbssvaxcATRz1rMa9mX5FAIxQ4eBVDXrqFPrgjhqBU
    \\rhhjyzGGY9Y=
    \\-----END CERTIFICATE-----
;

// basicConstraints CA:FALSE.
const leaf_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIC0zCCAbugAwIBAgIJAMgXAt8QpxYLMA0GCSqGSIb3DQEBCwUAMBcxFTATBgNV
    \\BAMMDG1hbHQtdGVzdC1jYTAeFw0yNjA4MjQxMTQzMjNaFw00NjA4MTkxMTQzMjNa
    \\MBkxFzAVBgNVBAMMDm1hbHQtdGVzdC1sZWFmMIIBIjANBgkqhkiG9w0BAQEFAAOC
    \\AQ8AMIIBCgKCAQEA0xTO6ezrqxZIr30p+demfTt/1vbCDGCwUbEXh4mAlDbnYmGi
    \\8VTQcDUhE8N9QB8NOp2p7pA+2cV0PIHI64ysqyss1iAD+2Nb719rxaXM5rUxVLCu
    \\qmWPCPaFl4UcGC6wNvOM8BD7JTK+8JSy4+3tp5GolfInwp8KBq5ig/p9/SHlk2ig
    \\OIWJdOJT5D5WEf/7CRI+/ElKdieqHeZFcHDwrXFwcQ1uTDuysjJXqfR7qA+H+9Go
    \\u6NljZ9kVCAQf/xDUjAAeUL5bVs02EyaQP+hB1w2cjr0Qa3QdNEidQp7Tuz0ws3T
    \\+FM+QDSOqaM2ecJzPUCn7a6G4K+L4aM17OeKpQIDAQABoyAwHjAMBgNVHRMBAf8E
    \\AjAAMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAQEAI4h51dP1CGFc
    \\UMxbTYJ//gJCu97hvs53SHaa4NnjOH/0rDXyn1DWzOASd2QIYeEo5vbpFjqR2iZM
    \\4hc9Va0jNA36Zm6r/BPrnxB95YLpVC5jDCNNoABVfnBDfCzm3j4/FkA7Z6Wvb8gh
    \\XvlTxTXOTaZzLCTv4VTtsIfhQutuNcwAiLgHNQcQGXsNWnS1ugnybikhvN0OsEw6
    \\yRxjKkBgHNbrjFoRIWK1MoZNTjEdaAInUzQZ91q+5O3XavU4DAqNIIvcv9orC4ju
    \\ZNbwUFS2teiPJ29iIq3bjyqLrvLc6/kYMB2ESYpdgjSGJNbyDy7SIHfYa91VdnGb
    \\TKqbdBnuoA==
    \\-----END CERTIFICATE-----
;

// basicConstraints CA:TRUE but keyUsage omits keyCertSign.
const nosign_pem =
    \\-----BEGIN CERTIFICATE-----
    \\MIIC3DCCAcSgAwIBAgIJAN26xpzUVxpoMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV
    \\BAMMEG1hbHQtdGVzdC1ub3NpZ24wHhcNMjYwODI0MTE0MzIzWhcNNDYwODE5MTE0
    \\MzIzWjAbMRkwFwYDVQQDDBBtYWx0LXRlc3Qtbm9zaWduMIIBIjANBgkqhkiG9w0B
    \\AQEFAAOCAQ8AMIIBCgKCAQEAuWhlri6XWPM/pZGch+iixybw66+f4usw3GE8CyRr
    \\wwj7eViEEQk01ewFpebGR/ovSlLX+71iWyxDlKkxemWAEvaS5LHfEFvMe5wvFHgh
    \\+tUpCPfjU3vo2427ICSxcPPd+COzj872266D0HL1jmTKOC0Nk6jJ9lIGzAlSspY8
    \\rbSsGPJkYj5ni6gEf8lJBedKzz3itsjQFC2LoTxM2WTPaMbf4O3P5Uh1etxjH/Kz
    \\O0ThQVI4ekOM+k/2JP5vjbT9Z86LAKDlTep5oqe2k9juu3T7bW79uKBoNh8q/ie4
    \\qM7jV7c7J0SqTXutwuCCAmSffNrJwYcgCKj1eeqzngp7VQIDAQABoyMwITAPBgNV
    \\HRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAQEA
    \\HPzKP55UinctKs/OoiEHPYYMrrAMxgumY2kO3lvHYEFAuKlUhdc0o7Jm8uodtMoB
    \\5A79mlelxbJynkVnyv8MnPKU6V2R7nMrMHvCZBlwsc9iYcDmeei7JqSv8mtUAqJc
    \\sffcx70yPtNlGX7JjmRvxobvRU06tZsVcFGdBBWqq5qEMtFdUMWz2XVdsGz5AhIg
    \\mGqR1RMM6cZ0DzE9bb3bMaC9rTEkn+VkFled3nXyHzMl+jxDZocWBAw422skngR9
    \\Htppx3ZT56GpwavY5pgGcrRst86L4tLcEo7gV+hBGyDLFZAwasyNCodt5VffVdlE
    \\1A9ATcgUbl7yaqY4MTWBiA==
    \\-----END CERTIFICATE-----
;

/// Seconds inside every fixture's validity window.
const now_valid: i64 = 1_800_000_000;

fn classifyPem(pem: []const u8) !Class {
    var buf: [max_der_bytes]u8 = undefined;
    const bytes = try derFromPem(&buf, pem);
    std.debug.assert(wellFormedCertificate(bytes));
    return classify(.{ .buffer = bytes, .index = 0 });
}

test "a CA with basicConstraints CA:TRUE and keyCertSign classifies as a CA" {
    try testing.expectEqual(Class.ca, try classifyPem(ca_pem));
}

test "basicConstraints CA:FALSE classifies as not a CA" {
    try testing.expectEqual(Class.not_ca, try classifyPem(leaf_pem));
}

test "keyUsage without keyCertSign disqualifies a CA:TRUE certificate" {
    // openssl consults keyUsage before basicConstraints; so does this.
    try testing.expectEqual(Class.not_ca, try classifyPem(nosign_pem));
}

test "a trusted, unexpired CA lands in the bundle" {
    const out = try buildFrom(
        testing.allocator,
        &.{.{ .pem = ca_pem, .purpose = .basic }},
        .{ .call = allowAll },
        now_valid,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(ca_pem ++ "\n", out);
}

test "expiry is judged at the notAfter second, not a day either side of it" {
    var buf: [max_der_bytes]u8 = undefined;
    const bytes = try derFromPem(&buf, ca_pem);
    const not_after: i64 = @intCast(
        (try Certificate.parse(.{ .buffer = bytes, .index = 0 })).validity.not_after,
    );

    for ([_]struct { now: i64, kept: bool }{
        .{ .now = not_after - 1, .kept = true },
        .{ .now = not_after, .kept = true },
        .{ .now = not_after + 1, .kept = false },
    }) |case| {
        const out = try buildFrom(
            testing.allocator,
            &.{.{ .pem = ca_pem, .purpose = .basic }},
            .{ .call = allowAll },
            case.now,
        );
        defer testing.allocator.free(out);
        try testing.expectEqual(case.kept, out.len > 0);
    }
}

test "a certificate past its notAfter is dropped without consulting trust" {
    const Never = struct {
        fn call(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
            unreachable;
        }
    };
    // Year 2286: past every fixture's validity window.
    const out = try buildFrom(
        testing.allocator,
        &.{.{ .pem = ca_pem, .purpose = .basic }},
        .{ .call = Never.call },
        9_999_999_999,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "a keychain certificate the trust store rejects is left out" {
    const out = try buildFrom(
        testing.allocator,
        &.{.{ .pem = ca_pem, .purpose = .basic }},
        .{ .call = denyAll },
        now_valid,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "a non-CA keychain certificate is dropped before the trust evaluation" {
    const Never = struct {
        fn call(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
            unreachable;
        }
    };
    const out = try buildFrom(
        testing.allocator,
        &.{.{ .pem = leaf_pem, .purpose = .basic }},
        .{ .call = Never.call },
        now_valid,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "the mozilla source takes certificates whole, with no trust evaluation" {
    const Never = struct {
        fn call(_: ?*anyopaque, _: []const u8, _: Purpose) Verdict {
            unreachable;
        }
    };
    // Not a CA and never trust-evaluated, yet upstream keeps it: the shipped
    // bundle is authoritative for its own contents.
    const out = try buildFrom(testing.allocator, &.{.{ .pem = leaf_pem }}, .{ .call = Never.call }, now_valid);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(leaf_pem ++ "\n", out);
}

/// The same certificate as `ca_pem`, re-wrapped with a blank line after the
/// header: identical DER, different block bytes. Dedup keys on the DER, so
/// this is what makes "which source won" observable.
const ca_pem_rewrapped = "-----BEGIN CERTIFICATE-----\n\n" ++
    ca_pem["-----BEGIN CERTIFICATE-----\n".len..];

test "a certificate in two sources is emitted once, keeping the first source's bytes" {
    const out = try buildFrom(
        testing.allocator,
        &.{
            .{ .pem = ca_pem_rewrapped, .purpose = .basic },
            .{ .pem = ca_pem },
        },
        .{ .call = allowAll },
        now_valid,
    );
    defer testing.allocator.free(out);
    // Keeping the last source instead would emit `ca_pem` here.
    try testing.expectEqualStrings(ca_pem_rewrapped ++ "\n", out);
}

test "the two renderings really are the same certificate" {
    var a_buf: [max_der_bytes]u8 = undefined;
    var b_buf: [max_der_bytes]u8 = undefined;
    const a = try derFromPem(&a_buf, ca_pem);
    const b = try derFromPem(&b_buf, ca_pem_rewrapped);
    try testing.expectEqualSlices(u8, a, b);
    // ...but not the same bytes, or the test above proves nothing.
    try testing.expect(!std.mem.eql(u8, ca_pem, ca_pem_rewrapped));
}

test "sources are concatenated in the order given" {
    const out = try buildFrom(
        testing.allocator,
        &.{ .{ .pem = leaf_pem }, .{ .pem = nosign_pem } },
        .{ .call = allowAll },
        now_valid,
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(leaf_pem ++ "\n" ++ nosign_pem ++ "\n", out);
}

test "one source's certificates are emitted in upstream's glob order" {
    // Three distinct certificates in a single source. Upstream visits
    // 1, 10, 11, ... 2, ... so with three it is 1, 2, 3 — the interesting
    // case is that the reorder is applied at all, which 10+ would show.
    const many = leaf_pem ++ "\n" ++ nosign_pem ++ "\n" ++ ca_pem;
    const out = try buildFrom(testing.allocator, &.{.{ .pem = many }}, .{ .call = allowAll }, now_valid);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        leaf_pem ++ "\n\n" ++ nosign_pem ++ "\n\n" ++ ca_pem ++ "\n",
        out,
    );
}

test "a trust store that cannot be asked aborts, rather than dropping the root" {
    try testing.expectError(error.TrustEvaluationFailed, buildFrom(
        testing.allocator,
        &.{.{ .pem = ca_pem, .purpose = .basic }},
        .{ .call = undetermined },
        now_valid,
    ));
}

test "an empty source set yields an empty bundle" {
    const out = try buildFrom(testing.allocator, &.{}, .{ .call = denyAll }, now_valid);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}
