//! malt — Ruby subprocess post_install executor
//! Delegates post_install script execution to the system Ruby interpreter.
//! This is an experimental stopgap until malt can natively evaluate the
//! Homebrew DSL.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const builtin = @import("builtin");
const codesign = @import("../macho/codesign.zig");
const pins = @import("pins.zig");
const http_client = @import("../net/client.zig");
const api_mod = @import("../net/api.zig");
const sandbox = @import("sandbox/macos.zig");
const dsl_lexer = @import("dsl/lexer.zig");
const dsl_parser = @import("dsl/parser.zig");
const fs_atomic = @import("../fs/atomic.zig");

pub const RubyError = error{
    RubyNotFound,
    TapNotFound,
    FormulaSourceNotFound,
    PostInstallBodyNotFound,
    ScriptWriteFailed,
    PostInstallFailed,
    OutOfMemory,
    InvalidInput,
};

/// Human-readable hint for each RubyError variant. CLI renders these so
/// core/* itself emits no UI.
pub fn describeError(err: RubyError) []const u8 {
    return switch (err) {
        RubyError.RubyNotFound => "no Ruby interpreter found (tried /opt/homebrew, /usr/local, rbenv, asdf, PATH)",
        RubyError.TapNotFound => "homebrew-core tap not found; run `brew tap --force homebrew/core`",
        RubyError.FormulaSourceNotFound => "formula .rb source not found in the homebrew-core tap",
        RubyError.PostInstallBodyNotFound => "could not extract post_install body from formula source",
        RubyError.ScriptWriteFailed => "could not write the temporary Ruby wrapper script",
        RubyError.PostInstallFailed => "post_install script failed to run or exited non-zero",
        RubyError.OutOfMemory => "out of memory running post_install",
        RubyError.InvalidInput => "invalid formula name, version, or prefix",
    };
}

/// Upper bound on a fetched formula .rb blob. The Homebrew-wide 99th
/// percentile is ~40 KiB; 1 MiB is orders of magnitude of headroom
/// without giving a hostile response room to grow.
const MAX_FORMULA_RB_BYTES: usize = 1024 * 1024;

/// Detect a usable Ruby interpreter. Returns a caller-owned absolute path
/// or null. Caller must free the returned slice with `allocator.free`.
///
/// Previously this function returned static slices for the hardcoded
/// candidates and `allocator.dupe`d slices for the rbenv/asdf/PATH
/// branches — the only call site never freed, so the heap branches
/// leaked. Unifying the contract on "always heap-owned" lets the caller
/// pair every successful return with one `defer allocator.free(...)`.
///
/// Public for testability; not part of the stable surface.
pub fn detectRuby(allocator: std.mem.Allocator) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/ruby/bin/ruby",
        "/usr/local/opt/ruby/bin/ruby",
        "/usr/bin/ruby",
    };
    for (candidates) |path| {
        fs_compat.accessAbsolute(path, .{}) catch continue;
        return allocator.dupe(u8, path) catch return null;
    }

    // Reusable scratch for path joining — avoids per-iteration heap churn.
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // User-local version managers: rbenv, asdf
    if (fs_compat.getenv("HOME")) |home| {
        const shim_suffixes = [_][]const u8{ "/.rbenv/shims/ruby", "/.asdf/shims/ruby" };
        for (shim_suffixes) |suffix| {
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ home, suffix }) catch continue;
            fs_compat.accessAbsolute(path, .{}) catch continue;
            return allocator.dupe(u8, path) catch return null;
        }
    }

    // PATH search
    if (fs_compat.getenv("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fmt.bufPrint(&buf, "{s}/ruby", .{dir}) catch continue;
            fs_compat.accessAbsolute(candidate, .{}) catch continue;
            return allocator.dupe(u8, candidate) catch return null;
        }
    }

    return null;
}

