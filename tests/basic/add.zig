const std = @import("std");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn _start() void {
    const result = add(3, 4);
    std.debug.print("3 + 4 = {d}\n", .{result});
}
