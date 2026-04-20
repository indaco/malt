//! malt — per-command help text
//! Returns help text for each subcommand, displayed on -h / --help.

const std = @import("std");
const io_mod = @import("../ui/io.zig");

/// Check if args contain -h or --help. If so, print help to stdout (so the
/// output is pipeable — `malt install --help | less`) and return true.
pub fn showIfRequested(args: []const []const u8, command: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            io_mod.stdoutWriteAll(helpFor(command));
            return true;
        }
    }
    return false;
}

/// Return the help text for a given command, or a generic fallback. Exposed
/// so tests can assert content without spawning the binary.
pub fn helpFor(command: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "install", install_help },
        .{ "uninstall", uninstall_help },
        .{ "upgrade", upgrade_help },
        .{ "update", update_help },
        .{ "outdated", outdated_help },
        .{ "list", list_help },
        .{ "info", info_help },
        .{ "search", search_help },
        .{ "doctor", doctor_help },
        .{ "tap", tap_help },
        .{ "migrate", migrate_help },
        .{ "rollback", rollback_help },
        .{ "run", run_help },
        .{ "link", link_help },
        .{ "unlink", unlink_help2 },
        .{ "completions", completions_help },
        .{ "backup", backup_help },
        .{ "restore", restore_help },
        .{ "purge", purge_help },
        .{ "uses", uses_help },
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
    \\  malt install --local <path.rb>         install from a local Ruby formula
    \\
    \\Flags:
    \\  --cask             Force cask installation
    \\  --formula          Force formula installation
    \\  --local            Install from a local .rb file path (code-exec surface:
    \\                     only pass files you trust)
    \\  --dry-run          Show what would be installed
    \\  --force            Overwrite existing installations
    \\  --use-system-ruby[=<name>,...]  Run post_install via the system Ruby interpreter
    \\                     (experimental, sandboxed). A bare flag requires a single
    \\                     package; use =<name>,... to scope when installing multiple.
    \\  --quiet, -q        Suppress non-error output
    \\  --json             Output result as JSON
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

const doctor_help =
    \\Usage: malt doctor
    \\
    \\Run system health checks: database integrity, orphaned store
    \\entries, broken symlinks, disk space, API reachability, and more.
    \\
;

const tap_help =
    \\Usage: malt tap [<user>/<repo>]
    \\       malt tap --refresh <user>/<repo>
    \\       malt untap <user>/<repo>
    \\
    \\Manage taps. Without arguments, lists registered taps + their
    \\pinned commit. `tap <slug>` resolves the repo's HEAD commit at
    \\that moment and stores it; subsequent installs from the tap fetch
    \\against the pin, not whatever HEAD happens to point to later.
    \\`--refresh` explicitly advances the pin to the current HEAD.
    \\
    \\Taps are auto-resolved during install, so explicit `tap` is
    \\usually unnecessary — the auto-tap also pins the SHA on first use.
    \\
;

const migrate_help =
    \\Usage: malt migrate [flags]
    \\
    \\Import an existing Homebrew installation into malt.
    \\Does NOT modify the Homebrew installation.
    \\
    \\Flags:
    \\  --dry-run          Show what would be migrated
    \\  --json             Emit a machine-readable summary on stdout (pairs with
    \\                     --dry-run to list kegs, or with a real run to report
    \\                     per-category names + counts for migrated / skipped /
    \\                     failed).
    \\  --use-system-ruby=<name>,...  Run post_install via the system Ruby interpreter
    \\                     (experimental, sandboxed) for the named kegs only. A bare
    \\                     `--use-system-ruby` is not allowed here — it would widen
    \\                     the trust boundary to every keg discovered in the Cellar.
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

