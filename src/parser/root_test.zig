const std = @import("std");
const parser_mod = @import("root.zig");
const payload_mod = @import("payload.zig");

const Parser = parser_mod.Parser;
const ParseResult = parser_mod.ParseResult;
const ParseState = parser_mod.ParseState;
const ParserError = parser_mod.ParserError;
const SectionCode = payload_mod.SectionCode;

const wasm_magic_number: u32 = 0x6d736100;

test "parses a module header in one call" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    const result = parser.parse(&header, false);

    switch (result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 8), parsed.consumed);
            switch (parsed.payload) {
                .module_header => |module_header| {
                    try std.testing.expectEqual(wasm_magic_number, module_header.magic_number);
                    try std.testing.expectEqual(@as(u32, 1), module_header.version);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }

    try std.testing.expectEqual(ParseState.BEGIN_WASM, parser.cur_state);
}

test "needs more data until the full header is available" {
    const prefix = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const full_header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    try expect_need_more_data(parser.parse(&prefix, false));

    const result = parser.parse(&full_header, false);
    switch (result) {
        .parsed => |parsed| try std.testing.expectEqual(@as(usize, 8), parsed.consumed),
        else => return error.UnexpectedParseResult,
    }
}

test "returns an error for a bad magic number" {
    const header = [_]u8{ 0x01, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    try expect_error(ParserError.BadMagicNumber, parser.parse(&header, false));
}

test "returns an error for an unsupported version" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x03, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    try expect_error(ParserError.BadVersionNumber, parser.parse(&header, false));
}

test "empty input before eof requests more data" {
    var parser = Parser.init();
    try expect_need_more_data(parser.parse(&.{}, false));
}

test "truncated header at eof still requests more data" {
    const prefix = [_]u8{ 0x00, 0x61, 0x73, 0x6d };

    var parser = Parser.init();
    try expect_need_more_data(parser.parse(&prefix, true));
}

test "returns end after the header when eof is reached with no more bytes" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    _ = parser.parse(&header, false);
    try expect_end(parser.parse(&.{}, true));
}

test "parses an empty section as a single event" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x00,
    };

    var parser = Parser.init();
    _ = parser.parse(module[0..8], false);

    const result = parser.parse(module[8..], false);
    switch (result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 3), parsed.consumed);
            switch (parsed.payload) {
                .section_info => |section_info| {
                    try std.testing.expectEqual(SectionCode.type, section_info.id);
                    try std.testing.expectEqual(@as(?[]const u8, null), section_info.name);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }

    try std.testing.expectEqual(ParseState.TYPE_SECTION_ENTRY, parser.cur_state);
}

test "returns need_more_data when a full section is not yet available" {
    const partial_section = [_]u8{ 0x01, 0x03, 0x01 };

    var parser = Parser.init();
    parser.cur_state = .BEGIN_WASM;
    try expect_need_more_data(parser.parse(&partial_section, false));
}

test "parses a custom section name only when the full section is available" {
    const custom_section = [_]u8{ 0x00, 0x05, 0x04, 'n', 'a', 'm', 'e' };

    var parser = Parser.init();
    parser.cur_state = .BEGIN_WASM;

    const result = parser.parse(&custom_section, false);
    switch (result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, custom_section.len), parsed.consumed);
            switch (parsed.payload) {
                .section_info => |section_info| {
                    try std.testing.expectEqual(SectionCode.custom, section_info.id);
                    try std.testing.expectEqualStrings("name", section_info.name.?);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }
}

test "partial section after the header asks for more data" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const trailing = [_]u8{0x00};

    var parser = Parser.init();
    _ = parser.parse(&header, false);
    try expect_need_more_data(parser.parse(&trailing, true));
}

fn expect_need_more_data(result: ParseResult) !void {
    switch (result) {
        .need_more_data => {},
        else => return error.UnexpectedParseResult,
    }
}

fn expect_end(result: ParseResult) !void {
    switch (result) {
        .end => {},
        else => return error.UnexpectedParseResult,
    }
}

fn expect_error(expected: ParserError, result: ParseResult) !void {
    switch (result) {
        .err => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.UnexpectedParseResult,
    }
}
