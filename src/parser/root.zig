const std = @import("std");
const builtin = @import("builtin");
const DataRange = @import("range.zig").DataRange;
const payload_mod = @import("payload");
const Payload = payload_mod.Payload;
const Type = payload_mod.Type;
const TypeEntry = payload_mod.TypeEntry;
const RefType = payload_mod.RefType;
const HeapType = payload_mod.HeapType;
const TypeKind = payload_mod.TypeKind;
const ExternalKind = payload_mod.ExternalKind;
const ResizableLimits = payload_mod.ResizableLimits;
const TableType = payload_mod.TableType;
const MemoryType = payload_mod.MemoryType;
const GlobalType = payload_mod.GlobalType;
const GlobalVariable = payload_mod.GlobalVariable;
const TagType = payload_mod.TagType;
const TagAttribute = payload_mod.TagAttribute;
const NameType = payload_mod.NameType;
const Naming = payload_mod.Naming;
const LocalName = payload_mod.LocalName;
const FieldName = payload_mod.FieldName;
const RelocType = payload_mod.RelocType;
const OperatorCode = payload_mod.OperatorCode;
const OperatorInformation = payload_mod.OperatorInformation;
const MemoryAddress = payload_mod.MemoryAddress;
const CatchHandler = payload_mod.CatchHandler;
const CatchHandlerKind = payload_mod.CatchHandlerKind;
const ImportEntry = payload_mod.ImportEntry;
const ImportEntryType = payload_mod.ImportEntryType;
const ExportEntry = payload_mod.ExportEntry;
const ElementMode = payload_mod.ElementMode;
const ElementSegment = payload_mod.ElementSegment;
const ElementSegmentBody = payload_mod.ElementSegmentBody;
const DataMode = payload_mod.DataMode;
const DataSegment = payload_mod.DataSegment;
const DataSegmentBody = payload_mod.DataSegmentBody;
const Locals = payload_mod.Locals;
const FunctionInformation = payload_mod.FunctionInformation;
const SectionCode = payload_mod.SectionCode;
const SectionInformation = payload_mod.SectionInformation;
const LinkingType = payload_mod.LinkingType;
const LinkingEntry = payload_mod.LinkingEntry;

const WASM_MAGIC_NUMBER = 0x6d736100;
const WASM_SUPPORTED_VERSION = [_]u32{ 0x1, 0x2, 0x0d };

const ElementSegmentType = enum(u8) {
    legacy_active_funcref_externval = 0x00,
    passive_externval = 0x01,
    active_externval = 0x02,
    declared_externval = 0x03,
    legacy_active_funcref_elemexpr = 0x04,
    passive_elemexpr = 0x05,
    active_elemexpr = 0x06,
    declared_elemexpr = 0x07,
};

const CodeUnitKind = enum {
    function_body,
    expression,
};

