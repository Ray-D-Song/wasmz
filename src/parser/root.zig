const std = @import("std");
const DataRange = @import("range.zig").DataRange;
const payload_mod = @import("payload.zig");
const Payload = payload_mod.Payload;
const SectionCode = payload_mod.SectionCode;
const SectionInformation = payload_mod.SectionInformation;

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
                .END_WASM => {
                    if (!self.has_more_bytes()) {
                        return .end;
                    }

                    return self.fail_with_state(ParserError.TrailingBytesAfterModule);
                },
                .ERROR => return self.fail_with_state(ParserError.UnsupportedState),
                // Read the next complete section after the module header or the previous section.
                .BEGIN_WASM, .END_SECTION => return self.read_sect(),

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

    /// Check if there are enough bytes to read a WebAssembly string (length-prefixed with LEB128 varuint32) starting from the current position.
    ///
    /// WebAssembly strings are encoded as a length field (varuint32) followed by that many bytes of UTF-8 data. To check if we can read a complete string, we need to:
    /// 1. Check if there are enough bytes to read the length field (LEB128 varuint32).
    /// 2. Check if there are enough bytes to read the string content based on the length field.
    fn has_str_bytes(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const pos = self.cur_pos;
        const length = self.read_var_uint32();
        const result = self.has_bytes(length);
        self.cur_pos = pos;

        return result;
    }

    fn read_str_bytes(self: *Parser) []const u8 {
        const length = self.read_var_uint32();
        return self.read_bytes(length);
    }

    fn read_bytes(self: *Parser, len: usize) []const u8 {
        const bytes = self.cur_data[self.cur_pos .. self.cur_pos + len];
        self.cur_pos += len;
        return bytes;
    }

    /// Check if there are enough bytes to read a complete LEB128 integer starting from the current position.
    /// LEB128 uses the most significant bit as a continuation flag.
    /// When a byte with the most significant bit set to 0 is encountered, it indicates the end of the integer.
    fn has_var_int_bytes(self: *Parser) bool {
        var pos = self.cur_pos;
        while (pos < self.cur_len) {
            // 0x80: LEB128_CONTINUATION_BIT
            // If the continuation bit is not set, it means this is the last byte of the LEB128 integer, so we can return true.
            if ((self.cur_data[pos] & 0x80) == 0) return true;
            pos += 1;
        }
        return false;
    }

    /// Read a single byte and interpret it as a boolean value (varuint1).
    /// Used for boolean values or flags, such as the has_max flag in memory limits.
    /// Directly reads 1 byte and takes the lowest 1 bit.
    fn read_var_uint1(self: *Parser) u1 {
        return @truncate(self.read_u8());
    }

    /// Read a 7-bit unsigned integer (varuint7).
    /// Directly reads 1 byte, value range 0-127.
    /// Commonly used for Section ID (standard Section ID range 0-12, 7 bits are sufficient).
    fn read_var_uint7(self: *Parser) u7 {
        return @truncate(self.read_u8());
    }

    /// Read a 7-bit signed integer (varint7).
    /// Used for scenarios where a negative value is needed, such as type encoding in the Type Section.
    /// Sign extension: converts the 7-bit value to a signed integer, range -64 to 63.
    fn read_var_int7(self: *Parser) i7 {
        const byte = self.read_u8();
        // Extract the lower 7 bits, value range 0-127
        const value = byte & 0x7f;
        // If the most significant bit (bit 6) is 1, it indicates a negative number (range 64-127 corresponds to -64 to -1)
        if (value & 0x40 != 0) {
            // Negative number: convert to two's complement representation
            // For example: 64 (0x40) should represent -64
            // Map 64 to 127 to -64 to -1
            const signed_value = @as(i16, @intCast(value)) - 128;
            return @as(i7, @intCast(signed_value));
        } else {
            // Positive number: 0 to 63
            return @as(i7, @intCast(value));
        }
    }

    /// Read a 32-bit unsigned LEB128 integer (varuint32)
    ///
    /// Decoding process:
    /// 1. Loop through bytes, extracting the lower 7 bits (byte & 0x7f)
    /// 2. Shift left by 7 bits for each subsequent byte and accumulate the result
    /// 3. Stop when a byte with the continuation bit 0 ((byte & 0x80) == 0) is encountered
    ///
    /// Encoding length: 1-5 bytes
    /// Maximum representable value: 2^32 - 1 = 4294967295
    fn read_var_uint32(self: *Parser) u32 {
        var result: u32 = 0;
        var shift: u32 = 0;

        while (true) {
            const byte = self.read_u8();
            // Extract the lower 7 bits and shift to the correct position
            result |= @as(u32, byte & 0x7f) << @intCast(shift);
            shift += 7;
            // Check the continuation flag: if 0, this is the last byte
            if ((byte & 0x80) == 0) break;
        }

        return result;
    }

    /// Read a 32-bit signed LEB128 integer (varint32)
    ///
    /// Similar to the unsigned version, but requires sign extension:
    /// If the total number of bits is less than 32, shift left and then right by the same amount to extend the sign bit to the highest bit.
    ///
    /// For example, decoding -1:
    ///   Encoding: 0x7F (01111111) -> end, value is 127
    ///   Sign extension: (127 << 25) >> 25 = -1
    fn read_var_int32(self: *Parser) i32 {
        var result: u32 = 0;
        var shift: u32 = 0;

        while (true) {
            const byte = self.read_u8();
            result |= @as(u32, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if ((byte & 0x80) == 0) break;
        }

        // Sign extension: if shift < 32, extend the sign bit to the highest bit (bit 31)
        if (shift < 32) {
            const ashift: u5 = @intCast(32 - shift);
            // Shift left to move the sign bit to the highest position, then arithmetic right shift to extend the sign
            const signed_result = @as(i32, @bitCast(result << ashift)) >> ashift;
            return signed_result;
        }

        return @as(i32, @bitCast(result));
    }

    /// Read a 64-bit signed LEB128 integer (varint64)
    ///
    /// Decoding process is similar to the 32-bit version, but uses 64-bit storage
    /// Encoding length: 1-10 bytes
    /// Maximum representable value: 2^63 - 1 = 9223372036854775807
    fn read_var_int64(self: *Parser) i64 {
        var result: u64 = 0;
        var shift: u32 = 0;

        while (true) {
            const byte = self.read_u8();
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            shift += 7;
            if ((byte & 0x80) == 0) break;
        }

        // Sign extension: if shift < 64, extend the sign bit to the highest bit (bit 63)
        if (shift < 64) {
            const ashift: u6 = @intCast(64 - shift);
            const signed_result = @as(i64, @bitCast(result << ashift)) >> ashift;
            return signed_result;
        }

        return @as(i64, @bitCast(result));
    }

    fn read_sect(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (!self.has_more_bytes() and self.cur_eof) {
            self.cur_state = .END_WASM;
            return .end;
        }

        // Check if there are enough bytes to read the section header (at least 1 byte for section ID and 1 byte for section size)
        if (!self.has_var_int_bytes()) {
            return .need_more_data;
        }

        const sect_id = self.read_var_uint7();

        if (!self.has_var_int_bytes()) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }

        const payload_len = self.read_var_uint32();
        const payload_end_pos = self.cur_pos + payload_len;

        var custom_section_name: ?[]const u8 = null;
        if (sect_id == 0) {
            if (!self.has_str_bytes()) {
                self.cur_pos = start_pos;
                return .need_more_data;
            }
            custom_section_name = self.read_str_bytes();
        }

        if (payload_end_pos > self.cur_len) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }

        self.cur_pos = payload_end_pos;
        self.cur_state = .END_SECTION;

        return .{ .parsed = .{
            .consumed = payload_end_pos - start_pos,
            .payload = Payload{
                .section_info = SectionInformation{
                    .id = sect_id,
                    .name = custom_section_name,
                },
            },
        } };
    }

    fn fail_with_state(self: *Parser, err: ParserError) ParseResult {
        self.last_err_state = @intFromEnum(self.cur_state);
        return .{ .err = err };
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

test "parses an empty section as a single event" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6d,
        0x01, 0x00, 0x00, 0x00,
        0x01, // type section id
        0x01, // payload length
        0x00, // type count
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

    try std.testing.expectEqual(ParseState.END_SECTION, parser.cur_state);
}

