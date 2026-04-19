//! malt — update origin detection.
//!
//! Self-update must not overwrite a brew-managed binary. Classify by
//! resolved path so the updater can defer to `brew upgrade` instead of
//! fighting the Cellar/Caskroom.

const std = @import("std");
const fs_compat = @import("../fs/compat.zig");

pub const Origin = enum { direct, homebrew };

/// Pure classification of a *resolved* (realpath-ed) binary path.
///
/// Caller must resolve symlinks first — `std.process.executablePath` on
/// darwin returns the argv[0] shape, which for brew installs is a shim
/// at `$(brew --prefix)/bin/malt`. Classifying the shim directly would
/// misreport a brew install as `direct`.
pub fn classify(resolved_path: []const u8) Origin {
    // Match both formula (`/Cellar/`) and cask (`/Caskroom/`) layouts.
    // Stable across Intel, Apple Silicon, linuxbrew, and custom
    // HOMEBREW_PREFIX — only the prefix changes, the component names don't.
    if (std.mem.indexOf(u8, resolved_path, "/Cellar/") != null) return .homebrew;
    if (std.mem.indexOf(u8, resolved_path, "/Caskroom/") != null) return .homebrew;
    return .direct;
}

/// Classify a possibly-symlinked path: resolve via `realpath(2)`, then
/// `classify()` the real path. Returns `.direct` if the path cannot be
/// resolved - a missing/unreadable binary should fall through to the
/// normal updater rather than refusing based on a resolution error.
pub fn classifyResolved(out_buf: []u8, path: []const u8) Origin {
    const resolved = fs_compat.cwd().realpath(path, out_buf) catch return .direct;
    return classify(resolved);
}
