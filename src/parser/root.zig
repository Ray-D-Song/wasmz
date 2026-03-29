const std = @import("std");
const DataRange = @import("range.zig").DataRange;
const Payload = @import("payload.zig").Payload;

const WASM_MAGIC_NUMBER = 0x6d736100;
const WASM_SUPPORTED_VERSION = [_]u32{ 0x1, 0x2 };

pub const Parser = struct {
    // The current state of the parser.
    cur_state: ParseState = .INITIAL,
    // Input data for the current parse call.
    cur_data: []const u8 = &.{},
    // Current position in the input data.
    cur_pos: usize = 0,
    // Total length of the current input data.
    cur_len: usize = 0,
    // Flag to indicate if the end of the file has been reached.
    cur_eof: bool = false,
    cur_sect_range: ?DataRange = null,
    cur_fn_range: ?DataRange = null,

    last_err_arg: u32 = 0,
    last_err_state: i32 = 0,

    pub fn init() Parser {
        return .{};
    }

    // Incremental parsing: one observable parser event per call.
    pub fn parse(self: *Parser, input: []const u8, eof: bool) ParseResult {
        self.cur_data = input;
        self.cur_pos = 0;
        self.cur_len = input.len;
        self.cur_eof = eof;

        while (true) {
            switch (self.cur_state) {
                .INITIAL => {
                    const start_pos = self.cur_pos;
                    if (!self.has_bytes(8)) {
                        self.cur_pos = start_pos;
                        return .need_more_data;
                    }

                    const magic_number = self.read_u32();
                    if (magic_number != WASM_MAGIC_NUMBER) {
                        self.last_err_arg = magic_number;
                        self.cur_state = .ERROR;
                        return ParseResult{ .err = ParserError.BadMagicNumber };
                    }

                    const version = self.read_u32();
                    if (!contains_u32(WASM_SUPPORTED_VERSION[0..], version)) {
                        self.last_err_arg = version;
                        self.cur_state = .ERROR;
                        return ParseResult{ .err = ParserError.BadVersionNumber };
                    }

                    self.cur_state = .BEGIN_WASM;
                    return ParseResult{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = Payload{
                            .module_header = .{
                                .magic_number = magic_number,
                                .version = version,
                            },
                        },
                    } };
                },
                .BEGIN_WASM, .END_SECTION => return self.read_sect_header(),
                .END_WASM => {
                    if (!self.has_more_bytes()) {
                        return .end;
                    }

                    return self.fail_with_state(ParserError.TrailingBytesAfterModule);
                },
                .ERROR => return self.fail_with_state(ParserError.UnsupportedState),
                else => return self.fail_with_state(ParserError.UnsupportedState),
            }
        }
    }

    // Full parsing, it will call parse() internally.
    pub fn parseAll() void {}

    // Helper function to check if there are enough bytes left in the input data for parsing.
    fn has_bytes(self: *Parser, len: usize) bool {
        return self.cur_pos + len <= self.cur_len;
    }

    fn has_more_bytes(self: *Parser) bool {
        return self.cur_pos < self.cur_len;
    }

    fn read_u8(self: *Parser) u8 {
        const byte = self.cur_data[self.cur_pos];
        self.cur_pos += 1;
        return byte;
    }

    // Helper function to peek a u32 value from the input data at the current position without advancing the position.
    fn peek_u32(self: *Parser) u32 {
        const b1 = self.cur_data[self.cur_pos];
        const b2 = self.cur_data[self.cur_pos + 1];
        const b3 = self.cur_data[self.cur_pos + 2];
        const b4 = self.cur_data[self.cur_pos + 3];
        return @as(u32, b1) | (@as(u32, b2) << 8) | (@as(u32, b3) << 16) | (@as(u32, b4) << 24);
    }

    // Helper function to read a u32 value from the input data at the current position.
    fn read_u32(self: *Parser) u32 {
        const b1 = self.read_u8();
        const b2 = self.read_u8();
        const b3 = self.read_u8();
        const b4 = self.read_u8();

        return @as(u32, b1) | (@as(u32, b2) << 8) | (@as(u32, b3) << 16) | (@as(u32, b4) << 24);
    }

    fn read_sect_header(self: *Parser) ParseResult {
        if (!self.has_more_bytes()) {
            if (self.cur_eof) {
                self.cur_state = .END_WASM;
                return .end;
            }

            return .need_more_data;
        }

        // Section parsing is not implemented yet. Any remaining bytes are treated
        // as work for a future section parser stage rather than a second module.
        return self.fail_with_state(ParserError.UnsupportedState);
    }

    fn fail_with_state(self: *Parser, err: ParserError) ParseResult {
        self.last_err_state = @intFromEnum(self.cur_state);
        return ParseResult{ .err = err };
    }
};

pub const ParserError = error{
    // "Unexpected type kind: ${kind}}"
    UnexpectedTypeKind,
    // "Unknown type kind: ${kind}" / "Unknown type kind: ${form}"
    UnknownTypeKind,
    // "Unsupported element segment type ${segmentType}"
    // "Unsupported element segment type ${this._segmentType}"
    UnsupportedElementSegmentType,
    // "Unsupported data segment type ${segmentType}"
    UnsupportedDataSegmentType,
    // "Bad linking type: ${type}"
    BadLinkingType,
    // "Bad relocation type: ${type}"
    BadRelocationType,
    // "Unknown operator: ${code}"
    // "Unknown operator: 0x${code.toString(16).padStart(4, \"0\")}"
    UnknownOperator,
    // "atomic.fence consistency model must be 0"
    AtomicFenceConsistencyModelMustBeZero,
    // "Unsupported section: ${this._sectionId}"
    UnsupportedSection,
    // "Bad magic number"
    BadMagicNumber,
    // "Bad version number ${version}"
    BadVersionNumber,
    // "Unexpected section type: ${this._sectionId}"
    UnexpectedSectionType,
    // "Unsupported state: ${this.state}"
    UnsupportedState,
    // "Trailing bytes found after the module end"
    TrailingBytesAfterModule,
};

