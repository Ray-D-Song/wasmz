const std = @import("std");
const builtin = @import("builtin");
const DataRange = @import("range.zig").DataRange;
const payload_mod = @import("payload.zig");
const Payload = payload_mod.Payload;
const Type = payload_mod.Type;
const TypeEntry = payload_mod.TypeEntry;
const RefType = payload_mod.RefType;
const HeapType = payload_mod.HeapType;
const TypeKind = payload_mod.TypeKind;
const SectionCode = payload_mod.SectionCode;
const SectionInformation = payload_mod.SectionInformation;

const WASM_MAGIC_NUMBER = 0x6d736100;
const WASM_SUPPORTED_VERSION = [_]u32{ 0x1, 0x2 };

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
    cur_section_entries_left: u32 = 0,
    cur_rec_group_types_left: i32 = -1,
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
                    if (self.cur_section_entries_left == 0 and self.cur_rec_group_types_left < 0) {
                        self.finish_current_section();
                        continue;
                    }
                    if (self.cur_rec_group_types_left == 0) {
                        // Rec group boundaries are internal-only; once all nested
                        // types are emitted, immediately advance to the next type-section item.
                        self.cur_section_entries_left -= 1;
                        self.cur_rec_group_types_left = -1;
                        continue;
                    }
                    if (self.cur_rec_group_types_left > 0) {
                        return self.read_rec_group_entry();
                    }
                    return self.read_type_entry();
                },
                .IMPORT_SECTION_ENTRY,
                .FUNCTION_SECTION_ENTRY,
                .TABLE_SECTION_ENTRY,
                .MEMORY_SECTION_ENTRY,
                .GLOBAL_SECTION_ENTRY,
                .EXPORT_SECTION_ENTRY,
                .DATA_SECTION_ENTRY,
                .ELEMENT_SECTION_ENTRY,
                .LINKING_SECTION_ENTRY,
                .TAG_SECTION_ENTRY,
                .READING_FUNCTION_HEADER,
                .DATA_COUNT_SECTION_ENTRY,
                .NAME_SECTION_ENTRY,
                .RELOC_SECTION_ENTRY,
                => {
                    if (self.cur_section_entries_left == 0) {
                        self.finish_current_section();
                        continue;
                    }
                    return self.fail_with_state(ParserError.UnsupportedState);
                },
                .RELOC_SECTION_HEADER => {
                    if (!self.has_var_int_bytes()) return .need_more_data;
                    self.cur_section_entries_left = self.read_var_uint32();
                    if (self.cur_section_entries_left == 0) {
                        self.finish_current_section();
                        continue;
                    }
                    self.cur_state = .RELOC_SECTION_ENTRY;
                    return self.fail_with_state(ParserError.UnsupportedState);
                },

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
        self.cur_section_entries_left = 0;
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
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_rec_group_types_left = -1;
                self.cur_state = .TYPE_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .import => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .IMPORT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .@"export" => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .EXPORT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .function => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .FUNCTION_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .table => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .TABLE_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .memory => {
                if (!self.has_section_payload()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .MEMORY_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .global => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
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
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .READING_FUNCTION_HEADER;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .element => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .ELEMENT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .data => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .DATA_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .data_count => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
                self.cur_state = .DATA_COUNT_SECTION_ENTRY;
                return self.finish_section_dispatch(start_pos, custom_section_name);
            },
            .tag => {
                if (!self.has_var_int_bytes()) return self.rollback_section_parse(start_pos);
                self.cur_section_entries_left = self.read_var_uint32();
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
                    self.cur_section_entries_left = self.read_var_uint32();
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

    fn read_rec_group_entry(self: *Parser) ParseResult {
        const start_pos = self.cur_pos;
        const type_kind = self.read_var_int7();
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
        const type_kind = self.read_var_int7();
        if (type_kind == @intFromEnum(TypeKind.rec_group)) {
            self.cur_rec_group_types_left = @intCast(self.read_var_uint32());
            return self.read_rec_group_entry();
        }

        const type_entry = self.read_type_entry_common(type_kind) catch {
            return self.fail_with_state(ParserError.UnknownTypeKind);
        };
        self.cur_section_entries_left -= 1;
        return .{ .parsed = .{
            .consumed = self.cur_pos - start_pos,
            .payload = .{ .type_entry = type_entry },
        } };
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

    // TODO
    // read_func_type
    //   read_type
    //     read_heap_type
    // read_sub_type
    // read_struct_type
    // read_array_type

    fn read_struct_type(self: *Parser) !TypeEntry {
        const field_count = self.read_var_uint32();
        const field_types = try self.allocator.alloc(Type, @intCast(field_count));
        const field_mutabilities = try self.allocator.alloc(bool, @intCast(field_count));
        for (field_types, field_mutabilities) |*field_type, *field_mutability| {
            field_type.* = self.read_type();
            field_mutability.* = self.read_var_uint1() != 0;
        }
        return .{
            .type = .struct_type,
            .fields = field_types,
            .mutabilities = field_mutabilities,
        };
    }

    fn read_array_type(self: *Parser) !TypeEntry {
        const element_type = self.read_type();
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
            super_type.* = self.read_heap_type();
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
            param_type.* = self.read_type();
        }
        const return_count = self.read_var_uint32();
        const return_types = try self.allocator.alloc(Type, @intCast(return_count));
        for (return_types) |*return_type| {
            return_type.* = self.read_type();
        }
        return .{
            .type = .func,
            .params = param_types,
            .returns = return_types,
        };
    }

    // Heap is used to represent reference types and type indices in WebAssembly
    fn read_heap_type(self: *Parser) HeapType {
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
    fn read_type(self: *Parser) Type {
        return switch (self.read_heap_type()) {
            .index => |index| .{ .index = index },
            .kind => |kind| switch (kind) {
                .ref_null, .ref_ => .{ .ref_type = .{
                    .nullable = kind == .ref_null,
                    .ref_index = self.read_heap_type(),
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

    fn fail_with_state(self: *Parser, err: ParserError) ParseResult {
        self.last_err_state = @intFromEnum(self.cur_state);
        return .{ .err = err };
    }

    fn rollback_section_parse(self: *Parser, start_pos: usize) ParseResult {
        self.cur_pos = start_pos;
        self.cur_sect_range = null;
        self.cur_sect_id = .unknown;
        self.cur_section_entries_left = 0;
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
        self.cur_section_entries_left = 0;
        self.cur_rec_group_types_left = -1;
    }
};

pub const testing = if (builtin.is_test) struct {
    pub fn read_heap_type(bytes: []const u8) HeapType {
        var parser = Parser.init(std.heap.page_allocator);
        parser.cur_data = bytes;
        parser.cur_len = bytes.len;
        return parser.read_heap_type();
    }

    pub fn read_type(bytes: []const u8) Type {
        var parser = Parser.init(std.heap.page_allocator);
        parser.cur_data = bytes;
        parser.cur_len = bytes.len;
        return parser.read_type();
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

fn parse_section_code(raw: u7) ?SectionCode {
    return std.meta.intToEnum(SectionCode, raw) catch null;
}

fn parse_type_kind(kind: i64) TypeKind {
    return std.meta.intToEnum(TypeKind, @as(i32, @intCast(kind))) catch {
        std.debug.panic("Unknown type kind: {}", .{kind});
    };
}
