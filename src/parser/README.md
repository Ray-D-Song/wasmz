The parser interface will be something like:

```zig
const std = @import("std");
const parser_mod = @import("root.zig");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("example.wasm", .{});
    defer file.close();

    var parser = parser_mod.Parser.init();

    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(&reader_buf);

    var pending_buf: [8192]u8 = undefined;
    var pending_len: usize = 0;

    while (true) {
        const n = try reader.interface.readSliceShort(pending_buf[pending_len..]);
        const eof = n == 0;

        var input = pending_buf[0 .. pending_len + n];

        while (true) {
            switch (parser.parse(input, eof)) {
                .parsed => |r| {
                    switch (r.payload) {
                        .module_header => {},
                        else => {},
                    }

                    input = input[r.consumed..];
                    if (input.len == 0) {
                        pending_len = 0;
                        break;
                    }
                },
                .need_more_data => {
                    std.mem.copyForwards(u8, pending_buf[0..input.len], input);
                    pending_len = input.len;

                    if (eof) return error.UnexpectedEof;
                    break;
                },
                .end => return,
                .err => |e| return e,
            }
        }
    }
}
```