pub fn formatParserError(
    parser: *const Parser,
    err: ParserError,
    writer: anytype,
) !void {
    switch (err) {
        .UnexpectedTypeKind => try writer.print("Unexpected type kind: {}", .{parser.last_err_arg}),
        .UnknownTypeKind => try writer.print("Unknown type kind: {}", .{parser.last_err_arg}),
        .UnsupportedElementSegmentType => {
            try writer.print("Unsupported element segment type {}", .{parser.last_err_arg});
        },
        .UnsupportedDataSegmentType => {
            try writer.print("Unsupported data segment type {}", .{parser.last_err_arg});
        },
        .BadLinkingType => try writer.print("Bad linking type: {}", .{parser.last_err_arg}),
        .BadRelocationType => try writer.print("Bad relocation type: {}", .{parser.last_err_arg}),
        .UnknownOperator => try writer.print("Unknown operator: 0x{x}", .{parser.last_err_arg}),
        .AtomicFenceConsistencyModelMustBeZero => {
            try writer.writeAll("atomic.fence consistency model must be 0");
        },
        .UnsupportedSection => try writer.print("Unsupported section: {}", .{parser.last_err_arg}),
        .BadMagicNumber => try writer.writeAll("Bad magic number"),
        .BadVersionNumber => try writer.print("Bad version number {}", .{parser.last_err_arg}),
        .UnexpectedSectionType => {
            try writer.print("Unexpected section type: {}", .{parser.last_err_arg});
        },
        .UnsupportedState => try writer.print("Unsupported state: {}", .{parser.last_err_state}),
        .TrailingBytesAfterModule => try writer.writeAll("Trailing bytes found after the module end"),
    }
}

pub const ParseResult = union(enum) {
    // Need more data to continue parsing.
    need_more_data,
    // Successfully parsed a payload.
    parsed: struct {
        consumed: usize,
        payload: Payload,
    },
    // Full wasm module is parsed.
    end,
    // Parsing error.
    err: ParserError,
};

pub const ParseState = enum(i32) {
    ERROR,
    INITIAL,
    BEGIN_WASM,
    END_WASM,
    BEGIN_SECTION,
    END_SECTION,
    SKIPPING_SECTION,
    READING_SECTION_RAW_DATA,
    SECTION_RAW_DATA,

    TYPE_SECTION_ENTRY,
    IMPORT_SECTION_ENTRY,
    FUNCTION_SECTION_ENTRY,
    TABLE_SECTION_ENTRY,
    MEMORY_SECTION_ENTRY,
    GLOBAL_SECTION_ENTRY,
    EXPORT_SECTION_ENTRY,
    DATA_SECTION_ENTRY,
    NAME_SECTION_ENTRY,
    ELEMENT_SECTION_ENTRY,
    LINKING_SECTION_ENTRY,
    START_SECTION_ENTRY,
    TAG_SECTION_ENTRY,

    BEGIN_INIT_EXPRESSION_BODY,
    INIT_EXPRESSION_OPERATOR,
    END_INIT_EXPRESSION_BODY,

    BEGIN_FUNCTION_BODY,
    READING_FUNCTION_HEADER,
    CODE_OPERATOR,
    END_FUNCTION_BODY,
    SKIPPING_FUNCTION_BODY,

    BEGIN_ELEMENT_SECTION_ENTRY,
    ELEMENT_SECTION_ENTRY_BODY,
    END_ELEMENT_SECTION_ENTRY,

    BEGIN_DATA_SECTION_ENTRY,
    DATA_SECTION_ENTRY_BODY,
    END_DATA_SECTION_ENTRY,

    BEGIN_GLOBAL_SECTION_ENTRY,
    END_GLOBAL_SECTION_ENTRY,

    RELOC_SECTION_HEADER,
    RELOC_SECTION_ENTRY,

    SOURCE_MAPPING_URL,

    BEGIN_OFFSET_EXPRESSION_BODY,
    OFFSET_EXPRESSION_OPERATOR,
    END_OFFSET_EXPRESSION_BODY,

    BEGIN_REC_GROUP,
    END_REC_GROUP,

    DATA_COUNT_SECTION_ENTRY,
};

fn contains_u32(values: []const u32, value: u32) bool {
    for (values) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

test "parses a module header in one call" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

    var parser = Parser.init();
    const result = parser.parse(&header, false);

    switch (result) {
        .parsed => |parsed| {
            try std.testing.expectEqual(@as(usize, 8), parsed.consumed);
            switch (parsed.payload) {
                .module_header => |module_header| {
                    try std.testing.expectEqual(@as(u32, WASM_MAGIC_NUMBER), module_header.magic_number);
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

test "remaining bytes after the header are not treated as a second module" {
    const header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
    const trailing = [_]u8{0x00};

    var parser = Parser.init();
    _ = parser.parse(&header, false);
    try expect_error(ParserError.UnsupportedState, parser.parse(&trailing, true));
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