pub const CodeReadError = error{
    NeedMoreData,
    UnknownOperator,
    UnsupportedState,
    AtomicFenceConsistencyModelMustBeZero,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
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
    cur_sect_id: SectionCode = .unknown,
    cur_sect_entries_left: u32 = 0,
    cur_rec_group_types_left: i32 = -1,
    cur_data_segment_active: bool = false,
    cur_element_segment_type: ?ElementSegmentType = null,
    cur_fn_range: ?DataRange = null,

    last_err_arg: u32 = 0,
    last_err_state: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return Parser{
            .allocator = allocator,
        };
    }

    // Incremental parsing: one observable parser event per call.
    pub fn parse(self: *Parser, input: []const u8, eof: bool) ParseResult {
        const old_pos = self.cur_pos;
        const shift = -@as(isize, @intCast(old_pos));
        if (old_pos != 0) {
            if (self.cur_sect_range) |*sect_range| {
                sect_range.offset(shift);
            }
            if (self.cur_fn_range) |*fn_range| {
                fn_range.offset(shift);
            }
        }

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
                .TYPE_SECTION_ENTRY => {
                    if (self.cur_sect_entries_left == 0 and self.cur_rec_group_types_left < 0) {
                        self.finish_current_section();
                        continue;
                    }
                    if (self.cur_rec_group_types_left == 0) {
                        // Rec group boundaries are internal-only; once all nested
                        // types are emitted, immediately advance to the next type-section item.
                        self.cur_sect_entries_left -= 1;
                        self.cur_rec_group_types_left = -1;
                        continue;
                    }
                    if (self.cur_rec_group_types_left > 0) {
                        return self.read_rec_group_entry();
                    }
                    return self.read_type_entry();
                },
                .IMPORT_SECTION_ENTRY => return self.read_import_entry(),
                .FUNCTION_SECTION_ENTRY => return self.read_function_entry(),
                .TABLE_SECTION_ENTRY => return self.read_table_entry(),
                .MEMORY_SECTION_ENTRY => return self.read_memory_entry(),
                .GLOBAL_SECTION_ENTRY => return self.read_global_entry(),
                .EXPORT_SECTION_ENTRY => return self.read_export_entry(),
                .DATA_SECTION_ENTRY,
                .END_DATA_SECTION_ENTRY,
                => return self.read_data_entry(),
                .BEGIN_DATA_SECTION_ENTRY => return self.read_data_entry_body(),
                .DATA_SECTION_ENTRY_BODY => {
                    self.cur_state = .END_DATA_SECTION_ENTRY;
                    continue;
                },
                .ELEMENT_SECTION_ENTRY,
                .END_ELEMENT_SECTION_ENTRY,
                => return self.read_element_entry(),
                .BEGIN_ELEMENT_SECTION_ENTRY => return self.read_element_entry_body(),
                .LINKING_SECTION_ENTRY => return self.read_linking_entry(),
                .TAG_SECTION_ENTRY => return self.read_tag_entry(),
                .READING_FUNCTION_HEADER, .END_FUNCTION_BODY => return self.read_function_body(),
                .DATA_COUNT_SECTION_ENTRY => return self.read_data_count_entry(),
                .NAME_SECTION_ENTRY => return self.read_name_entry(),
                .RELOC_SECTION_ENTRY => return self.read_reloc_entry(),
                .RELOC_SECTION_HEADER => return self.read_reloc_header(),

                else => return self.fail_with_state(ParserError.UnsupportedState),
            }
        }
    }

    // Parse a complete module from a contiguous input buffer and collect
    // every observable payload event in order.
    pub fn parseAll(self: *Parser, input: []const u8) ParseAllError![]Payload {
        var payloads: std.ArrayList(Payload) = .empty;
        errdefer payloads.deinit(self.allocator);

        var remaining = input;
        while (true) {
            switch (self.parse(remaining, true)) {
                .parsed => |parsed| {
                    if (parsed.consumed == 0) {
                        return error.UnexpectedNeedMoreData;
                    }
                    try payloads.append(self.allocator, parsed.payload);
                    remaining = remaining[parsed.consumed..];
                },
                .need_more_data => return error.UnexpectedNeedMoreData,
                .end => return try payloads.toOwnedSlice(self.allocator),
                .err => |err| return err,
            }
        }
    }

    // Helper function to check if there are enough bytes left in the input data for parsing.
    fn has_bytes(self: *Parser, len: usize) bool {
        return self.cur_pos + len <= self.cur_len;
    }

    fn has_more_bytes(self: *Parser) bool {
        return self.cur_pos < self.cur_len;
    }

    fn has_section_payload(self: *Parser) bool {
        const sect_range = self.cur_sect_range orelse return false;
        return self.has_bytes(sect_range.end - self.cur_pos);
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
            self.cur_sect_range = null;
            self.cur_sect_id = .unknown;
            self.cur_state = .END_WASM;
            return .end;
        }

        // Check if there are enough bytes to read the section header (at least 1 byte for section ID and 1 byte for section size)
        if (!self.has_var_int_bytes()) {
            return .need_more_data;
        }

        const sect_id_raw = self.read_var_uint7();

        if (!self.has_var_int_bytes()) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }

        const payload_len = self.read_var_uint32();
        const payload_end_pos = self.cur_pos + payload_len;
        self.cur_sect_id = parse_section_code(sect_id_raw) orelse {
            self.last_err_arg = sect_id_raw;
            return self.fail_with_state(ParserError.UnsupportedSection);
        };
        self.cur_sect_range = .{ .start = self.cur_pos, .end = payload_end_pos };
        self.cur_sect_entries_left = 0;
        self.cur_rec_group_types_left = -1;

        var custom_section_name: ?[]const u8 = null;
        if (self.cur_sect_id == .custom) {
            if (!self.has_str_bytes()) {
                return self.rollback_section_parse(start_pos);
            }
            custom_section_name = self.read_str_bytes();
        }

        return switch (self.cur_sect_id) {
            .type => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_rec_group_types_left = -1;
                self.cur_state = .TYPE_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .import => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .IMPORT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .@"export" => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .EXPORT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .function => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .FUNCTION_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .table => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .TABLE_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .memory => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .MEMORY_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .global => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .GLOBAL_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .start => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                const index = self.read_var_uint32();
                self.cur_state = .END_SECTION;
                self.cur_sect_range = null;
                self.cur_sect_id = .unknown;
                return .{ .parsed = .{
                    .consumed = self.cur_pos - start_pos,
                    .payload = .{ .start_entry = .{ .index = index } },
                } };
            },
            .code => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .READING_FUNCTION_HEADER;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .element => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .ELEMENT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .data => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .DATA_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .data_count => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = 1;
                self.cur_state = .DATA_COUNT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .tag => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_sect_entries_left = self.read_var_uint32();
                self.cur_state = .TAG_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .custom => {
                const name = custom_section_name orelse return self.rollback_section_parse(start_pos);
                if (std.mem.eql(u8, name, "name")) {
                    self.cur_state = .NAME_SECTION_ENTRY;
                    return self.finish_section_dispatch(start_pos, custom_section_name);
                }
                if (std.mem.startsWith(u8, name, "reloc.")) {
                    self.cur_state = .RELOC_SECTION_HEADER;
                    return self.finish_section_dispatch(start_pos, custom_section_name);
                }
                if (std.mem.eql(u8, name, "linking")) {
                    if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                    self.cur_sect_entries_left = self.read_var_uint32();
                    self.cur_state = .LINKING_SECTION_ENTRY;
                    return self.finish_section_dispatch(start_pos, custom_section_name);
                }
                if (std.mem.eql(u8, name, "sourceMappingURL")) {
                    if (!self.has_str_bytes()) return self.rollback_section_parse(start_pos);
                    const url = self.read_str_bytes();
                    self.cur_state = .END_SECTION;
                    self.cur_sect_range = null;
                    self.cur_sect_id = .unknown;
                    return .{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = .{ .source_mapping_url = .{ .url = url } },
                    } };
                }
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                const body = self.read_bytes(payload_end_pos - self.cur_pos);
                self.cur_state = .END_SECTION;
                self.cur_sect_range = null;
                self.cur_sect_id = .unknown;
                return .{ .parsed = .{
                    .consumed = self.cur_pos - start_pos,
                    .payload = .{ .bytes = body },
                } };
            },
            else => {
                self.last_err_arg = @bitCast(@as(i32, @intFromEnum(self.cur_sect_id)));
                return self.fail_with_state(ParserError.UnsupportedSection);
            },
        };
    }

    fn read_memory_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_memory_type()) {
            return .need_more_data;
        }
        self.cur_state = .MEMORY_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        const memory_type = self.read_memory_type();
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .memory_type = memory_type },
        } };
    }

    fn read_table_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_table_type()) {
            return .need_more_data;
        }
        self.cur_state = .TABLE_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        const table_type = self.read_table_type();
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .table_type = table_type },
        } };
    }

    fn read_function_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        if (!self.has_var_int_bytes()) {
            return .need_more_data;
        }
        const typeIdx = self.read_var_uint32();
        self.cur_state = .FUNCTION_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .function_entry = .{ .type_index = typeIdx } },
        } };
    }

    fn read_global_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_global_entry()) {
            return .need_more_data;
        }

        const typ = self.read_global_type();
        const init_expr_start = self.cur_pos;
        self.readCodeOperator(.expression) catch |err| switch (err) {
            error.NeedMoreData => return .need_more_data,
            error.UnknownOperator => return self.fail_with_state(ParserError.UnknownOperator),
            error.AtomicFenceConsistencyModelMustBeZero => {
                return self.fail_with_state(ParserError.AtomicFenceConsistencyModelMustBeZero);
            },
            error.UnsupportedState => return self.fail_with_state(ParserError.UnsupportedState),
        };
        const init_expr = self.cur_data[init_expr_start..self.cur_pos];
        self.cur_state = .GLOBAL_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .global_variable = GlobalVariable{
                .typ = typ,
                .init_expr = init_expr,
            } },
        } };
    }

    fn read_import_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_import_entry()) {
            return .need_more_data;
        }

        const module = self.read_str_bytes();
        const field = self.read_str_bytes();
        const kind_raw = self.read_u8();
        const kind = std.meta.intToEnum(ExternalKind, kind_raw) catch {
            std.debug.panic("Unknown external kind: {}", .{kind_raw});
        };

        var func_type_index: ?u32 = null;
        var typ: ?ImportEntryType = null;
        switch (kind) {
            .function => func_type_index = self.read_var_uint32(),
            .table => typ = .{ .table = self.read_table_type() },
            .memory => typ = .{ .memory = self.read_memory_type() },
            .global => typ = .{ .global = self.read_global_type() },
            .tag => typ = .{ .tag = self.read_tag_type() },
        }

        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .import_entry = ImportEntry{
                .module = module,
                .field = field,
                .kind = kind,
                .func_type_index = func_type_index,
                .typ = typ,
            } },
        } };
    }

    fn read_export_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_export_entry()) {
            return .need_more_data;
        }

        const field = self.read_str_bytes();
        const kind_raw = self.read_u8();
        const kind = std.meta.intToEnum(ExternalKind, kind_raw) catch {
            std.debug.panic("Unknown external kind: {}", .{kind_raw});
        };
        const index = self.read_var_uint32();

        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .export_entry = ExportEntry{
                .field = field,
                .kind = kind,
                .index = index,
            } },
        } };
    }

    fn read_tag_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_tag_type()) {
            return .need_more_data;
        }

        const tag_type = self.read_tag_type();
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .tag_type = tag_type },
        } };
    }

    fn read_function_body(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_function_body()) {
            return .need_more_data;
        }

        const body_size = self.read_var_uint32();
        const body_end = self.cur_pos + body_size;
        const local_count = self.read_var_uint32();
        const locals = self.allocator.alloc(Locals, @intCast(local_count)) catch {
            @panic("OOM");
        };
        for (locals) |*local| {
            local.* = .{
                .count = self.read_var_uint32(),
                .typ = self.readTypeInternal(),
            };
        }

        const body_start = self.cur_pos;
        self.cur_fn_range = .{ .start = self.cur_pos, .end = body_end };
        self.readCodeOperator(.function_body) catch |err| switch (err) {
            error.NeedMoreData => return .need_more_data,
            error.UnknownOperator => return self.fail_with_state(ParserError.UnknownOperator),
            error.AtomicFenceConsistencyModelMustBeZero => {
                return self.fail_with_state(ParserError.AtomicFenceConsistencyModelMustBeZero);
            },
            error.UnsupportedState => return self.fail_with_state(ParserError.UnsupportedState),
        };
        self.cur_fn_range = null;
        self.cur_state = .END_FUNCTION_BODY;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .function_info = FunctionInformation{
                .locals = locals,
                .body = self.cur_data[body_start..self.cur_pos],
            } },
        } };
    }

    fn read_data_count_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        if (!self.has_var_int_bytes()) {
            return .need_more_data;
        }

        const count = self.read_var_uint32();
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .number = count },
        } };
    }

    fn read_name_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        const sect_range = self.cur_sect_range orelse {
            return self.fail_with_state(ParserError.UnsupportedState);
        };

        while (true) {
            if (self.cur_pos >= sect_range.end) {
                return self.finish_name_section(start_pos);
            }

            var probe = self.*;
            if (!probe.skip_name_entry()) {
                return .need_more_data;
            }

            const typ_raw = self.read_var_uint7();
            const payload_len = self.read_var_uint32();
            const payload_end = self.cur_pos + payload_len;
            const typ = std.meta.intToEnum(NameType, typ_raw) catch {
                self.cur_pos = payload_end;
                continue;
            };

            switch (typ) {
                .module => {
                    const module_name = self.read_str_bytes();
                    self.cur_pos = payload_end;
                    return .{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = .{ .module_name_entry = .{
                            .typ = typ,
                            .module_name = module_name,
                        } },
                    } };
                },
                .function, .tag, .type, .table, .memory, .global => {
                    const names = self.read_name_map() catch @panic("OOM");
                    self.cur_pos = payload_end;
                    return .{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = switch (typ) {
                            .function => .{ .function_name_entry = .{ .typ = typ, .names = names } },
                            .tag => .{ .tag_name_entry = .{ .typ = typ, .names = names } },
                            .type => .{ .type_name_entry = .{ .typ = typ, .names = names } },
                            .table => .{ .table_name_entry = .{ .typ = typ, .names = names } },
                            .memory => .{ .memory_name_entry = .{ .typ = typ, .names = names } },
                            .global => .{ .global_name_entry = .{ .typ = typ, .names = names } },
                            else => unreachable,
                        },
                    } };
                },
                .local => {
                    const funcs_len = self.read_var_uint32();
                    const funcs = self.allocator.alloc(LocalName, @intCast(funcs_len)) catch @panic("OOM");
                    for (funcs) |*func| {
                        func.* = .{
                            .index = self.read_var_uint32(),
                            .locals = self.read_name_map() catch @panic("OOM"),
                        };
                    }
                    self.cur_pos = payload_end;
                    return .{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = .{ .local_name_entry = .{
                            .typ = typ,
                            .funcs = funcs,
                        } },
                    } };
                },
                .field => {
                    const types_len = self.read_var_uint32();
                    const types = self.allocator.alloc(FieldName, @intCast(types_len)) catch @panic("OOM");
                    for (types) |*field_name| {
                        field_name.* = .{
                            .index = self.read_var_uint32(),
                            .fields = self.read_name_map() catch @panic("OOM"),
                        };
                    }
                    self.cur_pos = payload_end;
                    return .{ .parsed = .{
                        .consumed = self.cur_pos - start_pos,
                        .payload = .{ .field_name_entry = .{
                            .typ = typ,
                            .types = types,
                        } },
                    } };
                },
                else => {
                    self.cur_pos = payload_end;
                    continue;
                },
            }
        }
    }

    fn finish_name_section(self: *Parser, start_pos: usize) ParseResult {
        const skipped = self.cur_pos - start_pos;
        self.finish_current_section();

        return switch (self.read_sect()) {
            .parsed => |parsed| .{ .parsed = .{
                .consumed = skipped + parsed.consumed,
                .payload = parsed.payload,
            } },
            .need_more_data => .need_more_data,
            .end => .end,
            .err => |err| .{ .err = err },
        };
    }

    fn read_reloc_header(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        var probe = self.*;
        if (!probe.skip_reloc_header()) {
            return .need_more_data;
        }

        const id_raw = self.read_var_uint7();
        const id = parse_section_code(id_raw) orelse {
            self.last_err_arg = id_raw;
            return self.fail_with_state(ParserError.UnsupportedSection);
        };
        const name = if (id == .custom) self.read_str_bytes() else &.{};
        self.cur_sect_entries_left = self.read_var_uint32();
        self.cur_state = .RELOC_SECTION_ENTRY;

        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .reloc_header = .{
                .id = id,
                .name = name,
            } },
        } };
    }

    fn read_reloc_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }

        var probe = self.*;
        if (!probe.skip_reloc_entry()) {
            return .need_more_data;
        }

        const typ_raw = self.read_var_uint7();
        const typ = std.meta.intToEnum(RelocType, typ_raw) catch {
            self.last_err_arg = typ_raw;
            return self.fail_with_state(ParserError.BadRelocationType);
        };
        const offset = self.read_var_uint32();
        const index = self.read_var_uint32();
        const addend = switch (typ) {
            .function_index_leb,
            .table_index_sleb,
            .table_index_i32,
            .type_index_leb,
            .global_index_leb,
            => null,
            .global_addr_leb,
            .global_addr_sleb,
            .global_addr_i32,
            => self.read_var_uint32(),
        };

        self.cur_state = .RELOC_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .reloc_entry = .{
                .typ = typ,
                .offset = offset,
                .index = index,
                .addend = addend,
            } },
        } };
    }

    fn read_data_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_data_entry()) {
            return .need_more_data;
        }

        const segment_type = self.read_var_uint32();
        var mode: DataMode = undefined;
        var memory_index: ?u32 = null;
        switch (segment_type) {
            0 => {
                mode = .active;
                memory_index = 0;
                self.cur_data_segment_active = true;
            },
            1 => {
                mode = .passive;
                self.cur_data_segment_active = false;
            },
            2 => {
                mode = .active;
                memory_index = self.read_var_uint32();
                self.cur_data_segment_active = true;
            },
            else => {
                self.last_err_arg = segment_type;
                return self.fail_with_state(ParserError.UnsupportedDataSegmentType);
            },
        }

        self.cur_state = .BEGIN_DATA_SECTION_ENTRY;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .data_segment = DataSegment{
                .mode = mode,
                .memory_index = memory_index,
            } },
        } };
    }

    fn read_data_entry_body(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        var offset_expr: []const u8 = &.{};
        if (self.cur_data_segment_active) {
            const offset_expr_start = self.cur_pos;
            self.readCodeOperator(.expression) catch |err| switch (err) {
                error.NeedMoreData => return .need_more_data,
                error.UnknownOperator => return self.fail_with_state(ParserError.UnknownOperator),
                error.AtomicFenceConsistencyModelMustBeZero => {
                    return self.fail_with_state(ParserError.AtomicFenceConsistencyModelMustBeZero);
                },
                error.UnsupportedState => return self.fail_with_state(ParserError.UnsupportedState),
            };
            offset_expr = self.cur_data[offset_expr_start..self.cur_pos];
        }
        if (!self.has_str_bytes()) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }

        const data = self.read_str_bytes();
        self.cur_state = .END_DATA_SECTION_ENTRY;
        self.cur_data_segment_active = false;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .data_segment_body = DataSegmentBody{ .data = data, .offset_expr = offset_expr } },
        } };
    }

    fn read_element_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_element_entry()) {
            return .need_more_data;
        }

        const segment_type_raw = self.read_u8();
        const segment_type = std.meta.intToEnum(ElementSegmentType, segment_type_raw) catch {
            self.last_err_arg = segment_type_raw;
            return self.fail_with_state(ParserError.UnsupportedElementSegmentType);
        };

        var mode: ElementMode = undefined;
        var table_index: ?u32 = null;
        switch (segment_type) {
            .legacy_active_funcref_externval, .legacy_active_funcref_elemexpr => {
                mode = .active;
                table_index = 0;
            },
            .passive_externval, .passive_elemexpr => {
                mode = .passive;
            },
            .active_externval, .active_elemexpr => {
                mode = .active;
                table_index = self.read_var_uint32();
            },
            .declared_externval, .declared_elemexpr => {
                mode = .declarative;
            },
        }

        self.cur_state = .BEGIN_ELEMENT_SECTION_ENTRY;
        self.cur_element_segment_type = segment_type;
        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .element_segment = ElementSegment{
                .mode = mode,
                .table_index = table_index,
            } },
        } };
    }

    fn read_element_entry_body(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        const segment_type = self.cur_element_segment_type orelse {
            return self.fail_with_state(ParserError.UnsupportedState);
        };
        var probe = self.*;
        if (!probe.skip_element_entry_body(segment_type)) {
            return .need_more_data;
        }

        var offset_expr: []const u8 = &.{};
        if (is_active_element_segment_type(segment_type)) {
            const offset_expr_start = self.cur_pos;
            self.readCodeOperator(.expression) catch |err| switch (err) {
                error.NeedMoreData => return .need_more_data,
                error.UnknownOperator => return self.fail_with_state(ParserError.UnknownOperator),
                error.AtomicFenceConsistencyModelMustBeZero => {
                    return self.fail_with_state(ParserError.AtomicFenceConsistencyModelMustBeZero);
                },
                error.UnsupportedState => return self.fail_with_state(ParserError.UnsupportedState),
            };
            offset_expr = self.cur_data[offset_expr_start..self.cur_pos];
        }

        var element_type: Type = .{ .kind = .funcref };
        switch (segment_type) {
            .passive_externval, .active_externval, .declared_externval => {
                _ = self.read_u8();
            },
            .passive_elemexpr, .active_elemexpr, .declared_elemexpr => {
                element_type = self.readTypeInternal();
            },
            .legacy_active_funcref_externval, .legacy_active_funcref_elemexpr => {},
        }

        const item_count = self.read_var_uint32();
        var func_indices: []const u32 = &.{};
        if (is_externval_element_segment_type(segment_type)) {
            const indices = self.allocator.alloc(u32, @intCast(item_count)) catch @panic("OOM");
            for (indices) |*idx| {
                idx.* = self.read_var_uint32();
            }
            func_indices = indices;
        } else {
            for (0..item_count) |_| {
                self.readCodeOperator(.expression) catch |err| switch (err) {
                    error.NeedMoreData => return .need_more_data,
                    error.UnknownOperator => return self.fail_with_state(ParserError.UnknownOperator),
                    error.AtomicFenceConsistencyModelMustBeZero => {
                        return self.fail_with_state(ParserError.AtomicFenceConsistencyModelMustBeZero);
                    },
                    error.UnsupportedState => return self.fail_with_state(ParserError.UnsupportedState),
                };
            }
        }

        self.cur_state = .END_ELEMENT_SECTION_ENTRY;
        self.cur_element_segment_type = null;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .element_segment_body = ElementSegmentBody{
                .element_type = element_type,
                .func_indices = func_indices,
                .offset_expr = offset_expr,
            } },
        } };
    }

    fn read_linking_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        if (self.cur_sect_entries_left == 0) {
            self.finish_current_section();
            return self.read_sect();
        }
        var probe = self.*;
        if (!probe.skip_linking_entry()) {
            return .need_more_data;
        }

        const typ_raw = self.read_var_uint32();
        const typ = std.meta.intToEnum(LinkingType, typ_raw) catch {
            self.last_err_arg = typ_raw;
            return self.fail_with_state(ParserError.BadLinkingType);
        };

        var index: ?u32 = null;
        switch (typ) {
            .stack_pointer => index = self.read_var_uint32(),
        }

        self.cur_sect_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .linking_entry = LinkingEntry{
                .typ = typ,
                .index = index,
            } },
        } };
    }

    fn read_rec_group_entry(self: *Parser) ParseResult {
        return self.read_rec_group_entry_from(self.cur_pos);
    }

    fn read_rec_group_entry_from(self: *Parser, start_pos: usize) ParseResult {
        if (!self.has_bytes(1)) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }
        const type_kind = self.read_var_int7();
        var probe = self.*;
        if (!probe.skip_type_entry_common(type_kind)) {
            self.cur_pos = start_pos;
            return .need_more_data;
        }
        const type_entry = self.read_type_entry_common(type_kind) catch {
            return self.fail_with_state(ParserError.UnknownTypeKind);
        };
        self.cur_rec_group_types_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .type_entry = type_entry },
        } };
    }

    fn read_type_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        while (true) {
            if (!self.has_bytes(1)) {
                self.cur_pos = start_pos;
                return .need_more_data;
            }

            const type_kind = self.read_var_int7();
            if (type_kind == @intFromEnum(TypeKind.rec_group)) {
                if (!self.has_var_int_bytes()) {
                    self.cur_pos = start_pos;
                    return .need_more_data;
                }

                self.cur_rec_group_types_left = @intCast(self.read_var_uint32());
                if (self.cur_rec_group_types_left == 0) {
                    self.cur_sect_entries_left -= 1;
                    self.cur_rec_group_types_left = -1;
                    continue;
                }
                return self.read_rec_group_entry_from(start_pos);
            }

            var probe = self.*;
            if (!probe.skip_type_entry_common(type_kind)) {
                self.cur_pos = start_pos;
                return .need_more_data;
            }

            const type_entry = self.read_type_entry_common(type_kind) catch {
                return self.fail_with_state(ParserError.UnknownTypeKind);
            };
            self.cur_sect_entries_left -= 1;
            return .{ .parsed = .{
                .consumed = self.cur_pos - start_pos,
                .payload = .{ .type_entry = type_entry },
            } };
        }
    }

    fn read_type_entry_common(self: *Parser, type_kind: i7) !TypeEntry {
        return switch (type_kind) {
            @intFromEnum(TypeKind.func) => try self.read_func_type(),
            @intFromEnum(TypeKind.subtype) => try self.read_sub_type(false),
            @intFromEnum(TypeKind.subtype_final) => try self.read_sub_type(true),
            @intFromEnum(TypeKind.struct_type) => try self.read_struct_type(),
            @intFromEnum(TypeKind.array_type) => try self.read_array_type(),
            @intFromEnum(TypeKind.i32),
            @intFromEnum(TypeKind.i64),
            @intFromEnum(TypeKind.f32),
            @intFromEnum(TypeKind.f64),
            @intFromEnum(TypeKind.v128),
            @intFromEnum(TypeKind.i8),
            @intFromEnum(TypeKind.i16),
            @intFromEnum(TypeKind.funcref),
            @intFromEnum(TypeKind.externref),
            @intFromEnum(TypeKind.exnref),
            @intFromEnum(TypeKind.anyref),
            @intFromEnum(TypeKind.eqref),
            => .{ .type = parse_type_kind(type_kind) },
            else => error.UnknownTypeKind,
        };
    }

    fn read_struct_type(self: *Parser) !TypeEntry {
        const field_count = self.read_var_uint32();
        const field_types = try self.allocator.alloc(Type, @intCast(field_count));
        const field_mutabilities = try self.allocator.alloc(bool, @intCast(field_count));
        for (field_types, field_mutabilities) |*field_type, *field_mutability| {
            field_type.* = self.readTypeInternal();
            field_mutability.* = self.read_var_uint1() != 0;
        }
        return .{
            .type = .struct_type,
            .fields = field_types,
            .mutabilities = field_mutabilities,
        };
    }

    fn read_array_type(self: *Parser) !TypeEntry {
        const element_type = self.readTypeInternal();
        const mutability = self.read_var_uint1() != 0;
        return .{
            .type = .array_type,
            .element_type = element_type,
            .mutability = mutability,
        };
    }

    fn read_base_type(self: *Parser) !TypeEntry {
        const type_kind = self.read_var_int7();
        return switch (type_kind) {
            @intFromEnum(TypeKind.func) => try self.read_func_type(),
            @intFromEnum(TypeKind.struct_type) => try self.read_struct_type(),
            @intFromEnum(TypeKind.array_type) => try self.read_array_type(),
            else => error.UnexpectedTypeKind,
        };
    }

    fn read_sub_type(self: *Parser, is_final: bool) !TypeEntry {
        const super_count = self.read_var_uint32();
        const super_types = try self.allocator.alloc(HeapType, @intCast(super_count));
        for (super_types) |*super_type| {
            super_type.* = self.readHeapTypeInternal();
        }
        var result = try self.read_base_type();
        result.final = is_final;
        result.super_types = super_types;
        return result;
    }

    fn read_func_type(self: *Parser) !TypeEntry {
        const param_count = self.read_var_uint32();
        const param_types = try self.allocator.alloc(Type, @intCast(param_count));
        for (param_types) |*param_type| {
            param_type.* = self.readTypeInternal();
        }
        const return_count = self.read_var_uint32();
        const return_types = try self.allocator.alloc(Type, @intCast(return_count));
        for (return_types) |*return_type| {
            return_type.* = self.readTypeInternal();
        }
        return .{
            .type = .func,
            .params = param_types,
            .returns = return_types,
        };
    }

    // Heap is used to represent reference types and type indices in WebAssembly
    fn readHeapTypeInternal(self: *Parser) HeapType {
        const lsb = self.read_u8();

        const raw: i64 = if ((lsb & 0x80) != 0) blk: {
            const tail = self.read_var_int32();
            break :blk (@as(i64, tail) - 1) * 128 + @as(i64, lsb);
        } else blk: {
            const low7 = lsb & 0x7f;
            if ((low7 & 0x40) != 0) {
                break :blk @as(i64, @as(i16, @intCast(low7)) - 128);
            }
            break :blk @as(i64, low7);
        };

        if (raw >= 0) {
            return .{ .index = @intCast(raw) };
        }

        return .{
            .kind = parse_type_kind(raw),
        };
    }

    // Read Wasm type, create Type or RefType
    fn readTypeInternal(self: *Parser) Type {
        return switch (self.readHeapTypeInternal()) {
            .index => |index| .{ .index = index },
            .kind => |kind| switch (kind) {
                .ref_null, .ref_ => .{ .ref_type = .{
                    .nullable = kind == .ref_null,
                    .ref_index = self.readHeapTypeInternal(),
                } },
                .i32,
                .i64,
                .f32,
                .f64,
                .v128,
                .i8,
                .i16,
                .funcref,
                .externref,
                .exnref,
                .anyref,
                .eqref,
                .i31ref,
                .null_externref,
                .null_funcref,
                .null_exnref,
                .structref,
                .arrayref,
                .null_ref,
                .func,
                .struct_type,
                .array_type,
                .subtype,
                .rec_group,
                .subtype_final,
                .empty_block_type,
                => .{ .kind = kind },
                else => std.debug.panic("Unknown type kind: {}", .{kind}),
            },
        };
    }

    fn read_resizable_limits(self: *Parser, max_present: bool) ResizableLimits {
        const initial = self.read_var_uint32();
        const maximum = if (max_present) self.read_var_uint32() else null;
        return .{
            .initial = initial,
            .maximum = maximum,
        };
    }

    fn read_table_type(self: *Parser) TableType {
        const element_type = self.readTypeInternal();
        const flags = self.read_var_uint32();
        return .{
            .element_type = element_type,
            .limits = self.read_resizable_limits((flags & 0x01) != 0),
        };
    }

    fn read_memory_type(self: *Parser) MemoryType {
        const flags = self.read_var_uint32();
        return .{
            .limits = self.read_resizable_limits((flags & 0x01) != 0),
            .shared = (flags & 0x02) != 0,
        };
    }

    fn read_global_type(self: *Parser) GlobalType {
        return .{
            .content_type = self.readTypeInternal(),
            .mutability = self.read_var_uint1(),
        };
    }

    fn read_tag_type(self: *Parser) TagType {
        const attribute = self.read_var_uint32();
        return .{
            .attribute = std.meta.intToEnum(TagAttribute, @as(u8, @intCast(attribute))) catch {
                std.debug.panic("Unknown tag attribute: {}", .{attribute});
            },
            .type_index = self.read_var_uint32(),
        };
    }

    fn read_name_map(self: *Parser) ![]const Naming {
        const count = self.read_var_uint32();
        const names = try self.allocator.alloc(Naming, @intCast(count));
        for (names) |*name| {
            name.* = .{
                .index = self.read_var_uint32(),
                .name = self.read_str_bytes(),
            };
        }
        return names;
    }

    fn readCodeOperator(self: *Parser, unit: CodeUnitKind) CodeReadError!void {
        const start_pos = self.cur_pos;
        errdefer self.cur_pos = start_pos;

        switch (unit) {
            .function_body => {
                const fn_range = self.cur_fn_range orelse return error.UnsupportedState;
                if (!self.has_bytes(fn_range.end - self.cur_pos)) return error.NeedMoreData;
                while (self.cur_pos < fn_range.end) {
                    _ = try self.readSingleOperator();
                }
            },
            .expression => {
                while (true) {
                    const operator = try self.readSingleOperator();
                    if (operator.code == .end) break;
                }
            },
        }
    }

    fn read_memory_immediate(self: *Parser) CodeReadError!MemoryAddress {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const flags = self.read_var_uint32();
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const offset = self.read_var_uint32();
        return .{ .flags = flags, .offset = offset };
    }

    fn read_type_checked(self: *Parser) CodeReadError!Type {
        var probe = self.*;
        if (!probe.skip_type()) return error.NeedMoreData;
        return self.readTypeInternal();
    }

    fn read_heap_type_checked(self: *Parser) CodeReadError!HeapType {
        var probe = self.*;
        _ = probe.skip_heap_type() orelse return error.NeedMoreData;
        return self.readHeapTypeInternal();
    }

    fn read_br_table(self: *Parser) CodeReadError![]const u32 {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const table_count = self.read_var_uint32();
        const br_table = self.allocator.alloc(u32, @intCast(table_count + 1)) catch @panic("OOM");
        for (br_table) |*depth| {
            if (!self.has_var_int_bytes()) return error.NeedMoreData;
            depth.* = self.read_var_uint32();
        }
        return br_table;
    }

    fn read_try_table(self: *Parser) CodeReadError![]const CatchHandler {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const table_count = self.read_var_uint32();
        const handlers = self.allocator.alloc(CatchHandler, @intCast(table_count)) catch @panic("OOM");
        for (handlers) |*handler| {
            if (!self.has_var_int_bytes()) return error.NeedMoreData;
            const kind_raw = self.read_var_uint32();
            const kind = std.meta.intToEnum(CatchHandlerKind, kind_raw) catch {
                self.last_err_arg = kind_raw;
                return error.UnknownOperator;
            };
            var tag_index: ?u32 = null;
            switch (kind) {
                .catch_, .catch_ref => {
                    if (!self.has_var_int_bytes()) return error.NeedMoreData;
                    tag_index = self.read_var_uint32();
                },
                .catch_all, .catch_all_ref => {},
            }
            if (!self.has_var_int_bytes()) return error.NeedMoreData;
            handler.* = .{
                .kind = kind,
                .tag_index = tag_index,
                .depth = self.read_var_uint32(),
            };
        }
        return handlers;
    }

    fn read_code_operator_0xfb(self: *Parser) CodeReadError!OperatorInformation {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const subcode = self.read_var_uint32();
        const code_value = 0xfb00 | subcode;
        const code = std.meta.intToEnum(OperatorCode, code_value) catch {
            self.last_err_arg = code_value;
            return error.UnknownOperator;
        };

        var info = OperatorInformation{ .code = code };
        switch (code) {
            .br_on_cast, .br_on_cast_fail => {
                if (!self.has_bytes(1)) return error.NeedMoreData;
                info.literal = .{ .number = self.read_u8() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.br_depth = self.read_var_uint32();
                info.src_type = try self.read_heap_type_checked();
                info.ref_type = try self.read_heap_type_checked();
            },
            .array_get,
            .array_get_s,
            .array_get_u,
            .array_set,
            .array_new,
            .array_new_default,
            .struct_new,
            .struct_new_default,
            .array_fill,
            => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.ref_type = .{ .index = self.read_var_uint32() };
            },
            .array_new_fixed => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.ref_type = .{ .index = self.read_var_uint32() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.len = self.read_var_uint32();
            },
            .array_copy => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.ref_type = .{ .index = self.read_var_uint32() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.src_type = .{ .index = self.read_var_uint32() };
            },
            .struct_get, .struct_get_s, .struct_get_u, .struct_set => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.ref_type = .{ .index = self.read_var_uint32() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.field_index = self.read_var_uint32();
            },
            .array_new_data, .array_new_elem, .array_init_data, .array_init_elem => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.ref_type = .{ .index = self.read_var_uint32() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.segment_index = self.read_var_uint32();
            },
            .ref_test, .ref_test_null, .ref_cast, .ref_cast_null => {
                info.ref_type = try self.read_heap_type_checked();
            },
            .array_len,
            .extern_convert_any,
            .any_convert_extern,
            .ref_i31,
            .i31_get_s,
            .i31_get_u,
            => {},
            else => {
                self.last_err_arg = code_value;
                return error.UnknownOperator;
            },
        }
        return info;
    }

    fn read_code_operator_0xfc(self: *Parser) CodeReadError!OperatorInformation {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const subcode = self.read_var_uint32();
        const code_value = 0xfc00 | subcode;
        const code = std.meta.intToEnum(OperatorCode, code_value) catch {
            self.last_err_arg = code_value;
            return error.UnknownOperator;
        };

        var info = OperatorInformation{ .code = code };
        switch (code) {
            .i32_trunc_sat_f32_s,
            .i32_trunc_sat_f32_u,
            .i32_trunc_sat_f64_s,
            .i32_trunc_sat_f64_u,
            .i64_trunc_sat_f32_s,
            .i64_trunc_sat_f32_u,
            .i64_trunc_sat_f64_s,
            .i64_trunc_sat_f64_u,
            => {},
            .memory_copy => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
            },
            .memory_fill => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
            },
            .table_init => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.segment_index = self.read_var_uint32();
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.table_index = self.read_var_uint32();
            },
            .table_copy => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.table_index = self.read_var_uint32();
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.destination_index = self.read_var_uint32();
            },
            .table_grow, .table_size, .table_fill => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.table_index = self.read_var_uint32();
            },
            .memory_init => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.segment_index = self.read_var_uint32();
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
            },
            .data_drop, .elem_drop => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.segment_index = self.read_var_uint32();
            },
            else => {
                self.last_err_arg = code_value;
                return error.UnknownOperator;
            },
        }
        return info;
    }

    fn read_code_operator_0xfd(self: *Parser) CodeReadError!OperatorInformation {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const subcode = self.read_var_uint32();
        const code_value = 0xfd000 | subcode;
        const code = std.meta.intToEnum(OperatorCode, code_value) catch {
            self.last_err_arg = code_value;
            return error.UnknownOperator;
        };

        var info = OperatorInformation{ .code = code };
        switch (code) {
            .v128_load,
            .i16x8_load8x8_s,
            .i16x8_load8x8_u,
            .i32x4_load16x4_s,
            .i32x4_load16x4_u,
            .i64x2_load32x2_s,
            .i64x2_load32x2_u,
            .v8x16_load_splat,
            .v16x8_load_splat,
            .v32x4_load_splat,
            .v64x2_load_splat,
            .v128_store,
            .v128_load32_zero,
            .v128_load64_zero,
            => info.memory_address = try self.read_memory_immediate(),
            .v128_const => {
                if (!self.has_bytes(16)) return error.NeedMoreData;
                info.literal = .{ .bytes = self.read_bytes(16) };
            },
            .i8x16_shuffle => {
                if (!self.has_bytes(16)) return error.NeedMoreData;
                info.lines = self.read_bytes(16);
            },
            .i8x16_extract_lane_s,
            .i8x16_extract_lane_u,
            .i8x16_replace_lane,
            .i16x8_extract_lane_s,
            .i16x8_extract_lane_u,
            .i16x8_replace_lane,
            .i32x4_extract_lane,
            .i32x4_replace_lane,
            .i64x2_extract_lane,
            .i64x2_replace_lane,
            .f32x4_extract_lane,
            .f32x4_replace_lane,
            .f64x2_extract_lane,
            .f64x2_replace_lane,
            => {
                if (!self.has_bytes(1)) return error.NeedMoreData;
                info.line_index = self.read_u8();
            },
            .v128_load8_lane,
            .v128_load16_lane,
            .v128_load32_lane,
            .v128_load64_lane,
            .v128_store8_lane,
            .v128_store16_lane,
            .v128_store32_lane,
            .v128_store64_lane,
            => {
                info.memory_address = try self.read_memory_immediate();
                if (!self.has_bytes(1)) return error.NeedMoreData;
                info.line_index = self.read_u8();
            },
            .i8x16_swizzle,
            .i8x16_splat,
            .i16x8_splat,
            .i32x4_splat,
            .i64x2_splat,
            .f32x4_splat,
            .f64x2_splat,
            .i8x16_eq,
            .i8x16_ne,
            .i8x16_lt_s,
            .i8x16_lt_u,
            .i8x16_gt_s,
            .i8x16_gt_u,
            .i8x16_le_s,
            .i8x16_le_u,
            .i8x16_ge_s,
            .i8x16_ge_u,
            .i16x8_eq,
            .i16x8_ne,
            .i16x8_lt_s,
            .i16x8_lt_u,
            .i16x8_gt_s,
            .i16x8_gt_u,
            .i16x8_le_s,
            .i16x8_le_u,
            .i16x8_ge_s,
            .i16x8_ge_u,
            .i32x4_eq,
            .i32x4_ne,
            .i32x4_lt_s,
            .i32x4_lt_u,
            .i32x4_gt_s,
            .i32x4_gt_u,
            .i32x4_le_s,
            .i32x4_le_u,
            .i32x4_ge_s,
            .i32x4_ge_u,
            .f32x4_eq,
            .f32x4_ne,
            .f32x4_lt,
            .f32x4_gt,
            .f32x4_le,
            .f32x4_ge,
            .f64x2_eq,
            .f64x2_ne,
            .f64x2_lt,
            .f64x2_gt,
            .f64x2_le,
            .f64x2_ge,
            .v128_not,
            .v128_and,
            .v128_andnot,
            .v128_or,
            .v128_xor,
            .v128_bitselect,
            .v128_any_true,
            .f32x4_demote_f64x2_zero,
            .f64x2_promote_low_f32x4,
            .i8x16_abs,
            .i8x16_neg,
            .i8x16_popcnt,
            .i8x16_all_true,
            .i8x16_bitmask,
            .i8x16_narrow_i16x8_s,
            .i8x16_narrow_i16x8_u,
            .f32x4_ceil,
            .f32x4_floor,
            .f32x4_trunc,
            .f32x4_nearest,
            .i8x16_shl,
            .i8x16_shr_s,
            .i8x16_shr_u,
            .i8x16_add,
            .i8x16_add_sat_s,
            .i8x16_add_sat_u,
            .i8x16_sub,
            .i8x16_sub_sat_s,
            .i8x16_sub_sat_u,
            .f64x2_ceil,
            .f64x2_floor,
            .i8x16_min_s,
            .i8x16_min_u,
            .i8x16_max_s,
            .i8x16_max_u,
            .f64x2_trunc,
            .i8x16_avgr_u,
            .i16x8_extadd_pairwise_i8x16_s,
            .i16x8_extadd_pairwise_i8x16_u,
            .i32x4_extadd_pairwise_i16x8_s,
            .i32x4_extadd_pairwise_i16x8_u,
            .i16x8_abs,
            .i16x8_neg,
            .i16x8_q15mulr_sat_s,
            .i16x8_all_true,
            .i16x8_bitmask,
            .i16x8_narrow_i32x4_s,
            .i16x8_narrow_i32x4_u,
            .i16x8_extend_low_i8x16_s,
            .i16x8_extend_high_i8x16_s,
            .i16x8_extend_low_i8x16_u,
            .i16x8_extend_high_i8x16_u,
            .i16x8_shl,
            .i16x8_shr_s,
            .i16x8_shr_u,
            .i16x8_add,
            .i16x8_add_sat_s,
            .i16x8_add_sat_u,
            .i16x8_sub,
            .i16x8_sub_sat_s,
            .i16x8_sub_sat_u,
            .f64x2_nearest,
            .i16x8_mul,
            .i16x8_min_s,
            .i16x8_min_u,
            .i16x8_max_s,
            .i16x8_max_u,
            .i16x8_avgr_u,
            .i16x8_extmul_low_i8x16_s,
            .i16x8_extmul_high_i8x16_s,
            .i16x8_extmul_low_i8x16_u,
            .i16x8_extmul_high_i8x16_u,
            .i32x4_abs,
            .i32x4_neg,
            .i32x4_all_true,
            .i32x4_bitmask,
            .i32x4_extend_low_i16x8_s,
            .i32x4_extend_high_i16x8_s,
            .i32x4_extend_low_i16x8_u,
            .i32x4_extend_high_i16x8_u,
            .i32x4_shl,
            .i32x4_shr_s,
            .i32x4_shr_u,
            .i32x4_add,
            .i32x4_sub,
            .i32x4_mul,
            .i32x4_min_s,
            .i32x4_min_u,
            .i32x4_max_s,
            .i32x4_max_u,
            .i32x4_dot_i16x8_s,
            .i32x4_extmul_low_i16x8_s,
            .i32x4_extmul_high_i16x8_s,
            .i32x4_extmul_low_i16x8_u,
            .i32x4_extmul_high_i16x8_u,
            .i64x2_abs,
            .i64x2_neg,
            .i64x2_all_true,
            .i64x2_bitmask,
            .i64x2_extend_low_i32x4_s,
            .i64x2_extend_high_i32x4_s,
            .i64x2_extend_low_i32x4_u,
            .i64x2_extend_high_i32x4_u,
            .i64x2_shl,
            .i64x2_shr_s,
            .i64x2_shr_u,
            .i64x2_add,
            .i64x2_sub,
            .i64x2_mul,
            .i64x2_eq,
            .i64x2_ne,
            .i64x2_lt_s,
            .i64x2_gt_s,
            .i64x2_le_s,
            .i64x2_ge_s,
            .i64x2_extmul_low_i32x4_s,
            .i64x2_extmul_high_i32x4_s,
            .i64x2_extmul_low_i32x4_u,
            .i64x2_extmul_high_i32x4_u,
            .f32x4_abs,
            .f32x4_neg,
            .f32x4_sqrt,
            .f32x4_add,
            .f32x4_sub,
            .f32x4_mul,
            .f32x4_div,
            .f32x4_min,
            .f32x4_max,
            .f32x4_pmin,
            .f32x4_pmax,
            .f64x2_abs,
            .f64x2_neg,
            .f64x2_sqrt,
            .f64x2_add,
            .f64x2_sub,
            .f64x2_mul,
            .f64x2_div,
            .f64x2_min,
            .f64x2_max,
            .f64x2_pmin,
            .f64x2_pmax,
            .i32x4_trunc_sat_f32x4_s,
            .i32x4_trunc_sat_f32x4_u,
            .f32x4_convert_i32x4_s,
            .f32x4_convert_i32x4_u,
            .i32x4_trunc_sat_f64x2_s_zero,
            .i32x4_trunc_sat_f64x2_u_zero,
            .f64x2_convert_low_i32x4_s,
            .f64x2_convert_low_i32x4_u,
            .i8x16_relaxed_swizzle,
            .i32x4_relaxed_trunc_f32x4_s,
            .i32x4_relaxed_trunc_f32x4_u,
            .i32x4_relaxed_trunc_f64x2_s_zero,
            .i32x4_relaxed_trunc_f64x2_u_zero,
            .f32x4_relaxed_madd,
            .f32x4_relaxed_nmadd,
            .f64x2_relaxed_madd,
            .f64x2_relaxed_nmadd,
            .i8x16_relaxed_laneselect,
            .i16x8_relaxed_laneselect,
            .i32x4_relaxed_laneselect,
            .i64x2_relaxed_laneselect,
            .f32x4_relaxed_min,
            .f32x4_relaxed_max,
            .f64x2_relaxed_min,
            .f64x2_relaxed_max,
            .i16x8_relaxed_q15mulr_s,
            .i16x8_relaxed_dot_i8x16_i7x16_s,
            .i32x4_relaxed_dot_i8x16_i7x16_add_s,
            => {},
            else => {
                self.last_err_arg = code_value;
                return error.UnknownOperator;
            },
        }
        return info;
    }

    fn read_code_operator_0xfe(self: *Parser) CodeReadError!OperatorInformation {
        if (!self.has_var_int_bytes()) return error.NeedMoreData;
        const subcode = self.read_var_uint32();
        const code_value = 0xfe00 | subcode;
        const code = std.meta.intToEnum(OperatorCode, code_value) catch {
            self.last_err_arg = code_value;
            return error.UnknownOperator;
        };

        var info = OperatorInformation{ .code = code };
        switch (code) {
            .memory_atomic_notify,
            .memory_atomic_wait32,
            .memory_atomic_wait64,
            .i32_atomic_load,
            .i64_atomic_load,
            .i32_atomic_load8_u,
            .i32_atomic_load16_u,
            .i64_atomic_load8_u,
            .i64_atomic_load16_u,
            .i64_atomic_load32_u,
            .i32_atomic_store,
            .i64_atomic_store,
            .i32_atomic_store8,
            .i32_atomic_store16,
            .i64_atomic_store8,
            .i64_atomic_store16,
            .i64_atomic_store32,
            .i32_atomic_rmw_add,
            .i64_atomic_rmw_add,
            .i32_atomic_rmw8_add_u,
            .i32_atomic_rmw16_add_u,
            .i64_atomic_rmw8_add_u,
            .i64_atomic_rmw16_add_u,
            .i64_atomic_rmw32_add_u,
            .i32_atomic_rmw_sub,
            .i64_atomic_rmw_sub,
            .i32_atomic_rmw8_sub_u,
            .i32_atomic_rmw16_sub_u,
            .i64_atomic_rmw8_sub_u,
            .i64_atomic_rmw16_sub_u,
            .i64_atomic_rmw32_sub_u,
            .i32_atomic_rmw_and,
            .i64_atomic_rmw_and,
            .i32_atomic_rmw8_and_u,
            .i32_atomic_rmw16_and_u,
            .i64_atomic_rmw8_and_u,
            .i64_atomic_rmw16_and_u,
            .i64_atomic_rmw32_and_u,
            .i32_atomic_rmw_or,
            .i64_atomic_rmw_or,
            .i32_atomic_rmw8_or_u,
            .i32_atomic_rmw16_or_u,
            .i64_atomic_rmw8_or_u,
            .i64_atomic_rmw16_or_u,
            .i64_atomic_rmw32_or_u,
            .i32_atomic_rmw_xor,
            .i64_atomic_rmw_xor,
            .i32_atomic_rmw8_xor_u,
            .i32_atomic_rmw16_xor_u,
            .i64_atomic_rmw8_xor_u,
            .i64_atomic_rmw16_xor_u,
            .i64_atomic_rmw32_xor_u,
            .i32_atomic_rmw_xchg,
            .i64_atomic_rmw_xchg,
            .i32_atomic_rmw8_xchg_u,
            .i32_atomic_rmw16_xchg_u,
            .i64_atomic_rmw8_xchg_u,
            .i64_atomic_rmw16_xchg_u,
            .i64_atomic_rmw32_xchg_u,
            .i32_atomic_rmw_cmpxchg,
            .i64_atomic_rmw_cmpxchg,
            .i32_atomic_rmw8_cmpxchg_u,
            .i32_atomic_rmw16_cmpxchg_u,
            .i64_atomic_rmw8_cmpxchg_u,
            .i64_atomic_rmw16_cmpxchg_u,
            .i64_atomic_rmw32_cmpxchg_u,
            => info.memory_address = try self.read_memory_immediate(),
            .atomic_fence => {
                if (!self.has_bytes(1)) return error.NeedMoreData;
                const consistency_model = self.read_u8();
                if (consistency_model != 0) {
                    self.last_err_arg = consistency_model;
                    return error.AtomicFenceConsistencyModelMustBeZero;
                }
            },
            else => {
                self.last_err_arg = code_value;
                return error.UnknownOperator;
            },
        }
        return info;
    }

    fn readSingleOperator(self: *Parser) CodeReadError!OperatorInformation {
        const start_pos = self.cur_pos;
        errdefer self.cur_pos = start_pos;

        if (!self.has_bytes(1)) return error.NeedMoreData;
        const code_raw = self.read_u8();
        const code = std.meta.intToEnum(OperatorCode, code_raw) catch {
            self.last_err_arg = code_raw;
            return error.UnknownOperator;
        };

        switch (code) {
            .prefix_0xfb => return self.read_code_operator_0xfb(),
            .prefix_0xfc => return self.read_code_operator_0xfc(),
            .prefix_0xfd => return self.read_code_operator_0xfd(),
            .prefix_0xfe => return self.read_code_operator_0xfe(),
            else => {},
        }

        var info = OperatorInformation{ .code = code };
        switch (code) {
            .block, .loop, .if_, .try_ => info.block_type = try self.read_type_checked(),
            .br, .br_if, .br_on_null, .br_on_non_null => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.br_depth = self.read_var_uint32();
            },
            .br_table => info.br_table = try self.read_br_table(),
            .rethrow, .delegate => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.relative_depth = self.read_var_uint32();
            },
            .catch_, .throw => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.tag_index = self.read_var_uint32();
            },
            .try_table => {
                info.block_type = try self.read_type_checked();
                info.try_table = try self.read_try_table();
            },
            .ref_null => info.ref_type = try self.read_heap_type_checked(),
            .call, .return_call, .ref_func => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.func_index = self.read_var_uint32();
            },
            .call_indirect, .return_call_indirect => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.type_index = .{ .index = self.read_var_uint32() };
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
            },
            .local_get, .local_set, .local_tee => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.local_index = self.read_var_uint32();
            },
            .global_get, .global_set => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.global_index = self.read_var_uint32();
            },
            .table_get, .table_set => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.table_index = self.read_var_uint32();
            },
            .call_ref, .return_call_ref => info.type_index = try self.read_heap_type_checked(),
            .i32_load,
            .i64_load,
            .f32_load,
            .f64_load,
            .i32_load8_s,
            .i32_load8_u,
            .i32_load16_s,
            .i32_load16_u,
            .i64_load8_s,
            .i64_load8_u,
            .i64_load16_s,
            .i64_load16_u,
            .i64_load32_s,
            .i64_load32_u,
            .i32_store,
            .i64_store,
            .f32_store,
            .f64_store,
            .i32_store8,
            .i32_store16,
            .i64_store8,
            .i64_store16,
            .i64_store32,
            => info.memory_address = try self.read_memory_immediate(),
            .memory_size, .memory_grow => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                _ = self.read_var_uint32();
            },
            .i32_const => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.literal = .{ .number = self.read_var_int32() };
            },
            .i64_const => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                info.literal = .{ .int64 = self.read_var_int64() };
            },
            .f32_const => {
                if (!self.has_bytes(4)) return error.NeedMoreData;
                info.literal = .{ .bytes = self.read_bytes(4) };
            },
            .f64_const => {
                if (!self.has_bytes(8)) return error.NeedMoreData;
                info.literal = .{ .bytes = self.read_bytes(8) };
            },
            .select_with_type => {
                if (!self.has_var_int_bytes()) return error.NeedMoreData;
                const num_types = self.read_var_int32();
                if (num_types == 1) {
                    info.select_type = try self.read_type_checked();
                }
            },
            .unreachable_,
            .nop,
            .else_,
            .end,
            .return_,
            .catch_all,
            .drop,
            .select,
            .i32_eqz,
            .i32_eq,
            .i32_ne,
            .i32_lt_s,
            .i32_lt_u,
            .i32_gt_s,
            .i32_gt_u,
            .i32_le_s,
            .i32_le_u,
            .i32_ge_s,
            .i32_ge_u,
            .i64_eqz,
            .i64_eq,
            .i64_ne,
            .i64_lt_s,
            .i64_lt_u,
            .i64_gt_s,
            .i64_gt_u,
            .i64_le_s,
            .i64_le_u,
            .i64_ge_s,
            .i64_ge_u,
            .f32_eq,
            .f32_ne,
            .f32_lt,
            .f32_gt,
            .f32_le,
            .f32_ge,
            .f64_eq,
            .f64_ne,
            .f64_lt,
            .f64_gt,
            .f64_le,
            .f64_ge,
            .i32_clz,
            .i32_ctz,
            .i32_popcnt,
            .i32_add,
            .i32_sub,
            .i32_mul,
            .i32_div_s,
            .i32_div_u,
            .i32_rem_s,
            .i32_rem_u,
            .i32_and,
            .i32_or,
            .i32_xor,
            .i32_shl,
            .i32_shr_s,
            .i32_shr_u,
            .i32_rotl,
            .i32_rotr,
            .i64_clz,
            .i64_ctz,
            .i64_popcnt,
            .i64_add,
            .i64_sub,
            .i64_mul,
            .i64_div_s,
            .i64_div_u,
            .i64_rem_s,
            .i64_rem_u,
            .i64_and,
            .i64_or,
            .i64_xor,
            .i64_shl,
            .i64_shr_s,
            .i64_shr_u,
            .i64_rotl,
            .i64_rotr,
            .f32_abs,
            .f32_neg,
            .f32_ceil,
            .f32_floor,
            .f32_trunc,
            .f32_nearest,
            .f32_sqrt,
            .f32_add,
            .f32_sub,
            .f32_mul,
            .f32_div,
            .f32_min,
            .f32_max,
            .f32_copysign,
            .f64_abs,
            .f64_neg,
            .f64_ceil,
            .f64_floor,
            .f64_trunc,
            .f64_nearest,
            .f64_sqrt,
            .f64_add,
            .f64_sub,
            .f64_mul,
            .f64_div,
            .f64_min,
            .f64_max,
            .f64_copysign,
            .i32_wrap_i64,
            .i32_trunc_f32_s,
            .i32_trunc_f32_u,
            .i32_trunc_f64_s,
            .i32_trunc_f64_u,
            .i64_extend_i32_s,
            .i64_extend_i32_u,
            .i64_trunc_f32_s,
            .i64_trunc_f32_u,
            .i64_trunc_f64_s,
            .i64_trunc_f64_u,
            .f32_convert_i32_s,
            .f32_convert_i32_u,
            .f32_convert_i64_s,
            .f32_convert_i64_u,
            .f32_demote_f64,
            .f64_convert_i32_s,
            .f64_convert_i32_u,
            .f64_convert_i64_s,
            .f64_convert_i64_u,
            .f64_promote_f32,
            .i32_reinterpret_f32,
            .i64_reinterpret_f64,
            .f32_reinterpret_i32,
            .f64_reinterpret_i64,
            .i32_extend8_s,
            .i32_extend16_s,
            .i64_extend8_s,
            .i64_extend16_s,
            .i64_extend32_s,
            .ref_is_null,
            .ref_as_non_null,
            .ref_eq,
            .throw_ref,
            => {},
            else => {
                self.last_err_arg = @intFromEnum(code);
                return error.UnknownOperator;
            },
        }
        return info;
    }

    fn skip_type_entry_common(self: *Parser, type_kind: i7) bool {
        return switch (type_kind) {
            @intFromEnum(TypeKind.func) => self.skip_func_type(),
            @intFromEnum(TypeKind.subtype) => self.skip_sub_type(),
            @intFromEnum(TypeKind.subtype_final) => self.skip_sub_type(),
            @intFromEnum(TypeKind.struct_type) => self.skip_struct_type(),
            @intFromEnum(TypeKind.array_type) => self.skip_array_type(),
            @intFromEnum(TypeKind.i32),
            @intFromEnum(TypeKind.i64),
            @intFromEnum(TypeKind.f32),
            @intFromEnum(TypeKind.f64),
            @intFromEnum(TypeKind.v128),
            @intFromEnum(TypeKind.i8),
            @intFromEnum(TypeKind.i16),
            @intFromEnum(TypeKind.funcref),
            @intFromEnum(TypeKind.externref),
            @intFromEnum(TypeKind.exnref),
            @intFromEnum(TypeKind.anyref),
            @intFromEnum(TypeKind.eqref),
            => true,
            else => true,
        };
    }

    fn skip_func_type(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const param_count = self.read_var_uint32();
        for (0..param_count) |_| {
            if (!self.skip_type()) return false;
        }

        if (!self.has_var_int_bytes()) return false;
        const return_count = self.read_var_uint32();
        for (0..return_count) |_| {
            if (!self.skip_type()) return false;
        }
        return true;
    }

    fn skip_sub_type(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const super_count = self.read_var_uint32();
        for (0..super_count) |_| {
            if (self.skip_heap_type() == null) return false;
        }
        return self.skip_base_type();
    }

    fn skip_base_type(self: *Parser) bool {
        if (!self.has_bytes(1)) return false;
        const type_kind = self.read_var_int7();
        return switch (type_kind) {
            @intFromEnum(TypeKind.func) => self.skip_func_type(),
            @intFromEnum(TypeKind.struct_type) => self.skip_struct_type(),
            @intFromEnum(TypeKind.array_type) => self.skip_array_type(),
            else => true,
        };
    }

    fn skip_struct_type(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const field_count = self.read_var_uint32();
        for (0..field_count) |_| {
            if (!self.skip_type()) return false;
            if (!self.has_bytes(1)) return false;
            _ = self.read_var_uint1();
        }
        return true;
    }

    fn skip_array_type(self: *Parser) bool {
        if (!self.skip_type()) return false;
        if (!self.has_bytes(1)) return false;
        _ = self.read_var_uint1();
        return true;
    }

    fn skip_type(self: *Parser) bool {
        const heap_type = self.skip_heap_type() orelse return false;
        return switch (heap_type) {
            .index => true,
            .kind => |kind| switch (kind) {
                .ref_null, .ref_ => self.skip_heap_type() != null,
                else => true,
            },
        };
    }

    fn skip_import_entry(self: *Parser) bool {
        if (!self.has_str_bytes()) return false;
        _ = self.read_str_bytes();
        if (!self.has_str_bytes()) return false;
        _ = self.read_str_bytes();
        if (!self.has_bytes(1)) return false;

        const kind_raw = self.read_u8();
        const kind = std.meta.intToEnum(ExternalKind, kind_raw) catch return true;
        return switch (kind) {
            .function => blk: {
                if (!self.has_var_int_bytes()) break :blk false;
                _ = self.read_var_uint32();
                break :blk true;
            },
            .table => self.skip_table_type(),
            .memory => self.skip_memory_type(),
            .global => self.skip_global_type(),
            .tag => self.skip_tag_type(),
        };
    }

    fn skip_global_entry(self: *Parser) bool {
        if (!self.skip_global_type()) return false;
        return self.skip_init_expr();
    }

    fn skip_export_entry(self: *Parser) bool {
        if (!self.has_str_bytes()) return false;
        _ = self.read_str_bytes();
        if (!self.has_bytes(1)) return false;
        _ = self.read_u8();
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        return true;
    }

    fn skip_data_entry(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const segment_type = self.read_var_uint32();
        switch (segment_type) {
            0, 1 => return true,
            2 => {
                if (!self.has_var_int_bytes()) return false;
                _ = self.read_var_uint32();
                return true;
            },
            else => return true,
        }
    }

    fn skip_element_entry(self: *Parser) bool {
        if (!self.has_bytes(1)) return false;
        const segment_type_raw = self.read_u8();
        const segment_type = std.meta.intToEnum(ElementSegmentType, segment_type_raw) catch return true;
        return switch (segment_type) {
            .active_externval, .active_elemexpr => blk: {
                if (!self.has_var_int_bytes()) break :blk false;
                _ = self.read_var_uint32();
                break :blk true;
            },
            else => true,
        };
    }

    fn skip_element_entry_body(self: *Parser, segment_type: ElementSegmentType) bool {
        if (is_active_element_segment_type(segment_type)) {
            if (!self.skip_init_expr()) return false;
        }

        switch (segment_type) {
            .passive_externval, .active_externval, .declared_externval => {
                if (!self.has_bytes(1)) return false;
                _ = self.read_u8();
            },
            .passive_elemexpr, .active_elemexpr, .declared_elemexpr => {
                if (!self.skip_type()) return false;
            },
            .legacy_active_funcref_externval, .legacy_active_funcref_elemexpr => {},
        }

        if (!self.has_var_int_bytes()) return false;
        const item_count = self.read_var_uint32();
        if (is_externval_element_segment_type(segment_type)) {
            for (0..item_count) |_| {
                if (!self.has_var_int_bytes()) return false;
                _ = self.read_var_uint32();
            }
        } else {
            for (0..item_count) |_| {
                if (!self.skip_init_expr()) return false;
            }
        }
        return true;
    }

    fn skip_linking_entry(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const typ_raw = self.read_var_uint32();
        const typ = std.meta.intToEnum(LinkingType, typ_raw) catch return true;
        return switch (typ) {
            .stack_pointer => blk: {
                if (!self.has_var_int_bytes()) break :blk false;
                _ = self.read_var_uint32();
                break :blk true;
            },
        };
    }

    fn skip_name_map(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const count = self.read_var_uint32();
        for (0..count) |_| {
            if (!self.has_var_int_bytes()) return false;
            _ = self.read_var_uint32();
            if (!self.has_str_bytes()) return false;
            _ = self.read_str_bytes();
        }
        return true;
    }

    fn skip_name_entry(self: *Parser) bool {
        const sect_range = self.cur_sect_range orelse return false;
        if (self.cur_pos >= sect_range.end) return true;
        if (!self.has_var_int_bytes()) return false;
        const typ_raw = self.read_var_uint7();
        if (!self.has_var_int_bytes()) return false;
        const payload_len = self.read_var_uint32();
        if (!self.has_bytes(payload_len)) return false;

        const payload_end = self.cur_pos + payload_len;
        const typ = std.meta.intToEnum(NameType, typ_raw) catch {
            self.cur_pos = payload_end;
            return true;
        };

        switch (typ) {
            .module => {
                if (!self.has_str_bytes()) return false;
                _ = self.read_str_bytes();
            },
            .function, .tag, .type, .table, .memory, .global => {
                if (!self.skip_name_map()) return false;
            },
            .local => {
                if (!self.has_var_int_bytes()) return false;
                const funcs_len = self.read_var_uint32();
                for (0..funcs_len) |_| {
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_uint32();
                    if (!self.skip_name_map()) return false;
                }
            },
            .field => {
                if (!self.has_var_int_bytes()) return false;
                const types_len = self.read_var_uint32();
                for (0..types_len) |_| {
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_uint32();
                    if (!self.skip_name_map()) return false;
                }
            },
            else => {},
        }

        if (self.cur_pos > payload_end) return false;
        self.cur_pos = payload_end;
        return true;
    }

    fn skip_reloc_header(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const section_id_raw = self.read_var_uint7();
        const section_id = parse_section_code(section_id_raw) orelse return true;
        if (section_id == .custom) {
            if (!self.has_str_bytes()) return false;
            _ = self.read_str_bytes();
        }
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        return true;
    }

    fn skip_reloc_entry(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const typ_raw = self.read_var_uint7();
        const typ = std.meta.intToEnum(RelocType, typ_raw) catch return true;
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        switch (typ) {
            .function_index_leb,
            .table_index_sleb,
            .table_index_i32,
            .type_index_leb,
            .global_index_leb,
            => {},
            .global_addr_leb,
            .global_addr_sleb,
            .global_addr_i32,
            => {
                if (!self.has_var_int_bytes()) return false;
                _ = self.read_var_uint32();
            },
        }
        return true;
    }

    fn skip_function_body(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const body_size = self.read_var_uint32();
        if (!self.has_bytes(body_size)) return false;

        const body_end = self.cur_pos + body_size;
        if (!self.has_var_int_bytes()) return false;
        const local_count = self.read_var_uint32();
        for (0..local_count) |_| {
            if (!self.has_var_int_bytes()) return false;
            _ = self.read_var_uint32();
            if (!self.skip_type()) return false;
            if (self.cur_pos > body_end) return false;
        }

        self.cur_pos = body_end;
        return true;
    }

    fn skip_init_expr(self: *Parser) bool {
        while (true) {
            if (!self.has_bytes(1)) return false;
            const opcode = self.read_u8();
            switch (opcode) {
                0x0b => return true, // end
                0x23 => { // global.get
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_uint32();
                },
                0x41 => { // i32.const
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_int32();
                },
                0x42 => { // i64.const
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_int64();
                },
                0x43 => { // f32.const
                    if (!self.has_bytes(4)) return false;
                    _ = self.read_bytes(4);
                },
                0x44 => { // f64.const
                    if (!self.has_bytes(8)) return false;
                    _ = self.read_bytes(8);
                },
                0xd0 => { // ref.null
                    if (self.skip_heap_type() == null) return false;
                },
                0xd2 => { // ref.func
                    if (!self.has_var_int_bytes()) return false;
                    _ = self.read_var_uint32();
                },
                else => std.debug.panic("Unsupported init expr opcode: 0x{x}", .{opcode}),
            }
        }
    }

    fn skip_table_type(self: *Parser) bool {
        if (!self.skip_type()) return false;
        if (!self.has_var_int_bytes()) return false;
        const flags = self.read_var_uint32();
        return self.skip_resizable_limits((flags & 0x01) != 0);
    }

    fn skip_memory_type(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        const flags = self.read_var_uint32();
        return self.skip_resizable_limits((flags & 0x01) != 0);
    }

    fn skip_global_type(self: *Parser) bool {
        if (!self.skip_type()) return false;
        if (!self.has_bytes(1)) return false;
        _ = self.read_var_uint1();
        return true;
    }

    fn skip_tag_type(self: *Parser) bool {
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        return true;
    }

    fn skip_resizable_limits(self: *Parser, max_present: bool) bool {
        if (!self.has_var_int_bytes()) return false;
        _ = self.read_var_uint32();
        if (max_present) {
            if (!self.has_var_int_bytes()) return false;
            _ = self.read_var_uint32();
        }
        return true;
    }

    fn skip_heap_type(self: *Parser) ?HeapType {
        if (!self.has_bytes(1)) return null;

        const lsb = self.read_u8();
        const raw: i64 = if ((lsb & 0x80) != 0) blk: {
            if (!self.has_var_int_bytes()) return null;
            const tail = self.read_var_int32();
            break :blk (@as(i64, tail) - 1) * 128 + @as(i64, lsb);
        } else blk: {
            const low7 = lsb & 0x7f;
            if ((low7 & 0x40) != 0) {
                break :blk @as(i64, @as(i16, @intCast(low7)) - 128);
            }
            break :blk @as(i64, low7);
        };

        if (raw >= 0) {
            return .{ .index = @intCast(raw) };
        }
        return .{ .kind = parse_type_kind(raw) };
    }

    fn fail_with_state(self: *Parser, err: ParserError) ParseResult {
        self.last_err_state = @intFromEnum(self.cur_state);
        return .{ .err = err };
    }

    fn rollback_section_parse(self: *Parser, start_pos: usize) ParseResult {
        self.cur_pos = start_pos;
        self.cur_sect_range = null;
        self.cur_sect_id = .unknown;
        self.cur_sect_entries_left = 0;
        self.cur_rec_group_types_left = -1;
        return .need_more_data;
    }

    fn finish_section_dispatch(self: *Parser, start_pos: usize, custom_section_name: ?[]const u8) ParseResult {
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .section_info = SectionInformation{
                .id = self.cur_sect_id,
                .name = custom_section_name,
            } },
        } };
    }

    fn finish_current_section(self: *Parser) void {
        self.cur_state = .END_SECTION;
        self.cur_sect_range = null;
        self.cur_sect_id = .unknown;
        self.cur_sect_entries_left = 0;
        self.cur_rec_group_types_left = -1;
        self.cur_data_segment_active = false;
        self.cur_element_segment_type = null;
        self.cur_fn_range = null;
    }
};

