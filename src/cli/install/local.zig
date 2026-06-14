//! Tap + local (`.rb`) formula install orchestration: the shared
//! materialise pipeline plus the advisory permission classifier. The
//! pure Ruby/cask DSL parser lives in `rb_parse.zig`. Split out of
//! `cli/install.zig` so the GHCR bottle flow does not recompile when
//! this path changes.

const std = @import("std");

const AppCtx = @import("../../app_ctx.zig").AppCtx;
const cask_mod = @import("../../core/cask.zig");
const hash = @import("../../core/hash.zig");
const linker_mod = @import("../../core/linker.zig");
const tap_mod = @import("../../core/tap.zig");
const forge = @import("../../core/forge.zig");
const tap_cache = @import("../../core/tap_cache.zig");
const sqlite = @import("../../db/sqlite.zig");
const atomic = @import("../../fs/atomic.zig");
const client_mod = @import("../../net/client.zig");
const output = @import("../../ui/output.zig");
const progress_mod = @import("../../ui/progress.zig");
const install_mod = @import("../install.zig");
const args = @import("args.zig");
const download = @import("download.zig");
const rb_parse = @import("rb_parse.zig");
const RubyFormulaInfo = rb_parse.RubyFormulaInfo;
const parseRubyFormula = rb_parse.parseRubyFormula;
const parseCaskBinary = rb_parse.parseCaskBinary;
const parseCaskApp = rb_parse.parseCaskApp;
const tapCaskArtifactKind = rb_parse.tapCaskArtifactKind;
const record = @import("record.zig");
const InstallError = record.InstallError;
const sink_mod = @import("sink.zig");
const OutputSink = sink_mod.OutputSink;

/// Maximum size of a `.rb` formula file that `malt install --local`
/// will read. Real Homebrew formulas top out well below this (the
/// current heaviest, `llvm.rb`, is ~60 KB). The cap bounds the single
/// TOCTOU-safe read so a hostile symlink cannot force malt to slurp an
/// unbounded file before parsing.
pub const max_local_formula_bytes: usize = 1 * 1024 * 1024;

/// Post-parse payload shared by the tap and local-file install paths.
/// Slices point into caller-owned memory (parsed `.rb`, interpolated
/// URL buffer) and must outlive `materializeRubyFormula`. `pub` so
/// `tests/install_download_only_test.zig` can drive the materialise
/// path with a fabricated payload (cache-hit fixtures, ndjson event
/// shape).
pub const ResolvedRubyFormula = struct {
    /// Short formula name — becomes the Cellar dir, bin basename, and
    /// `kegs.name` column.
    name: []const u8,
    /// Full origin identifier stored in `kegs.full_name`. Tap slugs
    /// carry the `user/repo/formula` form; local installs carry the
    /// realpath so `mt list` shows where the `.rb` came from.
    full_name: []const u8,
    /// Label for the `kegs.tap` column and, optionally, `tap_mod.add`.
    tap_label: []const u8,
    version: []const u8,
    /// Archive URL post `#{version}` interpolation.
    url: []const u8,
    sha256: []const u8,
    /// Cask DSL `binary "<x>"` override. Set when the archive's
    /// top-level executable does not match `name` (e.g. the
    /// `longbridge-terminal` cask ships a `longbridge` binary). Null
    /// for formulas and for casks that omit the directive.
    binary_name: ?[]const u8 = null,
    /// Cask DSL `app "<x>.app"` directive. Disambiguates `.zip` casks
    /// (which ship a bundle) from formula bottles (which ship a binary
    /// tree). Null for formulas and for casks that omit the directive.
    app_name: ?[]const u8 = null,
    /// When set, the tap is registered in the DB (mirrors the original
    /// tap install behaviour). Local installs leave this null so they
    /// never pollute the tap list.
    tap_registration: ?TapRegistration = null,
};

const TapRegistration = struct {
    url: []const u8,
    commit_sha: []const u8,
    /// GitHub ETag for `/commits/HEAD` captured during cold-start
    /// resolve. Persisted alongside `commit_sha` so the next resolve
    /// sends `If-None-Match` and lets stable taps 304 free. Null on
    /// the warm path (cached SHA hit, no resolve needed) and when
    /// the server omitted the header.
    head_etag: ?[]const u8 = null,
};

/// Archive container formats the tap/local install path extracts.
/// `tar_gz` collapses `.tar.gz` and `.tgz` URLs into the same
/// extractor — the variant names match the `archive_mod.extract*`
/// functions called by `materializeRubyFormula`.
const TapArchiveKind = enum {
    tar_gz,
    tar_xz,
    zip,

    /// Canonical suffix used when staging the downloaded archive on
    /// disk. The `.tgz` alias is accepted on input via `fromUrl` but
    /// the staged file always carries `.tar.gz` so a stray inspection
    /// (or the `defer deleteFile`) finds a predictable name.
    fn extension(self: TapArchiveKind) []const u8 {
        return switch (self) {
            .tar_gz => ".tar.gz",
            .tar_xz => ".tar.xz",
            .zip => ".zip",
        };
    }

    /// Classify a tap URL by suffix. Returns null for any extension
    /// the tap installer does not extract — the caller surfaces an
    /// "unsupported archive format" error to the user.
    fn fromUrl(url: []const u8) ?TapArchiveKind {
        for (tap_archive_suffixes) |row| {
            if (std.mem.endsWith(u8, url, row.suffix)) return row.kind;
        }
        return null;
    }
};

/// Extractor-dispatch table for the tap/local archive flow. The parser
/// keeps its own version-stripping list in `rb_parse.zig` so a new
/// format requires updating both — the duplication is intentional:
/// each table represents a different concern.
const tap_archive_suffixes = [_]struct {
    suffix: []const u8,
    kind: TapArchiveKind,
}{
    .{ .suffix = ".tar.gz", .kind = .tar_gz },
    .{ .suffix = ".tgz", .kind = .tar_gz },
    .{ .suffix = ".tar.xz", .kind = .tar_xz },
    .{ .suffix = ".zip", .kind = .zip },
};

/// Selects which subdirectory of the tap the installer probes for the
/// `.rb` file. `.formula_or_cask` (the default for `mt install`) tries
/// `Formula/` first and falls back to `Casks/`; `.cask_only` skips the
/// Formula/ probe entirely.
///
/// `.cask_only` exists because the formula branch of
/// `materializeRubyFormula` opens its own DB transaction. Callers
/// holding an open transaction (currently `upgradeRoutedTapCask`)
/// would deadlock if a Formula/ probe accidentally resolved 200 — for
/// example, on a tap that ships both `Formula/<name>.rb` and
/// `Casks/<name>.rb` for the same token. The flag pins the resolver
/// to the cask subdirectory so that branch is structurally
/// unreachable.
const TapResolveKind = enum {
    formula_or_cask,
    cask_only,
};

