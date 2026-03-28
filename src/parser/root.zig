const std = @import("std");
const DataRange = @import("range.zig").DataRange;

const Parser = struct {
    // The current state of the parser
    cur_state: ParseState = .INITIAL,
    // Input data for parsing
    cur_data: []const u8,
    // Current position in the input data
    cur_pos: usize,
    // Total length of the input data
    cur_len: usize,
    // Flag to indicate if the end of the file has been reached
    cur_eof: bool,
    cur_sect_range: ?DataRange,
    cur_fn_range: ?DataRange,

    last_err_arg: u32,
    last_err_state: i32 = 0,

    pub fn init() Parser {}

    // Incremental parsing
    pub fn parse(self: *Parser, input: []const u8, pos: usize, eof: bool) ParseResult {
        const old_pos = self.cur_pos;

        // Update the parser state with the new input data
        self.cur_data = input;
        self.cur_pos = pos;
        self.cur_len = input.len;
        self.cur_eof = eof;

        const pos_shift: isize = @as(isize, @intCast(pos)) - @as(isize, @intCast(old_pos));
        if (self.cur_sect_range) |*sect_range| {
            // If we are currently parsing a section, update the section range
            sect_range.offset(pos_shift);
        }
        if (self.cur_fn_range) |*fn_range| {
            // If we are currently parsing a function, update the function range
            fn_range.offset(pos_shift);
        }

        // Implement the incremental parsing logic here
        // For example, check if there is enough data to parse a complete payload
        // If not, return .need_more_data with the number of bytes needed
        // If a complete payload is parsed, return .parsed with the consumed bytes and the payload
        // If the end of the file is reached and all data is parsed, return .end
        // If there is a parsing error, return .err with an appropriate error message

        switch (self.cur_state) {
            .INITIAL => {
                if (!self.has_bytes(8)) {
                    // Need at least 8 bytes to parse the magic number and version
                    return ParseResult{ .need_more_data = 8 - self.cur_len };
                }
            },
        }

        return ParseResult{ .need_more_data = 0 }; // Placeholder return value
    }

    // Full parsing, it will call parse() internally
    pub fn parseAll() void {}

    // Helper function to check if there are enough bytes left in the input data for parsing
    pub fn has_bytes(self: *Parser, len: usize) bool {
        return self.cur_len >= len;
    }
};

const Payload = struct {
    // Define the structure of the parsed payload here
};

const ParserError = error{
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
    }
}

const ParseResult = union(enum) {
    // Need more data to continue parsing
    need_more_data: usize,
    // Successfully parsed a payload
    // And return the number of bytes consumed from the input is `consumed`.
    parsed: struct {
        consumed: usize,
        payload: Payload,
    },
    // Full wasm module is parsed
    end,
    // Parsing error, with error message
    err: ParserError,
};

const ParseState = union(enum) {
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