pub const ConsumedCodeOperator = struct {
    consumed: usize,
    info: OperatorInformation,
};

pub fn consumeExpression(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!usize {
    return consumeExpressionInternal(allocator, bytes);
}

fn consumeExpressionInternal(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!usize {
    var parser = Parser.init(allocator);
    parser.cur_data = bytes;
    parser.cur_len = bytes.len;
    try parser.readCodeOperator(.expression);
    return parser.cur_pos;
}

pub fn readSingleOperator(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!OperatorInformation {
    return readSingleOperatorInternal(allocator, bytes);
}

fn readSingleOperatorInternal(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!OperatorInformation {
    var parser = Parser.init(allocator);
    parser.cur_data = bytes;
    parser.cur_len = bytes.len;
    return try parser.readSingleOperator();
}

pub fn readNextOperator(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!ConsumedCodeOperator {
    return readNextOperatorInternal(allocator, bytes);
}

fn readNextOperatorInternal(allocator: std.mem.Allocator, bytes: []const u8) CodeReadError!ConsumedCodeOperator {
    var parser = Parser.init(allocator);
    parser.cur_data = bytes;
    parser.cur_len = bytes.len;
    const info = try parser.readSingleOperator();
    return .{
        .consumed = parser.cur_pos,
        .info = info,
    };
}

pub const testing = if (builtin.is_test) struct {
    pub const ConsumedOperator = ConsumedCodeOperator;

    pub fn readHeapType(bytes: []const u8) HeapType {
        var parser = Parser.init(std.heap.page_allocator);
        parser.cur_data = bytes;
        parser.cur_len = bytes.len;
        return parser.readHeapTypeInternal();
    }

    pub fn readType(bytes: []const u8) Type {
        var parser = Parser.init(std.heap.page_allocator);
        parser.cur_data = bytes;
        parser.cur_len = bytes.len;
        return parser.readTypeInternal();
    }

    pub fn consumeExpression(bytes: []const u8) usize {
        return consumeExpressionInternal(std.heap.page_allocator, bytes) catch |err| {
            @panic(@errorName(err));
        };
    }

    pub fn readSingleOperator(bytes: []const u8) OperatorInformation {
        return readSingleOperatorInternal(std.heap.page_allocator, bytes) catch |err| {
            @panic(@errorName(err));
        };
    }

    pub fn readNextOperator(bytes: []const u8) ConsumedOperator {
        const parsed = readNextOperatorInternal(std.heap.page_allocator, bytes) catch |err| {
            @panic(@errorName(err));
        };
        return .{
            .consumed = parsed.consumed,
            .info = parsed.info,
        };
    }
} else struct {};

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

pub const ParseAllError = std.mem.Allocator.Error || ParserError || error{
    UnexpectedNeedMoreData,
};

pub fn formatParserError(
    parser: *const Parser,
    err: ParserError,
    writer: anytype,
) !void {
    switch (err) {
        error.UnexpectedTypeKind => try writer.print("Unexpected type kind: {}", .{parser.last_err_arg}),
        error.UnknownTypeKind => try writer.print("Unknown type kind: {}", .{parser.last_err_arg}),
        error.UnsupportedElementSegmentType => {
            try writer.print("Unsupported element segment type {}", .{parser.last_err_arg});
        },
        error.UnsupportedDataSegmentType => {
            try writer.print("Unsupported data segment type {}", .{parser.last_err_arg});
        },
        error.BadLinkingType => try writer.print("Bad linking type: {}", .{parser.last_err_arg}),
        error.BadRelocationType => try writer.print("Bad relocation type: {}", .{parser.last_err_arg}),
        error.UnknownOperator => try writer.print("Unknown operator: 0x{x}", .{parser.last_err_arg}),
        error.AtomicFenceConsistencyModelMustBeZero => {
            try writer.writeAll("atomic.fence consistency model must be 0");
        },
        error.UnsupportedSection => try writer.print("Unsupported section: {}", .{parser.last_err_arg}),
        error.BadMagicNumber => try writer.writeAll("Bad magic number"),
        error.BadVersionNumber => try writer.print("Bad version number {}", .{parser.last_err_arg}),
        error.UnexpectedSectionType => {
            try writer.print("Unexpected section type: {}", .{parser.last_err_arg});
        },
        error.UnsupportedState => try writer.print("Unsupported state: {}", .{parser.last_err_state}),
        error.TrailingBytesAfterModule => try writer.writeAll("Trailing bytes found after the module end"),
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
    END_SECTION,
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

    READING_FUNCTION_HEADER,
    END_FUNCTION_BODY,

    BEGIN_ELEMENT_SECTION_ENTRY,
    END_ELEMENT_SECTION_ENTRY,

    BEGIN_DATA_SECTION_ENTRY,
    DATA_SECTION_ENTRY_BODY,
    END_DATA_SECTION_ENTRY,

    RELOC_SECTION_HEADER,
    RELOC_SECTION_ENTRY,

    DATA_COUNT_SECTION_ENTRY,
};

fn contains_u32(values: []const u32, value: u32) bool {
    for (values) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

fn parse_section_code(raw: u7) ?SectionCode {
    return std.meta.intToEnum(SectionCode, raw) catch null;
}

fn parse_type_kind(kind: i64) TypeKind {
    return std.meta.intToEnum(TypeKind, @as(i32, @intCast(kind))) catch {
        std.debug.panic("Unknown type kind: {}", .{kind});
    };
}

fn is_active_element_segment_type(segment_type: ElementSegmentType) bool {
    return switch (segment_type) {
        .legacy_active_funcref_externval,
        .active_externval,
        .legacy_active_funcref_elemexpr,
        .active_elemexpr,
        => true,
        else => false,
    };
}

fn is_externval_element_segment_type(segment_type: ElementSegmentType) bool {
    return switch (segment_type) {
        .legacy_active_funcref_externval,
        .passive_externval,
        .active_externval,
        .declared_externval,
        => true,
        else => false,
    };
}

test {
    _ = @import("tests/unit_test.zig");
}
