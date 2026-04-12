//! malt — DSL AST node types
//! Tagged union AST for the Ruby subset interpreter.

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
        interpolation: []const *const Node,
        path_join: PathJoin,
        assignment: Assignment,
        identifier: []const u8,
        block: []const *const Node,
        postfix_if: PostfixIf,
        postfix_unless: PostfixUnless,
        if_else: IfElse,
        unless_statement: UnlessStatement,
        each_loop: EachLoop,
        begin_rescue: BeginRescue,
        array_literal: []const *const Node,
        hash_literal: []const HashEntry,
        heredoc_literal: []const u8,
        raise_statement: RaiseStatement,
        logical_and: LogicalBinary,
        logical_or: LogicalBinary,
        logical_not: *const Node,
    };
};

pub const MethodCall = struct {
    receiver: ?*const Node,
    method: []const u8,
    args: []const *const Node,
    blk: ?*const Node,
    block_params: []const []const u8,
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
    then_body: []const *const Node,
    elsif_branches: []const ElsifBranch,
    else_body: ?[]const *const Node,
};

pub const ElsifBranch = struct {
    condition: *const Node,
    body: []const *const Node,
};

pub const UnlessStatement = struct {
    condition: *const Node,
    body: []const *const Node,
    else_body: ?[]const *const Node,
};

pub const EachLoop = struct {
    iterable: *const Node,
    params: []const []const u8,
    body: []const *const Node,
};

pub const BeginRescue = struct {
    body: []const *const Node,
    rescue_body: []const *const Node,
    exception_var: ?[]const u8,
};

pub const LogicalBinary = struct {
    left: *const Node,
    right: *const Node,
};

pub const HashEntry = struct {
    key: *const Node,
    value: *const Node,
};

pub const RaiseStatement = struct {
    message: ?*const Node,
};
