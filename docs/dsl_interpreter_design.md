# DSL Interpreter Module Design

## ADR: Native Zig DSL Interpreter for post_install Blocks

**Status:** Accepted  
**Context:** The corpus spike (docs/post_install_histogram.md) confirms that 179/8,308 formulae have post_install blocks. A native Zig interpreter covering ~60-80 primitives handles 99.4% of them. Zero exotic patterns exist (no eval, define_method, metaprogramming).  
**Decision:** Implement a tree-walking interpreter for a Ruby subset, embedded in `src/core/dsl/`.  
**Consequences:** No external runtime dependency (mruby/Ruby). Binary size budget of <80 KB. Graceful fallback for the 1 unconvertible formula.

---

## 1. Module Structure

```
src/core/dsl/
├── root.zig           -- Module root; re-exports public API
├── lexer.zig          -- Ruby subset tokenizer
├── ast.zig            -- Tagged union AST node types
├── parser.zig         -- Recursive-descent parser
├── interpreter.zig    -- Tree-walking evaluator + ExecContext
├── values.zig         -- Runtime value enum
├── sandbox.zig        -- Path validation and sandboxing
├── fallback_log.zig   -- Structured telemetry for unsupported operations
├── builtins/
│   ├── root.zig       -- Builtin dispatch table
│   ├── pathname.zig   -- Pathname operations (/, mkpath, exist?, children, etc.)
│   ├── fileutils.zig  -- FileUtils (cp, mv, rm, rm_r, mkdir_p, chmod, touch, ln_s, ln_sf)
│   ├── ui.zig         -- ohai, opoo, odie -> src/ui/output.zig
│   ├── process.zig    -- system(), Utils.safe_popen_read, backtick capture
│   ├── inreplace.zig  -- Literal and regex inreplace
│   └── string.zig     -- gsub, sub, chomp, strip, split, interpolation eval
└── tests/
    ├── lexer_test.zig
    ├── parser_test.zig
    ├── interpreter_test.zig
    ├── sandbox_test.zig
    └── builtins_test.zig
```

### Integration with build.zig

The DSL module is compiled as part of the main `malt` executable via `src/lib.zig`. No separate compilation unit is needed. The `src/core/dsl/root.zig` file uses `@import` to pull in submodules, following the same pattern as `src/core/store.zig` and `src/core/linker.zig`.

Test files under `src/core/dsl/tests/` are added to the `test_modules` tuple in `build.zig`.

---

## 2. Lexer (`lexer.zig`)

### Token Types

```zig
pub const TokenKind = enum {
    // Literals
    string_double,      // "..." with interpolation markers
    string_single,      // '...' no interpolation
    heredoc_start,      // <<~EOS
    heredoc_body,       // heredoc content lines
    integer,            // 0, 1, 0o755, 0x1F
    float_lit,          // 3.14
    symbol,             // :foo

    // Identifiers and keywords
    identifier,         // variable names, method names
    kw_if,
    kw_unless,
    kw_else,
    kw_elsif,
    kw_end,
    kw_do,
    kw_each,
    kw_begin,
    kw_rescue,
    kw_nil,
    kw_true,
    kw_false,
    kw_def,
    kw_raise,

    // Operators
    dot,                // .
    double_colon,       // ::
    pipe,               // |
    comma,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    equals,             // =
    fat_arrow,          // =>
    question_mark,      // ? (for method names like exist?)
    bang,               // ! (for method names like rm_rf!)
    slash,              // / (path join)
    plus,
    minus,
    star,
    ampersand,          // &
    tilde,              // ~

    // Interpolation
    interp_start,       // #{
    interp_end,         // } (closing interpolation)

    // Regex
    regex,              // /pattern/flags

    // Structure
    newline,
    eof,
};
```

### Design Notes

- The lexer operates on `[]const u8` (the raw Ruby source extracted from the formula JSON).
- Source location (`line: u32, col: u32`) is tracked on every token for error reporting.
- Heredoc handling: when `<<~EOS` is encountered, the lexer switches to heredoc mode, collecting lines until the terminator. Indentation is stripped per Ruby semantics (`<<~` strips leading whitespace to the minimum indent level).
- String interpolation: double-quoted strings are emitted as a sequence of `string_double` fragments interleaved with `interp_start` / tokens / `interp_end`.
- No allocation during lexing -- tokens reference slices of the source buffer.