/// Locate the homebrew-core tap clone on disk. Returns the tap path or null.
pub fn findHomebrewCoreTap() ?[]const u8 {
    const tap_paths = [_][]const u8{
        "/opt/homebrew/Library/Taps/homebrew/homebrew-core",
        "/usr/local/Homebrew/Library/Taps/homebrew/homebrew-core",
    };
    for (tap_paths) |path| {
        fs_compat.accessAbsolute(path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Resolve the .rb source file path for a formula within the tap.
/// Tries new sharded layout first (Formula/f/foo.rb), falls back to flat
/// (Formula/foo.rb).
pub fn resolveFormulaRbPath(buf: *[1024]u8, tap_path: []const u8, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    // New layout: Formula/FIRST_LETTER/NAME.rb
    const new_path = std.fmt.bufPrint(buf, "{s}/Formula/{c}/{s}.rb", .{
        tap_path, name[0], name,
    }) catch return null;
    fs_compat.accessAbsolute(new_path, .{}) catch {
        // Fall through to old layout
        const old_path = std.fmt.bufPrint(buf, "{s}/Formula/{s}.rb", .{
            tap_path, name,
        }) catch return null;
        fs_compat.accessAbsolute(old_path, .{}) catch return null;
        return old_path;
    };
    return new_path;
}

/// Fetch a formula's .rb source from the pinned homebrew-core commit,
/// verify its SHA256 against the embedded manifest, and extract the
/// post_install body.
///
/// This path is the fallback when the homebrew-core tap is not cloned
/// locally. It refuses anything whose hash isn't pre-authorized in
/// `pins_manifest.txt` — a floating-HEAD fetch would give an attacker
/// who controls the raw.githubusercontent.com response (MITM with a
/// valid cert, compromised CDN edge, branch rewrite) a direct path to
/// code execution via `--use-system-ruby`.
///
/// Returns the post_install body or null on any fetch / verify / parse
/// failure. All failures are silent-to-caller; the caller decides
/// whether to warn.
pub fn fetchPostInstallFromGitHub(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    // Reject anything that wouldn't pass the API name allowlist
    // ([a-z0-9@._+-]) — the URL path substitutes the name directly.
    api_mod.validateName(name) catch return null;

    // Fail-closed: no manifest entry, no fetch. The caller decides whether
    // to warn — core stays headless.
    const expected_hash = pins.expectedSha256(name) orelse return null;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://raw.githubusercontent.com/Homebrew/homebrew-core/{s}/Formula/{c}/{s}.rb",
        .{ pins.HOMEBREW_CORE_COMMIT_SHA, name[0], name },
    ) catch return null;

    var http = http_client.HttpClient.init(allocator);
    defer http.deinit();

    var resp = http.get(url) catch return null;
    defer resp.deinit();
    if (resp.status != 200) return null;
    if (resp.body.len == 0 or resp.body.len > MAX_FORMULA_RB_BYTES) return null;

    var actual_hex: [pins.SHA256_HEX_LEN]u8 = undefined;
    pins.sha256Hex(resp.body, &actual_hex);
    if (!std.mem.eql(u8, actual_hex[0..], expected_hash)) return null;

    return extractPostInstallFromSource(allocator, resp.body);
}

/// Extract post_install body + any sibling `def` blocks at the same indent,
/// concatenated so the DSL sees helpers registered before the body runs.
/// Without this, formulas like ca-certificates/llvm@21 whose post_install
/// calls into private helpers would fall back to `--use-system-ruby`.
pub fn extractPostInstallFromSource(allocator: std.mem.Allocator, source: []const u8) ?[]const u8 {
    const post_install_span = findDefBlock(source, "post_install") orelse return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    // Siblings first — registered as user methods before the post_install
    // body runs. On parse fail we emit an empty stub under the sibling's
    // name so a dispatcher post_install (ca-certificates, …) resolves to a
    // no-op instead of logging `unknown_method` and tripping hasErrors().
    var pos: usize = 0;
    while (findAnyDefBlockAtIndent(source, pos, post_install_span.indent)) |span| {
        const is_self = std.mem.eql(u8, span.name, "post_install");
        if (!is_self) {
            if (canParseBlock(allocator, source[span.block_start..span.block_end])) {
                out.appendSlice(allocator, source[span.block_start..span.block_end]) catch return null;
                out.append(allocator, '\n') catch return null;
            } else {
                out.appendSlice(allocator, "def ") catch return null;
                out.appendSlice(allocator, span.name) catch return null;
                out.appendSlice(allocator, "\nend\n") catch return null;
            }
        }
        pos = span.block_end;
    }

    // Then the post_install body itself (no `def`/`end` wrapper).
    out.appendSlice(allocator, source[post_install_span.body_start..post_install_span.body_end]) catch return null;

    return out.toOwnedSlice(allocator) catch return null;
}

/// Run the DSL parser over an isolated sibling-def block and report whether
/// it produced zero diagnostics. Used to gate sibling inclusion so a formula
/// whose `def install` or `def macos_post_install` contains Ruby we don't
/// speak yet (keyword args, `Tempfile`, `.scan` regex blocks, …) doesn't
/// wreck the whole post_install extraction.
fn canParseBlock(allocator: std.mem.Allocator, src: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lex = dsl_lexer.Lexer.init(src);
    var p = dsl_parser.Parser.init(arena.allocator(), &lex);
    _ = p.parseBlock() catch return false;
    return p.diagnostics().len == 0;
}

/// Span describing a single `def NAME ... end` block at a known indent.
const DefSpan = struct {
    name: []const u8,
    indent: usize,
    block_start: usize, // column 0 of the `def` line
    block_end: usize, // index AFTER the matching `end` line's newline
    body_start: usize, // index just after the `def` line's newline
    body_end: usize, // `line_start` of the matching `end`
};

/// Find the named def (`def <name>`) at class-body indent and return its span.
fn findDefBlock(source: []const u8, name: []const u8) ?DefSpan {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "def {s}", .{name}) catch return null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, marker)) |idx| {
        const span = defSpanAt(source, idx) orelse {
            pos = idx + marker.len;
            continue;
        };
        if (std.mem.eql(u8, span.name, name)) return span;
        pos = span.block_end;
    }
    return null;
}

