//! malt — completions command
//! Prints shell completion scripts for bash, zsh, or fish to stdout.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");
const help = @import("help.zig");

pub const Shell = enum { bash, zsh, fish };

/// Parse a shell name into a Shell enum. Returns null for unknown shells.
pub fn parseShell(name: []const u8) ?Shell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    return null;
}

/// Return the completion script for a given shell.
pub fn scriptFor(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => bash_script,
        .zsh => zsh_script,
        .fish => fish_script,
    };
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    if (help.showIfRequested(args, "completions")) return;

    if (args.len == 0) {
        printUsage();
        std.process.exit(2);
    }

    const shell = parseShell(args[0]) orelse {
        const stderr = fs_compat.stderrFile();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: unknown shell '{s}'. Supported shells: bash, zsh, fish\n",
            .{args[0]},
        ) catch "malt: unknown shell. Supported shells: bash, zsh, fish\n";
        // exit(2) below is the real signal; a closed stderr shouldn't block that.
        stderr.writeAll(msg) catch {};
        std.process.exit(2);
    };

    try fs_compat.stdoutFile().writeAll(scriptFor(shell));
}

fn printUsage() void {
    const usage =
        \\Usage: malt completions <shell>
        \\
        \\Generate a shell completion script for bash, zsh, or fish.
        \\The script is printed to stdout so it can be eval'd or redirected.
        \\
        \\Shells:
        \\  bash    source with: eval "$(malt completions bash)"
        \\  zsh     source with: eval "$(malt completions zsh)"
        \\  fish    source with: malt completions fish | source
        \\
    ;
    // Usage is diagnostic; caller always follows with exit(2).
    fs_compat.stderrFile().writeAll(usage) catch {};
}

// ---------------------------------------------------------------------------
// bash
// ---------------------------------------------------------------------------

pub const bash_script =
    \\# bash completion for malt
    \\#
    \\# Install (temporary, current shell only):
    \\#   eval "$(malt completions bash)"
    \\#
    \\# Install (permanent):
    \\#   malt completions bash > /usr/local/etc/bash_completion.d/malt
    \\#
    \\# Requires bash-completion (brew install bash-completion@2).
    \\
    \\_malt_complete() {
    \\    local cur words cword
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    words=("${COMP_WORDS[@]}")
    \\    cword=$COMP_CWORD
    \\
    \\    local commands="install uninstall remove upgrade update outdated list ls info search uses which doctor tap untap migrate rollback link unlink pin unpin run version completions shellenv backup restore purge services bundle help"
    \\    local global_flags="--verbose -v --quiet -q --json --dry-run --help -h --version"
    \\
    \\    # Find the first non-flag word after the program — that's the subcommand.
    \\    local cmd="" i
    \\    for (( i=1; i<cword; i++ )); do
    \\        if [[ "${words[i]}" != -* ]]; then
    \\            cmd="${words[i]}"
    \\            break
    \\        fi
    \\    done
    \\
    \\    if [[ -z "$cmd" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            COMPREPLY=( $(compgen -W "$global_flags" -- "$cur") )
    \\        else
    \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\        fi
    \\        return 0
    \\    fi
    \\
    \\    case "$cmd" in
    \\        completions|shellenv)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        version)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "update" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        services)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "list start stop restart status logs" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        bundle)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "install create list remove export import" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\    esac
    \\
    \\    local cmd_flags=""
    \\    case "$cmd" in
    \\        install)          cmd_flags="--cask --formula --local --dry-run --force --quiet -q --json" ;;
    \\        backup)           cmd_flags="--output -o --versions --quiet -q" ;;
    \\        restore)          cmd_flags="--dry-run --force --quiet -q" ;;
    \\        purge)            cmd_flags="--store-orphans --unused-deps --cache --cache= --downloads --stale-casks --old-versions --housekeeping --wipe --backup -b --keep-cache --remove-binary --yes -y --dry-run -n" ;;
    \\        uninstall|remove) cmd_flags="--force --zap --dry-run" ;;
    \\        upgrade)          cmd_flags="--all --cask --formula --dry-run --force -f" ;;
    \\        outdated)         cmd_flags="--json --formula --cask --quiet -q" ;;
    \\        list|ls)          cmd_flags="--versions --formula --cask --pinned --json --quiet -q" ;;
    \\        info)             cmd_flags="--formula --cask --json" ;;
    \\        search)           cmd_flags="--formula --cask --json" ;;
    \\        uses)             cmd_flags="--recursive -r --json --quiet -q" ;;
    \\        which)            cmd_flags="--json" ;;
    \\        migrate|rollback) cmd_flags="--dry-run" ;;
    \\        link)             cmd_flags="--overwrite --force -f" ;;
    \\        services)         cmd_flags="--tail --stderr --follow -f --system --json" ;;
    \\        bundle)           cmd_flags="--dry-run --format --from-installed --purge" ;;
    \\        run)              cmd_flags="--keep" ;;
    \\    esac
    \\
    \\    if [[ "$cur" == -* ]]; then
    \\        COMPREPLY=( $(compgen -W "$cmd_flags $global_flags" -- "$cur") )
    \\    fi
    \\    return 0
    \\}
    \\
    \\complete -F _malt_complete malt
    \\complete -F _malt_complete mt
    \\