test "returns need_more_data when a full section is not yet available" {
    const partial_section = [_]u8{
        0x01, // type section id
        0x03, // payload length
        0x01, // part of payload only
    };

    var parser = Parser.init();
    parser.cur_state = .BEGIN_WASM;
    try expect_need_more_data(parser.parse(&partial_section, false));
}

test "parses a custom section name only when the full section is available" {
    const custom_section = [_]u8{
        0x00, // custom section id
        0x05, // payload length
        0x04, // name length
        'n',
        'a',
        'm',
        'e',
    };

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

test "LEB128 unsigned 32-bit encoding" {
    // Test varuint32 decoding
    var parser = Parser.init();

    // 1-byte encoding: 0x01 = 1
    parser.cur_data = &[_]u8{0x01};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u32, 1), parser.read_var_uint32());

    // 1-byte encoding: 0x7F = 127
    parser.cur_data = &[_]u8{0x7F};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u32, 127), parser.read_var_uint32());

    // 2-byte encoding: 0x80 0x01 = 128 (10000000 00000001)
    // 0x80: data=0, continue=1
    // 0x01: data=1, continue=0
    // result = 0 | (1 << 7) = 128
    parser.cur_data = &[_]u8{ 0x80, 0x01 };
    parser.cur_len = 2;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u32, 128), parser.read_var_uint32());

    // 3-byte encoding: 624485 (example from WebAssembly spec)
    // 624485 = 0x2638C5 = 00000010 01100011 10000101
    // Encoded: 0xE5 0x8E 0x26
    parser.cur_data = &[_]u8{ 0xE5, 0x8E, 0x26 };
    parser.cur_len = 3;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u32, 624485), parser.read_var_uint32());
}

