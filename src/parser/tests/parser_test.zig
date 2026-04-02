const std = @import("std");
const parser_mod = @import("parser");
const payload_mod = @import("payload");

const Parser = parser_mod.Parser;
const ParseResult = parser_mod.ParseResult;
const ParserError = parser_mod.ParserError;
const Payload = payload_mod.Payload;
const SectionCode = payload_mod.SectionCode;

const imports_wasm: []const u8 = @embedFile("fixtures/imports.wasm");
const globals_wasm: []const u8 = @embedFile("fixtures/globals.wasm");
const zig_hello_wasm: []const u8 = @embedFile("fixtures/zig_hello.wasm");
const malloc_v13_wasm: []const u8 = @embedFile("fixtures/malloc_v13.wasm");
const nop_wasm: []const u8 = @embedFile("fixtures/nop.wasm");

const StreamStats = struct {
    total_consumed: usize = 0,
    parsed_events: usize = 0,
    need_more_data_count: usize = 0,
    section_events: usize = 0,
    saw_header: bool = false,
    saw_end: bool = false,
    saw_type_section: bool = false,
    saw_import_section: bool = false,
    saw_function_section: bool = false,
    saw_global_section: bool = false,
    saw_export_section: bool = false,
    saw_code_section: bool = false,
    saw_function_info: bool = false,
    saw_global_variable: bool = false,
};

fn note_payload(stats: *StreamStats, payload: Payload) void {
    switch (payload) {
        .module_header => stats.saw_header = true,
        .section_info => |section_info| {
            stats.section_events += 1;
            switch (section_info.id) {
                .type => stats.saw_type_section = true,
                .import => stats.saw_import_section = true,
                .function => stats.saw_function_section = true,
                .global => stats.saw_global_section = true,
                .@"export" => stats.saw_export_section = true,
                .code => stats.saw_code_section = true,
                else => {},
            }
        },
        .function_info => stats.saw_function_info = true,
        .global_variable => stats.saw_global_variable = true,
        else => {},
    }
}

fn fail_parse(parser: *Parser, err: ParserError) error{ParseFailed} {
    std.debug.print(
        "streaming parse failed: err={any}, state={any}, arg={}, last_state={}\n",
        .{ err, parser.cur_state, parser.last_err_arg, parser.last_err_state },
    );
    return error.ParseFailed;
}

fn fail_parse_all(parser: *Parser, err: parser_mod.ParseAllError) parser_mod.ParseAllError {
    switch (err) {
        error.OutOfMemory, error.UnexpectedNeedMoreData => {
            std.debug.print(
                "parseAll failed: err={s}, state={any}, arg={}, last_state={}\n",
                .{ @errorName(err), parser.cur_state, parser.last_err_arg, parser.last_err_state },
            );
        },
        else => {
            const parser_err: ParserError = @errorCast(err);
            var detail_buf: [256]u8 = undefined;
            var detail_stream = std.io.fixedBufferStream(&detail_buf);

            parser_mod.formatParserError(parser, parser_err, detail_stream.writer()) catch {};
            std.debug.print(
                "parseAll failed: err={s}, detail={s}, state={any}, arg={}, last_state={}\n",
                .{
                    @errorName(parser_err),
                    detail_stream.getWritten(),
                    parser.cur_state,
                    parser.last_err_arg,
                    parser.last_err_state,
                },
            );
        },
    }

    return err;
}

fn collect_payload_stats(payloads: []const Payload) StreamStats {
    var stats = StreamStats{
        .parsed_events = payloads.len,
    };
    for (payloads) |payload| {
        note_payload(&stats, payload);
    }
    return stats;
}

