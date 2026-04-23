//! Tap + local (`.rb`) formula install paths. Owns the Ruby formula
//! parser, the shared materialise pipeline, and the advisory permission
//! classifier. Split out of `cli/install.zig` so the GHCR bottle flow
//! does not recompile when this path changes.

const std = @import("std");
const fs_compat = @import("../../fs/compat.zig");
const sqlite = @import("../../db/sqlite.zig");
const linker_mod = @import("../../core/linker.zig");
const tap_mod = @import("../../core/tap.zig");
const client_mod = @import("../../net/client.zig");
const output = @import("../../ui/output.zig");
const progress_mod = @import("../../ui/progress.zig");

const args = @import("args.zig");
const record = @import("record.zig");
const download = @import("download.zig");

const InstallError = record.InstallError;

/// Maximum size of a `.rb` formula file that `malt install --local`
/// will read. Real Homebrew formulas top out well below this (the
/// current heaviest, `llvm.rb`, is ~60 KB). The cap bounds the single
/// TOCTOU-safe read so a hostile symlink cannot force malt to slurp an
/// unbounded file before parsing.
pub const max_local_formula_bytes: usize = 1 * 1024 * 1024;

/// Post-parse payload shared by the tap and local-file install paths.
/// Slices point into caller-owned memory (parsed `.rb`, interpolated
/// URL buffer) and must outlive `materializeRubyFormula`.
const ResolvedRubyFormula = struct {
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
    /// When set, the tap is registered in the DB (mirrors the original
    /// tap install behaviour). Local installs leave this null so they
    /// never pollute the tap list.
    tap_registration: ?TapRegistration = null,
};

const TapRegistration = struct {
    url: []const u8,
    commit_sha: []const u8,
};