test "LEB128 signed 32-bit encoding" {
    var parser = Parser.init();

    // Positive numbers encoded same as unsigned
    // 0x01 = 1
    parser.cur_data = &[_]u8{0x01};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i32, 1), parser.read_var_int32());

    // Negative numbers need sign extension
    // -1 encoded as 0x7F (127 with sign extension becomes -1)
    parser.cur_data = &[_]u8{0x7F};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i32, -1), parser.read_var_int32());

    // -128 encoded as 0x80 0x7F
    // After decoding: 0x80 = 128, with sign extension: (128 << 25) >> 25 = -128
    // Actually: 0x80 | (0x7F << 7) = 0x80 | 0x3F80 = 0x4000 = 16384
    // Let me recalculate: -128 in LEB128
    // -128 = 0x80 (in 8-bit two's complement)
    // LEB128: 0x80 0x7F
    // 0x80: data=0, continue=1
    // 0x7F: data=127, continue=0
    // result = 0 | (127 << 7) = 16256, sign extend from bit 14
    // ashift = 32 - 14 = 18
    // (16256 << 18) >> 18 = -128 ✓
    parser.cur_data = &[_]u8{ 0x80, 0x7F };
    parser.cur_len = 2;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i32, -128), parser.read_var_int32());
}

test "LEB128 7-bit integers" {
    var parser = Parser.init();

    // varuint7: max value 127
    parser.cur_data = &[_]u8{0x7F};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u7, 127), parser.read_var_uint7());

    // varuint1: max value 1
    parser.cur_data = &[_]u8{0x01};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(u1, 1), parser.read_var_uint1());

    // varint7: positive 63
    parser.cur_data = &[_]u8{0x3F};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i7, 63), parser.read_var_int7());

    // varint7: negative -64
    // -64 in 7-bit signed = 0x40 (64)
    // But with proper sign extension from bit 7
    parser.cur_data = &[_]u8{0x40};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i7, -64), parser.read_var_int7());
}

test "LEB128 has_var_int_bytes check" {
    var parser = Parser.init();

    // Complete LEB128: single byte with continue=0
    parser.cur_data = &[_]u8{0x01};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expect(parser.has_var_int_bytes());

    // Incomplete LEB128: continue=1 but no more data
    parser.cur_data = &[_]u8{0x80};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expect(!parser.has_var_int_bytes());

    // Complete multi-byte: 0x80 0x01
    parser.cur_data = &[_]u8{ 0x80, 0x01 };
    parser.cur_len = 2;
    parser.cur_pos = 0;
    try std.testing.expect(parser.has_var_int_bytes());

    // Incomplete multi-byte: 0x80 0x80 (both continue=1, no terminator)
    parser.cur_data = &[_]u8{ 0x80, 0x80 };
    parser.cur_len = 2;
    parser.cur_pos = 0;
    try std.testing.expect(!parser.has_var_int_bytes());
}

test "LEB128 64-bit encoding" {
    var parser = Parser.init();

    // Simple positive number
    parser.cur_data = &[_]u8{0x01};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i64, 1), parser.read_var_int64());

    // Large positive number: 127 needs 2 bytes in signed LEB128
    // 127 = 0b1111111, encoded as 0xFF 0x00
    // 0xFF: data=127, continue=1
    // 0x00: data=0, continue=0
    // result = 127 | (0 << 7) = 127
    parser.cur_data = &[_]u8{ 0xFF, 0x00 };
    parser.cur_len = 2;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i64, 127), parser.read_var_int64());

    // Negative number: 0x7F is -1 in signed LEB128
    parser.cur_data = &[_]u8{0x7F};
    parser.cur_len = 1;
    parser.cur_pos = 0;
    try std.testing.expectEqual(@as(i64, -1), parser.read_var_int64());
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