fn parse_fixture_streaming(bytes: []const u8, chunk_size: usize) !StreamStats {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const pending_buf = try allocator.alloc(u8, bytes.len);

    var parser = Parser.init(allocator);
    var stats = StreamStats{};
    var source_pos: usize = 0;
    var pending_len: usize = 0;

    while (true) {
        const remaining = bytes.len - source_pos;
        const next_chunk_len = @min(chunk_size, remaining);
        if (next_chunk_len > 0) {
            std.mem.copyForwards(
                u8,
                pending_buf[pending_len .. pending_len + next_chunk_len],
                bytes[source_pos .. source_pos + next_chunk_len],
            );
            pending_len += next_chunk_len;
            source_pos += next_chunk_len;
        }

        const eof = source_pos == bytes.len;
        var input = pending_buf[0..pending_len];

        while (true) {
            switch (parser.parse(input, eof)) {
                .parsed => |parsed| {
                    try std.testing.expect(parsed.consumed > 0);
                    stats.total_consumed += parsed.consumed;
                    stats.parsed_events += 1;
                    note_payload(&stats, parsed.payload);

                    input = input[parsed.consumed..];
                    if (input.len == 0) {
                        pending_len = 0;
                        break;
                    }
                },
                .need_more_data => {
                    stats.need_more_data_count += 1;
                    if (eof) return error.UnexpectedNeedMoreDataAtEof;

                    std.mem.copyForwards(u8, pending_buf[0..input.len], input);
                    pending_len = input.len;
                    break;
                },
                .end => {
                    stats.saw_end = true;
                    try std.testing.expect(eof);
                    try std.testing.expectEqual(@as(usize, 0), input.len);
                    return stats;
                },
                .err => |err| return fail_parse(&parser, err),
            }
        }
    }
}

test "stream parses nop fixture across chunk sizes" {
    const chunk_sizes = [_]usize{ 1, 7, 64 };

    for (chunk_sizes) |chunk_size| {
        const stats = try parse_fixture_streaming(nop_wasm, chunk_size);

        try std.testing.expect(stats.saw_header);
        try std.testing.expect(stats.saw_end);
        try std.testing.expect(stats.saw_type_section);
        try std.testing.expect(stats.saw_function_section);
        try std.testing.expect(stats.saw_code_section);
        try std.testing.expect(stats.saw_function_info);
        try std.testing.expect(stats.parsed_events > 10);
        try std.testing.expect(stats.section_events > 2);
        try std.testing.expectEqual(nop_wasm.len, stats.total_consumed);

        if (chunk_size == 1) {
            try std.testing.expect(stats.need_more_data_count > 0);
        }
    }
}

test "stream parses imports fixture one byte at a time" {
    const stats = try parse_fixture_streaming(imports_wasm, 1);

    try std.testing.expect(stats.saw_header);
    try std.testing.expect(stats.saw_end);
    try std.testing.expect(stats.saw_type_section);
    try std.testing.expect(stats.saw_function_section);
    try std.testing.expect(stats.section_events > 2);
    try std.testing.expect(stats.need_more_data_count > 0);
    try std.testing.expectEqual(imports_wasm.len, stats.total_consumed);
}

test "stream parses globals fixture one byte at a time" {
    const stats = try parse_fixture_streaming(globals_wasm, 1);

    try std.testing.expect(stats.saw_header);
    try std.testing.expect(stats.saw_end);
    try std.testing.expect(stats.saw_type_section);
    try std.testing.expect(stats.saw_global_section);
    try std.testing.expect(stats.saw_export_section);
    try std.testing.expect(stats.saw_global_variable);
    try std.testing.expect(stats.need_more_data_count > 0);
    try std.testing.expectEqual(globals_wasm.len, stats.total_consumed);
}

test "parseAll parses nop fixture with the same event granularity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator());
    const payloads = try parser.parseAll(nop_wasm);
    const stats = collect_payload_stats(payloads);
    const streaming_stats = try parse_fixture_streaming(nop_wasm, 7);

    try std.testing.expect(stats.saw_header);
    try std.testing.expect(stats.saw_type_section);
    try std.testing.expect(stats.saw_function_section);
    try std.testing.expect(stats.saw_code_section);
    try std.testing.expect(stats.saw_function_info);
    try std.testing.expectEqual(streaming_stats.parsed_events, payloads.len);
}

test "parseAll accepts experimental version 0x0d fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator());
    const payloads = try parser.parseAll(malloc_v13_wasm);

    try std.testing.expect(payloads.len > 1);
    switch (payloads[0]) {
        .module_header => |module_header| {
            try std.testing.expectEqual(@as(u32, 0x0d), module_header.version);
        },
        else => return error.UnexpectedPayload,
    }
}

test "zig hello" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = Parser.init(arena.allocator());
    const payloads = parser.parseAll(zig_hello_wasm) catch |err| return fail_parse_all(&parser, err);
    try std.testing.expect(payloads.len > 1);
}
