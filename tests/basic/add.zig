const std = @import("std");

extern fn host_print_i32(value: i32) void;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn _start() void {
    const result = add(3, 4);
    host_print_i32(result);
}
