//! malt — Ruby subprocess post_install executor
//! Delegates post_install script execution to the system Ruby interpreter.
//! This is an experimental stopgap until malt can natively evaluate the
//! Homebrew DSL.

const std = @import("std");
const builtin = @import("builtin");
const output = @import("../ui/output.zig");
const codesign = @import("../macho/codesign.zig");

pub const RubyError = error{
    RubyNotFound,
    TapNotFound,
    FormulaSourceNotFound,
    PostInstallBodyNotFound,
    ScriptWriteFailed,
    PostInstallFailed,
    OutOfMemory,
};

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
        std.fs.accessAbsolute(path, .{}) catch continue;
        return allocator.dupe(u8, path) catch return null;
    }

    // Reusable scratch for path joining — avoids per-iteration heap churn.
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // User-local version managers: rbenv, asdf
    if (std.posix.getenv("HOME")) |home| {
        const shim_suffixes = [_][]const u8{ "/.rbenv/shims/ruby", "/.asdf/shims/ruby" };
        for (shim_suffixes) |suffix| {
            const path = std.fmt.bufPrint(&buf, "{s}{s}", .{ home, suffix }) catch continue;
            std.fs.accessAbsolute(path, .{}) catch continue;
            return allocator.dupe(u8, path) catch return null;
        }
    }

    // PATH search
    if (std.posix.getenv("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fmt.bufPrint(&buf, "{s}/ruby", .{dir}) catch continue;
            std.fs.accessAbsolute(candidate, .{}) catch continue;
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
        std.fs.accessAbsolute(path, .{}) catch continue;
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
    std.fs.accessAbsolute(new_path, .{}) catch {
        // Fall through to old layout
        const old_path = std.fmt.bufPrint(buf, "{s}/Formula/{s}.rb", .{
            tap_path, name,
        }) catch return null;
        std.fs.accessAbsolute(old_path, .{}) catch return null;
        return old_path;
    };
    return new_path;
}

/// Fetch a formula's .rb source from GitHub and extract the post_install body.
/// This is the fallback when the homebrew-core tap is not cloned locally.
/// Uses curl for simplicity and TLS handling.
/// Returns the post_install body or null if the fetch fails or no post_install exists.
pub fn fetchPostInstallFromGitHub(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;

    // Build the GitHub raw URL: Formula/FIRST_LETTER/NAME.rb
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/{c}/{s}.rb", .{
        name[0], name,
    }) catch return null;

    const argv = [_][]const u8{ "curl", "-fsSL", "--max-time", "10", url };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const stdout = child.stdout orelse return null;
    const body = stdout.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    const term = child.wait() catch return null;

    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(body);
            return null;
        },
        else => {
            allocator.free(body);
            return null;
        },
    }

    if (body.len == 0) {
        allocator.free(body);
        return null;
    }

    // Extract post_install from the fetched source
    const result = extractPostInstallFromSource(allocator, body);
    allocator.free(body);
    return result;
}

/// Extract post_install body from Ruby source text (in-memory version).
pub fn extractPostInstallFromSource(allocator: std.mem.Allocator, source: []const u8) ?[]const u8 {
    const marker = "def post_install";
    const start_idx = std.mem.indexOf(u8, source, marker) orelse return null;
    const body_start = std.mem.findScalarPos(u8, source, start_idx, '\n') orelse return null;

    const def_line_start = if (start_idx > 0)
        if (std.mem.findScalarLast(u8, source[0..start_idx], '\n')) |nl| nl + 1 else 0
    else
        0;

    var def_indent: usize = 0;
    for (source[def_line_start..start_idx]) |c| {
        if (c == ' ') def_indent += 1 else break;
    }

    var pos = body_start + 1;
    while (pos < source.len) {
        const line_start = pos;
        const line_end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;

        var line_indent: usize = 0;
        var scan = line_start;
        while (scan < line_end and source[scan] == ' ') {
            line_indent += 1;
            scan += 1;
        }

        if (line_indent == def_indent and
            line_end - scan >= 3 and
            std.mem.eql(u8, source[scan..@min(scan + 3, line_end)], "end") and
            (scan + 3 >= line_end or source[scan + 3] == ' ' or source[scan + 3] == '\n'))
        {
            const body = source[body_start + 1 .. line_start];
            return allocator.dupe(u8, body) catch return null;
        }

        pos = if (line_end < source.len) line_end + 1 else source.len;
    }

    return null;
}

