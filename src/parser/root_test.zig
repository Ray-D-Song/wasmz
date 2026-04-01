const std = @import("std");
const parser_mod = @import("root.zig");
const payload_mod = @import("payload.zig");

const Parser = parser_mod.Parser;
const ParseResult = parser_mod.ParseResult;
const ParseState = parser_mod.ParseState;
const ParserError = parser_mod.ParserError;
const ExternalKind = payload_mod.ExternalKind;
const SectionCode = payload_mod.SectionCode;
const TypeKind = payload_mod.TypeKind;
const parser_testing = parser_mod.testing;

const wasm_magic_number: u32 = 0x6d736100;

test "parses a module header in one call" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
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

    var parser = Parser.init(std.testing.allocator);
    try expect_need_more_data(parser.parse(&prefix, false));

    const result = parser.parse(&full_header, false);
    switch (result) {
        .parsed => |parsed| try std.testing.expectEqual(@as(usize, 8), parsed.consumed),
        else => return error.UnexpectedParseResult,
    }
}

test "returns an error for a bad magic number" {
    const header = [_]u8{ 0x01, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    try expect_error(ParserError.BadMagicNumber, parser.parse(&header, false));
}

test "returns an error for an unsupported version" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x03, 0x00, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    try expect_error(ParserError.BadVersionNumber, parser.parse(&header, false));
}

test "empty input before eof requests more data" {
    var parser = Parser.init(std.testing.allocator);
    try expect_need_more_data(parser.parse(&.{}, false));
}

test "truncated header at eof still requests more data" {
    const prefix = [_]u8{ 0x00, 0x61, 0x73, 0x6d };

    var parser = Parser.init(std.testing.allocator);
    try expect_need_more_data(parser.parse(&prefix, true));
}

test "returns end after the header when eof is reached with no more bytes" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);
    try expect_end(parser.parse(&.{}, true));
}

test "parses an empty section as a single event" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x00,
    };

    var parser = Parser.init(std.testing.allocator);
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

    var parser = Parser.init(std.testing.allocator);
    parser.cur_state = .BEGIN_WASM;
    try expect_need_more_data(parser.parse(&partial_section, false));
}

test "parses a custom section name only when the full section is available" {
    const custom_section = [_]u8{ 0x00, 0x05, 0x04, 'n', 'a', 'm', 'e' };

    var parser = Parser.init(std.testing.allocator);
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

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);
    try expect_need_more_data(parser.parse(&trailing, true));
}

test "type section entry asks for more data when a func type body is truncated" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const type_section = [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&type_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    try std.testing.expectEqual(@as(usize, 3), consumed);
    try expect_need_more_data(parser.parse(type_section[consumed .. consumed + 1], false));
}

test "type section entry parses a func type" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const type_section = [_]u8{ 0x01, 0x04, 0x01, 0x60, 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&type_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    const entry_result = parser.parse(type_section[consumed..], false);
    switch (entry_result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 3), parsed.consumed);
            switch (parsed.payload) {
                .type_entry => |type_entry| {
                    try std.testing.expectEqual(TypeKind.func, type_entry.type);
                    try std.testing.expectEqual(@as(usize, 0), type_entry.params.len);
                    try std.testing.expectEqual(@as(usize, 0), type_entry.returns.len);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }
}

test "import section entry asks for more data when payload is truncated" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const import_section = [_]u8{ 0x02, 0x07, 0x01, 0x01, 'm', 0x01, 'f', 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&import_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    try std.testing.expectEqual(@as(usize, 3), consumed);
    try expect_need_more_data(parser.parse(import_section[consumed .. consumed + 3], false));
}

test "import section entry parses a function import" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const import_section = [_]u8{ 0x02, 0x07, 0x01, 0x01, 'm', 0x01, 'f', 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&import_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    const entry_result = parser.parse(import_section[consumed..], false);
    switch (entry_result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 6), parsed.consumed);
            switch (parsed.payload) {
                .import_entry => |import_entry| {
                    try std.testing.expectEqualStrings("m", import_entry.module);
                    try std.testing.expectEqualStrings("f", import_entry.field);
                    try std.testing.expectEqual(ExternalKind.function, import_entry.kind);
                    try std.testing.expectEqual(@as(?u32, 0), import_entry.func_type_index);
                    try std.testing.expectEqual(@as(?payload_mod.ImportEntryType, null), import_entry.typ);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }
}