/// Return the next `def ... end` block at `indent` starting at or after
/// `pos`. Returns null when no more defs at that indent exist.
fn findAnyDefBlockAtIndent(source: []const u8, start: usize, indent: usize) ?DefSpan {
    var pos = start;
    while (std.mem.indexOfPos(u8, source, pos, "def ")) |idx| {
        const span = defSpanAt(source, idx) orelse {
            pos = idx + 4;
            continue;
        };
        if (span.indent == indent) return span;
        pos = span.block_end;
    }
    return null;
}

/// If `idx` points at the `d` of a `def` that starts a line, build its
/// DefSpan. Returns null if the context isn't a real top-of-line def.
fn defSpanAt(source: []const u8, idx: usize) ?DefSpan {
    // Must be at line start (optionally preceded by spaces).
    const line_start = if (idx == 0)
        0
    else if (std.mem.findScalarLast(u8, source[0..idx], '\n')) |nl|
        nl + 1
    else
        0;

    // Verify the gap between line_start and idx is only spaces.
    for (source[line_start..idx]) |c| if (c != ' ') return null;
    const indent = idx - line_start;

    // Skip `def ` + optional leading whitespace to the name.
    var name_start = idx + 4; // after "def "
    while (name_start < source.len and source[name_start] == ' ') name_start += 1;

    // Ruby method names: letters, digits, `_`, optional trailing `?`/`!`/`=`.
    var ne = name_start;
    while (ne < source.len) : (ne += 1) {
        const c = source[ne];
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        break;
    }
    if (ne < source.len and (source[ne] == '?' or source[ne] == '!' or source[ne] == '=')) {
        ne += 1;
    }
    if (ne == name_start) return null;

    const body_start = std.mem.findScalarPos(u8, source, idx, '\n') orelse return null;
    const matching_end = findMatchingEnd(source, body_start + 1, indent) orelse return null;

    return .{
        .name = source[name_start..ne],
        .indent = indent,
        .block_start = line_start,
        .block_end = matching_end.block_end,
        .body_start = body_start + 1,
        .body_end = matching_end.end_line_start,
    };
}

/// Locate the matching `end` line at exactly `indent` columns. Returns both
/// the index AFTER the end line's newline and the index of the end line's
/// first character so callers can slice both the block and its body.
fn findMatchingEnd(source: []const u8, start: usize, indent: usize) ?struct {
    end_line_start: usize,
    block_end: usize,
} {
    var pos = start;
    while (pos < source.len) {
        const line_start = pos;
        const line_end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;

        var line_indent: usize = 0;
        var scan = line_start;
        while (scan < line_end and source[scan] == ' ') : (scan += 1) line_indent += 1;

        if (line_indent == indent and
            line_end - scan >= 3 and
            std.mem.eql(u8, source[scan..@min(scan + 3, line_end)], "end") and
            (scan + 3 >= line_end or source[scan + 3] == ' ' or source[scan + 3] == '\n'))
        {
            const block_end = if (line_end < source.len) line_end + 1 else source.len;
            return .{ .end_line_start = line_start, .block_end = block_end };
        }

        pos = if (line_end < source.len) line_end + 1 else source.len;
    }
    return null;
}