### Struct

```zig
pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8,
    line: u32,
    col: u32,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Lexer { ... }
    pub fn next(self: *Lexer) Token { ... }
    pub fn peek(self: *Lexer) Token { ... }
};
```

---

## 3. AST (`ast.zig`)

### Node Tagged Union

```zig
pub const SourceLoc = struct {
    line: u32,
    col: u32,
};

pub const Node = struct {
    loc: SourceLoc,
    kind: Kind,

    pub const Kind = union(enum) {
        method_call: MethodCall,
        string_literal: StringLiteral,
        int_literal: i64,
        float_literal: f64,
        bool_literal: bool,
        nil_literal: void,
        symbol_literal: []const u8,
        interpolation: []const Node,       // sequence of literal + expr parts
        path_join: PathJoin,
        assignment: Assignment,
        identifier: []const u8,
        block: []const Node,               // sequence of statements
        postfix_if: PostfixIf,
        postfix_unless: PostfixUnless,
        if_else: IfElse,
        unless_statement: UnlessStatement,
        each_loop: EachLoop,
        begin_rescue: BeginRescue,
        array_literal: []const Node,
        hash_literal: []const HashEntry,
        heredoc_literal: []const u8,
        raise_statement: RaiseStatement,
    };
};
```

### Composite Node Definitions

```zig
pub const MethodCall = struct {
    receiver: ?*const Node,    // nil for bare function calls (system, ohai)
    method: []const u8,
    args: []const Node,
    block: ?*const Node,       // do...end or {...} block
    block_params: []const []const u8,  // |param1, param2|
};

pub const StringLiteral = struct {
    parts: []const StringPart,
};

pub const StringPart = union(enum) {
    literal: []const u8,
    interpolation: *const Node,
};

pub const PathJoin = struct {
    left: *const Node,
    right: *const Node,
};

pub const Assignment = struct {
    name: []const u8,
    value: *const Node,
};

pub const PostfixIf = struct {
    body: *const Node,
    condition: *const Node,
};

pub const PostfixUnless = struct {
    body: *const Node,
    condition: *const Node,
};

pub const IfElse = struct {
    condition: *const Node,
    then_body: []const Node,
    elsif_branches: []const ElsifBranch,
    else_body: ?[]const Node,
};

pub const ElsifBranch = struct {
    condition: *const Node,
    body: []const Node,
};

pub const UnlessStatement = struct {
    condition: *const Node,
    body: []const Node,
    else_body: ?[]const Node,
};

pub const EachLoop = struct {
    iterable: *const Node,
    params: []const []const u8,
    body: []const Node,
};

pub const BeginRescue = struct {
    body: []const Node,
    rescue_body: []const Node,
    exception_var: ?[]const u8,
};

pub const HashEntry = struct {
    key: *const Node,
    value: *const Node,
};

pub const RaiseStatement = struct {
    message: ?*const Node,
};
```

### Memory Strategy

All AST nodes are allocated from an arena allocator passed to the parser. The arena is freed in one shot after `executePostInstall` completes. This matches the pattern used in `formula.zig` where `_parsed` owns the JSON tree lifetime.

---

## 4. Parser (`parser.zig`)

### Design

Recursive-descent, single-pass, no backtracking. The grammar is a strict subset of Ruby -- only constructs observed in the corpus are supported.

```zig
pub const Parser = struct {
    lexer: *Lexer,
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),

    pub fn init(allocator: std.mem.Allocator, lexer: *Lexer) Parser { ... }

    /// Parse a complete post_install block body (sequence of statements).
    pub fn parseBlock(self: *Parser) DslError![]const Node { ... }

    // Internal methods (not pub)
    fn parseStatement(self: *Parser) DslError!Node { ... }
    fn parseExpression(self: *Parser) DslError!Node { ... }
    fn parseMethodChain(self: *Parser) DslError!Node { ... }
    fn parsePrimary(self: *Parser) DslError!Node { ... }
    fn parseString(self: *Parser) DslError!Node { ... }
    fn parseHeredoc(self: *Parser) DslError!Node { ... }
    fn parseIf(self: *Parser) DslError!Node { ... }
    fn parseUnless(self: *Parser) DslError!Node { ... }
    fn parseEach(self: *Parser) DslError!Node { ... }
    fn parseBeginRescue(self: *Parser) DslError!Node { ... }
};

pub const Diagnostic = struct {
    loc: SourceLoc,
    message: []const u8,
    severity: enum { warning, err },
};
```