/// Extract the post_install method body from a formula .rb source file.
/// Returns the raw Ruby source between `def post_install` and its matching
/// `end`, or null if not found.
pub fn extractPostInstallBody(allocator: std.mem.Allocator, rb_path: []const u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(rb_path, .{}) catch return null;
    defer file.close();

    const source = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;

    // Find `def post_install`
    const marker = "def post_install";
    const start_idx = std.mem.indexOf(u8, source, marker) orelse {
        allocator.free(source);
        return null;
    };

    // Find the start of the body (after the def line)
    const body_start = std.mem.findScalarPos(u8, source, start_idx, '\n') orelse {
        allocator.free(source);
        return null;
    };

    // Find matching `end` — simple heuristic: first line starting with
    // exactly "  end" or "end" after the def. We track indentation depth.
    const def_line_start = if (start_idx > 0)
        if (std.mem.findScalarLast(u8, source[0..start_idx], '\n')) |nl| nl + 1 else 0
    else
        0;

    // Measure indent of `def post_install`
    var def_indent: usize = 0;
    for (source[def_line_start..start_idx]) |c| {
        if (c == ' ') {
            def_indent += 1;
        } else break;
    }

    // Scan for matching end at the same indent level
    var pos = body_start + 1;
    while (pos < source.len) {
        // Find next line
        const line_start = pos;
        const line_end = std.mem.findScalarPos(u8, source, pos, '\n') orelse source.len;

        // Check if this line is `end` at the same indent level
        var line_indent: usize = 0;
        var scan = line_start;
        while (scan < line_end and source[scan] == ' ') {
            line_indent += 1;
            scan += 1;
        }

        if (line_indent == def_indent and
            line_end - scan >= 3 and
            std.mem.eql(u8, source[scan..@min(scan + 3, line_end)], "end") and
            (scan + 3 >= line_end or source[scan + 3] == ' ' or source[scan + 3] == '\n'))
        {
            // Found the matching end — body is source[body_start+1 .. line_start]
            const body = source[body_start + 1 .. line_start];
            const result = allocator.dupe(u8, body) catch {
                allocator.free(source);
                return null;
            };
            allocator.free(source);
            return result;
        }

        pos = if (line_end < source.len) line_end + 1 else source.len;
    }

    allocator.free(source);
    return null;
}

/// Generate the Ruby wrapper script that provides a FormulaStub sandbox
/// and evaluates the post_install body.
pub fn generateWrapper(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    prefix: []const u8,
    post_install_body: []const u8,
) ![]const u8 {
    var script: std.ArrayList(u8) = .empty;
    errdefer script.deinit(allocator);

    const writer = script.writer(allocator);

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

    return script.toOwnedSlice(allocator);
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
    // 1. Find Ruby (caller-owned heap slice — see detectRuby contract).
    const ruby_path = detectRuby(allocator) orelse {
        output.err("No Ruby interpreter found. Tried:", .{});
        output.err("  /opt/homebrew/opt/ruby/bin/ruby", .{});
        output.err("  /usr/local/opt/ruby/bin/ruby", .{});
        output.err("  ~/.rbenv/shims/ruby, ~/.asdf/shims/ruby", .{});
        output.err("  /usr/bin/ruby", .{});
        output.err("  PATH search", .{});
        return RubyError.RubyNotFound;
    };
    defer allocator.free(ruby_path);

    // 2. Find homebrew-core tap
    const tap_path = findHomebrewCoreTap() orelse {
        output.err("homebrew-core tap not found. Required for --use-system-ruby.", .{});
        output.err("Run: brew tap --force homebrew/core", .{});
        return RubyError.TapNotFound;
    };

    // 3. Resolve .rb source file
    var rb_buf: [1024]u8 = undefined;
    const rb_path = resolveFormulaRbPath(&rb_buf, tap_path, name) orelse {
        output.err("Formula source not found: {s}", .{name});
        output.err("Expected at: {s}/Formula/{c}/{s}.rb", .{ tap_path, name[0], name });
        return RubyError.FormulaSourceNotFound;
    };

    // 4. Extract post_install body
    const body = extractPostInstallBody(allocator, rb_path) orelse {
        output.err("Could not extract post_install body from {s}", .{rb_path});
        return RubyError.PostInstallBodyNotFound;
    };
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
    std.crypto.random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const pid = std.c.getpid();
    const tmp_path = std.fmt.bufPrint(
        &tmp_path_buf,
        "/tmp/malt_post_install_{s}_{d}_{s}.rb",
        .{ name, pid, hex[0..] },
    ) catch return RubyError.ScriptWriteFailed;

    const tmp_file = std.fs.createFileAbsolute(tmp_path, .{
        .exclusive = true,
        .mode = 0o600,
    }) catch return RubyError.ScriptWriteFailed;
    tmp_file.writeAll(script) catch {
        tmp_file.close();
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return RubyError.ScriptWriteFailed;
    };
    tmp_file.close();

    // Ensure cleanup
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // 7. Spawn Ruby subprocess — inherit stdout/stderr so post_install
    // output flows directly to the user's terminal.
    const argv = [_][]const u8{ ruby_path, tmp_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return RubyError.PostInstallFailed;

    const term = child.wait() catch return RubyError.PostInstallFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                output.err("post_install script exited with code {d}", .{code});
                return RubyError.PostInstallFailed;
            }
        },
        else => return RubyError.PostInstallFailed,
    }
}