/// Install a tap formula or cask. Probes `Formula/<name>.rb` first and
/// falls back to `Casks/<name>.rb` so a single entry point covers both
/// shapes — the `mt install <user>/<repo>/<name>` form the user types.
pub fn installTapFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    download_only: bool,
    sink: OutputSink,
) !void {
    return installTapRb(ctx, allocator, pkg_name, db, linker, prefix, dry_run, force, download_only, .formula_or_cask, sink);
}

/// Install a tap cask whose owning tap is already known. Skips the
/// `Formula/` probe — safe to call from inside an open DB transaction
/// because the formula branch of `materializeRubyFormula` (which
/// begins its own transaction) is structurally unreachable. Upgrade
/// callers never opt into `download_only`, so the legacy false is
/// hard-wired here rather than forwarded.
pub fn installTapCask(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    sink: OutputSink,
) !void {
    return installTapRb(ctx, allocator, pkg_name, db, linker, prefix, dry_run, force, false, .cask_only, sink);
}

fn installTapRb(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    download_only: bool,
    kind: TapResolveKind,
    sink: OutputSink,
) !void {
    const parts = args.parseTapName(pkg_name) orelse {
        sink.err("Invalid tap formula format: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    sink.info("Resolving tap {s}/{s}/{s}...", .{ parts.user, parts.repo, parts.formula });

    // Determine the commit SHA to fetch against. Prefer the pin
    // already in the DB (set at tap-add or last --refresh); if no pin
    // exists yet, resolve HEAD once and record it below. Refuses to
    // build a URL from a floating HEAD at install time.
    var tap_slug_buf: [128]u8 = undefined;
    const tap_slug = std.fmt.bufPrint(&tap_slug_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch
        return InstallError.FormulaNotFound;

    const urls = try tap_mod.resolveTapBaseUrls(allocator, db, tap_slug);
    defer urls.deinit(allocator);

    // Cold-start: pass null for cached_etag (no pin → no etag either);
    // warm-start: skip resolve entirely. The etag captured here is
    // forwarded into TapRegistration so the persist step at the bottom
    // of materializeRubyFormula writes both fields atomically.
    var fresh_head_etag: ?[]const u8 = null;
    defer if (fresh_head_etag) |e| allocator.free(e);
    const commit_sha = blk: {
        if ((tap_mod.getCommitSha(allocator, db, tap_slug) catch null)) |cached| {
            break :blk cached;
        }
        var rerr_buf: [512]u8 = undefined;
        var head_res = tap_mod.resolveHeadCommit(ctx.io, ctx.environ, allocator, urls.forge, urls.api_head_url, null) catch |e| {
            sink.err("Could not resolve {s}'s HEAD commit: {s}", .{ tap_slug, tap_mod.describeResolveError(&rerr_buf, e, urls.forge, urls.host) });
            return mapTapResolveError(e);
        };
        defer head_res.deinit();
        const sha = head_res.sha orelse {
            sink.err("Could not resolve {s}'s HEAD commit: empty response", .{tap_slug});
            return InstallError.FormulaNotFound;
        };
        const sha_owned = try allocator.dupe(u8, sha);
        if (head_res.etag) |e| fresh_head_etag = try allocator.dupe(u8, e);
        break :blk sha_owned;
    };
    defer allocator.free(commit_sha);

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;

    // First probe: Formula/ for the default mode, Casks/ when the
    // caller has pinned the resolve to cask-only.
    const initial_kind: forge.RawKind = switch (kind) {
        .formula_or_cask => .formula,
        .cask_only => .cask,
    };
    var url_buf: [512]u8 = undefined;
    const rb_url = forge.rawFileUrl(
        &url_buf,
        urls.forge,
        urls.raw_base,
        commit_sha,
        initial_kind,
        parts.formula,
    ) catch return InstallError.FormulaNotFound;

    var rb_resp = tap_mod.getRawFile(&http, ctx.environ, urls.forge, rb_url) catch {
        sink.err("Cannot fetch tap from GitHub", .{});
        return InstallError.FormulaNotFound;
    };
    defer rb_resp.deinit();

    // Distinct handles for the Casks/ and root-layout retries: each
    // fetch pairs with its own defer, so a future reorder cannot turn
    // the previous single-`resp` reuse into a double-free or
    // use-after-free.
    var cask_resp: ?client_mod.Response = null;
    defer if (cask_resp) |*c| c.deinit();
    var root_resp: ?client_mod.Response = null;
    defer if (root_resp) |*r| r.deinit();

    const resp: *const client_mod.Response = blk: {
        if (rb_resp.status == 200) break :blk &rb_resp;
        // `.cask_only` already probed Casks/ — there is no fallback to
        // try, and the downstream `resp.status != 200` check surfaces
        // the not-found error.
        if (kind == .cask_only) break :blk &rb_resp;

        const cask_url = forge.rawFileUrl(
            &url_buf,
            urls.forge,
            urls.raw_base,
            commit_sha,
            .cask,
            parts.formula,
        ) catch return InstallError.FormulaNotFound;

        cask_resp = tap_mod.getRawFile(&http, ctx.environ, urls.forge, cask_url) catch {
            sink.err("Cannot fetch tap from GitHub", .{});
            return InstallError.FormulaNotFound;
        };
        if (cask_resp.?.status == 200) break :blk &cask_resp.?;

        // Last resort: the older Homebrew layout keeps `<name>.rb` at the
        // repo root (koekeishiya/felixkratz taps). Only reached on the
        // double-miss path, so the common Formula/ install pays no extra GET.
        const root_url = forge.rawFileUrl(
            &url_buf,
            urls.forge,
            urls.raw_base,
            commit_sha,
            .formula_root,
            parts.formula,
        ) catch return InstallError.FormulaNotFound;

        root_resp = tap_mod.getRawFile(&http, ctx.environ, urls.forge, root_url) catch {
            sink.err("Cannot fetch tap from GitHub", .{});
            return InstallError.FormulaNotFound;
        };
        break :blk &root_resp.?;
    };

    if (resp.status != 200) {
        sink.err("Tap formula/cask not found: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    }

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(resp.body) orelse {
        sink.err("Cannot parse tap formula (unsupported Ruby DSL shape). Use: brew install {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    // Substitute #{version} and #{arch} so the SHA-verified fetch
    // hits the right per-platform asset.
    var final_url_buf: [512]u8 = undefined;
    const final_url = args.interpolateUrl(&final_url_buf, rb.url, rb.version, rb.arch_token);

    const resolved = ResolvedRubyFormula{
        .name = parts.formula,
        .full_name = pkg_name,
        .tap_label = tap_slug,
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        .binary_name = parseCaskBinary(resp.body),
        .app_name = parseCaskApp(resp.body),
        .tap_registration = .{
            .url = urls.repo_url,
            .commit_sha = commit_sha,
            .head_etag = fresh_head_etag,
        },
    };
    try materializeRubyFormula(ctx, allocator, resolved, &http, db, linker, prefix, dry_run, force, download_only, sink);
}

/// Install a formula from a local `.rb` file on disk. Gated by the
/// explicit `--local` flag (or autodetection with warning). Reads the
/// file once with a size cap so a hostile symlink cannot force an
/// unbounded read, parses via the same `parseRubyFormula` the tap path
/// uses, and then hands off to the shared materialize helper.
///
/// `pkg_arg` is the argument as typed (possibly relative, possibly with
/// `~/`); the canonical realpath used for messages and DB storage is
/// derived inside the function.
pub fn installLocalFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    pkg_arg: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    sink: OutputSink,
) InstallError!void {
    // Expand a leading `~/` to `$HOME` so the common "drop it in
    // your dotfiles" path works without requiring shell expansion.
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const expanded = args.expandTildePath(ctx, &home_buf, pkg_arg) orelse {
        sink.err("Cannot resolve home directory for '{s}'", .{pkg_arg});
        return InstallError.LocalFormulaNotReadable;
    };

    // Canonicalise once via open+F_GETPATH. This both checks the file
    // exists AND gives us a symlink-free absolute path for audit
    // messages and the kegs row — defeating the "relative path in a
    // shared Brewfile" footgun.
    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_n = if (std.fs.path.isAbsolute(expanded))
        std.Io.Dir.realPathFileAbsolute(ctx.io, expanded, &real_buf) catch {
            sink.err("Cannot open local formula: {s}", .{pkg_arg});
            return InstallError.LocalFormulaNotReadable;
        }
    else
        std.Io.Dir.cwd().realPathFile(ctx.io, expanded, &real_buf) catch {
            sink.err("Cannot open local formula: {s}", .{pkg_arg});
            return InstallError.LocalFormulaNotReadable;
        };
    const realpath = real_buf[0..real_n];

    // Security warning on every install — the `.rb` is a code-execution
    // vector (parse is pure, but post_install + the archive URL trust
    // this file). Printing the realpath surfaces hidden /tmp or
    // world-writable locations to an attentive reader.
    sink.warn("Installing from local file '{s}'. Only install .rb files you trust.", .{realpath});

    // Reject non-regular files outright (directory, socket, device)
    // before allocating a read buffer.
    const f = std.Io.Dir.openFileAbsolute(ctx.io, realpath, .{ .mode = .read_only }) catch {
        sink.err("Cannot open local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer f.close(ctx.io);
    const st = f.stat(ctx.io) catch {
        sink.err("Cannot stat local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    if (st.kind != .file) {
        sink.err("Local formula is not a regular file: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    if (st.size > max_local_formula_bytes) {
        sink.err("Local formula exceeds {d}-byte read cap: {s}", .{ max_local_formula_bytes, realpath });
        return InstallError.LocalFormulaNotReadable;
    }

    // Advisory: warn if the file is world-writable or owned by a
    // different user. `--local` is already the trust gate so we don't
    // block — but we make the risk visible on the same line style as
    // the primary security warning.
    if (fstatRisk(f)) |risk| switch (risk) {
        .world_writable => sink.warn("Local formula is world-writable — any local user could rewrite it between reads.", .{}),
        .other_owner => sink.warn("Local formula is not owned by you — another account wrote this file.", .{}),
    };

    const size: usize = @intCast(@min(@as(u64, max_local_formula_bytes), st.size));
    const body_buf = allocator.alloc(u8, size) catch {
        sink.err("Cannot read local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    const n = f.readPositionalAll(ctx.io, body_buf, 0) catch {
        allocator.free(body_buf);
        sink.err("Cannot read local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    const body = if (n == body_buf.len) body_buf else allocator.realloc(body_buf, n) catch {
        allocator.free(body_buf);
        sink.err("Cannot read local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer allocator.free(body);

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(body) orelse {
        sink.err("Cannot parse local formula (missing version/url/sha256 or unsupported DSL shape): {s}", .{realpath});
        return InstallError.FormulaNotFound;
    };

    // Formula name comes from the basename minus `.rb` — mirrors
    // Homebrew's convention where `wget.rb` installs `wget`. This is
    // the canonical surface for the cellar path, bin name, and DB row.
    const base = std.fs.path.basename(realpath);
    if (!std.mem.endsWith(u8, base, ".rb") or base.len <= 3) {
        sink.err("Local formula must end in .rb: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    const name = base[0 .. base.len - 3];

    var final_url_buf: [512]u8 = undefined;
    const final_url = args.interpolateUrl(&final_url_buf, rb.url, rb.version, rb.arch_token);

    const resolved = ResolvedRubyFormula{
        .name = name,
        .full_name = realpath,
        .tap_label = "local",
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        // No tap_registration — never pollute `mt tap` with a local path.
    };

    var http = client_mod.HttpClient.init(ctx.io, ctx.environ, allocator);
    defer http.deinit();
    http.offline = ctx.offline;
    // `--local` is out of scope for `--download-only`: the user already
    // holds the archive on disk so warming a tap-cache entry adds no
    // value. Hard-wire false here rather than threading the flag.
    try materializeRubyFormula(ctx, allocator, resolved, &http, db, linker, prefix, dry_run, force, false, sink);
}

/// Ordered set of advisory risk labels that may fire on a `.rb` file
/// the user asked to install. `world_writable` dominates `other_owner`
/// because any local account can win the TOCTOU race while only the
/// owner can edit a 0o644 file. Pure enum — no allocation, trivially
/// table-testable (see `describeLocalPermissionRisk`).
pub const LocalPermissionRisk = enum { world_writable, other_owner };

/// Classify a local formula's filesystem metadata into at most one
/// advisory risk label. Returns null when the file is plausibly safe
/// (owned by the effective user and not world-writable). The caller
/// uses the result to emit a single extra `⚠` line — never to block
/// the install, since `--local` is itself the explicit trust decision.
pub fn describeLocalPermissionRisk(mode: u32, file_uid: u32, effective_uid: u32) ?LocalPermissionRisk {
    if (mode & 0o002 != 0) return .world_writable;
    if (file_uid != effective_uid) return .other_owner;
    return null;
}

/// Thin wrapper that pulls raw POSIX `st_mode`/`st_uid` from the
/// already-opened handle and routes them through the pure predicate.
/// `Stat` in `std.Io` doesn't surface uid or mode bits directly, so a
/// libc `fstat(2)` is the path of least resistance on macOS.
fn fstatRisk(f: std.Io.File) ?LocalPermissionRisk {
    var raw: std.c.Stat = undefined;
    if (std.c.fstat(f.handle, &raw) != 0) return null;
    const effective = std.c.geteuid();
    return describeLocalPermissionRisk(@intCast(raw.mode), @intCast(raw.uid), @intCast(effective));
}

/// Compose the staging-archive path used by the tap/local install
/// flow. The pid suffix prevents two concurrent invocations from
/// racing on a shared `tap_download.<ext>` filename — without it,
/// one install would overwrite the other's in-flight download.
pub fn formatTapDownloadName(
    buf: []u8,
    prefix: []const u8,
    ext: []const u8,
    pid: i32,
) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/tmp/tap_download.{d}{s}", .{ prefix, pid, ext });
}

/// Shared "from parsed `.rb` to linked keg" path, used by the tap and
/// local installers. Does the network fetch for the archive, SHA256
/// verification, cellar materialisation, and DB + linker commit.
/// `pub` so the integration tests can drive the materialise flow with
/// a fabricated `ResolvedRubyFormula` (cache-hit fixtures, ndjson
/// shape) without standing up a tap-resolution stub.
pub fn materializeRubyFormula(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    resolved: ResolvedRubyFormula,
    http: *client_mod.HttpClient,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
    download_only: bool,
    sink: OutputSink,
) InstallError!void {
    sink.info("Found {s} {s}", .{ resolved.name, resolved.version });

    // Refuse any scheme other than `https://`. A `.rb` that smuggled
    // `http://` (downgrade), `file:///etc/passwd`, `ftp://`, or a data
    // URI would otherwise be trusted by the HTTP client. Enforced for
    // every caller of this helper — tap and local share the check.
    if (!args.isAllowedArchiveUrl(resolved.url)) {
        sink.err("Refusing to fetch non-HTTPS archive URL for {s}: {s}", .{ resolved.name, resolved.url });
        return InstallError.InsecureArchiveUrl;
    }

    // .dmg/.pkg/.zip-with-app casks route through the cask installer —
    // mounting, ditto, and `installer` live there. Tar.gz/tar.xz/zip
    // formula archives keep the simple-extract path below.
    if (tapCaskArtifactKind(resolved.url, resolved.app_name != null)) |kind| {
        return materializeTapCask(ctx, allocator, resolved, db, kind, dry_run, force, download_only, sink);
    }

    if (dry_run) {
        sink.info("Dry run: would install {s} {s} from {s}", .{ resolved.name, resolved.version, resolved.url });
        return;
    }

    // `--download-only` deliberately skips `isInstalled`: a warm
    // request must refresh the cache regardless of install state.
    if (!download_only and !force and record.isInstalled(db, resolved.name)) {
        sink.info("{s} is already installed", .{resolved.name});
        return;
    }

    // Pick the archive kind early so the cache-or-fetch step below
    // can compose `<prefix>/cache/Tap/<sha>.<ext>` before any HTTP
    // work. Unknown formats fail fast — no point fetching bytes we
    // can't extract.
    const archive_kind = TapArchiveKind.fromUrl(resolved.url) orelse {
        sink.err("Unsupported archive format for {s}: {s}", .{ resolved.name, resolved.url });
        sink.err("Supported formats: .tar.gz, .tar.xz, .zip.", .{});
        return InstallError.DownloadFailed;
    };
    const archive_ext = archive_kind.extension();

    // Same ndjson event shape as the bottle + cask paths so CI
    // pipelines see one event vocabulary across the dispatcher.
    if (download_only) output.emitNdjsonEvent(.download_started, resolved.name, null);
    // Errdefer guarantees a paired `download_complete` even on the
    // error paths below; the success branch sets the flag first so we
    // never double-fire.
    var dl_complete_emitted = false;
    errdefer if (download_only and !dl_complete_emitted) {
        output.emitNdjsonEvent(.download_complete, resolved.name, "failed");
    };

    // Prefer the persistent cache; fall back to a network fetch that
    // publishes via atomic rename. Either branch yields `cache_path`
    // as the on-disk source the extractor reads from below.
    var cache_path_buf: [512]u8 = undefined;
    const cache_path = blk: {
        if (tap_cache.exists(ctx.io, prefix, resolved.sha256, archive_ext)) {
            // Warm cache: skip the fetch. SHA-keyed filename is its
            // own verification — a follow-up install of the same
            // formula consumes the warmed bytes instead of refetching.
            break :blk tap_cache.cachePath(&cache_path_buf, prefix, resolved.sha256, archive_ext) catch
                return InstallError.DownloadFailed;
        }

        // Cold cache: stream the archive into pid-suffixed staging,
        // SHA-verify the in-memory body, then atomic-rename to the
        // permanent cache path. A crash mid-write leaves only the
        // staging file (which `mt doctor --fix` and the tap-tmp
        // cleanup regression already reclaim).
        // A non-terminal sink (bundle) skips the bar — the global progress
        // mode is set-once and can't be quieted mid-run. Rendered as a
        // one-line group so it disables autowrap and restores on exit.
        var sp: ?progress_mod.SingleBar = if (sink.show_progress) progress_mod.SingleBar.init(resolved.name, 0) else null;
        defer if (sp) |*s| s.finish();
        const bar_cb: ?client_mod.ProgressCallback = if (sp) |*s|
            .{ .context = @ptrCast(s.bind()), .func = &download.progressBridge }
        else
            null;
        var download_resp = http.getWithHeaders(resolved.url, &.{}, bar_cb) catch {
            if (sp) |*s| s.bar.finish();
            sink.err("Failed to download {s}", .{resolved.name});
            return InstallError.DownloadFailed;
        };
        defer download_resp.deinit();
        if (sp) |*s| s.bar.finish();

        if (download_resp.status != 200) {
            sink.err("Download failed with status {d}", .{download_resp.status});
            return InstallError.DownloadFailed;
        }

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(download_resp.body, &digest, .{});
        var hex_buf: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hex_buf[i * 2] = hex_chars[b >> 4];
            hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        const computed: []const u8 = &hex_buf;

        // Constant-time compare on the SHA256: a stock `mem.eql`
        // leaks per-byte progress via timing, giving an adaptive
        // attacker a byte-by-byte oracle against the expected hash.
        if (!hash.constantTimeEql(u8, computed, resolved.sha256)) {
            sink.err("SHA256 mismatch for {s}", .{resolved.name});
            return InstallError.DownloadFailed;
        }

        var tmp_buf: [512]u8 = undefined;
        const tmp_archive = formatTapDownloadName(&tmp_buf, prefix, archive_ext, std.c.getpid()) catch
            return InstallError.DownloadFailed;

        const tmp_file = std.Io.Dir.createFileAbsolute(ctx.io, tmp_archive, .{}) catch return InstallError.DownloadFailed;
        tmp_file.writeStreamingAll(ctx.io, download_resp.body) catch {
            tmp_file.close(ctx.io);
            std.Io.Dir.cwd().deleteFile(ctx.io, tmp_archive) catch {};
            return InstallError.DownloadFailed;
        };
        tmp_file.close(ctx.io);
        // promoteStagingToCache succeeds → tmp_archive no longer
        // exists at its source path. On failure we still wipe it so
        // the next run's pid collision space stays clean.
        errdefer std.Io.Dir.cwd().deleteFile(ctx.io, tmp_archive) catch {};
        break :blk tap_cache.promoteStagingToCache(
            ctx.io,
            prefix,
            resolved.sha256,
            archive_ext,
            tmp_archive,
            &cache_path_buf,
        ) catch return InstallError.DownloadFailed;
    };

    // `--download-only` stops once the cache holds the SHA-verified
    // bytes — no Cellar writes, no DB inserts. A follow-up
    // `mt install` consumes the warmed entry above.
    if (download_only) {
        output.emitNdjsonEvent(.download_complete, resolved.name, "ok");
        dl_complete_emitted = true;
        sink.success("{s} {s} downloaded to {s}", .{ resolved.name, resolved.version, cache_path });
        return;
    }

    // Extract to Cellar directly (tap-style binaries are simple archives).
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, resolved.name, resolved.version }) catch
        return InstallError.CellarFailed;

    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, resolved.name }) catch
        return InstallError.CellarFailed;
    std.Io.Dir.createDirAbsolute(ctx.io, parent, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };
    // `--force` pre-materialize: wipe the resolved-version dir so the
    // archive extracts into a clean target. Without this, extract
    // mixes new and prior files at the same paths, and the post-link
    // sweep would only address symlinks + DB rows. Matches the JSON
    // pipeline's pre-materialize call.
    if (force) {
        install_mod.pruneCellarForReinstall(ctx, prefix, resolved.name, resolved.version);
    }
    std.Io.Dir.createDirAbsolute(ctx.io, cellar_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    var bin_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{cellar_path}) catch
        return InstallError.CellarFailed;
    std.Io.Dir.createDirAbsolute(ctx.io, bin_path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    const archive_mod = @import("../../fs/archive.zig");
    switch (archive_kind) {
        .tar_gz => archive_mod.extractTarGz(ctx.io, cache_path, cellar_path) catch {
            sink.err("Failed to extract archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .tar_xz => archive_mod.extractTarXzFile(ctx.io, cache_path, cellar_path) catch {
            sink.err("Failed to extract .tar.xz archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .zip => archive_mod.extractZip(ctx.io, cache_path, cellar_path) catch {
            sink.err("Failed to extract .zip archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
    }

    // Promote the binary to bin/ (GoReleaser may extract directly or
    // into a subdirectory — walk to handle both). For casks that
    // declare `binary "<x>"`, the archive file is named `<x>` while
    // the keg is named by the cask token; match on the declared
    // binary so a tap cask like `longbridge-terminal` lands its
    // `longbridge` executable.
    const target_binary = resolved.binary_name orelse resolved.name;
    {
        var cellar_dir = std.Io.Dir.openDirAbsolute(ctx.io, cellar_path, .{ .iterate = true }) catch return InstallError.CellarFailed;
        defer cellar_dir.close(ctx.io);

        var walker = cellar_dir.walk(allocator) catch return InstallError.CellarFailed;
        defer walker.deinit();

        // Separate buffer: writing into `tmp_buf` here would corrupt the
        // `tmp_archive` slice that the deferred cleanup still holds.
        var dest_buf: [512]u8 = undefined;
        while (walker.next(ctx.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const basename = std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, basename, target_binary)) {
                const dest_name = std.fmt.bufPrint(&dest_buf, "bin/{s}", .{basename}) catch continue;
                std.Io.Dir.copyFile(cellar_dir, entry.path, cellar_dir, dest_name, ctx.io, .{}) catch continue;
                const bin_file = cellar_dir.openFile(ctx.io, dest_name, .{ .mode = .read_write }) catch continue;
                defer bin_file.close(ctx.io);
                // chmod may fail on FUSE/NFS; linker still resolves the path.
                bin_file.setPermissions(ctx.io, std.Io.File.Permissions.fromMode(0o755)) catch {};
                break;
            }
        }
    }

    sink.info("Linking {s}...", .{resolved.name});

    // Single DB transaction: keg row → optional tap registration →
    // linker work → commit. `errdefer rollback` unwinds cleanly if any
    // step fails before commit.
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    // `--force` pre-link: clear every same-name prior install's
    // symlinks so the upcoming linker.link does not collide. Rows
    // + dependencies stay so the recordKeg INSERT OR REPLACE below
    // can inherit the user pin from any stale row via COALESCE-MAX.
    if (force) {
        install_mod.unlinkSameVersionKegLinks(linker, db, resolved.name, cellar_path);
        install_mod.unlinkStaleKegLinks(db, linker, resolved.name, cellar_path);
    }

    var keg_id: i64 = 0;
    {
        // The COALESCE on `pinned` carries any existing user pin across
        // INSERT OR REPLACE so a force-reinstall preserves the hold.
        var stmt = db.prepare(
            "INSERT OR REPLACE INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason, pinned)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'direct', COALESCE((SELECT MAX(pinned) FROM kegs WHERE name = ?1), 0));",
        ) catch return InstallError.RecordFailed;
        defer stmt.finalize();
        stmt.bindText(1, resolved.name) catch return InstallError.RecordFailed;
        stmt.bindText(2, resolved.full_name) catch return InstallError.RecordFailed;
        stmt.bindText(3, resolved.version) catch return InstallError.RecordFailed;
        stmt.bindText(4, resolved.tap_label) catch return InstallError.RecordFailed;
        stmt.bindText(5, resolved.sha256) catch return InstallError.RecordFailed;
        stmt.bindText(6, cellar_path) catch return InstallError.RecordFailed;
        _ = stmt.step() catch return InstallError.RecordFailed;

        keg_id = record.getLastInsertId(db) catch return InstallError.RecordFailed;

        if (resolved.tap_registration) |t| {
            // `COALESCE` in tap_mod.add pins the commit on first install
            // and leaves later pins untouched. Tap row is advisory — keg
            // is already recorded; a missing tap row self-heals next sync.
            // (owner, repo) routes through `effectiveOwnerRepo` so the
            // synthesis used at fetch time and at persist time can't drift.
            if (tap_mod.effectiveOwnerRepo(allocator, db, resolved.tap_label, "github.com")) |pair| {
                defer pair.deinit(allocator);
                tap_mod.add(db, resolved.tap_label, pair.owner, pair.repo, t.commit_sha) catch {};
                if (t.head_etag) |et| tap_mod.updateHead(db, resolved.tap_label, t.commit_sha, et) catch {};
            } else |_| {}
        }
    }

    linker.link(cellar_path, resolved.name, keg_id, false) catch {
        sink.warn("Some links for {s} could not be created", .{resolved.name});
    };
    linker.linkOpt(resolved.name, resolved.version) catch {
        sink.warn("Could not create opt link for {s}", .{resolved.name});
    };

    // `--force` post-link: the new row is recorded and the pin (if
    // any) is inherited; safe to drop the prior other-version rows
    // and their dirs. Disk safety net catches any cellar dir without
    // a row.
    if (force) {
        install_mod.dropStaleKegRows(ctx, allocator, db, resolved.name, cellar_path);
        install_mod.pruneOtherCellarVersionsForReinstall(ctx, allocator, prefix, resolved.name, resolved.version);
    }

    db.commit() catch return InstallError.RecordFailed;

    sink.success("{s} {s} installed", .{ resolved.name, resolved.version });
}

/// Hand a tap cask off to the shared `core/cask.zig` installer by
/// minting a Homebrew-API-shaped JSON document from the parsed Ruby
/// directives. Reuses every download/SHA/extract path the brew-API
/// cask flow already exercises — the only thing the tap path adds is
/// the JSON adapter. When `download_only` is set, the cask installer's
/// `downloadOnly` seam reuses the existing `<prefix>/cache/Cask/`
/// layout established by T-028 instead of writing to `cache/Tap/`.
fn materializeTapCask(
    ctx: *const AppCtx,
    allocator: std.mem.Allocator,
    resolved: ResolvedRubyFormula,
    db: *sqlite.Database,
    kind: cask_mod.ArtifactType,
    dry_run: bool,
    force: bool,
    download_only: bool,
    sink: OutputSink,
) InstallError!void {
    // `--download-only` deliberately ignores `isInstalled` so a user
    // can refresh the cached artefact ahead of an `mt upgrade` even
    // when an older revision is on disk. The regular install path
    // keeps the "already installed" short-circuit.
    if (!download_only and !force and cask_mod.isInstalled(db, resolved.name)) {
        sink.info("{s} is already installed", .{resolved.name});
        return;
    }

    if (dry_run) {
        sink.info("Dry run: would install cask {s} {s} from {s}", .{ resolved.name, resolved.version, resolved.url });
        return;
    }

    // Sentinel-terminated copy of the active prefix; the cask installer
    // expects [:0]const u8 because it threads the value into bufPrint
    // formats that share the buffer with C-string consumers.
    const prefix_z = atomic.maltPrefixOrAbort();

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);
    buildSyntheticCaskJson(allocator, &json_buf, resolved) catch return InstallError.RecordFailed;

    var cask = cask_mod.parseCask(allocator, json_buf.items) catch {
        sink.err("Failed to materialise cask {s} from tap DSL", .{resolved.name});
        return InstallError.CaskNotFound;
    };
    defer cask.deinit();

    var installer = cask_mod.CaskInstaller.init(ctx.io, ctx.environ, allocator, db, prefix_z);
    installer.artifact_type_override = kind;
    installer.offline = ctx.offline;

    // A non-terminal sink (bundle) skips the bar — the global progress
    // mode is set-once and can't be quieted mid-run. Rendered as a
    // one-line group so it disables autowrap and restores on exit.
    var sp: ?progress_mod.SingleBar = if (sink.show_progress) progress_mod.SingleBar.init(cask.token, 0) else null;
    defer if (sp) |*s| s.finish();
    if (sp) |*s| {
        installer.progress = .{
            .context = @ptrCast(s.bind()),
            .func = &download.progressBridge,
        };
    }

    if (kind == .pkg) {
        sink.warn("{s} is a PKG cask and requires sudo to install via macOS Installer.", .{cask.token});
    }

    // `--download-only` for a cask-shaped tap entry reuses the cask
    // cache established by T-028 (`<prefix>/cache/Cask/`). The shared
    // `downloadOnly` seam handles sha-verify against the archive
    // bytes; we stop before /Applications writes and DB inserts.
    if (download_only) {
        output.emitNdjsonEvent(.download_started, cask.token, null);
        const cache_path = installer.downloadOnly(&cask) catch |e| {
            if (sp) |*s| s.bar.finish();
            output.emitNdjsonEvent(.download_complete, cask.token, "failed");
            sink.err("Failed to download cask {s}: {s}", .{ cask.token, @errorName(e) });
            return switch (e) {
                error.DownloadFailed, error.Sha256Mismatch => InstallError.DownloadFailed,
                error.OutOfMemory => InstallError.RecordFailed,
                else => InstallError.CaskNotFound,
            };
        };
        if (sp) |*s| s.bar.finish();
        defer allocator.free(cache_path);
        output.emitNdjsonEvent(.download_complete, cask.token, "ok");
        sink.success("{s} {s} downloaded to {s}", .{ cask.token, cask.version, cache_path });
        return;
    }

    const app_path = installer.install(&cask) catch |e| {
        if (sp) |*s| s.bar.finish();
        sink.err("Failed to install cask {s}: {s}", .{ cask.token, @errorName(e) });
        return switch (e) {
            error.DownloadFailed, error.Sha256Mismatch => InstallError.DownloadFailed,
            error.OutOfMemory => InstallError.RecordFailed,
            else => InstallError.CaskNotFound,
        };
    };
    if (sp) |*s| s.bar.finish();
    defer allocator.free(app_path);

    // `try` is the invariant: success line never fires without a row.
    try finalizeTapCaskInstall(allocator, db, &cask, app_path, resolved.tap_label, resolved.tap_registration, sink);

    sink.success("{s} {s} installed", .{ cask.token, cask.version });
}

/// Serialize a Homebrew-cask-API-shaped JSON document so the existing
/// `parseCask` + `CaskInstaller` pipeline can consume a tap-DSL cask.
/// `app` wins over `binary` when both directives appear because the
/// `.app` bundle is what `installDmg`/`installZip` look up first.
fn buildSyntheticCaskJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    resolved: ResolvedRubyFormula,
) !void {
    try out.appendSlice(allocator, "{\"token\":");
    try writeJsonString(allocator, out, resolved.name);
    try out.appendSlice(allocator, ",\"name\":[");
    try writeJsonString(allocator, out, resolved.name);
    try out.appendSlice(allocator, "],\"version\":");
    try writeJsonString(allocator, out, resolved.version);
    try out.appendSlice(allocator, ",\"url\":");
    try writeJsonString(allocator, out, resolved.url);
    try out.appendSlice(allocator, ",\"sha256\":");
    try writeJsonString(allocator, out, resolved.sha256);
    try out.appendSlice(allocator, ",\"desc\":\"\",\"homepage\":\"\",\"auto_updates\":false,\"artifacts\":[");
    if (resolved.app_name) |app| {
        try out.appendSlice(allocator, "{\"app\":[");
        try writeJsonString(allocator, out, app);
        try out.appendSlice(allocator, "]}");
    } else if (resolved.binary_name) |bin| {
        try out.appendSlice(allocator, "{\"binary\":[");
        try writeJsonString(allocator, out, bin);
        try out.appendSlice(allocator, "]}");
    }
    try out.appendSlice(allocator, "]}");
}

fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var hex_buf: [6]u8 = undefined;
                const seq = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                try out.appendSlice(allocator, seq);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

/// Map `tap_mod` resolve errors to specific `InstallError` tags so the
/// dispatch line ("Failed to install X: <tag>") names the cause —
/// `RateLimited` / `NetworkError` instead of collapsing every failure
/// to the misleading `FormulaNotFound`.
fn mapTapResolveError(e: tap_mod.TapError) InstallError {
    return switch (e) {
        error.RateLimited => InstallError.RateLimited,
        error.NetworkError => InstallError.NetworkError,
        error.NotFound,
        error.MalformedJson,
        error.InvalidSha,
        error.ResolveFailed,
        => InstallError.FormulaNotFound,
        error.OutOfMemory => InstallError.RecordFailed,
    };
}

/// Persist before print: any failure surfaces as `RecordFailed` so
/// the caller cannot print "installed" without a committed row. The
/// err wording is a public contract for `scripts/regressions/*.sh`.
fn finalizeTapCaskInstall(
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    cask: *const cask_mod.Cask,
    app_path: ?[]const u8,
    tap_label: []const u8,
    tap_registration: ?TapRegistration,
    sink: OutputSink,
) InstallError!void {
    cask_mod.recordInstall(db, cask, app_path, tap_label) catch {
        sink.err("failed to record installed cask {s}", .{cask.token});
        return InstallError.RecordFailed;
    };
    // Tap row + etag are advisory; the cask row is the install
    // source of truth and tap_mod state self-heals on next sync.
    // (owner, repo) routes through `effectiveOwnerRepo` so the
    // persisted pair matches the one fetched against.
    if (tap_registration) |t| {
        if (tap_mod.effectiveOwnerRepo(allocator, db, tap_label, "github.com")) |pair| {
            defer pair.deinit(allocator);
            tap_mod.add(db, tap_label, pair.owner, pair.repo, t.commit_sha) catch {};
            if (t.head_etag) |et| tap_mod.updateHead(db, tap_label, t.commit_sha, et) catch {};
        } else |_| {}
    }
}

test "formatTapDownloadName encodes pid + extension into tmp/ path" {
    var buf: [128]u8 = undefined;
    const got = try formatTapDownloadName(&buf, "/opt/h", ".tar.gz", 4242);
    try std.testing.expectEqualStrings("/opt/h/tmp/tap_download.4242.tar.gz", got);
}

test "formatTapDownloadName distinct pids produce distinct paths" {
    // Two concurrent `mt install <user>/<tap>/<formula>` invocations
    // must not race on a shared filename — the returned path carries
    // the live process id so each install streams into its own archive.
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const path_a = try formatTapDownloadName(&a, "/opt/h", ".zip", 1);
    const path_b = try formatTapDownloadName(&b, "/opt/h", ".zip", 2);
    try std.testing.expect(!std.mem.eql(u8, path_a, path_b));
}

test "formatTapDownloadName surfaces NoSpaceLeft instead of truncating" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, formatTapDownloadName(&buf, "/opt/h", ".tar.gz", 4242));
}

test "mapTapResolveError surfaces rate limit and network failure as their own tags" {
    // Bug repro: pre-fix every resolve error collapsed to FormulaNotFound,
    // so "Failed to install X: FormulaNotFound" told the user the wrong
    // story when the real cause was a 60/hr rate-limit or a flaky DNS.
    try std.testing.expectEqual(InstallError.RateLimited, mapTapResolveError(error.RateLimited));
    try std.testing.expectEqual(InstallError.NetworkError, mapTapResolveError(error.NetworkError));
}

test "mapTapResolveError keeps non-classified causes on FormulaNotFound" {
    try std.testing.expectEqual(InstallError.FormulaNotFound, mapTapResolveError(error.NotFound));
    try std.testing.expectEqual(InstallError.FormulaNotFound, mapTapResolveError(error.MalformedJson));
    try std.testing.expectEqual(InstallError.FormulaNotFound, mapTapResolveError(error.InvalidSha));
    try std.testing.expectEqual(InstallError.FormulaNotFound, mapTapResolveError(error.ResolveFailed));
}

test "mapTapResolveError handles every TapError tag" {
    // Comptime sweep: a future TapError addition without a switch arm
    // fails to compile here, surfacing the gap loudly.
    inline for (@typeInfo(tap_mod.TapError).error_set.?) |err| {
        const tag = @field(tap_mod.TapError, err.name);
        const mapped = mapTapResolveError(tag);
        try std.testing.expect(mapped == InstallError.RateLimited or
            mapped == InstallError.NetworkError or
            mapped == InstallError.FormulaNotFound or
            mapped == InstallError.RecordFailed);
    }
}

test "finalizeTapCaskInstall persists the cask row on the happy path" {
    // Guards against "always RecordFailed" or a recordInstall arg-swap
    // regression that the failure-mode test alone would not catch.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE casks (
        \\    id INTEGER PRIMARY KEY,
        \\    token TEXT NOT NULL UNIQUE,
        \\    name TEXT NOT NULL,
        \\    version TEXT NOT NULL,
        \\    url TEXT NOT NULL,
        \\    sha256 TEXT,
        \\    app_path TEXT,
        \\    auto_updates INTEGER NOT NULL DEFAULT 0,
        \\    pinned INTEGER NOT NULL DEFAULT 0,
        \\    tap TEXT
        \\);
    );

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(std.testing.allocator);
    try buildSyntheticCaskJson(std.testing.allocator, &json_buf, .{
        .name = "deckclip",
        .full_name = "yuzeguitarist/deck/deckclip",
        .tap_label = "yuzeguitarist/deck",
        .version = "1.4.5",
        .url = "https://example.com/Deck.dmg",
        .sha256 = "deadbeefcafe",
        .app_name = "Deck.app",
    });

    var cask = try cask_mod.parseCask(std.testing.allocator, json_buf.items);
    defer cask.deinit();

    try finalizeTapCaskInstall(std.testing.allocator, &db, &cask, "/tmp/Deck.app", "yuzeguitarist/deck", null, sink_mod.terminal);

    var stmt = try db.prepare("SELECT version, tap FROM casks WHERE token = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, "deckclip");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("1.4.5", std.mem.sliceTo(stmt.columnText(0) orelse "", 0));
    try std.testing.expectEqualStrings("yuzeguitarist/deck", std.mem.sliceTo(stmt.columnText(1) orelse "", 0));
}

test "finalizeTapCaskInstall stamps the owning tap when tap_registration is set" {
    // tap row + etag must persist so subsequent `mt upgrade` pre-routes
    // via `casks.tap` instead of probing every registered tap.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE casks (
        \\    id INTEGER PRIMARY KEY,
        \\    token TEXT NOT NULL UNIQUE,
        \\    name TEXT NOT NULL,
        \\    version TEXT NOT NULL,
        \\    url TEXT NOT NULL,
        \\    sha256 TEXT,
        \\    app_path TEXT,
        \\    auto_updates INTEGER NOT NULL DEFAULT 0,
        \\    pinned INTEGER NOT NULL DEFAULT 0,
        \\    tap TEXT
        \\);
    );
    try db.exec(
        \\CREATE TABLE taps (
        \\    name TEXT PRIMARY KEY,
        \\    url TEXT NOT NULL,
        \\    commit_sha TEXT,
        \\    head_etag TEXT,
        \\    github_owner TEXT NOT NULL DEFAULT '',
        \\    github_repo TEXT NOT NULL DEFAULT '',
        \\    host TEXT NOT NULL DEFAULT 'github.com',
        \\    forge TEXT
        \\);
    );

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(std.testing.allocator);
    try buildSyntheticCaskJson(std.testing.allocator, &json_buf, .{
        .name = "deckclip",
        .full_name = "yuzeguitarist/deck/deckclip",
        .tap_label = "yuzeguitarist/deck",
        .version = "1.4.5",
        .url = "https://example.com/Deck.dmg",
        .sha256 = "deadbeefcafe",
        .app_name = "Deck.app",
    });

    var cask = try cask_mod.parseCask(std.testing.allocator, json_buf.items);
    defer cask.deinit();

    // updateHead validates SHA shape; a short SHA silently skips etag.
    const sha = "0123456789abcdef0123456789abcdef01234567";
    try finalizeTapCaskInstall(std.testing.allocator, &db, &cask, "/tmp/Deck.app", "yuzeguitarist/deck", .{
        .url = "https://github.com/yuzeguitarist/homebrew-deck",
        .commit_sha = sha,
        .head_etag = "\"etag-abc\"",
    }, sink_mod.terminal);

    var stmt = try db.prepare("SELECT commit_sha, head_etag FROM taps WHERE name = ?1;");
    defer stmt.finalize();
    try stmt.bindText(1, "yuzeguitarist/deck");
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings(sha, std.mem.sliceTo(stmt.columnText(0) orelse "", 0));
    try std.testing.expectEqualStrings("\"etag-abc\"", std.mem.sliceTo(stmt.columnText(1) orelse "", 0));
}

test "finalizeTapCaskInstall fails loud when the cask DB row cannot persist" {
    // Reproduces the partial-success bug: persist failure must NOT
    // collapse to "installed" stdout + exit 0.
    var db = try sqlite.Database.open(":memory:");
    defer db.close();
    // No schema → recordInstall fails at prepare (no casks table).

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(std.testing.allocator);
    try buildSyntheticCaskJson(std.testing.allocator, &json_buf, .{
        .name = "deckclip",
        .full_name = "yuzeguitarist/deck/deckclip",
        .tap_label = "yuzeguitarist/deck",
        .version = "1.4.5",
        .url = "https://example.com/Deck.dmg",
        .sha256 = "deadbeefcafe",
        .app_name = "Deck.app",
    });

    var cask = try cask_mod.parseCask(std.testing.allocator, json_buf.items);
    defer cask.deinit();

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(std.testing.allocator);
    output.beginStderrCapture(std.testing.allocator, &captured);
    defer output.endStderrCapture();

    // Mirror the materializeTapCask call site shape. The terminal sink
    // forwards to `ui/output`, so the captured stderr below still sees
    // finalize's error line — proving the diagnostic survives the sink.
    var finalize_err: ?InstallError = null;
    finalizeTapCaskInstall(std.testing.allocator, &db, &cask, null, "yuzeguitarist/deck", null, sink_mod.terminal) catch |e| {
        finalize_err = e;
    };
    if (finalize_err == null) {
        output.success("{s} {s} installed", .{ cask.token, cask.version });
        return error.TestExpectedRecordFailed;
    }
    try std.testing.expectEqual(InstallError.RecordFailed, finalize_err.?);

    // Substring is the public contract for the regression skip-classifier.
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "failed to record installed cask") != null);
    // Success line must never fire on a failed persist.
    try std.testing.expect(std.mem.indexOf(u8, captured.items, "deckclip 1.4.5 installed") == null);
}
