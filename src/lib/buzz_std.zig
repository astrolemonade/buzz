const std = @import("std");
const api = @import("buzz_api.zig");

export fn print(ctx: *api.NativeCtx) c_int {
    var len: usize = 0;
    const string = ctx.vm.bz_peek(0).bz_valueToString(&len);

    if (len == 0) {
        return 0;
    }

    _ = std.io.getStdOut().write(string.?[0..len]) catch return 0;
    _ = std.io.getStdOut().write("\n") catch return 0;

    return 0;
}

export fn toInt(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromInteger(
            if (value.isFloat())
                @floatToInt(i32, value.float())
            else
                value.integer(),
        ),
    );

    return 1;
}

export fn toFloat(ctx: *api.NativeCtx) c_int {
    const value = ctx.vm.bz_peek(0);

    ctx.vm.bz_push(
        api.Value.fromFloat(
            if (value.isInteger())
                @intToFloat(f64, value.integer())
            else
                value.float(),
        ),
    );

    return 1;
}

export fn parseInt(ctx: *api.NativeCtx) c_int {
    const string_value = ctx.vm.bz_peek(0);

    var len: usize = 0;
    const string = string_value.bz_valueToString(&len);

    if (len == 0) {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    }

    const string_slice = string.?[0..len];

    const number: i32 = std.fmt.parseInt(i32, string_slice, 10) catch {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    };

    ctx.vm.bz_push(api.Value.fromInteger(number));

    return 1;
}

export fn parseFloat(ctx: *api.NativeCtx) c_int {
    const string_value = ctx.vm.bz_peek(0);

    var len: usize = 0;
    const string = string_value.bz_valueToString(&len);

    if (len == 0) {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    }

    const string_slice = string.?[0..len];

    const number: f64 = std.fmt.parseFloat(f64, string_slice) catch {
        ctx.vm.bz_push(api.Value.Null);

        return 1;
    };

    ctx.vm.bz_push(api.Value.fromFloat(number));

    return 1;
}

export fn char(ctx: *api.NativeCtx) c_int {
    const byte_value = ctx.vm.bz_peek(0);

    var byte = byte_value.integer();

    if (byte > 255) {
        byte = 255;
    } else if (byte < 0) {
        byte = 0;
    }

    const str = [_]u8{@intCast(u8, byte)};

    if (api.ObjString.bz_string(ctx.vm, str[0..], 1)) |obj_string| {
        ctx.vm.bz_push(obj_string.bz_objStringToValue());

        return 1;
    }

    ctx.vm.pushError("lib.errors.OutOfMemoryError");

    return -1;
}

export fn assert(ctx: *api.NativeCtx) c_int {
    const condition_value = ctx.vm.bz_peek(1);
    const message_value = ctx.vm.bz_peek(0);

    if (!condition_value.boolean()) {
        var len: usize = 0;
        const message = api.Value.bz_valueToString(message_value, &len).?;
        // TODO: debug.getTrace
        std.io.getStdOut().writer().print(
            "Assert failed: {s}\n",
            .{
                message[0..len],
            },
        ) catch unreachable;

        std.os.exit(1);
    }

    return 0;
}
