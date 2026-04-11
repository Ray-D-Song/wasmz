const std = @import("std");

// Error type which can be returned by Wasm code or by the host environment.
//
// Under some conditions, Wasm execution may produce a `Trap`,
// which immediately aborts execution.
// Traps cannot be handled by WebAssembly code, but are reported to the
// host embedder.

pub const InvalidTrapCode = error{
    InvalidTrapCode,
};

pub const TrapCode = enum(u8) {
    // Note: zero is reserved for "no trap",
    // so the first valid trap code starts at 1.

    // Wasm code executed `unreachable` opcode.
    //
    // This indicates that unreachable Wasm code was actually reached.
    // This opcode have a similar purpose as `ud2` in x86.
    UnreachableCodeReached = 1,

    // Attempt to load or store at the address which
    // lies outside of bounds of the memory.
    //
    // Since addresses are interpreted as unsigned integers, out of bounds access
    // can't happen with negative addresses (i.e. they will always wrap).
    MemoryOutOfBounds = 2,

    // Similar to `MemoryOutOfBounds`, but for table accesses.
    TableOutOfBounds = 3,

    // Similar to `nullptr`
    IndirectCallToNull = 4,

    // Attempt to divide an integer by zero,
    // or to perform integer overflow in a division operation.
    IntegerDivisionByZero = 5,

    // Attempt to perform an integer operation which overflows.
    IntegerOverflow = 6,

    // Attempt to convert a value to an integer type,
    // but the value is not representable in that type.
    BadConversionToInteger = 7,

    // We all know what this is.
    StackOverflow = 8,

    // Attempt to call an indirect function,
    // but the type of the function does not match the expected type.
    BadSignature = 9,

    // All fuel consumed by WebAssembly.
    OutOfFuel = 10,

    // Attempt to grow memory or table, but the operation is limited by the embedder.
    GrowthOperationLimited = 11,

    OutOfSystemMemory = 12,

    // ── GC-specific trap codes ────────────────────────────────────────────────────
    // Attempt to dereference a null GC reference.
    NullReference = 13,

    // Attempt to cast a GC reference to an incompatible type.
    CastFailure = 14,

    // Array access out of bounds.
    ArrayOutOfBounds = 15,

    // GC heap exhausted: allocation failed even after a collection cycle.
    OutOfMemory = 16,

    // An exception was thrown but no matching catch handler was found.
    UnhandledException = 17,

    pub fn fromInt(value: u8) InvalidTrapCode!TrapCode {
        return switch (value) {
            inline 1...17 => @enumFromInt(value),
            else => InvalidTrapCode.InvalidTrapCode,
        };
    }

    pub fn trapMessage(self: TrapCode) []const u8 {
        return switch (self) {
            .UnreachableCodeReached => "wasm `unreachable` instruction executed",
            .MemoryOutOfBounds => "out of bounds memory access",
            .TableOutOfBounds => "undefined element: out of bounds table access",
            .IndirectCallToNull => "uninitialized element 2",
            .IntegerDivisionByZero => "integer divide by zero",
            .IntegerOverflow => "integer overflow",
            .BadConversionToInteger => "invalid conversion to integer",
            .StackOverflow => "call stack exhausted",
            .BadSignature => "indirect call type mismatch",
            .OutOfFuel => "all fuel consumed by WebAssembly",
            .GrowthOperationLimited => "growth operation limited",
            .OutOfSystemMemory => "out of system memory",
            .NullReference => "null reference dereference",
            .CastFailure => "cast failure",
            .ArrayOutOfBounds => "out of bounds array access",
            .OutOfMemory => "GC heap out of memory",
            .UnhandledException => "unhandled exception",
        };
    }
};

const ReasonTag = enum {
    // Occurred during the execution of WebAssembly code,
    // with a specific trap code.
    instruction_trap,
    // Occurred due to an explicit exit from WebAssembly code,
    // with a specific i32 exit status.
    i32_exit,
    // Occurred due to a message from WebAssembly code.
    // Just a string message, with no specific trap code.
    message,
    // Occurred due to a message from the host environment.
    host_message,
};

// The reason for a trap, which can be one of several variants.
const Reason = union(ReasonTag) {
    instruction_trap: TrapCode,
    i32_exit: i32,
    message: []const u8,
    host_message: []const u8,
};

pub const Trap = struct {
    reason: Reason,
    allocator: ?std.mem.Allocator = null,
    owned_buffer: ?[]u8 = null,

    pub fn fromTrapCode(code: TrapCode) Trap {
        return .{
            .reason = .{ .instruction_trap = code },
        };
    }

    pub fn fromMessage(msg: []const u8) Trap {
        return .{
            .reason = .{ .message = msg },
        };
    }

    // Creates a new trap with an owned message.
    // It will copy the message into a new buffer allocated with the provided allocator,
    // and the trap will take ownership of that buffer.
    pub fn newOwned(allocator: std.mem.Allocator, msg: []const u8) !Trap {
        const duped = try allocator.dupe(u8, msg);
        return .{
            .reason = .{ .message = duped },
            .allocator = allocator,
            .owned_buffer = duped,
        };
    }

    pub fn hostMessage(msg: []const u8) Trap {
        return .{
            .reason = .{ .host_message = msg },
        };
    }

    pub fn hostMessageOwned(allocator: std.mem.Allocator, msg: []const u8) !Trap {
        const duped = try allocator.dupe(u8, msg);
        return .{
            .reason = .{ .host_message = duped },
            .allocator = allocator,
            .owned_buffer = duped,
        };
    }

    pub fn i32Exit(status: i32) Trap {
        return .{
            .reason = .{ .i32_exit = status },
        };
    }

    pub fn deinit(self: *Trap) void {
        if (self.owned_buffer) |buffer| {
            if (self.allocator) |allocator| {
                allocator.free(buffer);
            }
        }
        self.allocator = null;
        self.owned_buffer = null;
    }

    pub fn i32ExitStatus(self: Trap) ?i32 {
        return switch (self.reason) {
            .i32_exit => |status| status,
            else => null,
        };
    }

    pub fn trapCode(self: Trap) ?TrapCode {
        return switch (self.reason) {
            .instruction_trap => |code| code,
            else => null,
        };
    }

    // Transforms the trap into a human-readable message,
    // allocating a new string with the provided allocator and return
    pub fn allocPrint(self: Trap, allocator: std.mem.Allocator) ![]u8 {
        return switch (self.reason) {
            .instruction_trap => |code| allocator.dupe(u8, code.trapMessage()),
            .i32_exit => |status| std.fmt.allocPrint(
                allocator,
                "Exited with i32 exit status {}",
                .{status},
            ),
            .message => |msg| allocator.dupe(u8, msg),
            .host_message => |msg| allocator.dupe(u8, msg),
        };
    }
};
