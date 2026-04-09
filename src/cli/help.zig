//! malt — per-command help text
//! Returns help text for each subcommand, displayed on -h / --help.

const std = @import("std");

/// Check if args contain -h or --help. If so, print help and return true.
pub fn showIfRequested(args: []const []const u8, command: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            const text = helpFor(command);
            std.fs.File.stderr().writeAll(text) catch {};
            return true;
        }
    }
    return false;
}

fn helpFor(command: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "install", install_help },
        .{ "uninstall", uninstall_help },
        .{ "upgrade", upgrade_help },
        .{ "update", update_help },
        .{ "outdated", outdated_help },
        .{ "list", list_help },
        .{ "info", info_help },
        .{ "search", search_help },
        .{ "cleanup", cleanup_help },
        .{ "gc", gc_help },
        .{ "doctor", doctor_help },
        .{ "tap", tap_help },
        .{ "autoremove", autoremove_help },
        .{ "migrate", migrate_help },
        .{ "rollback", rollback_help },
        .{ "run", run_help },
        .{ "link", link_help },
        .{ "unlink", unlink_help2 },
    });
    return map.get(command) orelse "No help available.\n";
}

const install_help =
    \\Usage: malt install <package> [<package> ...] [flags]
    \\
    \\Install formulas, casks, or tap formulas.
    \\
    \\  malt install <name>                    auto-detect formula or cask
    \\  malt install <name>@<version>          specific version
    \\  malt install --cask <app>              explicit cask
    \\  malt install --formula <name>          explicit formula
    \\  malt install <user>/<tap>/<formula>    inline tap
    \\
    \\Flags:
    \\  --cask         Force cask installation
    \\  --formula      Force formula installation
    \\  --dry-run      Show what would be installed
    \\  --force        Overwrite existing installations
    \\  --quiet, -q    Suppress non-error output
    \\  --json         Output result as JSON
    \\
;

const uninstall_help =
    \\Usage: malt uninstall <package> [flags]
    \\
    \\Remove installed packages.
    \\
    \\Flags:
    \\  --force        Remove even if other packages depend on it
    \\  --zap          Deep clean (cask only)
    \\  --dry-run      Show what would be removed
    \\
;

const upgrade_help =
    \\Usage: malt upgrade [<package>] [flags]
    \\
    \\Upgrade installed packages to latest versions.
    \\
    \\Flags:
    \\  --all          Upgrade everything (formulas + casks)
    \\  --cask         Upgrade casks only
    \\  --formula      Upgrade formulas only
    \\  --dry-run      Show what would be upgraded
    \\
;

const update_help =
    \\Usage: malt update
    \\
    \\Refresh the local formula/cask metadata cache.
    \\
;

const outdated_help =
    \\Usage: malt outdated [flags]
    \\
    \\List packages with newer versions available.
    \\
    \\Flags:
    \\  --json         Output as JSON
    \\  --formula      Show outdated formulas only
    \\  --cask         Show outdated casks only
    \\  --quiet, -q    Suppress status messages
    \\
;

const list_help =
    \\Usage: malt list [flags]
    \\
    \\List installed packages.
    \\
    \\Flags:
    \\  --versions     Show version numbers
    \\  --formula      Formulas only
    \\  --cask         Casks only
    \\  --pinned       Pinned packages only
    \\  --json         Output as JSON
    \\  --quiet, -q    Names only, one per line
    \\
;

const info_help =
    \\Usage: malt info <package> [flags]
    \\
    \\Show detailed information about a formula or cask.
    \\
    \\Flags:
    \\  --formula      Show formula info only
    \\  --cask         Show cask info only
    \\  --json         Output as JSON
    \\
;

const search_help =
    \\Usage: malt search <query> [flags]
    \\
    \\Search formulas and casks by name.
    \\
    \\Flags:
    \\  --formula      Search formulas only
    \\  --cask         Search casks only
    \\  --json         Output as JSON
    \\
;

const cleanup_help =
    \\Usage: malt cleanup [flags]
    \\
    \\Remove old package versions and prune caches.
    \\
    \\Flags:
    \\  --dry-run      Show what would be removed
    \\  --prune=<days> Cache age threshold (default: 30)
    \\  -s             Scrub entire download cache
    \\
;

const gc_help =
    \\Usage: malt gc [flags]
    \\
    \\Garbage collect unreferenced store entries.
    \\
    \\Flags:
    \\  --dry-run      Show what would be removed
    \\
;

const doctor_help =
    \\Usage: malt doctor
    \\
    \\Run system health checks: database integrity, orphaned store
    \\entries, broken symlinks, disk space, API reachability, and more.
    \\
;

const tap_help =
    \\Usage: malt tap [<user>/<repo>]
    \\       malt untap <user>/<repo>
    \\
    \\Manage taps. Without arguments, lists registered taps.
    \\Taps are auto-resolved during install, so explicit tap is optional.
    \\
;

const autoremove_help =
    \\Usage: malt autoremove [flags]
    \\
    \\Remove orphaned dependencies no longer needed by any
    \\directly-installed package.
    \\
    \\Flags:
    \\  --dry-run      Show what would be removed
    \\
;

const migrate_help =
    \\Usage: malt migrate [flags]
    \\
    \\Import an existing Homebrew installation into malt.
    \\Does NOT modify the Homebrew installation.
    \\
    \\Flags:
    \\  --dry-run      Show what would be migrated
    \\
;

const rollback_help =
    \\Usage: malt rollback <package> [flags]
    \\
    \\Revert a package to its previous version using the
    \\content-addressable store. No re-download needed.
    \\
    \\Flags:
    \\  --dry-run      Show what would happen
    \\
;

const run_help =
    \\Usage: malt run <package> [-- <args...>]
    \\
    \\Run a package binary without installing it. Downloads to a
    \\temp directory, executes, and cleans up. If the package is
    \\already installed, runs the installed binary directly.
    \\
    \\Example:
    \\  malt run jq -- --version
    \\
;

const link_help =
    \\Usage: malt link <formula> [flags]
    \\
    \\Create symlinks for an installed keg in the prefix (bin/, lib/, etc.).
    \\
    \\Flags:
    \\  --overwrite    Replace existing symlinks
    \\  --force, -f    Same as --overwrite
    \\
;

const unlink_help2 =
    \\Usage: malt unlink <formula>
    \\
    \\Remove symlinks for an installed keg from the prefix.
    \\The keg remains installed in the Cellar.
    \\
;