### Grammar Subset (EBNF sketch)

```
block         = statement* ;
statement     = assignment | expr_statement | if_stmt | unless_stmt | begin_rescue ;
expr_statement= expression (KW_IF expression | KW_UNLESS expression)? NEWLINE ;
assignment    = IDENT '=' expression NEWLINE ;
expression    = method_chain ;
method_chain  = primary ('.' method_call_tail)* ;
method_call_tail = IDENT ('(' arg_list ')')? block? ;
primary       = string | integer | float | bool | nil | symbol | array | hash
              | IDENT | '(' expression ')' | heredoc ;
string        = STRING_DOUBLE | STRING_SINGLE ;
array         = '[' (expression (',' expression)*)? ']' ;
hash          = '{' (hash_entry (',' hash_entry)*)? '}' ;
hash_entry    = (expression '=>' expression) | (IDENT ':' expression) ;
block         = 'do' ('|' param_list '|')? block 'end'
              | '{' ('|' param_list '|')? block '}' ;
```

---

## 5. Values (`values.zig`)

### Runtime Value Enum

```zig
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    nil: void,
    pathname: []const u8,      // String with path-join semantics
    array: []const Value,
    hash: []const HashPair,
    symbol: []const u8,

    pub const HashPair = struct {
        key: Value,
        value: Value,
    };

    /// Truthiness: nil and false are falsy, everything else is truthy.
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .nil => false,
            .bool => |b| b,
            else => true,
        };
    }

    /// Equality for if/unless comparisons.
    pub fn eql(self: Value, other: Value) bool { ... }

    /// Coerce to string for interpolation and path operations.
    pub fn asString(self: Value, allocator: std.mem.Allocator) ![]const u8 { ... }
};
```

### Path Join Semantics

When `Value.pathname` is on the left side of a `/` operator (mapped from `PathJoin` AST node), the result is a new `pathname` value with the right operand appended via `std.fs.path.join`. This mirrors Ruby's `Pathname#/` operator.

---

## 6. Interpreter (`interpreter.zig`)

### ExecContext

```zig
pub const ExecContext = struct {
    allocator: std.mem.Allocator,

    // Formula path bindings (all Pathname values)
    prefix: []const u8,
    cellar_path: []const u8,     // /opt/malt/Cellar/<name>/<version>
    bin: []const u8,
    sbin: []const u8,
    lib: []const u8,
    libexec: []const u8,
    include_dir: []const u8,
    share: []const u8,
    pkgshare: []const u8,
    etc: []const u8,
    var_dir: []const u8,
    opt_prefix: []const u8,
    buildpath: []const u8,

    // Global constants
    malt_prefix: []const u8,     // e.g. /opt/malt
    homebrew_prefix: []const u8, // alias for malt_prefix (compat)
    homebrew_cellar: []const u8, // /opt/malt/Cellar

    // Environment map (for ENV["KEY"] access)
    env: std.StringHashMap([]const u8),

    // Local variable scope (stack for nested blocks)
    scopes: std.ArrayList(Scope),

    // Sandbox root for path validation
    sandbox_root: []const u8,

    // Fallback log writer
    fallback_log: *FallbackLog,

    pub fn init(
        allocator: std.mem.Allocator,
        formula: *const Formula,
        malt_prefix: []const u8,
        fallback_log: *FallbackLog,
    ) ExecContext { ... }

    pub fn resolveBinding(self: *ExecContext, name: []const u8) ?Value { ... }
    pub fn pushScope(self: *ExecContext) void { ... }
    pub fn popScope(self: *ExecContext) void { ... }
    pub fn setLocal(self: *ExecContext, name: []const u8, value: Value) void { ... }
};

pub const Scope = struct {
    locals: std.StringHashMap(Value),
};
```

### Interpreter Core

```zig
pub const Interpreter = struct {
    ctx: *ExecContext,
    allocator: std.mem.Allocator,

    pub fn init(ctx: *ExecContext) Interpreter { ... }

    pub fn execute(self: *Interpreter, nodes: []const Node) DslError!void { ... }

    fn eval(self: *Interpreter, node: *const Node) DslError!Value { ... }
    fn evalMethodCall(self: *Interpreter, call: *const MethodCall, loc: SourceLoc) DslError!Value { ... }
    fn evalInterpolation(self: *Interpreter, parts: []const StringPart) DslError!Value { ... }
};
```