/// Install a tap formula by fetching the Ruby formula from GitHub and
/// extracting URL + SHA256 for the current platform.
pub fn installTapFormula(
    allocator: std.mem.Allocator,
    pkg_name: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) !void {
    const parts = args.parseTapName(pkg_name) orelse {
        output.err("Invalid tap formula format: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    output.info("Resolving tap {s}/{s}/{s}...", .{ parts.user, parts.repo, parts.formula });

    // Determine the commit SHA to fetch against. Prefer the pin
    // already in the DB (set at tap-add or last --refresh); if no pin
    // exists yet, resolve HEAD once and record it below. Refuses to
    // build a URL from a floating HEAD at install time.
    var tap_slug_buf: [128]u8 = undefined;
    const tap_slug = std.fmt.bufPrint(&tap_slug_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch
        return InstallError.FormulaNotFound;
    const commit_sha = blk: {
        if ((tap_mod.getCommitSha(allocator, db, tap_slug) catch null)) |cached| {
            break :blk cached;
        }
        break :blk tap_mod.resolveHeadCommit(allocator, parts.user, parts.repo) catch {
            output.err("Could not resolve {s}'s HEAD commit — refusing to install from a floating HEAD.", .{tap_slug});
            return InstallError.FormulaNotFound;
        };
    };
    defer allocator.free(commit_sha);

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();

    // Try Formula/ first, then Casks/
    var url_buf: [512]u8 = undefined;
    const rb_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/{s}/Formula/{s}.rb", .{
        parts.user,
        parts.repo,
        commit_sha,
        parts.formula,
    }) catch return InstallError.FormulaNotFound;

    var resp = http.get(rb_url) catch {
        output.err("Cannot fetch tap from GitHub", .{});
        return InstallError.FormulaNotFound;
    };

    if (resp.status != 200) {
        resp.deinit();
        // Try Casks/ directory
        const cask_url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/{s}/homebrew-{s}/{s}/Casks/{s}.rb", .{
            parts.user,
            parts.repo,
            commit_sha,
            parts.formula,
        }) catch return InstallError.FormulaNotFound;

        resp = http.get(cask_url) catch {
            output.err("Cannot fetch tap from GitHub", .{});
            return InstallError.FormulaNotFound;
        };
    }
    defer resp.deinit();

    if (resp.status != 200) {
        output.err("Tap formula/cask not found: {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    }

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(resp.body) orelse {
        output.err("Cannot parse tap formula (Ruby format). Use: brew install {s}", .{pkg_name});
        return InstallError.FormulaNotFound;
    };

    // Interpolate #{version} in URL if present
    var final_url_buf: [512]u8 = undefined;
    const final_url = args.interpolateVersion(&final_url_buf, rb.url, rb.version);

    var tap_buf: [128]u8 = undefined;
    const tap_name = std.fmt.bufPrint(&tap_buf, "{s}/{s}", .{ parts.user, parts.repo }) catch
        return InstallError.FormulaNotFound;
    var tap_url_buf: [256]u8 = undefined;
    const tap_url = std.fmt.bufPrint(&tap_url_buf, "https://github.com/{s}", .{tap_name}) catch
        return InstallError.FormulaNotFound;

    const resolved = ResolvedRubyFormula{
        .name = parts.formula,
        .full_name = pkg_name,
        .tap_label = tap_name,
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        .tap_registration = .{ .url = tap_url, .commit_sha = commit_sha },
    };
    try materializeRubyFormula(allocator, resolved, &http, db, linker, prefix, dry_run, force);
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
    allocator: std.mem.Allocator,
    pkg_arg: []const u8,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) InstallError!void {
    // Expand a leading `~/` to `$HOME` so the common "drop it in
    // your dotfiles" path works without requiring shell expansion.
    var home_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const expanded = args.expandTildePath(&home_buf, pkg_arg) orelse {
        output.err("Cannot resolve home directory for '{s}'", .{pkg_arg});
        return InstallError.LocalFormulaNotReadable;
    };

    // Canonicalise once via open+F_GETPATH. This both checks the file
    // exists AND gives us a symlink-free absolute path for audit
    // messages and the kegs row — defeating the "relative path in a
    // shared Brewfile" footgun.
    var real_buf: [fs_compat.max_path_bytes]u8 = undefined;
    const realpath = fs_compat.cwd().realpath(expanded, &real_buf) catch {
        output.err("Cannot open local formula: {s}", .{pkg_arg});
        return InstallError.LocalFormulaNotReadable;
    };

    // Security warning on every install — the `.rb` is a code-execution
    // vector (parse is pure, but post_install + the archive URL trust
    // this file). Printing the realpath surfaces hidden /tmp or
    // world-writable locations to an attentive reader.
    output.warn("Installing from local file '{s}'. Only install .rb files you trust.", .{realpath});

    // Reject non-regular files outright (directory, socket, device)
    // before allocating a read buffer.
    const f = fs_compat.openFileAbsolute(realpath, .{ .mode = .read_only }) catch {
        output.err("Cannot open local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer f.close();
    const st = f.stat() catch {
        output.err("Cannot stat local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    if (st.kind != .file) {
        output.err("Local formula is not a regular file: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    if (st.size > max_local_formula_bytes) {
        output.err("Local formula exceeds {d}-byte read cap: {s}", .{ max_local_formula_bytes, realpath });
        return InstallError.LocalFormulaNotReadable;
    }

    // Advisory: warn if the file is world-writable or owned by a
    // different user. `--local` is already the trust gate so we don't
    // block — but we make the risk visible on the same line style as
    // the primary security warning.
    if (fstatRisk(f)) |risk| switch (risk) {
        .world_writable => output.warn("Local formula is world-writable — any local user could rewrite it between reads.", .{}),
        .other_owner => output.warn("Local formula is not owned by you — another account wrote this file.", .{}),
    };

    const body = f.readToEndAlloc(allocator, max_local_formula_bytes) catch {
        output.err("Cannot read local formula: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    };
    defer allocator.free(body);

    // Parse the Ruby formula to extract name, version, URL, SHA256 for current arch
    const rb = parseRubyFormula(body) orelse {
        output.err("Cannot parse local formula (missing version/url/sha256): {s}", .{realpath});
        return InstallError.FormulaNotFound;
    };

    // Formula name comes from the basename minus `.rb` — mirrors
    // Homebrew's convention where `wget.rb` installs `wget`. This is
    // the canonical surface for the cellar path, bin name, and DB row.
    const base = std.fs.path.basename(realpath);
    if (!std.mem.endsWith(u8, base, ".rb") or base.len <= 3) {
        output.err("Local formula must end in .rb: {s}", .{realpath});
        return InstallError.LocalFormulaNotReadable;
    }
    const name = base[0 .. base.len - 3];

    var final_url_buf: [512]u8 = undefined;
    const final_url = args.interpolateVersion(&final_url_buf, rb.url, rb.version);

    const resolved = ResolvedRubyFormula{
        .name = name,
        .full_name = realpath,
        .tap_label = "local",
        .version = rb.version,
        .url = final_url,
        .sha256 = rb.sha256,
        // No tap_registration — never pollute `mt tap` with a local path.
    };

    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    try materializeRubyFormula(allocator, resolved, &http, db, linker, prefix, dry_run, force);
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
fn fstatRisk(f: fs_compat.File) ?LocalPermissionRisk {
    var raw: std.c.Stat = undefined;
    if (std.c.fstat(f.inner.handle, &raw) != 0) return null;
    const effective = std.c.geteuid();
    return describeLocalPermissionRisk(@intCast(raw.mode), @intCast(raw.uid), @intCast(effective));
}

/// Shared "from parsed `.rb` to linked keg" path, used by the tap and
/// local installers. Does the network fetch for the archive, SHA256
/// verification, cellar materialisation, and DB + linker commit.
fn materializeRubyFormula(
    allocator: std.mem.Allocator,
    resolved: ResolvedRubyFormula,
    http: *client_mod.HttpClient,
    db: *sqlite.Database,
    linker: *linker_mod.Linker,
    prefix: []const u8,
    dry_run: bool,
    force: bool,
) InstallError!void {
    output.info("Found {s} {s}", .{ resolved.name, resolved.version });

    if (dry_run) {
        output.info("Dry run: would install {s} {s} from {s}", .{ resolved.name, resolved.version, resolved.url });
        return;
    }

    // Skip silently when the keg is already present (unless --force).
    if (!force and record.isInstalled(db, resolved.name)) {
        output.info("{s} is already installed", .{resolved.name});
        return;
    }

    // Refuse any scheme other than `https://`. A `.rb` that smuggled
    // `http://` (downgrade), `file:///etc/passwd`, `ftp://`, or a data
    // URI would otherwise be trusted by the HTTP client. Enforced for
    // every caller of this helper — tap and local share the check.
    if (!args.isAllowedArchiveUrl(resolved.url)) {
        output.err("Refusing to fetch non-HTTPS archive URL for {s}: {s}", .{ resolved.name, resolved.url });
        return InstallError.InsecureArchiveUrl;
    }

    // Stream with a progress bar, matching formula/cask downloads.
    var bar = progress_mod.ProgressBar.init(resolved.name, 0);
    var download_resp = http.getWithHeaders(resolved.url, &.{}, .{
        .context = @ptrCast(&bar),
        .func = &download.progressBridge,
    }) catch {
        bar.finish();
        output.err("Failed to download {s}", .{resolved.name});
        return InstallError.DownloadFailed;
    };
    defer download_resp.deinit();
    bar.finish();

    if (download_resp.status != 200) {
        output.err("Download failed with status {d}", .{download_resp.status});
        return InstallError.DownloadFailed;
    }

    // Verify SHA256 before anything touches the filesystem.
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(download_resp.body, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    const computed: []const u8 = &hex_buf;

    // Constant-time compare on the SHA256: a stock `mem.eql` leaks
    // per-byte progress via timing, giving an adaptive attacker a
    // byte-by-byte oracle against the expected hash.
    if (!record.constantTimeEql(u8, computed, resolved.sha256)) {
        output.err("SHA256 mismatch for {s}", .{resolved.name});
        return InstallError.DownloadFailed;
    }

    // Extract to Cellar directly (tap-style binaries are simple archives).
    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(&cellar_buf, "{s}/Cellar/{s}/{s}", .{ prefix, resolved.name, resolved.version }) catch
        return InstallError.CellarFailed;

    var parent_buf: [512]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}/Cellar/{s}", .{ prefix, resolved.name }) catch
        return InstallError.CellarFailed;
    fs_compat.makeDirAbsolute(parent) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };
    fs_compat.makeDirAbsolute(cellar_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    var bin_buf: [512]u8 = undefined;
    const bin_path = std.fmt.bufPrint(&bin_buf, "{s}/bin", .{cellar_path}) catch
        return InstallError.CellarFailed;
    fs_compat.makeDirAbsolute(bin_path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return InstallError.CellarFailed,
    };

    // Pick archive kind from the URL suffix; reject unknown formats
    // rather than feeding them to tar and printing a generic "failed".
    const TapArchive = enum { tar_gz, tar_xz, zip };
    const kind: ?TapArchive = blk: {
        if (std.mem.endsWith(u8, resolved.url, ".tar.gz") or std.mem.endsWith(u8, resolved.url, ".tgz")) break :blk .tar_gz;
        if (std.mem.endsWith(u8, resolved.url, ".tar.xz")) break :blk .tar_xz;
        if (std.mem.endsWith(u8, resolved.url, ".zip")) break :blk .zip;
        break :blk null;
    };
    const archive_kind = kind orelse {
        output.err("Unsupported archive format for {s}: {s}", .{ resolved.name, resolved.url });
        output.err("Supported formats: .tar.gz, .tar.xz, .zip.", .{});
        return InstallError.DownloadFailed;
    };
    const ext: []const u8 = switch (archive_kind) {
        .tar_gz => ".tar.gz",
        .tar_xz => ".tar.xz",
        .zip => ".zip",
    };
    var tmp_buf: [512]u8 = undefined;
    const tmp_archive = std.fmt.bufPrint(&tmp_buf, "{s}/tmp/tap_download{s}", .{ prefix, ext }) catch
        return InstallError.DownloadFailed;

    const tmp_file = fs_compat.createFileAbsolute(tmp_archive, .{}) catch return InstallError.DownloadFailed;
    tmp_file.writeAll(download_resp.body) catch {
        tmp_file.close();
        return InstallError.DownloadFailed;
    };
    tmp_file.close();
    defer fs_compat.cwd().deleteFile(tmp_archive) catch {};

    const archive_mod = @import("../../fs/archive.zig");
    switch (archive_kind) {
        .tar_gz => archive_mod.extractTarGz(tmp_archive, cellar_path) catch {
            output.err("Failed to extract archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .tar_xz => archive_mod.extractTarXzFile(tmp_archive, cellar_path) catch {
            output.err("Failed to extract .tar.xz archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
        .zip => archive_mod.extractZip(tmp_archive, cellar_path) catch {
            output.err("Failed to extract .zip archive for {s}", .{resolved.name});
            return InstallError.CellarFailed;
        },
    }

    // Promote the binary to bin/ (GoReleaser may extract directly or
    // into a subdirectory — walk to handle both).
    {
        var cellar_dir = fs_compat.openDirAbsolute(cellar_path, .{ .iterate = true }) catch return InstallError.CellarFailed;
        defer cellar_dir.close();

        var walker = cellar_dir.walk(allocator) catch return InstallError.CellarFailed;
        defer walker.deinit();

        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            const basename = std.fs.path.basename(entry.path);
            if (std.mem.eql(u8, basename, resolved.name)) {
                const dest_name = std.fmt.bufPrint(&tmp_buf, "bin/{s}", .{basename}) catch continue;
                cellar_dir.copyFile(entry.path, cellar_dir, dest_name, .{}) catch continue;
                const bin_file = cellar_dir.openFile(dest_name, .{ .mode = .read_write }) catch continue;
                defer bin_file.close();
                bin_file.chmod(0o755) catch {};
                break;
            }
        }
    }

    output.info("Linking {s}...", .{resolved.name});

    // Single DB transaction: keg row → optional tap registration →
    // linker work → commit. `errdefer rollback` unwinds cleanly if any
    // step fails before commit.
    db.beginTransaction() catch return InstallError.RecordFailed;
    errdefer db.rollback();

    var keg_id: i64 = 0;
    {
        var stmt = db.prepare(
            "INSERT OR REPLACE INTO kegs (name, full_name, version, tap, store_sha256, cellar_path, install_reason)" ++
                " VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'direct');",
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
            // and leaves later pins untouched.
            tap_mod.add(db, resolved.tap_label, t.url, t.commit_sha) catch {};
        }
    }

    linker.link(cellar_path, resolved.name, keg_id) catch {
        output.warn("Some links for {s} could not be created", .{resolved.name});
    };
    linker.linkOpt(resolved.name, resolved.version) catch {
        output.warn("Could not create opt link for {s}", .{resolved.name});
    };

    db.commit() catch return InstallError.RecordFailed;

    output.success("{s} {s} installed", .{ resolved.name, resolved.version });
}

/// Minimal Ruby formula parser for GoReleaser-style formulas.
/// Extracts version, URL, and SHA256 for the current platform.
pub const RubyFormulaInfo = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub fn parseRubyFormula(rb_content: []const u8) ?RubyFormulaInfo {
    const is_arm = @import("../../macho/codesign.zig").isArm64();

    var version: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var sha256: ?[]const u8 = null;

    // State machine: look for the right CPU section
    var in_correct_section = false;
    var in_macos = false;

    var line_start: usize = 0;
    for (rb_content, 0..) |ch, idx| {
        if (ch == '\n' or idx == rb_content.len - 1) {
            const line_end = if (ch == '\n') idx else idx + 1;
            const line = std.mem.trim(u8, rb_content[line_start..line_end], " \t\r");
            line_start = idx + 1;

            // Extract version (global)
            if (version == null) {
                if (extractQuoted(line, "version \"")) |v| {
                    version = v;
                }
            }

            // Track on_macos block
            if (std.mem.indexOf(u8, line, "on_macos") != null) {
                in_macos = true;
            }

            // Track CPU section (Formula style: Hardware::CPU, Cask style: on_arm/on_intel)
            if (in_macos) {
                if (is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.arm?") != null or
                    std.mem.indexOf(u8, line, "on_arm") != null))
                {
                    in_correct_section = true;
                } else if (!is_arm and (std.mem.indexOf(u8, line, "Hardware::CPU.intel?") != null or
                    std.mem.indexOf(u8, line, "on_intel") != null))
                {
                    in_correct_section = true;
                }
            }

            // Extract URL and SHA256 within the correct section
            if (in_correct_section) {
                if (url == null) {
                    if (extractQuoted(line, "url \"")) |u| {
                        url = u;
                    }
                }
                if (sha256 == null) {
                    if (extractQuoted(line, "sha256 \"")) |s| {
                        sha256 = s;
                    }
                }
            }

            // If we have both, stop
            if (url != null and sha256 != null) break;
        }
    }

    // Fallback: if no CPU-specific section found, try global url/sha256
    if (url == null or sha256 == null) {
        var ls: usize = 0;
        for (rb_content, 0..) |ch, idx| {
            if (ch == '\n' or idx == rb_content.len - 1) {
                const le = if (ch == '\n') idx else idx + 1;
                const ln = std.mem.trim(u8, rb_content[ls..le], " \t\r");
                ls = idx + 1;

                if (url == null) {
                    if (extractQuoted(ln, "url \"")) |u| url = u;
                }
                if (sha256 == null) {
                    if (extractQuoted(ln, "sha256 \"")) |s| sha256 = s;
                }
            }
        }
    }

    if (version != null and url != null and sha256 != null) {
        return .{ .version = version.?, .url = url.?, .sha256 = sha256.? };
    }
    return null;
}

pub fn extractQuoted(line: []const u8, prefix: []const u8) ?[]const u8 {
    _, const after = std.mem.cut(u8, line, prefix) orelse return null;
    const body, _ = std.mem.cut(u8, after, "\"") orelse return null;
    return body;
}
