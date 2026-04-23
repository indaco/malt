//! malt — DSL module root
//! Re-exports the public API for the post_install DSL interpreter.

pub const ast = @import("ast.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const context = @import("context.zig");
pub const interpreter = @import("interpreter.zig");
pub const values = @import("values.zig");
pub const sandbox = @import("sandbox.zig");
pub const fallback_log = @import("fallback_log.zig");
pub const builtins = @import("builtins/root.zig");

// Public API re-exports
pub const executePostInstall = interpreter.executePostInstall;
pub const DslError = context.DslError;
pub const ExecContext = context.ExecContext;
pub const FormulaRef = context.FormulaRef;
pub const FallbackLog = fallback_log.FallbackLog;
pub const FallbackEntry = fallback_log.FallbackEntry;
pub const FallbackReason = fallback_log.FallbackReason;
pub const Value = values.Value;
