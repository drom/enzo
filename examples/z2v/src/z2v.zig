const std = @import("std");
const Io = std.Io;

const Ast = std.zig.Ast;
const Node = Ast.Node;

/// Walk a parsed Zig AST and emit a Verilog-2001 description.
///
/// Two top-level shapes are recognized:
///   * flat: top-level `enum(uN)` -> `localparam`, top-level `pub fn` -> combinational module.
///   * generic module: `pub fn M(comptime p: parameters) type { return struct {
///       const E = enum(uN){...};        // -> localparam inside the module
///       const T = std.meta.Int(.., p.W); // -> parametrized width [W-1:0]
///       inputs:  struct { ... },          // -> input ports
///       outputs: struct { ... },          // -> output reg ports
///       always:  struct { pub fn ... },   // -> always @(*) blocks
///     }; }`  paired with `pub const parameters = struct { W: u32 = N };` -> `#( parameter W = N )`.
///
/// Unhandled constructs emit a `// TODO` / `/* TODO */` marker rather than crashing.
pub fn z2v(gpa: std.mem.Allocator, ast: Ast, writer: *Io.Writer) !void {
    var emitter: Emitter = .{ .tree = &ast, .w = writer, .gpa = gpa };
    defer emitter.deinit();
    try emitter.run();
}

/// A Verilog bit width, possibly symbolic (a parameter name).
const Width = union(enum) {
    single, // 1 bit, no `[..]` range
    bits: u16, // fixed, e.g. 3 -> `[2:0]`
    sym: []const u8, // parametrized, e.g. "DW" -> `[DW-1:0]`
};

const Dir = enum { input, output };
const Port = struct { dir: Dir, width: Width, name: []const u8 };