;

// ---------------------------------------------------------------------------
// zsh
// ---------------------------------------------------------------------------

pub const zsh_script =
    \\#compdef malt mt
    \\#
    \\# zsh completion for malt
    \\#
    \\# Install (temporary, current shell only) — run AFTER `compinit`:
    \\#   eval "$(malt completions zsh)"
    \\#
    \\# Install (permanent):
    \\#   malt completions zsh > "${fpath[1]}/_malt"
    \\#
    \\# Requires: autoload -Uz compinit && compinit
    \\
    \\_malt() {
    \\    local curcontext="$curcontext" state line
    \\    local -a commands
    \\
    \\    commands=(
    \\        'install:Install formulas, casks, or tap formulas'
    \\        'uninstall:Remove installed packages'
    \\        'remove:Remove installed packages (alias for uninstall)'
    \\        'upgrade:Upgrade installed packages'
    \\        'update:Refresh metadata cache'
    \\        'outdated:List packages with newer versions available'
    \\        'list:List installed packages'
    \\        'ls:List installed packages (alias for list)'
    \\        'info:Show detailed package information'
    \\        'search:Search formulas and casks'
    \\        'uses:Show installed packages that depend on a formula'
    \\        'which:Resolve a prefix binary to its owning keg'
    \\        'doctor:System health check'
    \\        'tap:Manage taps'
    \\        'untap:Remove a tap'
    \\        'migrate:Import existing Homebrew installation'
    \\        'rollback:Revert a package to its previous version'
    \\        'link:Create symlinks for an installed keg'
    \\        'unlink:Remove symlinks (keg stays installed)'
    \\        'pin:Protect an installed keg from upgrade'
    \\        'unpin:Lift the pin on an installed keg'
    \\        'run:Run a package binary without installing'
    \\        'version:Show version or self-update'
    \\        'completions:Generate shell completion scripts'
    \\        'shellenv:Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init'
    \\        'backup:Dump installed packages to a restorable text file'
    \\        'restore:Reinstall every package listed in a backup file'
    \\        'purge:Housekeeping or full wipe (requires a scope flag)'
    \\        'services:Manage long-running launchd services'
    \\        'bundle:Install or export a Brewfile/Maltfile.json bundle'
    \\        'help:Show help'
    \\    )
    \\
    \\    _arguments -C \
    \\        '(--verbose -v)'{--verbose,-v}'[Verbose output]' \
    \\        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\        '--json[JSON output]' \
    \\        '--dry-run[Preview without executing]' \
    \\        '(- : *)'{--help,-h}'[Show help]' \
    \\        '(- : *)--version[Show version]' \
    \\        '1: :->command' \
    \\        '*:: :->args' && return 0
    \\
    \\    case $state in
    \\        command)
    \\            _describe -t commands 'malt command' commands
    \\            ;;
    \\        args)
    \\            case $words[1] in
    \\                install)
    \\                    _arguments \
    \\                        '--cask[Force cask installation]' \
    \\                        '--formula[Force formula installation]' \
    \\                        '--local[Install from a local .rb path]:formula:_files -g "*.rb"' \
    \\                        '--dry-run[Show what would be installed]' \
    \\                        '--force[Overwrite existing installations]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\                        '--json[Output result as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                uninstall|remove)
    \\                    _arguments \
    \\                        '--force[Remove even if depended on]' \
    \\                        '--zap[Deep clean (cask only)]' \
    \\                        '--dry-run[Show what would be removed]' \
    \\                        '*::package:'
    \\                    ;;
    \\                upgrade)
    \\                    _arguments \
    \\                        '--all[Upgrade everything]' \
    \\                        '--cask[Upgrade casks only]' \
    \\                        '--formula[Upgrade formulas only]' \
    \\                        '--dry-run[Show what would be upgraded]' \
    \\                        '(--force -f)'{--force,-f}'[Bypass pin protection]' \
    \\                        '*::package:'
    \\                    ;;
    \\                pin|unpin)
    \\                    _arguments '*::keg:'
    \\                    ;;
    \\                run)
    \\                    _arguments \
    \\                        '--keep[Cache extracted bottle under {cache}/run/<sha256>/]' \
    \\                        '*::package:'
    \\                    ;;
    \\                which)
    \\                    _arguments \
    \\                        '--json[Output as JSON]' \
    \\                        '*::name-or-path:'
    \\                    ;;
    \\                outdated)
    \\                    _arguments \
    \\                        '--json[Output as JSON]' \
    \\                        '--formula[Show outdated formulas only]' \
    \\                        '--cask[Show outdated casks only]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress status messages]'
    \\                    ;;
    \\                list|ls)
    \\                    _arguments \
    \\                        '--versions[Show version numbers]' \
    \\                        '--formula[Formulas only]' \
    \\                        '--cask[Casks only]' \
    \\                        '--pinned[Pinned packages only]' \
    \\                        '--json[Output as JSON]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Names only]'
    \\                    ;;
    \\                info)
    \\                    _arguments \
    \\                        '--formula[Show formula info only]' \
    \\                        '--cask[Show cask info only]' \
    \\                        '--json[Output as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                search)
    \\                    _arguments \
    \\                        '--formula[Search formulas only]' \
    \\                        '--cask[Search casks only]' \
    \\                        '--json[Output as JSON]' \
    \\                        '*::query:'
    \\                    ;;
    \\                migrate|rollback)
    \\                    _arguments '--dry-run[Preview without executing]'
    \\                    ;;
    \\                link)
    \\                    _arguments \
    \\                        '--overwrite[Replace existing symlinks]' \
    \\                        '(--force -f)'{--force,-f}'[Same as --overwrite]' \
    \\                        '*::formula:'
    \\                    ;;
    \\                completions|shellenv)
    \\                    _values 'shell' bash zsh fish
    \\                    ;;
    \\                backup)
    \\                    _arguments \
    \\                        '(--output -o)'{--output,-o}'[Write to a specific file]:path:_files' \
    \\                        '--versions[Pin each entry to its current version]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]'
    \\                    ;;
    \\                restore)
    \\                    _arguments \
    \\                        '--dry-run[Preview without installing]' \
    \\                        '--force[Pass --force to the install]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\                        '*:file:_files'
    \\                    ;;
    \\                purge)
    \\                    _arguments \
    \\                        '--store-orphans[Refcount-0 store blobs]' \
    \\                        '--unused-deps[Orphaned dependency kegs]' \
    \\                        '--cache=-[Prune cache files older than N days]::days:' \
    \\                        '--cache[Prune cache files older than 30 days]' \
    \\                        '--downloads[Wipe the downloads cache]' \
    \\                        '--stale-casks[Remove cache + Caskroom for uninstalled casks]' \
    \\                        '--old-versions[Remove non-latest Cellar versions]' \
    \\                        '--housekeeping[All safe scopes at once]' \
    \\                        '--wipe[Nuclear: remove every malt artefact]' \
    \\                        '(--backup -b)'{--backup,-b}'[Write a restorable manifest before deleting]:path:_files' \
    \\                        '--keep-cache[--wipe only: leave the cache directory intact]' \
    \\                        '--remove-binary[--wipe only: also unlink /usr/local/bin/{mt,malt}]' \
    \\                        '(--yes -y)'{--yes,-y}'[Skip every typed confirmation]' \
    \\                        '(--dry-run -n)'{--dry-run,-n}'[Preview without removing]'
    \\                    ;;
    \\                version)
    \\                    _values 'subcommand' 'update[Self-update the binary]'
    \\                    ;;
    \\                services)
    \\                    _values 'subcommand' \
    \\                        'list[Show registered services and runtime state]' \
    \\                        'start[Bootstrap a service under launchd]' \
    \\                        'stop[Boot a service out of launchd]' \
    \\                        'restart[stop then start]' \
    \\                        'status[Show registered + runtime state]' \
    \\                        'logs[Tail a service log file]'
    \\                    ;;
    \\                bundle)
    \\                    _values 'subcommand' \
    \\                        'install[Install members of a Brewfile/Maltfile.json]' \
    \\                        'create[Write currently-installed set to a bundle file]' \
    \\                        'list[List bundles registered in the database]' \
    \\                        'remove[Unregister a bundle]' \
    \\                        'export[Print bundle to stdout]' \
    \\                        'import[Register a bundle definition without installing]'
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\}
    \\
    \\# When sourced via `eval`, register the completion with the running shell.
    \\# When placed in fpath as `_malt`, the `#compdef` line above handles it and
    \\# this call is harmless.
    \\compdef _malt malt mt 2>/dev/null || true
    \\