const completions_help =
    \\Usage: malt completions <shell>
    \\
    \\Generate a shell completion script. The script is printed to stdout
    \\so it can be eval'd for the current shell or redirected to a file.
    \\
    \\Shells:
    \\  bash    Source with: eval "$(malt completions bash)"
    \\  zsh     Source with: eval "$(malt completions zsh)"
    \\  fish    Source with: malt completions fish | source
    \\
    \\Permanent install:
    \\  bash    malt completions bash > /usr/local/etc/bash_completion.d/malt
    \\  zsh     malt completions zsh  > "${fpath[1]}/_malt"
    \\  fish    malt completions fish > ~/.config/fish/completions/malt.fish
    \\
;

const backup_help =
    \\Usage: malt backup [flags]
    \\
    \\Dump the list of directly-installed formulae and casks to a plain-text
    \\file that `malt restore` can consume to reproduce the environment on
    \\another machine.
    \\
    \\By default the file is written to the current directory with a
    \\timestamped name, e.g. `malt-backup-2026-04-10T14-32-05.txt`.
    \\
    \\Flags:
    \\  --output, -o <path>  Write to a specific file (use `-` for stdout)
    \\  --versions           Pin each entry to its current version (@ver)
    \\  --quiet, -q          Suppress non-error output
    \\
    \\Examples:
    \\  malt backup
    \\  malt backup -o ~/dotfiles/packages.txt
    \\  malt backup --versions -o - > snapshot.txt
    \\
;

const purge_help =
    \\Usage: malt purge <scope> [<scope>...] [flags]
    \\
    \\Unified housekeeping and full-wipe command. At least one scope flag
    \\is required — running `malt purge` with no scope is an error.
    \\
    \\Scopes (one or more required):
    \\  --store-orphans      Refcount-0 blobs in {prefix}/store
    \\  --unused-deps        Indirect-install kegs no other package needs
    \\  --cache[=DAYS]       Cache files older than DAYS (default 30)
    \\  --downloads          Wipe {cache}/downloads entirely        (typed confirm)
    \\  --stale-casks        Cask cache + Caskroom for uninstalled casks
    \\  --old-versions       Non-latest versions in {prefix}/Cellar (typed confirm)
    \\  --housekeeping       = --store-orphans --unused-deps --cache --stale-casks
    \\  --wipe               Nuclear: every malt artefact on disk    (typed confirm)
    \\
    \\Shared flags:
    \\  --dry-run, -n        Preview only
    \\  --yes, -y            Skip every typed confirmation prompt
    \\  --quiet, -q          Suppress per-item output
    \\  --backup, -b <path>  Write a `mt restore`-compatible manifest first
    \\
    \\--wipe-only flags:
    \\  --keep-cache         Do not delete the cache directory
    \\  --remove-binary      Also unlink /usr/local/bin/{mt,malt}
    \\
    \\Examples:
    \\  malt purge --housekeeping
    \\  malt purge --store-orphans --dry-run
    \\  malt purge --cache=60 --stale-casks
    \\  malt purge --old-versions --yes
    \\  malt purge --wipe --backup ~/malt-snapshot.txt --remove-binary --yes
    \\
    \\For per-package removal use `mt uninstall <name>`.
    \\
;

const restore_help =
    \\Usage: malt restore <file> [flags]
    \\
    \\Read a backup file produced by `malt backup` and install every entry
    \\it lists. Formulae and casks are installed in a single batched run each
    \\so dependency resolution and parallel downloads apply normally.
    \\
    \\Flags:
    \\  --dry-run     Print the list of packages that would be installed
    \\  --force       Pass --force to the underlying install
    \\  --quiet, -q   Suppress non-error output
    \\
    \\Example:
    \\  malt restore malt-backup-2026-04-10T14-32-05.txt
    \\
;

const uses_help =
    \\Usage: malt uses <formula> [flags]
    \\
    \\Show installed packages that depend on <formula>. By default only
    \\direct dependents are shown — pass --recursive for the transitive
    \\closure.
    \\
    \\Flags:
    \\  --recursive, -r   Include transitive dependents
    \\  --json            Output as JSON
    \\  --quiet, -q       Suppress status messages
    \\
    \\Examples:
    \\  malt uses openssl@3
    \\  malt uses --recursive icu4c@78
    \\  malt --json uses node@20
    \\
;