### Method Dispatch Order

1. Check receiver type. If receiver is a `pathname` value, dispatch to `builtins/pathname.zig`.
2. If receiver is nil (bare call), check the builtin registry in `builtins/root.zig`.
3. If method name matches a known binding (e.g., `prefix`, `bin`), return the binding value.
4. If none match, log to `FallbackLog` as `UnknownMethod` and return `DslError.UnknownMethod`.

---

## 7. Path Sandboxing (`sandbox.zig`)

### Security Model

All filesystem-mutating operations (write, rm, chmod, mkdir, symlink, mv, cp) MUST pass through the sandbox validator before execution.

```zig
pub const SandboxError = error{PathSandboxViolation};

/// Validate that `target_path` is within allowed boundaries.
/// Allowed prefixes:
///   - cellar_path (the formula's own keg)
///   - malt_prefix (for shared directories like etc, var, share)
///
/// Rejects:
///   - Paths containing ".." after normalization
///   - Symlinks that resolve outside the sandbox
///   - Absolute paths not under allowed prefixes
pub fn validatePath(
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void { ... }

/// Resolve a path to its canonical form (resolving symlinks)
/// and then validate it.
pub fn validateResolved(
    target_path: []const u8,
    cellar_path: []const u8,
    malt_prefix: []const u8,
) SandboxError!void { ... }
```

### Implementation Notes

- Use `std.fs.realpath` to resolve symlinks before validation.
- Normalize with `std.fs.path.resolve` to eliminate `..` components.
- Read-only operations (`exist?`, `read`, `children`, `glob`) are NOT sandboxed -- they may read system paths (e.g., `/usr/include` for header detection).

---

## 8. Fallback Log (`fallback_log.zig`)

### Purpose

Structured telemetry for operations the interpreter cannot handle. The caller (install command) uses this to decide whether to fall back to `brew` for the formula.

```zig
pub const FallbackReason = enum {
    unknown_method,
    unsupported_node,
    sandbox_violation,
    system_command_failed,
};

pub const FallbackEntry = struct {
    formula: []const u8,
    reason: FallbackReason,
    detail: []const u8,       // method name, node kind, or path
    loc: ?SourceLoc,
};

pub const FallbackLog = struct {
    entries: std.ArrayList(FallbackEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FallbackLog { ... }
    pub fn deinit(self: *FallbackLog) void { ... }

    pub fn log(self: *FallbackLog, entry: FallbackEntry) void { ... }

    pub fn hasErrors(self: *FallbackLog) bool { ... }
    pub fn hasFatal(self: *FallbackLog) bool { ... }

    /// Serialize to JSON for telemetry reporting.
    pub fn toJson(self: *FallbackLog, allocator: std.mem.Allocator) ![]const u8 { ... }
};
```

### Behavior

- `UnknownMethod` and `UnsupportedNode` are non-fatal: logged, execution continues.
- `PathSandboxViolation` is fatal: logged, execution halts immediately.
- `SystemCommandFailed` severity depends on the original Ruby code -- if it was inside a `begin/rescue`, it is non-fatal.
- After `executePostInstall` returns, the caller inspects `FallbackLog.hasFatal()` to decide whether post_install succeeded or needs fallback.

---

## 9. Builtins

### Dispatch Table (`builtins/root.zig`)

```zig
pub const BuiltinFn = *const fn (
    ctx: *ExecContext,
    receiver: ?Value,
    args: []const Value,
    block: ?*const Node,
) DslError!Value;

pub const builtins = std.StaticStringMap(BuiltinFn).initComptime(.{
    // Pathname
    .{ "mkpath", pathname.mkpath },
    .{ "exist?", pathname.existQ },
    .{ "directory?", pathname.directoryQ },
    .{ "symlink?", pathname.symlinkQ },
    .{ "children", pathname.children },
    .{ "glob", pathname.glob },
    .{ "write", pathname.write },
    .{ "read", pathname.read },
    .{ "basename", pathname.basename },
    .{ "dirname", pathname.dirname },
    .{ "extname", pathname.extname },
    .{ "to_s", pathname.toS },
    .{ "realpath", pathname.realpath },
    .{ "install_symlink", pathname.installSymlink },

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
    .{ "Utils.safe_popen_read", process.safePopenRead },

    // Inreplace
    .{ "inreplace", inreplace.inreplace },

    // String (dispatched when receiver is a string value)
    .{ "gsub", string.gsub },
    .{ "sub", string.sub },
    .{ "chomp", string.chomp },
    .{ "strip", string.strip },
    .{ "split", string.split },
    .{ "include?", string.includeQ },
    .{ "start_with?", string.startWithQ },
    .{ "end_with?", string.endWithQ },
});
```