;

// ---------------------------------------------------------------------------
// fish
// ---------------------------------------------------------------------------

pub const fish_script =
    \\# fish completion for malt
    \\#
    \\# Install (temporary, current shell only):
    \\#   malt completions fish | source
    \\#
    \\# Install (permanent):
    \\#   malt completions fish > ~/.config/fish/completions/malt.fish
    \\
    \\function __malt_needs_command
    \\    set -l tokens (commandline -opc)
    \\    set -l i 2
    \\    while test $i -le (count $tokens)
    \\        if not string match -q -- '-*' $tokens[$i]
    \\            return 1
    \\        end
    \\        set i (math $i + 1)
    \\    end
    \\    return 0
    \\end
    \\
    \\function __malt_using_command
    \\    set -l tokens (commandline -opc)
    \\    set -l i 2
    \\    while test $i -le (count $tokens)
    \\        if not string match -q -- '-*' $tokens[$i]
    \\            if test "$tokens[$i]" = "$argv[1]"
    \\                return 0
    \\            end
    \\            return 1
    \\        end
    \\        set i (math $i + 1)
    \\    end
    \\    return 1
    \\end
    \\
    \\for __malt_bin in malt mt
    \\    complete -c $__malt_bin -f
    \\
    \\    # Global flags
    \\    complete -c $__malt_bin -s v -l verbose -d 'Verbose output'
    \\    complete -c $__malt_bin -s q -l quiet   -d 'Suppress non-error output'
    \\    complete -c $__malt_bin      -l json    -d 'JSON output'
    \\    complete -c $__malt_bin      -l dry-run -d 'Preview without executing'
    \\    complete -c $__malt_bin -s h -l help    -d 'Show help'
    \\    complete -c $__malt_bin      -l version -d 'Show version'
    \\
    \\    # Subcommands
    \\    complete -c $__malt_bin -n __malt_needs_command -a install     -d 'Install formulas, casks, or tap formulas'
    \\    complete -c $__malt_bin -n __malt_needs_command -a uninstall   -d 'Remove installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a remove      -d 'Remove installed packages (alias)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a upgrade     -d 'Upgrade installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a update      -d 'Refresh metadata cache'
    \\    complete -c $__malt_bin -n __malt_needs_command -a outdated    -d 'List packages with newer versions'
    \\    complete -c $__malt_bin -n __malt_needs_command -a list        -d 'List installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a ls          -d 'List installed packages (alias)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a info        -d 'Show detailed package information'
    \\    complete -c $__malt_bin -n __malt_needs_command -a search      -d 'Search formulas and casks'
    \\    complete -c $__malt_bin -n __malt_needs_command -a uses        -d 'Show packages that depend on a formula'
    \\    complete -c $__malt_bin -n __malt_needs_command -a which       -d 'Resolve a prefix binary to its owning keg'
    \\    complete -c $__malt_bin -n __malt_needs_command -a doctor      -d 'System health check'
    \\    complete -c $__malt_bin -n __malt_needs_command -a tap         -d 'Manage taps'
    \\    complete -c $__malt_bin -n __malt_needs_command -a untap       -d 'Remove a tap'
    \\    complete -c $__malt_bin -n __malt_needs_command -a migrate     -d 'Import existing Homebrew'
    \\    complete -c $__malt_bin -n __malt_needs_command -a rollback    -d 'Revert package to previous version'
    \\    complete -c $__malt_bin -n __malt_needs_command -a link        -d 'Create symlinks for a keg'
    \\    complete -c $__malt_bin -n __malt_needs_command -a unlink      -d 'Remove symlinks (keg stays)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a pin         -d 'Protect an installed keg from upgrade'
    \\    complete -c $__malt_bin -n __malt_needs_command -a unpin       -d 'Lift the pin on an installed keg'
    \\    complete -c $__malt_bin -n __malt_needs_command -a run         -d 'Run package binary without installing'
    \\    complete -c $__malt_bin -n __malt_needs_command -a version     -d 'Show version or self-update'
    \\    complete -c $__malt_bin -n __malt_needs_command -a completions -d 'Generate shell completion scripts'
    \\    complete -c $__malt_bin -n __malt_needs_command -a shellenv    -d 'Print shell init exports (PATH, MANPATH, HOMEBREW_PREFIX)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a backup      -d 'Dump installed packages to a text file'
    \\    complete -c $__malt_bin -n __malt_needs_command -a restore     -d 'Reinstall every package in a backup file'
    \\    complete -c $__malt_bin -n __malt_needs_command -a purge       -d 'Housekeeping or full wipe (requires a scope)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a services    -d 'Manage long-running launchd services'
    \\    complete -c $__malt_bin -n __malt_needs_command -a bundle      -d 'Install or export a Brewfile/Maltfile.json'
    \\    complete -c $__malt_bin -n __malt_needs_command -a help        -d 'Show help'
    \\
    \\    # install
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l cask    -d 'Force cask'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l formula -d 'Force formula'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l local   -d 'Install from a local .rb path'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l force   -d 'Overwrite existing'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l json    -d 'JSON output'
    \\
    \\    # uninstall / remove
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l force   -d 'Remove even if depended on'
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l zap     -d 'Deep clean (cask only)'
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l force   -d 'Remove even if depended on'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l zap     -d 'Deep clean (cask only)'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l dry-run -d 'Preview'
    \\
    \\    # upgrade
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l all     -d 'Upgrade everything'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l cask    -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l formula -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -s f -l force -d 'Bypass pin protection'
    \\
    \\    # outdated
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l json    -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l formula -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l cask    -d 'Casks only'
    \\
    \\    # list / ls
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l versions -d 'Show version numbers'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l formula  -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l cask     -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l pinned   -d 'Pinned only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l json     -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l versions -d 'Show version numbers'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l formula  -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l cask     -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l pinned   -d 'Pinned only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l json     -d 'JSON output'
    \\
    \\    # info
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l formula -d 'Formula only'
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l cask    -d 'Cask only'
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l json    -d 'JSON output'
    \\
    \\    # search
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l formula -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l cask    -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l json    -d 'JSON output'
    \\
    \\    # uses
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l recursive -s r -d 'Include transitive dependents'
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l json               -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l quiet     -s q    -d 'Suppress status messages'
    \\
    \\    # which
    \\    complete -c $__malt_bin -n '__malt_using_command which' -l json -d 'JSON output'
    \\
    \\    # migrate / rollback
    \\    complete -c $__malt_bin -n '__malt_using_command migrate'    -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command rollback'   -l dry-run -d 'Preview'
    \\
    \\    # link
    \\    complete -c $__malt_bin -n '__malt_using_command link' -l overwrite -d 'Replace existing symlinks'
    \\    complete -c $__malt_bin -n '__malt_using_command link' -s f -l force -d 'Same as --overwrite'
    \\
    \\    # run
    \\    complete -c $__malt_bin -n '__malt_using_command run' -l keep -d 'Cache extracted bottle under {cache}/run/<sha256>/'
    \\
    \\    # completions — shell name as positional
    \\    complete -c $__malt_bin -n '__malt_using_command completions' -f -a 'bash zsh fish'
    \\
    \\    # shellenv — shell name as positional
    \\    complete -c $__malt_bin -n '__malt_using_command shellenv' -f -a 'bash zsh fish'
    \\
    \\    # backup
    \\    complete -c $__malt_bin -n '__malt_using_command backup' -s o -l output   -r -d 'Output file (use - for stdout)'
    \\    complete -c $__malt_bin -n '__malt_using_command backup'      -l versions    -d 'Pin each entry to its current version'
    \\
    \\    # restore — positional backup file
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -l dry-run -d 'Preview without installing'
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -l force   -d 'Pass --force to install'
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -F
    \\
    \\    # purge — scope flags
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l store-orphans    -d 'Refcount-0 store blobs'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l unused-deps      -d 'Orphaned dependency kegs'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l cache            -d 'Prune cache files older than 30 days (or N via --cache=N)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l downloads        -d 'Wipe the downloads cache (typed confirm)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l stale-casks      -d 'Cask cache + Caskroom for uninstalled casks'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l old-versions     -d 'Non-latest Cellar versions (typed confirm)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l housekeeping     -d 'All safe scopes at once'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l wipe             -d 'Nuclear: every malt artefact (typed confirm)'
    \\    # purge — shared / wipe-only flags
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s b -l backup        -r -d 'Write a restorable manifest before deleting'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l keep-cache       -d '--wipe only: leave the cache directory intact'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l remove-binary    -d '--wipe only: also unlink /usr/local/bin/{mt,malt}'
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s y -l yes             -d 'Skip every typed confirmation'
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s n -l dry-run          -d 'Preview without removing'
    \\
    \\    # version — sub-subcommand
    \\    complete -c $__malt_bin -n '__malt_using_command version' -f -a 'update' -d 'Self-update'
    \\
    \\    # services — sub-subcommands
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'list'    -d 'Show registered services'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'start'   -d 'Bootstrap a service under launchd'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'stop'    -d 'Boot a service out of launchd'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'restart' -d 'Stop then start'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'status'  -d 'Show runtime + DB state'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'logs'    -d 'Tail a service log'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l tail   -d 'Number of trailing log lines'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l stderr -d 'Read stderr instead of stdout'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l follow -s f -d 'Tail appended bytes until SIGINT'
    \\
    \\    # bundle — sub-subcommands
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'install' -d 'Install Brewfile/Maltfile.json members'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'create'  -d 'Write installed set to a bundle file'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'list'    -d 'List registered bundles'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'remove'  -d 'Unregister a bundle'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'export'  -d 'Print bundle to stdout'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'import'  -d 'Register a bundle without installing'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l dry-run        -d 'Preview without installing'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l format -r -a 'brewfile json' -d 'Output format'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l from-installed -d 'Populate from installed packages'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l purge          -d 'Also uninstall members on remove'
    \\end
    \\
    \\set -e __malt_bin
    \\
;
