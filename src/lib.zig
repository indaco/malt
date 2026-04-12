//! malt — shared library root for test imports.
//! Re-exports all modules that tests need to access.

pub const cask = @import("core/cask.zig");
pub const cellar = @import("core/cellar.zig");
pub const deps = @import("core/deps.zig");
pub const formula = @import("core/formula.zig");
pub const linker = @import("core/linker.zig");
pub const store = @import("core/store.zig");
pub const lock = @import("db/lock.zig");
pub const schema = @import("db/schema.zig");
pub const sqlite = @import("db/sqlite.zig");
pub const atomic = @import("fs/atomic.zig");
pub const clonefile = @import("fs/clonefile.zig");
pub const codesign = @import("macho/codesign.zig");
pub const parser = @import("macho/parser.zig");
pub const patcher = @import("macho/patcher.zig");
pub const api = @import("net/api.zig");
pub const client = @import("net/client.zig");
pub const output = @import("ui/output.zig");
pub const progress = @import("ui/progress.zig");
pub const version = @import("version.zig");
pub const completions = @import("cli/completions.zig");
pub const backup = @import("cli/backup.zig");
pub const purge = @import("cli/purge.zig");
pub const install = @import("cli/install.zig");
pub const doctor = @import("cli/doctor.zig");
pub const dsl = @import("core/dsl/root.zig");
