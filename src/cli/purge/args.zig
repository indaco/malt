//! malt — purge argv parsing and shared types.

const std = @import("std");

pub const Error = error{
    InvalidArgs,
    NoScope,
    UserAborted,
    LockFailed,
    DatabaseError,
    OpenFileFailed,
    WriteFailed,
    OutOfMemory,
};

pub const default_cache_days: i64 = 30;

/// Bitfield of selected scopes.  At least one must be set or `execute`
/// errors with `NoScope`.  `wipe` is mutually exclusive with the others.
pub const Scope = struct {
    store_orphans: bool = false,
    unused_deps: bool = false,
    cache: bool = false,
    downloads: bool = false,
    stale_casks: bool = false,
    old_versions: bool = false,
    wipe: bool = false,

    pub fn isEmpty(self: Scope) bool {
        return !(self.store_orphans or self.unused_deps or self.cache or
            self.downloads or self.stale_casks or self.old_versions or self.wipe);
    }

    pub fn anyNonWipe(self: Scope) bool {
        return self.store_orphans or self.unused_deps or self.cache or
            self.downloads or self.stale_casks or self.old_versions;
    }
};

/// User-controllable options parsed from the purge subcommand's argv.
pub const Options = struct {
    scope: Scope = .{},
    cache_days: i64 = default_cache_days,
    yes: bool = false,
    backup_path: ?[]const u8 = null,
    // --wipe-only:
    keep_cache: bool = false,
    remove_binary: bool = false,
};

/// Category of a deletion target — used by buildPlan/wipe.
pub const Category = enum {
    linked_dir, // {prefix}/bin, sbin, lib, include, share, etc
    opt, // {prefix}/opt
    cellar, // {prefix}/Cellar
    caskroom, // {prefix}/Caskroom
    store, // {prefix}/store
    cache, // {prefix}/cache (or $MALT_CACHE)
    tmp, // {prefix}/tmp
    db, // {prefix}/db — removed AFTER the lock is released
    prefix_root, // {prefix} itself — only removed if empty
    binary, // /usr/local/bin/{mt,malt} — opt-in via --remove-binary

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .linked_dir => "linked",
            .opt => "opt",
            .cellar => "Cellar",
            .caskroom => "Caskroom",
            .store => "store",
            .cache => "cache",
            .tmp => "tmp",
            .db => "db",
            .prefix_root => "prefix",
            .binary => "binary",
        };
    }
};

pub const Target = struct {
    path: []const u8,
    category: Category,
};

pub fn parseArgs(args: []const []const u8) Error!Options {
    var opts: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Scope flags
        if (std.mem.eql(u8, arg, "--store-orphans")) {
            opts.scope.store_orphans = true;
        } else if (std.mem.eql(u8, arg, "--unused-deps")) {
            opts.scope.unused_deps = true;
        } else if (std.mem.eql(u8, arg, "--cache")) {
            opts.scope.cache = true;
        } else if (std.mem.startsWith(u8, arg, "--cache=")) {
            opts.scope.cache = true;
            opts.cache_days = std.fmt.parseInt(i64, arg["--cache=".len..], 10) catch
                return Error.InvalidArgs;
        } else if (std.mem.eql(u8, arg, "--downloads")) {
            opts.scope.downloads = true;
        } else if (std.mem.eql(u8, arg, "--stale-casks")) {
            opts.scope.stale_casks = true;
        } else if (std.mem.eql(u8, arg, "--old-versions")) {
            opts.scope.old_versions = true;
        } else if (std.mem.eql(u8, arg, "--housekeeping")) {
            opts.scope.store_orphans = true;
            opts.scope.unused_deps = true;
            opts.scope.cache = true;
            opts.scope.stale_casks = true;
        } else if (std.mem.eql(u8, arg, "--wipe")) {
            opts.scope.wipe = true;
        }

        // Shared flags
        else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--backup") or std.mem.eql(u8, arg, "-b")) {
            if (i + 1 >= args.len) return Error.InvalidArgs;
            i += 1;
            opts.backup_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--backup=")) {
            opts.backup_path = arg["--backup=".len..];
        }

        // --wipe-only flags
        else if (std.mem.eql(u8, arg, "--keep-cache")) {
            opts.keep_cache = true;
        } else if (std.mem.eql(u8, arg, "--remove-binary")) {
            opts.remove_binary = true;
        }

        // Anything else is invalid (positionals included)
        else {
            return Error.InvalidArgs;
        }
    }

    if (opts.scope.wipe and opts.scope.anyNonWipe()) return Error.InvalidArgs;
    return opts;
}