/// Extract the post_install method body + sibling helpers from a formula
/// .rb source file. Thin file-IO wrapper around `extractPostInstallFromSource`
/// so the parsing contract lives in one place.
pub fn extractPostInstallBody(allocator: std.mem.Allocator, rb_path: []const u8) ?[]const u8 {
    const file = fs_compat.openFileAbsolute(rb_path, .{}) catch return null;
    defer file.close();

    const source = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(source);

    return extractPostInstallFromSource(allocator, source);
}

/// Generate the Ruby wrapper script that provides a FormulaStub sandbox
/// and evaluates the post_install body.
///
/// `prefix`, `name`, `version` are interpolated into single-quoted Ruby
/// literals. They MUST contain only bytes from the centralised charset in
/// `fs/atomic.zig` — anything else (`'`, `\`, `\n`, control bytes, …)
/// would break the literal or open an injection (BUG-007). We validate
/// at the boundary rather than escape so the contract is one-line
/// reviewable: pass → safe to interpolate, fail → InvalidInput.
pub fn generateWrapper(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
    post_install_body: []const u8,
) ![]const u8 {
    if (prefix.len == 0 or name.len == 0 or version.len == 0) return error.InvalidInput;
    for (prefix) |b| if (!fs_atomic.isAllowedPrefixByte(b)) return error.InvalidInput;
    for (name) |b| if (!fs_atomic.isAllowedNameByte(b)) return error.InvalidInput;
    for (version) |b| if (!fs_atomic.isAllowedNameByte(b)) return error.InvalidInput;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const writer = &aw.writer;

    try writer.writeAll(
        \\require 'pathname'
        \\require 'fileutils'
        \\
        \\class FormulaStub
        \\  def initialize(name, version, malt_prefix)
        \\    @name = name
        \\    @version = version
        \\    @malt_prefix = Pathname.new(malt_prefix)
        \\    @prefix_path = @malt_prefix/'Cellar'/name/version
        \\  end
        \\
        \\  def name; @name; end
        \\  def version; @version; end
        \\  def prefix; @prefix_path; end
        \\  def bin; prefix/'bin'; end
        \\  def sbin; prefix/'sbin'; end
        \\  def lib; prefix/'lib'; end
        \\  def libexec; prefix/'libexec'; end
        \\  def include; prefix/'include'; end
        \\  def share; prefix/'share'; end
        \\  def pkgshare; share/@name; end
        \\  def frameworks; prefix/'Frameworks'; end
        \\  def kext_prefix; prefix/'Library/Extensions'; end
        \\  def etc; @malt_prefix/'etc'; end
        \\  def var; @malt_prefix/'var'; end
        \\  def opt_prefix; @malt_prefix/'opt'/@name; end
        \\  def opt_bin; opt_prefix/'bin'; end
        \\  def opt_lib; opt_prefix/'lib'; end
        \\  def opt_include; opt_prefix/'include'; end
        \\  def buildpath; prefix; end
        \\  def cellar; @malt_prefix/'Cellar'; end
        \\
        \\  HOMEBREW_PREFIX = Pathname.new('
    );
    try writer.writeAll(prefix);
    try writer.writeAll(
        \\')
        \\  HOMEBREW_CELLAR = HOMEBREW_PREFIX/'Cellar'
        \\
        \\  def inreplace(path, before = nil, after = nil, &block)
        \\    content = File.read(path.to_s)
        \\    if block
        \\      block.call(content)
        \\    else
        \\      content.gsub!(before.to_s, after.to_s)
        \\    end
        \\    File.write(path.to_s, content)
        \\  end
        \\
        \\  def system(*args)
        \\    result = Kernel.system(*args.map(&:to_s))
        \\    raise "system command failed: #{args.join(' ')}" unless result
        \\  end
        \\
        \\  def ohai(msg); puts "==> #{msg}"; end
        \\  def opoo(msg); $stderr.puts "Warning: #{msg}"; end
        \\  def odie(msg); $stderr.puts "Error: #{msg}"; exit 1; end
        \\
        \\  def which(cmd)
        \\    ENV['PATH'].split(':').each do |dir|
        \\      path = File.join(dir, cmd.to_s)
        \\      return Pathname.new(path) if File.executable?(path)
        \\    end
        \\    nil
        \\  end
        \\end
        \\
        \\
    );

    // Instantiate and run
    try writer.print("stub = FormulaStub.new('{s}', '{s}', '{s}')\n", .{ name, version, prefix });
    try writer.writeAll("stub.instance_eval do\n");
    try writer.writeAll(post_install_body);
    try writer.writeAll("\nend\n");

    return aw.toOwnedSlice();
}

/// Run the post_install hook for a formula via the system Ruby interpreter.
///
/// Requires:
/// - A Ruby interpreter available on the system
/// - The homebrew-core tap cloned locally (for the .rb formula source)
pub fn runPostInstall(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
) RubyError!void {
    // 0. Validate inputs at the boundary. A hostile Cellar dir name (the
    //    on-disk source of `name` on the runPostInstall path) must die
    //    here, not deeper in script generation or the sandbox spawn.
    if (prefix.len == 0 or name.len == 0 or version.len == 0) return RubyError.InvalidInput;
    for (prefix) |b| if (!fs_atomic.isAllowedPrefixByte(b)) return RubyError.InvalidInput;
    for (name) |b| if (!fs_atomic.isAllowedNameByte(b)) return RubyError.InvalidInput;
    for (version) |b| if (!fs_atomic.isAllowedNameByte(b)) return RubyError.InvalidInput;

    // Core returns outcomes; UI renders at the boundary — the CLI caller
    // maps each RubyError variant to user-facing text.

    // 1. Find Ruby (caller-owned heap slice — see detectRuby contract).
    const ruby_path = detectRuby(allocator) orelse return RubyError.RubyNotFound;
    defer allocator.free(ruby_path);

    // 2. Find homebrew-core tap
    const tap_path = findHomebrewCoreTap() orelse return RubyError.TapNotFound;

    // 3. Resolve .rb source file
    var rb_buf: [1024]u8 = undefined;
    const rb_path = resolveFormulaRbPath(&rb_buf, tap_path, name) orelse
        return RubyError.FormulaSourceNotFound;

    // 4. Extract post_install body
    const body = extractPostInstallBody(allocator, rb_path) orelse
        return RubyError.PostInstallBodyNotFound;
    defer allocator.free(body);

    // 5. Generate wrapper script
    const script = generateWrapper(allocator, name, version, prefix, body) catch
        return RubyError.OutOfMemory;
    defer allocator.free(script);

    // 6. Write temp file with an exclusive-create to defeat tmp-file races.
    // The path includes the PID and a 128-bit random suffix so concurrent
    // post_install runs for the same (or a different) formula cannot collide,
    // and an attacker cannot pre-create the target to redirect execution.
    var tmp_path_buf: [256]u8 = undefined;
    var rand_bytes: [16]u8 = undefined;
    fs_compat.randomBytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const pid = std.c.getpid();
    const tmp_path = std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/malt_post_install_{s}_{d}_{s}.rb",
        .{ name, pid, hex[0..] },
    ) catch return RubyError.ScriptWriteFailed;

    const tmp_file = fs_compat.createFileAbsolute(tmp_path, .{
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return RubyError.ScriptWriteFailed;
    tmp_file.writeAll(script) catch {
        tmp_file.close();
        fs_compat.deleteFileAbsolute(tmp_path) catch {};
        return RubyError.ScriptWriteFailed;
    };
    tmp_file.close();

    // Ensure cleanup
    defer fs_compat.deleteFileAbsolute(tmp_path) catch {};

    // 7. Spawn Ruby under sandbox-exec with a per-formula profile,
    //    scrubbed env, and resource limits. stdout/stderr inherit the
    //    parent's so post_install output still reaches the user.
    //    The parent's env is intentionally NOT forwarded — only HOME,
    //    a minimal PATH, MALT_PREFIX, and a formula-scoped TMPDIR pass.

    var cellar_buf: [512]u8 = undefined;
    const cellar_path = std.fmt.bufPrint(
        &cellar_buf,
        "{s}/Cellar/{s}/{s}",
        .{ prefix, name, version },
    ) catch return RubyError.PostInstallFailed;

    const home = fs_compat.getenv("HOME") orelse "/tmp";
    const env: sandbox.ScrubbedEnv = .{
        .home = home,
        .path = sandbox.SANDBOX_PATH,
        .malt_prefix = prefix,
        .tmpdir = "/tmp",
    };

    const exit_code = sandbox.runRubySandboxed(
        allocator,
        ruby_path,
        tmp_path,
        cellar_path,
        prefix,
        env,
        .{},
    ) catch return RubyError.PostInstallFailed;
    if (exit_code != 0) return RubyError.PostInstallFailed;
}