### builtins/pathname.zig

Maps Pathname operations to `std.fs` calls. Key behaviors:

- `/` operator creates path joins via `std.fs.path.join`
- `mkpath` -> `std.fs.makeDirAbsolute` (recursive)
- `exist?` -> `std.fs.cwd().access`
- `write` -> sandbox-validated `std.fs.createFileAbsolute` + write
- `children` -> directory iteration, returns array of Pathname values
- `glob` -> pattern matching via manual wildcard expansion
- `install_symlink` -> delegates to sandbox-validated symlink creation

### builtins/fileutils.zig

Maps Ruby FileUtils module calls to `std.fs` operations. All mutating operations go through `sandbox.validatePath` before execution.

### builtins/ui.zig

Direct delegation to `src/ui/output.zig`:

- `ohai(msg)` -> `output.info("{s}", .{msg})`
- `opoo(msg)` -> `output.warn("{s}", .{msg})`
- `odie(msg)` -> `output.err("{s}", .{msg})` + return error

### builtins/process.zig

- `system(cmd, *args)` -> `std.process.Child` with stdout/stderr capture
- `Utils.safe_popen_read(cmd, *args)` -> capture stdout, return as string value
- Backtick expressions -> same as popen_read
- Working directory is set to `cellar_path`
- Environment inherits from `ExecContext.env`

### builtins/inreplace.zig

- Literal inreplace: read file, `std.mem.replace` on content, write back
- Regex inreplace: requires a minimal regex engine -- use POSIX `regcomp`/`regexec` via libc (already linked). This keeps binary size minimal.
- Sandbox validation on the target file path before any write.

### builtins/string.zig

- `gsub`/`sub` with string patterns -> `std.mem.replace` / first occurrence
- `gsub`/`sub` with regex -> POSIX regex via libc
- `chomp`/`strip`/`split` -> `std.mem.trim`, `std.mem.splitSequence`
- String interpolation evaluation is handled in the interpreter, not here

---

## 10. Error Handling

### Error Set

```zig
pub const DslError = error{
    ParseError,
    UnknownMethod,
    UnsupportedNode,
    PathSandboxViolation,
    PostInstallFailed,
    SystemCommandFailed,
    OutOfMemory,
};
```

### Propagation Strategy

| Error                | Fatal?      | Action                                         |
| -------------------- | ----------- | ---------------------------------------------- |
| ParseError           | Yes         | Log diagnostic, return error to caller         |
| UnknownMethod        | No          | Log to FallbackLog, return `.nil` and continue |
| UnsupportedNode      | No          | Log to FallbackLog, return `.nil` and continue |
| PathSandboxViolation | Yes         | Log to FallbackLog, halt execution             |
| PostInstallFailed    | Yes         | Raised by `odie` or explicit `raise`           |
| SystemCommandFailed  | Conditional | Fatal unless inside begin/rescue               |
| OutOfMemory          | Yes         | Propagated via Zig error union                 |

---

## 11. Public API

```zig
/// Execute a formula's post_install block.
///
/// Lifecycle:
///   1. Create arena allocator
///   2. Lex ruby_source into token stream
///   3. Parse tokens into AST
///   4. Build ExecContext from formula metadata
///   5. Tree-walk the AST
///   6. Destroy arena (all AST + intermediate values freed)
///
/// On success: post_install completed without fatal errors.
/// On DslError: caller inspects fallback_log for details and may
///              retry with system Ruby or skip.
pub fn executePostInstall(
    allocator: std.mem.Allocator,
    formula: *const Formula,
    ruby_source: []const u8,
    malt_prefix: []const u8,
    fallback_log: *FallbackLog,
) DslError!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lexer = Lexer.init(ruby_source);
    var parser = Parser.init(a, &lexer);
    const nodes = try parser.parseBlock();

    var ctx = ExecContext.init(a, formula, malt_prefix, fallback_log);
    var interp = Interpreter.init(&ctx);
    try interp.execute(nodes);
}
```

