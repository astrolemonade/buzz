const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const _obj = @import("obj.zig");
const GarbageCollector = @import("memory.zig").GarbageCollector;
const Obj = _obj.Obj;
const objToString = _obj.objToString;
const copyObj = _obj.copyObj;
const ObjTypeDef = _obj.ObjTypeDef;

// TODO: do it for little endian?

const Tag = u3;
pub const TagBoolean: Tag = 0;
pub const TagInteger: Tag = 1;
pub const TagUnsignedInteger: Tag = 2;
pub const TagNull: Tag = 3;
pub const TagVoid: Tag = 4;
pub const TagObj: Tag = 5;
pub const TagError: Tag = 6;

/// Most significant bit.
pub const SignMask: u64 = 1 << 63;

/// QNAN and one extra bit to the right.
pub const TaggedValueMask: u64 = 0x7ffc000000000000;

/// TaggedMask + Sign bit indicates a pointer value.
pub const PointerMask: u64 = TaggedValueMask | SignMask;

pub const BooleanMask: u64 = TaggedValueMask | (@as(u64, TagBoolean) << 32);
pub const FalseMask: u64 = BooleanMask;
pub const TrueBitMask: u64 = 1;
pub const TrueMask: u64 = BooleanMask | TrueBitMask;

pub const IntegerMask: u64 = TaggedValueMask | (@as(u64, TagInteger) << 32);
pub const UnsignedIntegerMask: u64 = TaggedValueMask | (@as(u64, TagUnsignedInteger) << 32);
pub const NullMask: u64 = TaggedValueMask | (@as(u64, TagNull) << 32);
pub const VoidMask: u64 = TaggedValueMask | (@as(u64, TagVoid) << 32);
pub const ErrorMask: u64 = TaggedValueMask | (@as(u64, TagError) << 32);

pub const TagMask: u32 = (1 << 3) - 1;
pub const TaggedPrimitiveMask = TaggedValueMask | (@as(u64, TagMask) << 32);

pub const Value = packed struct {
    val: u64,

    pub const Null = Value{ .val = NullMask };
    pub const Void = Value{ .val = VoidMask };
    pub const True = Value{ .val = TrueMask };
    pub const False = Value{ .val = FalseMask };
    // We only need this so that an NativeFn can see the error returned by its raw function
    pub const Error = Value{ .val = ErrorMask };

    pub inline fn fromBoolean(val: bool) Value {
        return if (val) True else False;
    }

    pub inline fn fromInteger(val: i32) Value {
        return .{ .val = IntegerMask | @as(u32, @bitCast(val)) };
    }

    pub inline fn fromUnsigned(val: u32) Value {
        return .{ .val = UnsignedIntegerMask | val };
    }

    pub inline fn fromFloat(val: f64) Value {
        return .{ .val = @as(u64, @bitCast(val)) };
    }

    pub inline fn fromObj(val: *Obj) Value {
        return .{ .val = PointerMask | @intFromPtr(val) };
    }

    pub inline fn getTag(self: Value) Tag {
        return @as(Tag, @intCast(@as(u32, @intCast(self.val >> 32)) & TagMask));
    }

    pub inline fn isBool(self: Value) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == BooleanMask;
    }

    pub inline fn isInteger(self: Value) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == IntegerMask;
    }

    pub inline fn isUnsigned(self: Value) bool {
        return self.val & (TaggedPrimitiveMask | SignMask) == UnsignedIntegerMask;
    }

    pub inline fn isFloat(self: Value) bool {
        return self.val & TaggedValueMask != TaggedValueMask;
    }

    pub inline fn isNumber(self: Value) bool {
        return self.isFloat() or self.isInteger() or self.isUnsigned();
    }

    pub inline fn isObj(self: Value) bool {
        return self.val & PointerMask == PointerMask;
    }

    pub inline fn isNull(self: Value) bool {
        return self.val == NullMask;
    }

    pub inline fn isVoid(self: Value) bool {
        return self.val == VoidMask;
    }

    pub inline fn isError(self: Value) bool {
        return self.val == ErrorMask;
    }

    pub inline fn boolean(self: Value) bool {
        return self.val == TrueMask;
    }

    pub inline fn booleanOrNull(self: Value) ?bool {
        return if (self.isBool()) self.boolean() else null;
    }

    pub inline fn integer(self: Value) i32 {
        return @as(i32, @bitCast(@as(u32, @intCast(self.val & 0xffffffff))));
    }

    pub inline fn integerOrNull(self: Value) ?i32 {
        return if (self.isInteger()) self.integer() else null;
    }

    pub inline fn unsigned(self: Value) u32 {
        return @intCast(self.val & 0xffffffff);
    }

    pub inline fn unsignedOrNull(self: Value) ?u32 {
        return if (self.isUnsigned()) self.unsigned() else null;
    }

    pub inline fn float(self: Value) f64 {
        return @bitCast(self.val);
    }

    pub inline fn floatOrNull(self: Value) ?f64 {
        return if (self.isFloat()) self.float() else null;
    }

    pub inline fn obj(self: Value) *Obj {
        return @as(*Obj, @ptrFromInt(self.val & ~PointerMask));
    }

    pub inline fn objOrNull(self: Value) ?*Obj {
        return if (self.isObj()) self.obj() else null;
    }

    pub fn typeOf(self: Value, gc: *GarbageCollector) !*ObjTypeDef {
        if (self.isObj()) {
            return try self.obj().typeOf(gc);
        }

        if (self.isFloat()) {
            return try gc.type_registry.getTypeDef(.{ .def_type = .Float });
        }

        return try gc.type_registry.getTypeDef(
            .{
                .def_type = switch (self.getTag()) {
                    TagBoolean => .Bool,
                    TagInteger => .Integer,
                    TagUnsignedInteger => .UnsignedInteger,
                    TagNull, TagVoid => .Void,
                    else => .Float,
                },
            },
        );
    }
};

