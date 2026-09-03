//! Habush High-level Intermediate Representation.
//!
//! `AstGen.zig` converts AST nodes to these instructions. The representation
//! owns all data needed by later semantic analysis and execution planning; it
//! does not borrow the AST, its token list, or its source bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Hir = @This();

instructions: std.MultiArrayList(Inst).Slice,
/// Storage for strings referenced by instructions and extra payloads.
/// Strings may contain null bytes, so references always carry a length.
string_bytes: []u8,
/// The meaning of this data is determined by `Inst.Tag`.
extra: []u32,

pub const ByteOffset = u32;

pub const ExtraIndex = enum(u32) {
    _,
};

pub const StringIndex = enum(u32) {
    _,

    pub fn toOptional(index: StringIndex) OptionalIndex {
        const result: OptionalIndex = @enumFromInt(@intFromEnum(index));
        std.debug.assert(result != .none);
        return result;
    }

    pub const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(index: OptionalIndex) ?StringIndex {
            return if (index == .none) null else @enumFromInt(@intFromEnum(index));
        }
    };
};

pub const String = struct {
    start: StringIndex,
    len: u32,

    pub fn get(value: String, hir: Hir) []const u8 {
        return hir.string_bytes[@intFromEnum(value.start)..][0..value.len];
    }
};

fn ExtraData(comptime T: type) type {
    return struct {
        data: T,
        end: usize,
    };
}

pub fn deinit(hir: *Hir, gpa: Allocator) void {
    hir.instructions.deinit(gpa);
    gpa.free(hir.string_bytes);
    gpa.free(hir.extra);
    hir.* = undefined;
}

pub fn instructionTag(hir: Hir, index: Inst.Index) Inst.Tag {
    return hir.instructions.items(.tag)[@intFromEnum(index)];
}

pub fn instructionData(hir: Hir, index: Inst.Index) Inst.Data {
    return hir.instructions.items(.data)[@intFromEnum(index)];
}

pub fn root(hir: Hir) ?Inst.Index {
    std.debug.assert(hir.instructionTag(.root) == .root);
    return hir.instructionData(.root).un.operand.unwrap();
}

pub fn pipeline(hir: Hir, index: Inst.Index) Inst.Bin {
    const tag = hir.instructionTag(index);
    std.debug.assert(tag == .pipe or tag == .pipe_and);
    return hir.instructionData(index).bin;
}

pub fn negatedPipeline(hir: Hir, index: Inst.Index) Inst.Index {
    std.debug.assert(hir.instructionTag(index) == .negated_pipeline);
    return hir.instructionData(index).un.operand.unwrap().?;
}

pub fn extraData(hir: Hir, comptime T: type, index: ExtraIndex) ExtraData(T) {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    var cursor: usize = @intFromEnum(index);
    inline for (fields) |field| {
        const raw = hir.extra[cursor];
        @field(result, field.name) = switch (@typeInfo(field.type)) {
            .int => raw,
            .@"enum" => @enumFromInt(raw),
            .@"struct" => @bitCast(raw),
            else => @compileError("unsupported HIR extra field: " ++
                @typeName(T) ++ "." ++ field.name ++ ": " ++ @typeName(field.type)),
        };
        cursor += 1;
    }
    return .{ .data = result, .end = cursor };
}

pub fn simpleCommandParts(hir: Hir, index: Inst.Index) []const Inst.Index {
    std.debug.assert(hir.instructionTag(index) == .simple_command);
    const payload = hir.extraData(SimpleCommand, hir.instructionData(index).pl.payload_index);
    return hir.instructionSlice(payload.end, payload.data.parts_len);
}

pub fn assignment(hir: Hir, index: Inst.Index) Assignment.Value {
    std.debug.assert(hir.instructionTag(index) == .assignment);
    const payload = hir.extraData(Assignment, hir.instructionData(index).pl.payload_index).data;
    return .{
        .name = (String{ .start = payload.name_start, .len = payload.name_len }).get(hir),
        .value = payload.value,
    };
}

pub fn wordParts(hir: Hir, index: Inst.Index) []const Inst.Index {
    std.debug.assert(hir.instructionTag(index) == .word);
    const payload = hir.extraData(Word, hir.instructionData(index).pl.payload_index);
    return hir.instructionSlice(payload.end, payload.data.parts_len);
}

pub fn wordPart(hir: Hir, index: Inst.Index) []const u8 {
    std.debug.assert(hir.instructionTag(index).isWordPart());
    return hir.instructionData(index).str.get(hir);
}