test "global section entry asks for more data when init expr is truncated" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const global_section = [_]u8{ 0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&global_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    try std.testing.expectEqual(@as(usize, 3), consumed);
    try expect_need_more_data(parser.parse(global_section[consumed .. consumed + 4], false));
}

test "global section entry parses a global with i32 const init expr" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const global_section = [_]u8{ 0x06, 0x06, 0x01, 0x7f, 0x00, 0x41, 0x00, 0x0b };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&global_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    const entry_result = parser.parse(global_section[consumed..], false);
    switch (entry_result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 5), parsed.consumed);
            switch (parsed.payload) {
                .global_variable => |global_variable| {
                    try std.testing.expectEqual(TypeKind.i32, switch (global_variable.typ.content_type) {
                        .kind => |kind| kind,
                        else => return error.UnexpectedPayload,
                    });
                    try std.testing.expectEqual(@as(u8, 0), global_variable.typ.mutability);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }
}

test "export section entry asks for more data when payload is truncated" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const export_section = [_]u8{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&export_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    try std.testing.expectEqual(@as(usize, 3), consumed);
    try expect_need_more_data(parser.parse(export_section[consumed .. consumed + 2], false));
}

test "export section entry parses a function export" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const export_section = [_]u8{ 0x07, 0x05, 0x01, 0x01, 'f', 0x00, 0x00 };

    var parser = Parser.init(std.testing.allocator);
    _ = parser.parse(&header, false);

    const section_result = parser.parse(&export_section, false);
    const consumed = switch (section_result) {
        .parsed => |parsed| parsed.consumed,
        else => return error.UnexpectedParseResult,
    };

    const entry_result = parser.parse(export_section[consumed..], false);
    switch (entry_result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 4), parsed.consumed);
            switch (parsed.payload) {
                .export_entry => |export_entry| {
                    try std.testing.expectEqualStrings("f", export_entry.field);
                    try std.testing.expectEqual(ExternalKind.function, export_entry.kind);
                    try std.testing.expectEqual(@as(u32, 0), export_entry.index);
                },
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedParseResult,
    }
}

test "read_heap_type decodes a single-byte negative heap type" {
    switch (parser_testing.read_heap_type(&[_]u8{0x70})) {
        .kind => |kind| try std.testing.expectEqual(TypeKind.funcref, kind),
        else => return error.UnexpectedPayload,
    }
}

test "read_heap_type decodes a continued heap type index" {
    switch (parser_testing.read_heap_type(&[_]u8{ 0xff, 0x00 })) {
        .index => |index| try std.testing.expectEqual(@as(u32, 127), index),
        else => return error.UnexpectedPayload,
    }
}

test "read_type decodes a type index" {
    const typ = parser_testing.read_type(&[_]u8{ 0xff, 0x00 });

    switch (typ) {
        .index => |index| try std.testing.expectEqual(@as(u32, 127), index),
        else => return error.UnexpectedPayload,
    }
}

test "read_type decodes a primitive value type" {
    const typ = parser_testing.read_type(&[_]u8{0x7f});

    switch (typ) {
        .kind => |kind| try std.testing.expectEqual(TypeKind.i32, kind),
        else => return error.UnexpectedPayload,
    }
}

test "read_type decodes a nullable reference type" {
    const typ = parser_testing.read_type(&[_]u8{ 0x63, 0x70 });

    switch (typ) {
        .ref_type => |ref_type| {
            try std.testing.expect(ref_type.nullable);
            switch (ref_type.ref_index) {
                .kind => |kind| try std.testing.expectEqual(TypeKind.funcref, kind),
                else => return error.UnexpectedPayload,
            }
        },
        else => return error.UnexpectedPayload,
    }
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