---

## 12. Binary Size Budget

Target: <80 KB for the entire `src/core/dsl/` module (measured via `--release=small`).

| Component            | Estimated Size                         |
| -------------------- | -------------------------------------- |
| Lexer                | ~4 KB                                  |
| AST types            | ~2 KB (data definitions, minimal code) |
| Parser               | ~12 KB                                 |
| Interpreter dispatch | ~8 KB                                  |
| Values               | ~3 KB                                  |
| Sandbox              | ~2 KB                                  |
| FallbackLog          | ~3 KB                                  |
| builtins/pathname    | ~10 KB                                 |
| builtins/fileutils   | ~8 KB                                  |
| builtins/ui          | ~2 KB                                  |
| builtins/process     | ~8 KB                                  |
| builtins/inreplace   | ~6 KB                                  |
| builtins/string      | ~6 KB                                  |
| **Total**            | **~74 KB**                             |

Notes:

- No `std.fmt` format strings for user-facing output beyond what `src/ui/output.zig` already uses.
- POSIX regex via libc adds no binary size (dynamically linked, libc already required for SQLite).
- Arena allocation avoids per-node free logic, keeping code size down.

---

## 13. Phase Implementation Plan

### Phase 1 (24.6% coverage -- 44 formulae)

Implement: lexer, parser (basic statements + method calls), interpreter core, ExecContext, sandbox, and builtins: pathname (mkpath, exist?, write, install_symlink), fileutils (rm, rm_r, mkdir_p, chmod, touch, ln_s, ln_sf, mv, cp_r), ui (ohai, opoo, odie), process (system).

### Phase 2 (cumulative 45.3% -- 81 formulae)

Add: string interpolation evaluation (in lexer + interpreter), literal inreplace, string builtins (gsub, sub, chomp, strip, split), single-quoted strings, heredoc literals.

### Phase 3 (cumulative 82.7% -- 148 formulae)

Add: `each` loops, glob iteration, `if`/`unless` (both statement and postfix forms), `elsif`/`else`, array/hash literals, block parameters, Pathname#children, Pathname#glob.

### Phase 4 (cumulative 99.4% -- 178 formulae)

Add: regex inreplace (POSIX libc), Utils.safe_popen_read / backtick capture, begin/rescue, raise, version comparison helpers (MacOS.version, Hardware::CPU.arch), OS.mac?/OS.linux? constants.

### Fallback (1 formula)

The single unconvertible formula uses `--use-system-ruby` or the `brew` fallback path. No DSL changes needed.

---

## 14. Testing Strategy

### Unit Tests (per-module)

- **Lexer tests**: Token sequence assertions for each token type, heredoc edge cases, interpolation boundaries.
- **Parser tests**: AST shape assertions from known Ruby snippets extracted from real formulae.
- **Interpreter tests**: End-to-end execution of synthetic post_install blocks against a temporary directory tree (using `std.testing.tmpDir`).
- **Sandbox tests**: Attempt to escape via `..`, symlink tricks, absolute paths outside prefix.
- **Builtin tests**: Each builtin function tested in isolation with mock ExecContext.

### Integration Tests

Extract the actual `post_install` Ruby source from 10-15 representative formulae (covering each phase) and execute them against a mock cellar directory. Assert expected filesystem state after execution.

### Regression Corpus

A `tests/fixtures/post_install/` directory contains `.rb` snippets and expected `.json` fallback-log outputs. CI runs all of them on every change to `src/core/dsl/`.

---

## 15. Constraints and Risks

| Risk                                                    | Mitigation                                                                                                       |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Ruby grammar ambiguity (e.g., `/` as division vs regex) | Context-sensitive lexer: `/` after `)`, identifier, or literal is division; after operator or `(` is regex start |
| Helper methods defined outside post_install             | Phase 4+ can inline known helpers (rm_r is already a builtin). Unknown helpers -> FallbackLog                    |
| Binary size overrun                                     | Measure after each phase. If over budget, split rarely-used builtins into a lazy-init table                      |
| POSIX regex portability                                 | macOS libc provides regcomp/regexec; no Linux target currently                                                   |
| Deep nesting stack overflow                             | Limit AST depth to 64 levels; reject deeper nesting with ParseError                                              |