pub fn redirect(hir: Hir, index: Inst.Index) Redirect.Value {
    std.debug.assert(hir.instructionTag(index) == .redirect);
    const payload = hir.extraData(Redirect, hir.instructionData(index).pl.payload_index).data;
    return .{
        .operator = payload.operator,
        .io_number = if (payload.io_number_start.unwrap()) |start|
            (String{ .start = start, .len = payload.io_number_len }).get(hir)
        else
            null,
        .target = payload.target,
        .here_document = payload.here_document,
    };
}

pub fn hereDocument(hir: Hir, index: Inst.Index) HereDocument.Value {
    std.debug.assert(hir.instructionTag(index) == .here_document);
    const payload = hir.extraData(HereDocument, hir.instructionData(index).pl.payload_index).data;
    return .{
        .delimiter = (String{
            .start = payload.delimiter_start,
            .len = payload.delimiter_len,
        }).get(hir),
        .strip_tabs = payload.flags.strip_tabs,
        .expand_body = payload.flags.expand_body,
        .body = if (payload.body_start.unwrap()) |start|
            (String{ .start = start, .len = payload.body_len }).get(hir)
        else
            null,
    };
}

fn instructionSlice(hir: Hir, start: usize, len: u32) []const Inst.Index {
    return @ptrCast(hir.extra[start..][0..len]);
}

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(index: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(index));
            std.debug.assert(result != .none);
            return result;
        }
    };

    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(index: OptionalIndex) ?Index {
            return if (index == .none) null else @enumFromInt(@intFromEnum(index));
        }
    };

    pub const Tag = enum(u8) {
        /// `data.un`: the top-level command, if any.
        root,
        /// `data.pl`: `SimpleCommand`, followed by `Inst.Index` values.
        simple_command,
        /// `data.pl`: `Assignment`.
        assignment,
        /// `data.pl`: `Word`, followed by word-part `Inst.Index` values.
        word,
        /// `data.pl`: `Redirect`.
        redirect,
        /// `data.pl`: `HereDocument`.
        here_document,

        /// `data.bin`: the commands connected by `|` or `|&`.
        pipe,
        pipe_and,
        /// `data.un`: the pipeline following `!`.
        negated_pipeline,

        /// `data.str`: the bytes represented by this word part.
        literal,
        escaped,
        single_quoted,
        double_quoted,
        double_quoted_escaped,
        parameter,
        braced_parameter,
        double_quoted_parameter,
        double_quoted_braced_parameter,

        pub fn isWordPart(tag: Tag) bool {
            return switch (tag) {
                .literal,
                .escaped,
                .single_quoted,
                .double_quoted,
                .double_quoted_escaped,
                .parameter,
                .braced_parameter,
                .double_quoted_parameter,
                .double_quoted_braced_parameter,
                => true,
                else => false,
            };
        }
    };

    /// The active field is determined by `Tag`. Common payloads fit in eight
    /// bytes, following the same compact layout used by ZIR.
    pub const Data = union {
        none: void,
        un: struct {
            operand: OptionalIndex,
            src_start: ByteOffset = 0,
        },
        bin: Bin,
        pl: struct {
            src_start: ByteOffset,
            payload_index: ExtraIndex,
        },
        str: String,
    };

    pub const Bin = struct {
        lhs: Index,
        rhs: Index,
    };
};

pub const SimpleCommand = struct {
    parts_len: u32,
};

pub const Assignment = struct {
    name_start: StringIndex,
    name_len: u32,
    value: Inst.Index,

    pub const Value = struct {
        name: []const u8,
        value: Inst.Index,
    };
};

pub const Word = struct {
    parts_len: u32,
};

pub const Redirect = struct {
    operator: Operator,
    io_number_start: StringIndex.OptionalIndex,
    io_number_len: u32,
    target: Inst.Index,
    here_document: Inst.OptionalIndex,

    pub const Operator = enum(u32) {
        input,
        output,
        append,
        here_document,
        here_document_strip_tabs,
        here_string,
        duplicate_input,
        duplicate_output,
        input_output,
        clobber,
        output_both,
        append_both,
    };

    pub const Value = struct {
        operator: Operator,
        io_number: ?[]const u8,
        target: Inst.Index,
        here_document: Inst.OptionalIndex,
    };
};

pub const HereDocument = struct {
    delimiter_start: StringIndex,
    delimiter_len: u32,
    body_start: StringIndex.OptionalIndex,
    body_len: u32,
    flags: Flags,

    pub const Flags = packed struct(u32) {
        strip_tabs: bool,
        expand_body: bool,
        _: u30 = 0,
    };

    pub const Value = struct {
        delimiter: []const u8,
        strip_tabs: bool,
        expand_body: bool,
        body: ?[]const u8,
    };
};