pub fn valueToStringAlloc(allocator: Allocator, value: Value) (Allocator.Error || std.fmt.BufPrintError)!std.ArrayList(u8) {
    var str = std.ArrayList(u8).init(allocator);

    try valueToString(&str.writer(), value);

    return str;
}

pub fn valueToString(writer: *const std.ArrayList(u8).Writer, value: Value) (Allocator.Error || std.fmt.BufPrintError)!void {
    if (value.isObj()) {
        try objToString(writer, value.obj());

        return;
    }

    if (value.isFloat()) {
        try writer.print("{d}", .{value.float()});
        return;
    }

    switch (value.getTag()) {
        TagBoolean => try writer.print("{}", .{value.boolean()}),
        TagInteger => try writer.print("{d}", .{value.integer()}),
        TagUnsignedInteger => try writer.print("{d}", .{value.unsigned()}),
        TagNull => try writer.print("null", .{}),
        TagVoid => try writer.print("void", .{}),
        else => try writer.print("{d}", .{value.float()}),
    }
}

pub fn valueEql(a: Value, b: Value) bool {
    // zig fmt: off
    if (a.isObj() != b.isObj()
        or a.isNumber() != b.isNumber()
        or (!a.isNumber() and !b.isNumber() and a.getTag() != b.getTag())) {
        return false;
    }
    // zig fmt: on

    if (a.isObj()) {
        return a.obj().eql(b.obj());
    }

    if (a.isUnsigned() or a.isInteger() or a.isFloat()) {
        const a_f: ?f64 = if (a.isFloat()) a.float() else null;
        const b_f: ?f64 = if (b.isFloat()) b.float() else null;
        const a_i: ?i32 = if (a.isInteger()) a.integer() else null;
        const b_i: ?i32 = if (b.isInteger()) b.integer() else null;
        const a_ui: ?u32 = if (a.isUnsigned()) a.unsigned() else null;
        const b_ui: ?u32 = if (b.isUnsigned()) b.unsigned() else null;

        if (a_f != null or b_f != null) {
            return a_f orelse @as(
                f64,
                if (a_i) |ai|
                    @floatFromInt(ai)
                else
                    @floatFromInt(a_ui.?),
            ) == b_f orelse @as(
                f64,
                if (b_i) |bi|
                    @floatFromInt(bi)
                else
                    @floatFromInt(b_ui.?),
            );
        } else if (a_ui != null and b_ui != null) {
            return a_ui.? == b_ui.?;
        } else if (a_ui != null) {
            return a_ui.? == b_i.?;
        } else if (b_ui != null) {
            return a_i.? == b_ui.?;
        } else {
            return a_i.? == b_i.?;
        }
    }

    return switch (a.getTag()) {
        TagBoolean => a.boolean() == b.boolean(),
        TagNull => true,
        TagVoid => true,
        else => unreachable,
    };
}

pub fn valueIs(type_def_val: Value, value: Value) bool {
    const type_def: *ObjTypeDef = ObjTypeDef.cast(type_def_val.obj()).?;

    if (value.isObj()) {
        return value.obj().is(type_def);
    }

    if (value.isFloat()) {
        return type_def.def_type == .Float;
    }

    return switch (value.getTag()) {
        TagBoolean => type_def.def_type == .Bool,
        TagInteger => type_def.def_type == .Integer,
        TagUnsignedInteger => type_def.def_type == .UnsignedInteger,
        // TODO: this one is ambiguous at runtime, is it the `null` constant? or an optional local with a null value?
        TagNull => type_def.def_type == .Void or type_def.optional,
        TagVoid => type_def.def_type == .Void,
        else => type_def.def_type == .Float,
    };
}

pub fn valueTypeEql(value: Value, type_def: *ObjTypeDef) bool {
    if (value.isObj()) {
        return value.obj().typeEql(type_def);
    }

    if (value.isFloat()) {
        return type_def.def_type == .Float;
    }

    return switch (value.getTag()) {
        TagBoolean => type_def.def_type == .Bool,
        TagInteger => type_def.def_type == .Integer,
        TagUnsignedInteger => type_def.def_type == .UnsignedInteger,
        // TODO: this one is ambiguous at runtime, is it the `null` constant? or an optional local with a null value?
        TagNull => type_def.def_type == .Void or type_def.optional,
        TagVoid => type_def.def_type == .Void,
        else => type_def.def_type == .Float,
    };
}