const Emitter = struct {
    tree: *const Ast,
    w: *Io.Writer,
    gpa: std.mem.Allocator,
    /// type name -> bit width (enum types, width aliases like `DWT`)
    widths: std.StringHashMapUnmanaged(Width) = .empty,
    /// `parameters` struct container node, if present
    params_node: ?Node.Index = null,
    /// output port that an `always` block's `return` assigns to
    out_name: []const u8 = "y",

    fn deinit(self: *Emitter) void {
        self.widths.deinit(self.gpa);
    }

    fn run(self: *Emitter) !void {
        // pass 0: locate the `parameters` decl (shared by generic modules)
        for (self.tree.rootDecls()) |decl| {
            if (self.parametersContainer(decl)) |pn| self.params_node = pn;
        }
        // pass 1: flat top-level enums -> localparams
        for (self.tree.rootDecls()) |decl| {
            _ = try self.tryEmitEnum(decl);
        }
        // pass 2: one module per top-level fn
        for (self.tree.rootDecls()) |decl| {
            if (self.tag(decl) != .fn_decl) continue;
            if (self.returnsType(decl))
                try self.emitModuleGeneric(decl)
            else
                try self.emitModuleFlat(decl);
        }
    }

    // --- small helpers -----------------------------------------------------

    fn tag(self: *const Emitter, node: Node.Index) Node.Tag {
        return self.tree.nodeTag(node);
    }
    fn tok(self: *const Emitter, t: Ast.TokenIndex) []const u8 {
        return self.tree.tokenSlice(t);
    }
    fn mainStr(self: *const Emitter, node: Node.Index) []const u8 {
        return self.tok(self.tree.nodeMainToken(node));
    }
    /// `a.b` field-access -> the `b` field name.
    fn fieldName(self: *const Emitter, node: Node.Index) []const u8 {
        return self.tok(self.tree.nodeData(node).node_and_token[1]);
    }
    fn indent(self: *Emitter, n: usize) !void {
        for (0..n) |_| try self.w.writeAll("  ");
    }
    fn emitUpper(self: *Emitter, s: []const u8) !void {
        for (s) |c| try self.w.writeByte(std.ascii.toUpper(c));
    }
    /// Verilog bit-range prefix; single-bit ports get no `[..]`.
    fn emitRange(self: *Emitter, width: Width) !void {
        switch (width) {
            .single => {},
            .bits => |b| if (b > 1) try self.w.print("[{d}:0] ", .{b - 1}),
            .sym => |s| try self.w.print("[{s}-1:0] ", .{s}),
        }
    }

    fn widthFromName(self: *const Emitter, name: []const u8) Width {
        if (self.widths.get(name)) |w| return w;
        if (std.mem.eql(u8, name, "bool")) return .single;
        if (name.len > 1 and (name[0] == 'u' or name[0] == 'i')) {
            const bits = std.fmt.parseInt(u16, name[1..], 10) catch return .single;
            return if (bits <= 1) .single else .{ .bits = bits };
        }
        return .single;
    }
    fn widthFromTypeNode(self: *const Emitter, node: Node.Index) Width {
        if (self.tag(node) != .identifier) return .single;
        return self.widthFromName(self.mainStr(node));
    }
    /// Width from the bit-count argument of `std.meta.Int(.., <expr>)`.
    fn widthFromExpr(self: *const Emitter, node: Node.Index) Width {
        return switch (self.tag(node)) {
            .number_literal => blk: {
                const bits = std.fmt.parseInt(u16, self.mainStr(node), 10) catch break :blk .single;
                break :blk if (bits <= 1) .single else .{ .bits = bits };
            },
            .field_access => .{ .sym = self.fieldName(node) },
            .identifier => .{ .sym = self.mainStr(node) },
            else => .single,
        };
    }

    // --- type registration -------------------------------------------------

    fn isEnumContainer(self: *const Emitter, init_node: Node.Index) bool {
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, init_node) orelse return false;
        return self.tree.tokenTag(cd.ast.main_token) == .keyword_enum;
    }
    /// `std.meta.Int(..)` (or any call to an `Int` function).
    fn isIntAlias(self: *const Emitter, init_node: Node.Index) bool {
        switch (self.tag(init_node)) {
            .call, .call_comma, .call_one, .call_one_comma => {},
            else => return false,
        }
        var buf: [1]Node.Index = undefined;
        const call = self.tree.fullCall(&buf, init_node) orelse return false;
        const fe = call.ast.fn_expr;
        return switch (self.tag(fe)) {
            .field_access => std.mem.eql(u8, self.fieldName(fe), "Int"),
            .identifier => std.mem.eql(u8, self.mainStr(fe), "Int"),
            else => false,
        };
    }

    fn enumBackingWidth(self: *const Emitter, init_node: Node.Index) Width {
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, init_node) orelse return .single;
        return if (cd.ast.arg.unwrap()) |arg| self.widthFromTypeNode(arg) else .single;
    }

    /// Register the width of a `const X = enum(..)` or `const X = std.meta.Int(.., E)`.
    fn registerTypeDecl(self: *Emitter, decl: Node.Index) !void {
        const vd = self.tree.fullVarDecl(decl) orelse return;
        const init_node = vd.ast.init_node.unwrap() orelse return;
        const name = self.tok(vd.ast.mut_token + 1);
        if (self.isEnumContainer(init_node)) {
            try self.widths.put(self.gpa, name, self.enumBackingWidth(init_node));
        } else if (self.isIntAlias(init_node)) {
            var buf: [1]Node.Index = undefined;
            const call = self.tree.fullCall(&buf, init_node) orelse return;
            if (call.ast.params.len == 0) return;
            const bits_expr = call.ast.params[call.ast.params.len - 1];
            try self.widths.put(self.gpa, name, self.widthFromExpr(bits_expr));
        }
    }

    // --- enum -> localparam ------------------------------------------------

    /// Emit a `const X = enum(..) {..}` as a `localparam` line at `ind`.
    fn emitEnumLocalparam(self: *Emitter, decl: Node.Index, ind: usize) !void {
        const vd = self.tree.fullVarDecl(decl) orelse return;
        const init_node = vd.ast.init_node.unwrap() orelse return;
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, init_node) orelse return;

        try self.indent(ind);
        try self.w.writeAll("localparam ");
        try self.emitRange(self.enumBackingWidth(init_node));
        var value: u32 = 0;
        for (cd.ast.members) |m| {
            const cf = self.tree.fullContainerField(m) orelse continue;
            const fname = self.tok(cf.ast.main_token);
            if (std.mem.eql(u8, fname, "_")) continue; // non-exhaustive marker
            if (value != 0) try self.w.writeAll(", ");
            try self.emitUpper(fname);
            try self.w.print("={d}", .{value});
            value += 1;
        }
        try self.w.writeAll(";\n");
    }

    /// Flat top-level enum: register + emit localparam at column 0.
    fn tryEmitEnum(self: *Emitter, decl: Node.Index) !bool {
        const vd = self.tree.fullVarDecl(decl) orelse return false;
        const init_node = vd.ast.init_node.unwrap() orelse return false;
        if (!self.isEnumContainer(init_node)) return false;
        try self.registerTypeDecl(decl);
        try self.emitEnumLocalparam(decl, 0);
        try self.w.writeByte('\n');
        return true;
    }

    // --- generic module: fn(parameters) type -> struct{...} ----------------

    fn returnsType(self: *const Emitter, fn_decl: Node.Index) bool {
        const proto_node = self.tree.nodeData(fn_decl).node_and_node[0];
        var buf: [1]Node.Index = undefined;
        const proto = self.tree.fullFnProto(&buf, proto_node) orelse return false;
        const rt = proto.ast.return_type.unwrap() orelse return false;
        return self.tag(rt) == .identifier and std.mem.eql(u8, self.mainStr(rt), "type");
    }

    /// A var decl named `parameters` whose init is a struct -> its container node.
    fn parametersContainer(self: *const Emitter, decl: Node.Index) ?Node.Index {
        const vd = self.tree.fullVarDecl(decl) orelse return null;
        if (!std.mem.eql(u8, self.tok(vd.ast.mut_token + 1), "parameters")) return null;
        const init_node = vd.ast.init_node.unwrap() orelse return null;
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, init_node) orelse return null;
        return if (self.tree.tokenTag(cd.ast.main_token) == .keyword_struct) init_node else null;
    }

    /// The struct type a module-constructor fn returns.
    fn returnedStruct(self: *const Emitter, fn_decl: Node.Index) ?Node.Index {
        const body = self.tree.nodeData(fn_decl).node_and_node[1];
        return self.firstReturnOperand(body);
    }
    fn firstReturnOperand(self: *const Emitter, node: Node.Index) ?Node.Index {
        switch (self.tag(node)) {
            .block_two, .block_two_semicolon => {
                const d = self.tree.nodeData(node).opt_node_and_opt_node;
                if (d[0].unwrap()) |s| if (self.firstReturnOperand(s)) |r| return r;
                if (d[1].unwrap()) |s| if (self.firstReturnOperand(s)) |r| return r;
                return null;
            },
            .block, .block_semicolon => {
                const stmts = self.tree.extraDataSlice(self.tree.nodeData(node).extra_range, Node.Index);
                for (stmts) |s| if (self.firstReturnOperand(s)) |r| return r;
                return null;
            },
            .@"return" => return self.tree.nodeData(node).opt_node.unwrap(),
            else => return null,
        }
    }

    fn emitModuleGeneric(self: *Emitter, fn_decl: Node.Index) !void {
        const proto_node = self.tree.nodeData(fn_decl).node_and_node[0];
        var pbuf: [1]Node.Index = undefined;
        const proto = self.tree.fullFnProto(&pbuf, proto_node) orelse return;
        const name = if (proto.name_token) |nt| self.tok(nt) else "top";

        const container = self.returnedStruct(fn_decl) orelse {
            try self.w.print("// TODO: module {s} has no returned struct\n", .{name});
            return;
        };
        var cbuf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&cbuf, container) orelse return;
        const members = cd.ast.members;

        // pass A: register enum/width types so ports can reference them
        for (members) |m| switch (self.tag(m)) {
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => try self.registerTypeDecl(m),
            else => {},
        };

        // header: module name + parameters
        try self.w.print("module {s}", .{name});
        try self.emitParams();
        try self.w.writeAll(" (\n");

        // ports from `inputs:`/`outputs:` sections
        var ports: std.ArrayListUnmanaged(Port) = .empty;
        defer ports.deinit(self.gpa);
        for (members) |m| {
            const cf = self.tree.fullContainerField(m) orelse continue;
            const fname = self.tok(cf.ast.main_token);
            const dir: Dir = if (std.mem.eql(u8, fname, "inputs"))
                .input
            else if (std.mem.eql(u8, fname, "outputs"))
                .output
            else
                continue;
            if (cf.ast.type_expr.unwrap()) |te| try self.collectPorts(te, dir, &ports);
        }
        for (ports.items, 0..) |p, i| {
            try self.indent(1);
            try self.w.writeAll(if (p.dir == .input) "input  " else "output reg ");
            try self.emitRange(p.width);
            try self.w.writeAll(p.name);
            if (i != ports.items.len - 1) try self.w.writeByte(',');
            try self.w.writeByte('\n');
        }
        try self.w.writeAll(");\n");

        // assignments target the first declared output
        for (ports.items) |p| {
            if (p.dir == .output) {
                self.out_name = p.name;
                break;
            }
        }

        // body: enum localparams, then always blocks
        for (members) |m| switch (self.tag(m)) {
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
                const vd = self.tree.fullVarDecl(m) orelse continue;
                const init_node = vd.ast.init_node.unwrap() orelse continue;
                if (self.isEnumContainer(init_node)) try self.emitEnumLocalparam(m, 1);
            },
            else => {},
        };
        for (members) |m| {
            const cf = self.tree.fullContainerField(m) orelse continue;
            if (!std.mem.eql(u8, self.tok(cf.ast.main_token), "always")) continue;
            if (cf.ast.type_expr.unwrap()) |te| try self.emitAlwaysSection(te);
        }

        try self.w.writeAll("endmodule\n\n");
    }

    fn emitParams(self: *Emitter) !void {
        const pn = self.params_node orelse return;
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, pn) orelse return;
        try self.w.writeAll(" #(\n");
        for (cd.ast.members, 0..) |m, i| {
            const cf = self.tree.fullContainerField(m) orelse continue;
            try self.indent(1);
            try self.w.print("parameter {s}", .{self.tok(cf.ast.main_token)});
            if (cf.ast.value_expr.unwrap()) |ve| {
                try self.w.writeAll(" = ");
                try self.emitExpr(ve);
            }
            if (i != cd.ast.members.len - 1) try self.w.writeByte(',');
            try self.w.writeByte('\n');
        }
        try self.w.writeAll(")");
    }

    fn collectPorts(self: *Emitter, struct_type: Node.Index, dir: Dir, ports: *std.ArrayListUnmanaged(Port)) !void {
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, struct_type) orelse return;
        for (cd.ast.members) |m| {
            const cf = self.tree.fullContainerField(m) orelse continue;
            const width: Width = if (cf.ast.type_expr.unwrap()) |te| self.widthFromTypeNode(te) else .single;
            try ports.append(self.gpa, .{ .dir = dir, .width = width, .name = self.tok(cf.ast.main_token) });
        }
    }

    /// Each `pub fn` in the `always:` struct becomes one `always @(*)` block.
    fn emitAlwaysSection(self: *Emitter, struct_type: Node.Index) !void {
        var buf: [2]Node.Index = undefined;
        const cd = self.tree.fullContainerDecl(&buf, struct_type) orelse return;
        for (cd.ast.members) |m| {
            if (self.tag(m) != .fn_decl) continue;
            const body = self.tree.nodeData(m).node_and_node[1];
            try self.indent(1);
            try self.w.writeAll("always @(*) begin\n");
            try self.emitStmt(body, 2);
            try self.indent(1);
            try self.w.writeAll("end\n");
        }
    }

    // --- flat fn -> combinational module -----------------------------------

    fn emitModuleFlat(self: *Emitter, decl: Node.Index) !void {
        const proto_node, const body_node = self.tree.nodeData(decl).node_and_node;
        var buf: [1]Node.Index = undefined;
        const proto = self.tree.fullFnProto(&buf, proto_node) orelse return;

        const name = if (proto.name_token) |nt| self.tok(nt) else "top";
        try self.w.print("module {s} (\n", .{name});

        var it = proto.iterate(self.tree);
        while (it.next()) |param| {
            const pname = if (param.name_token) |pt| self.tok(pt) else "arg";
            const pw: Width = if (param.type_expr) |te| self.widthFromTypeNode(te) else .single;
            try self.w.writeAll("  input  ");
            try self.emitRange(pw);
            try self.w.print("{s},\n", .{pname});
        }

        const rw: Width = if (proto.ast.return_type.unwrap()) |rt| self.widthFromTypeNode(rt) else .single;
        try self.w.writeAll("  output reg ");
        try self.emitRange(rw);
        try self.w.writeAll("y\n);\n");

        self.out_name = "y";
        try self.w.writeAll("  always @(*) begin\n");
        try self.emitStmt(body_node, 2);
        try self.w.writeAll("  end\n");

        try self.w.writeAll("endmodule\n\n");
    }

    // --- statements & expressions ------------------------------------------

    fn emitStmt(self: *Emitter, node: Node.Index, ind: usize) (Io.Writer.Error)!void {
        switch (self.tag(node)) {
            .block, .block_semicolon => {
                const stmts = self.tree.extraDataSlice(self.tree.nodeData(node).extra_range, Node.Index);
                for (stmts) |s| try self.emitStmt(s, ind);
            },
            .block_two, .block_two_semicolon => {
                const d = self.tree.nodeData(node).opt_node_and_opt_node;
                if (d[0].unwrap()) |s| try self.emitStmt(s, ind);
                if (d[1].unwrap()) |s| try self.emitStmt(s, ind);
            },
            .@"return" => {
                const expr = self.tree.nodeData(node).opt_node.unwrap() orelse return;
                try self.emitReturn(expr, ind);
            },
            else => {
                try self.indent(ind);
                try self.w.print("// TODO stmt: {s}\n", .{@tagName(self.tag(node))});
            },
        }
    }

    /// A `return <expr>` assigns the module output. A `return switch (...)`
    /// becomes a `case` statement whose arms each assign the output.
    fn emitReturn(self: *Emitter, expr: Node.Index, ind: usize) (Io.Writer.Error)!void {
        switch (self.tag(expr)) {
            .@"switch", .switch_comma => try self.emitSwitch(expr, ind),
            else => {
                try self.indent(ind);
                try self.w.print("{s} = ", .{self.out_name});
                try self.emitExpr(expr);
                try self.w.writeAll(";\n");
            },
        }
    }

    fn emitSwitch(self: *Emitter, node: Node.Index, ind: usize) (Io.Writer.Error)!void {
        const sw = self.tree.fullSwitch(node) orelse return;
        try self.indent(ind);
        try self.w.writeAll("case (");
        try self.emitExpr(sw.ast.condition);
        try self.w.writeAll(")\n");
        for (sw.ast.cases) |case_node| {
            const case = self.tree.fullSwitchCase(case_node) orelse continue;
            try self.indent(ind + 1);
            if (case.ast.values.len == 0) {
                try self.w.writeAll("default");
            } else {
                for (case.ast.values, 0..) |v, i| {
                    if (i != 0) try self.w.writeAll(", ");
                    try self.emitExpr(v);
                }
            }
            try self.w.print(": {s} = ", .{self.out_name});
            try self.emitExpr(case.ast.target_expr);
            try self.w.writeAll(";\n");
        }
        try self.indent(ind);
        try self.w.writeAll("endcase\n");
    }

    fn emitExpr(self: *Emitter, node: Node.Index) (Io.Writer.Error)!void {
        const t = self.tag(node);
        if (binOp(t)) |op| {
            const d = self.tree.nodeData(node).node_and_node;
            try self.emitExpr(d[0]);
            try self.w.print(" {s} ", .{op});
            try self.emitExpr(d[1]);
            return;
        }
        switch (t) {
            .identifier, .number_literal => try self.w.writeAll(self.mainStr(node)),
            .enum_literal => try self.emitUpper(self.mainStr(node)),
            .field_access => try self.w.writeAll(self.fieldName(node)),
            .grouped_expression => {
                const inner = self.tree.nodeData(node).node_and_token[0];
                try self.w.writeByte('(');
                try self.emitExpr(inner);
                try self.w.writeByte(')');
            },
            .bit_not => try self.emitUnary("~", node),
            .bool_not => try self.emitUnary("!", node),
            .negation => try self.emitUnary("-", node),
            else => try self.w.print("/* TODO: {s} */", .{@tagName(t)}),
        }
    }

    fn emitUnary(self: *Emitter, op: []const u8, node: Node.Index) (Io.Writer.Error)!void {
        try self.w.writeAll(op);
        try self.emitExpr(self.tree.nodeData(node).node);
    }

    /// Zig binary-op node tag -> Verilog operator, or null if not a binary op.
    /// Wrapping ops (`+%`) map to plain ops since Verilog arithmetic wraps at width.
    fn binOp(t: Node.Tag) ?[]const u8 {
        return switch (t) {
            .add, .add_wrap => "+",
            .sub, .sub_wrap => "-",
            .mul, .mul_wrap => "*",
            .div => "/",
            .mod => "%",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
            .equal_equal => "==",
            .bang_equal => "!=",
            .less_than => "<",
            .greater_than => ">",
            .less_or_equal => "<=",
            .greater_or_equal => ">=",
            .bool_and => "&&",
            .bool_or => "||",
            else => null,
        };
    }
};
