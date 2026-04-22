//! Cross-platform path-relocation facade. Re-exports the active
//! backend's symbols under format-agnostic names so cellar / doctor
//! never import a macOS- or ELF-specific module directly.
//!
//! Dispatch is a `comptime` switch on the target OS — there is no
//! runtime indirection and no binary-size cost beyond the one active
//! backend. Adding Linux support is additive: drop
//! `src/elf/patcher.zig` in place with the same public surface and
//! uncomment the `.linux` arm below.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.target.os.tag) {
    .macos => @import("../macho/patcher.zig"),
    // .linux => @import("../elf/patcher.zig"),  // future task
    else => @compileError("unsupported target for patch relocation facade"),
};

pub const Replacement = backend.Replacement;
pub const PatchOutcome = backend.PatchOutcome;
pub const OverflowEntry = backend.OverflowEntry;
pub const PatchError = backend.PatchError;
pub const FallbackError = backend.FallbackError;
pub const patchPathsCollecting = backend.patchPathsCollecting;
pub const flushOverflow = backend.flushOverflow;
pub const external_tool_name = backend.external_tool_name;
