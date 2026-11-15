pub const css = struct {
    pub const Kind = @import("css/kind.zig").Kind;
    pub const Parser = @import("css/parse.zig").Parser;
    pub const Semantic = @import("css/semantic.zig").Semantic;
    pub const ast = @import("css/ast.zig");
    pub const expression = @import("css/expression.zig");
    pub const kind = @import("css/kind.zig");
    pub const semantic = @import("css/semantic.zig");
};

pub const go = struct {
    pub const Kind = @import("go/kind.zig").Kind;
    pub const Parser = @import("go/parse.zig").Parser;
    pub const Semantic = @import("go/semantic.zig").Semantic;
    pub const ast = @import("go/ast.zig");
    pub const expression = @import("go/expression.zig");
    pub const kind = @import("go/kind.zig");
    pub const semantic = @import("go/semantic.zig");
};

pub const javascript = struct {
    pub const Dialect = @import("javascript/dialect.zig").Dialect;
    pub const Kind = @import("javascript/kind.zig").Kind;
    pub const Parser = @import("javascript/parse.zig").Parser;
    pub const Semantic = @import("javascript/semantic.zig").Semantic;
    pub const ast = @import("javascript/ast.zig");
    pub const dialect = @import("javascript/dialect.zig");
    pub const expression = @import("javascript/expression.zig");
    pub const kind = @import("javascript/kind.zig");
    pub const semantic = @import("javascript/semantic.zig");
};

pub const odin = struct {
    pub const Kind = @import("odin/kind.zig").Kind;
    pub const Parser = @import("odin/parse.zig").Parser;
    pub const Semantic = @import("odin/semantic.zig").Semantic;
    pub const ast = @import("odin/ast.zig");
    pub const expression = @import("odin/expression.zig");
    pub const kind = @import("odin/kind.zig");
    pub const semantic = @import("odin/semantic.zig");
};

pub const python = struct {
    pub const AnnotationScratch = @import("python/semantic.zig").AnnotationScratch;
    pub const Kind = @import("python/kind.zig").Kind;
    pub const Parser = @import("python/parse.zig").Parser;
    pub const Semantic = @import("python/semantic.zig").Semantic;
    pub const ast = @import("python/ast.zig");
    pub const bind = @import("python/bind.zig");
    pub const check = @import("python/check.zig");
    pub const expression = @import("python/expression.zig");
    pub const kind = @import("python/kind.zig");
    pub const literal = @import("python/literal.zig");
    pub const semantic = @import("python/semantic.zig");
    pub const stdlib = @import("python/stdlib.zig");
};

pub const rust = struct {
    pub const Kind = @import("rust/kind.zig").Kind;
    pub const Parser = @import("rust/parse.zig").Parser;
    pub const Semantic = @import("rust/semantic.zig").Semantic;
    pub const ast = @import("rust/ast.zig");
    pub const expression = @import("rust/expression.zig");
    pub const kind = @import("rust/kind.zig");
    pub const semantic = @import("rust/semantic.zig");
};

pub const zig = struct {
    pub const Kind = @import("zig/kind.zig").Kind;
    pub const Parser = @import("zig/parse.zig").Parser;
    pub const Semantic = @import("zig/semantic.zig").Semantic;
    pub const ast = @import("zig/ast.zig");
    pub const expression = @import("zig/expression.zig");
    pub const kind = @import("zig/kind.zig");
    pub const semantic = @import("zig/semantic.zig");
};
