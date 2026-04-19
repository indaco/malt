//! malt — DSL builtin dispatch table
//! Central registry mapping method names to builtin functions.

const std = @import("std");
const values = @import("../values.zig");
const ast = @import("../ast.zig");
pub const pathname = @import("pathname.zig");
pub const fileutils = @import("fileutils.zig");
pub const ui = @import("ui.zig");
pub const process = @import("process.zig");
pub const string = @import("string.zig");
pub const inreplace = @import("inreplace.zig");

const Value = values.Value;
const ExecCtx = pathname.ExecCtx;
const BuiltinError = pathname.BuiltinError;

pub const BuiltinFn = *const fn (ExecCtx, ?Value, []const Value) BuiltinError!Value;

/// Dispatch table for bare method calls (no receiver).
pub const bare_builtins = std.StaticStringMap(BuiltinFn).initComptime(.{
    // FileUtils
    .{ "rm", fileutils.rm },
    .{ "rm_r", fileutils.rmR },
    .{ "rm_rf", fileutils.rmRf },
    .{ "mkdir_p", fileutils.mkdirP },
    .{ "cp", fileutils.cp },
    .{ "cp_r", fileutils.cpR },
    .{ "mv", fileutils.mv },
    .{ "chmod", fileutils.chmod },
    .{ "touch", fileutils.touch },
    .{ "ln_s", fileutils.lnS },
    .{ "ln_sf", fileutils.lnSf },

    // UI
    .{ "ohai", ui.ohai },
    .{ "opoo", ui.opoo },
    .{ "odie", ui.odie },

    // Process
    .{ "system", process.system },

    // Inreplace
    .{ "inreplace", inreplace.inreplace },

    // Dir.glob (bare form)
    .{ "Dir.glob", pathname.glob },

    // quiet_system — same as system but suppress failures
    .{ "quiet_system", process.quietSystem },

    // File.exist? — class method form
    .{ "File.exist?", process.fileExist },

    // DevelopmentTools.locate — PATH lookup
    .{ "DevelopmentTools.locate", process.devToolsLocate },

    // Formula["name"] — cross-formula lookup
    .{ "Formula.lookup", process.formulaLookup },

    // OS/platform builtins
    .{ "OS.mac?", process.osMac },
    .{ "OS.linux?", process.osLinux },
    .{ "MacOS.version", process.macosVersion },
    .{ "Hardware::CPU.arch", process.cpuArch },
    .{ "Hardware::CPU.arm?", process.osMac }, // arm? = true on Apple Silicon
    .{ "Hardware::CPU.intel?", process.osLinux }, // intel? = false on Apple Silicon
    .{ "OS.kernel_version", process.macosVersion },

    // Pathname.new
    .{ "Pathname.new", process.pathnameNew },

    // Utils.safe_popen_read
    .{ "Utils.safe_popen_read", process.safePopenRead },

    // ENV access
    .{ "ENV.get", process.envGet },
    .{ "ENV.set", process.envSet },
});

/// Dispatch table for receiver method calls (e.g., path.mkpath, path.exist?)
pub const receiver_builtins = std.StaticStringMap(BuiltinFn).initComptime(.{
    // Pathname
    .{ "mkpath", pathname.mkpath },
    .{ "exist?", pathname.existQ },
    .{ "directory?", pathname.directoryQ },
    .{ "symlink?", pathname.symlinkQ },
    .{ "children", pathname.children },
    .{ "write", pathname.write },
    .{ "read", pathname.read },
    .{ "basename", pathname.basename },
    .{ "dirname", pathname.dirname },
    .{ "extname", pathname.extname },
    .{ "to_s", pathname.toS },
    .{ "realpath", pathname.realpath },
    .{ "install_symlink", pathname.installSymlink },
    .{ "glob", pathname.glob },
    .{ "file?", pathname.fileQ },
    .{ "unlink", pathname.unlink },
    .{ "atomic_write", pathname.atomicWrite },

    // Formula path accessors (receiver is Pathname from Formula.lookup)
    .{ "opt_bin", pathname.optBin },
    .{ "opt_lib", pathname.optLib },
    .{ "opt_include", pathname.optInclude },
    .{ "opt_prefix", pathname.toS },
    .{ "pkgetc", pathname.pkgetc },

    // String methods
    .{ "gsub", string.gsub },
    .{ "gsub!", string.gsubBang },
    .{ "sub", string.sub },
    .{ "sub!", string.subBang },
    .{ "chomp", string.chomp },
    .{ "strip", string.strip },
    .{ "split", string.split },
    .{ "include?", string.includeQ },
    .{ "start_with?", string.startWithQ },
    .{ "end_with?", string.endWithQ },
    .{ "empty?", string.emptyQ },
    .{ "length", string.length },
    .{ "size", string.length },
    .{ "+", string.concat },
    // `s << x` — Ruby shovel; mutates in Ruby but we return a fresh
    // string (arena-allocated) since Values are immutable here. Callers
    // that care about in-place semantics reassign (`s = s << x`).
    .{ "<<", string.concat },

    // Version-style accessors on strings — keep the dispatch keys tight
    // to match Homebrew's shape (OS.kernel_version.major, etc.).
    .{ "major", string.major },
    .{ "minor", string.minor },
    .{ "patch", string.patch },
    .{ "to_i", string.toI },
});
