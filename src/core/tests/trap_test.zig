const std = @import("std");
const testing = std.testing;

const trap_mod = @import("../trap.zig");

const TrapCode = trap_mod.TrapCode;
const Trap = trap_mod.Trap;

test "trap code conversion" {
    const cases = [_]TrapCode{
        .UnreachableCodeReached,
        .MemoryOutOfBounds,
        .TableOutOfBounds,
        .IndirectCallToNull,
        .IntegerDivisionByZero,
        .IntegerOverflow,
        .BadConversionToInteger,
        .StackOverflow,
        .BadSignature,
        .OutOfFuel,
        .GrowthOperationLimited,
        .OutOfSystemMemory,
        .NullReference,
        .CastFailure,
        .ArrayOutOfBounds,
    };

    for (cases) |code| {
        try testing.expectEqual(code, try TrapCode.fromInt(@intFromEnum(code)));
    }
    try testing.expectError(
        trap_mod.InvalidTrapCode.InvalidTrapCode,
        TrapCode.fromInt(std.math.maxInt(u8)),
    );
}

test "trap formatting and accessors" {
    const allocator = testing.allocator;

    const trap_from_code = Trap.fromTrapCode(.OutOfFuel);
    try testing.expectEqual(@as(?TrapCode, .OutOfFuel), trap_from_code.trapCode());
    const code_message = try trap_from_code.allocPrint(allocator);
    defer allocator.free(code_message);
    try testing.expectEqualStrings("all fuel consumed by WebAssembly", code_message);

    var trap_from_message = try Trap.newOwned(allocator, "custom trap");
    defer trap_from_message.deinit();
    try testing.expectEqual(@as(?i32, null), trap_from_message.i32ExitStatus());
    const trap_message = try trap_from_message.allocPrint(allocator);
    defer allocator.free(trap_message);
    try testing.expectEqualStrings("custom trap", trap_message);

    const exit_trap = Trap.i32Exit(7);
    try testing.expectEqual(@as(?i32, 7), exit_trap.i32ExitStatus());
    const exit_message = try exit_trap.allocPrint(allocator);
    defer allocator.free(exit_message);
    try testing.expectEqualStrings("Exited with i32 exit status 7", exit_message);
}
