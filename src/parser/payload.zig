const std = @import("std");

pub const ExternalKind = enum(u8) {
    function = 0,
    table = 1,
    memory = 2,
    global = 3,
    tag = 4,
};

pub const NameType = enum(u8) {
    module = 0,
    function = 1,
    local = 2,
    label = 3,
    type = 4,
    table = 5,
    memory = 6,
    global = 7,
    elem = 8,
    data = 9,
    field = 10,
    tag = 11,
};

pub const SectionCode = enum(i8) {
    unknown = -1,
    custom = 0,
    type = 1,
    import = 2,
    function = 3,
    table = 4,
    memory = 5,
    global = 6,
    @"export" = 7,
    start = 8,
    element = 9,
    code = 10,
    data = 11,
    data_count = 12,
    tag = 13,
};

pub const LinkingType = enum(u32) {
    stack_pointer = 1,
};

pub const RelocType = enum(u8) {
    function_index_leb = 0,
    table_index_sleb = 1,
    table_index_i32 = 2,
    global_addr_leb = 3,
    global_addr_sleb = 4,
    global_addr_i32 = 5,
    type_index_leb = 6,
    global_index_leb = 7,
};

pub const ElementMode = enum(u8) {
    active = 0,
    passive = 1,
    declarative = 2,
};

pub const DataMode = enum(u8) {
    active = 0,
    passive = 1,
};

pub const TypeKind = enum(i32) {
    // Type indices and unspecified
    unspecified = 0,

    // Primitive Number Types - Basic numeric value types
    i32 = -0x01, // 32-bit signed integer
    i64 = -0x02, // 64-bit signed integer
    f32 = -0x03, // 32-bit IEEE 754 floating point
    f64 = -0x04, // 64-bit IEEE 754 floating point
    v128 = -0x05, // 128-bit SIMD vector type

    // SIMD Lane Types - Narrow integer types for vector lanes
    i8 = -0x08, // 8-bit signed integer (SIMD lane)
    i16 = -0x09, // 16-bit signed integer (SIMK lane)

    // Null Reference Types - Nullable reference types
    null_exnref = -0x0c, // Nullable exception reference
    null_funcref = -0x0d, // Nullable function reference
    null_externref = -0x0e, // Nullable external reference
    null_ref = -0x0f, // Nullable reference (null value)

    // Abstract Reference Types - Built-in reference type categories
    funcref = -0x10, // Function reference type (any function)
    externref = -0x11, // External reference type (any host reference)
    anyref = -0x12, // Any reference type (top of reference hierarchy)
    eqref = -0x13, // Equatable reference type (can compare for equality)
    i31ref = -0x14, // 31-bit integer reference (GC proposal)
    structref = -0x15, // Struct reference type (GC proposal)
    arrayref = -0x16, // Array reference type (GC proposal)
    exnref = -0x17, // Exception reference type

    // Concrete Reference Types - Parameterized reference types
    ref_ = -0x1c, // Non-nullable concrete reference
    ref_null = -0x1d, // Nullable concrete reference

    // Type Definition Kinds - For type section entries
    func = -0x20, // Function type definition
    struct_type = -0x21, // Struct type definition (GC proposal)
    array_type = -0x22, // Array type definition (GC proposal)

    // Subtyping Markers - For subtype relationships
    subtype = -0x30, // Non-final subtype marker
    subtype_final = -0x31, // Final subtype marker (no further subtyping)
    rec_group = -0x32, // Recursive type group marker (GC proposal)

    // Special Types
    empty_block_type = -0x40, // Void block type (no return value)
};

pub const HeapType = union(enum) {
    kind: TypeKind,
    index: u32,
};

pub const RefType = struct {
    nullable: bool,
    ref_index: HeapType,
};

pub const Type = union(enum) {
    kind: TypeKind,
    index: u32,
    ref_type: RefType,

    pub fn isIndex(self: Type) bool {
        return switch (self) {
            .index => true,
            else => false,
        };
    }
};

pub const OperatorCode = enum(u32) {
    // Control Flow Instructions - Block structures and control transfers
    unreachable_ = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    if_ = 0x04,
    else_ = 0x05,
    try_ = 0x06,
    catch_ = 0x07,
    throw = 0x08,
    rethrow = 0x09,
    throw_ref = 0x0a,
    end = 0x0b,
    br = 0x0c,
    br_if = 0x0d,
    br_table = 0x0e,
    return_ = 0x0f,
    call = 0x10,
    call_indirect = 0x11,
    return_call = 0x12,
    return_call_indirect = 0x13,
    call_ref = 0x14,
    return_call_ref = 0x15,
    let = 0x17,
    delegate = 0x18,
    catch_all = 0x19,

    // Parametric Instructions - Stack manipulation
    drop = 0x1a,
    select = 0x1b,
    select_with_type = 0x1c,
    try_table = 0x1f,

    // Variable Instructions - Local and global variable access
    local_get = 0x20,
    local_set = 0x21,
    local_tee = 0x22,
    global_get = 0x23,
    global_set = 0x24,
    table_get = 0x25,
    table_set = 0x26,

    // Memory Instructions - Memory access and manipulation (0x28-0x40)
    i32_load = 0x28,
    i64_load = 0x29,
    f32_load = 0x2a,
    f64_load = 0x2b,
    i32_load8_s = 0x2c,
    i32_load8_u = 0x2d,
    i32_load16_s = 0x2e,
    i32_load16_u = 0x2f,
    i64_load8_s = 0x30,
    i64_load8_u = 0x31,
    i64_load16_s = 0x32,
    i64_load16_u = 0x33,
    i64_load32_s = 0x34,
    i64_load32_u = 0x35,
    i32_store = 0x36,
    i64_store = 0x37,
    f32_store = 0x38,
    f64_store = 0x39,
    i32_store8 = 0x3a,
    i32_store16 = 0x3b,
    i64_store8 = 0x3c,
    i64_store16 = 0x3d,
    i64_store32 = 0x3e,
    memory_size = 0x3f,
    memory_grow = 0x40,

    // Numeric Constants - Load constant values onto the stack
    i32_const = 0x41,
    i64_const = 0x42,
    f32_const = 0x43,
    f64_const = 0x44,

    // i32 Comparison Instructions - Integer equality and ordering
    i32_eqz = 0x45,
    i32_eq = 0x46,
    i32_ne = 0x47,
    i32_lt_s = 0x48,
    i32_lt_u = 0x49,
    i32_gt_s = 0x4a,
    i32_gt_u = 0x4b,
    i32_le_s = 0x4c,
    i32_le_u = 0x4d,
    i32_ge_s = 0x4e,
    i32_ge_u = 0x4f,

    // i64 Comparison Instructions - 64-bit integer comparisons
    i64_eqz = 0x50,
    i64_eq = 0x51,
    i64_ne = 0x52,
    i64_lt_s = 0x53,
    i64_lt_u = 0x54,
    i64_gt_s = 0x55,
    i64_gt_u = 0x56,
    i64_le_s = 0x57,
    i64_le_u = 0x58,
    i64_ge_s = 0x59,
    i64_ge_u = 0x5a,

    // f32 Comparison Instructions - Single-precision float comparisons
    f32_eq = 0x5b,
    f32_ne = 0x5c,
    f32_lt = 0x5d,
    f32_gt = 0x5e,
    f32_le = 0x5f,
    f32_ge = 0x60,

    // f64 Comparison Instructions - Double-precision float comparisons
    f64_eq = 0x61,
    f64_ne = 0x62,
    f64_lt = 0x63,
    f64_gt = 0x64,
    f64_le = 0x65,
    f64_ge = 0x66,

    // i32 Arithmetic Instructions - 32-bit integer operations
    i32_clz = 0x67,
    i32_ctz = 0x68,
    i32_popcnt = 0x69,
    i32_add = 0x6a,
    i32_sub = 0x6b,
    i32_mul = 0x6c,
    i32_div_s = 0x6d,
    i32_div_u = 0x6e,
    i32_rem_s = 0x6f,
    i32_rem_u = 0x70,
    i32_and = 0x71,
    i32_or = 0x72,
    i32_xor = 0x73,
    i32_shl = 0x74,
    i32_shr_s = 0x75,
    i32_shr_u = 0x76,
    i32_rotl = 0x77,
    i32_rotr = 0x78,

    // i64 Arithmetic Instructions - 64-bit integer operations
    i64_clz = 0x79,
    i64_ctz = 0x7a,
    i64_popcnt = 0x7b,
    i64_add = 0x7c,
    i64_sub = 0x7d,
    i64_mul = 0x7e,
    i64_div_s = 0x7f,
    i64_div_u = 0x80,
    i64_rem_s = 0x81,
    i64_rem_u = 0x82,
    i64_and = 0x83,
    i64_or = 0x84,
    i64_xor = 0x85,
    i64_shl = 0x86,
    i64_shr_s = 0x87,
    i64_shr_u = 0x88,
    i64_rotl = 0x89,
    i64_rotr = 0x8a,

    // f32 Arithmetic Instructions - Single-precision float operations
    f32_abs = 0x8b,
    f32_neg = 0x8c,
    f32_ceil = 0x8d,
    f32_floor = 0x8e,
    f32_trunc = 0x8f,
    f32_nearest = 0x90,
    f32_sqrt = 0x91,
    f32_add = 0x92,
    f32_sub = 0x93,
    f32_mul = 0x94,
    f32_div = 0x95,
    f32_min = 0x96,
    f32_max = 0x97,
    f32_copysign = 0x98,

    // f64 Arithmetic Instructions - Double-precision float operations
    f64_abs = 0x99,
    f64_neg = 0x9a,
    f64_ceil = 0x9b,
    f64_floor = 0x9c,
    f64_trunc = 0x9d,
    f64_nearest = 0x9e,
    f64_sqrt = 0x9f,
    f64_add = 0xa0,
    f64_sub = 0xa1,
    f64_mul = 0xa2,
    f64_div = 0xa3,
    f64_min = 0xa4,
    f64_max = 0xa5,
    f64_copysign = 0xa6,

    // Type Conversion Instructions - Converting between types
    i32_wrap_i64 = 0xa7,
    i32_trunc_f32_s = 0xa8,
    i32_trunc_f32_u = 0xa9,
    i32_trunc_f64_s = 0xaa,
    i32_trunc_f64_u = 0xab,
    i64_extend_i32_s = 0xac,
    i64_extend_i32_u = 0xad,
    i64_trunc_f32_s = 0xae,
    i64_trunc_f32_u = 0xaf,
    i64_trunc_f64_s = 0xb0,
    i64_trunc_f64_u = 0xb1,
    f32_convert_i32_s = 0xb2,
    f32_convert_i32_u = 0xb3,
    f32_convert_i64_s = 0xb4,
    f32_convert_i64_u = 0xb5,
    f32_demote_f64 = 0xb6,
    f64_convert_i32_s = 0xb7,
    f64_convert_i32_u = 0xb8,
    f64_convert_i64_s = 0xb9,
    f64_convert_i64_u = 0xba,
    f64_promote_f32 = 0xbb,
    i32_reinterpret_f32 = 0xbc,
    i64_reinterpret_f64 = 0xbd,
    f32_reinterpret_i32 = 0xbe,
    f64_reinterpret_i64 = 0xbf,

    // Sign Extension Instructions - Extending signed integer values
    i32_extend8_s = 0xc0,
    i32_extend16_s = 0xc1,
    i64_extend8_s = 0xc2,
    i64_extend16_s = 0xc3,
    i64_extend32_s = 0xc4,

    // Reference Types Instructions - Typed reference operations
    ref_null = 0xd0,
    ref_is_null = 0xd1,
    ref_func = 0xd2,
    ref_eq = 0xd3,
    ref_as_non_null = 0xd4,
    br_on_null = 0xd5,
    br_on_non_null = 0xd6,

    // Multi-byte instruction prefixes - Extended instruction encoding
    prefix_0xfb = 0xfb, // GC Proposal
    prefix_0xfc = 0xfc, // Bulk Memory and Exception Handling
    prefix_0xfd = 0xfd, // SIMD (Single Instruction Multiple Data)
    prefix_0xfe = 0xfe, // Threading/Atomics

    // 0xfb prefix - GC (Garbage Collection) Proposal
    struct_new = 0xfb00,
    struct_new_default = 0xfb01,
    struct_get = 0xfb02,
    struct_get_s = 0xfb03,
    struct_get_u = 0xfb04,
    struct_set = 0xfb05,
    array_new = 0xfb06,
    array_new_default = 0xfb07,
    array_new_fixed = 0xfb08,
    array_new_data = 0xfb09,
    array_new_elem = 0xfb0a,
    array_get = 0xfb0b,
    array_get_s = 0xfb0c,
    array_get_u = 0xfb0d,
    array_set = 0xfb0e,
    array_len = 0xfb0f,
    array_fill = 0xfb10,
    array_copy = 0xfb11,
    array_init_data = 0xfb12,
    array_init_elem = 0xfb13,
    ref_test = 0xfb14,
    ref_test_null = 0xfb15,
    ref_cast = 0xfb16,
    ref_cast_null = 0xfb17,
    br_on_cast = 0xfb18,
    br_on_cast_fail = 0xfb19,
    any_convert_extern = 0xfb1a,
    extern_convert_any = 0xfb1b,
    ref_i31 = 0xfb1c,
    i31_get_s = 0xfb1d,
    i31_get_u = 0xfb1e,

    // 0xfc prefix - Bulk Memory and Exception Handling
    i32_trunc_sat_f32_s = 0xfc00,
    i32_trunc_sat_f32_u = 0xfc01,
    i32_trunc_sat_f64_s = 0xfc02,
    i32_trunc_sat_f64_u = 0xfc03,
    i64_trunc_sat_f32_s = 0xfc04,
    i64_trunc_sat_f32_u = 0xfc05,
    i64_trunc_sat_f64_s = 0xfc06,
    i64_trunc_sat_f64_u = 0xfc07,
    memory_init = 0xfc08,
    data_drop = 0xfc09,
    memory_copy = 0xfc0a,
    memory_fill = 0xfc0b,
    table_init = 0xfc0c,
    elem_drop = 0xfc0d,
    table_copy = 0xfc0e,
    table_grow = 0xfc0f,
    table_size = 0xfc10,
    table_fill = 0xfc11,

    // 0xfe prefix - Threading and Atomic Operations
    memory_atomic_notify = 0xfe00,
    memory_atomic_wait32 = 0xfe01,
    memory_atomic_wait64 = 0xfe02,
    atomic_fence = 0xfe03,
    i32_atomic_load = 0xfe10,
    i64_atomic_load = 0xfe11,
    i32_atomic_load8_u = 0xfe12,
    i32_atomic_load16_u = 0xfe13,
    i64_atomic_load8_u = 0xfe14,
    i64_atomic_load16_u = 0xfe15,
    i64_atomic_load32_u = 0xfe16,
    i32_atomic_store = 0xfe17,
    i64_atomic_store = 0xfe18,
    i32_atomic_store8 = 0xfe19,
    i32_atomic_store16 = 0xfe1a,
    i64_atomic_store8 = 0xfe1b,
    i64_atomic_store16 = 0xfe1c,
    i64_atomic_store32 = 0xfe1d,
    i32_atomic_rmw_add = 0xfe1e,
    i64_atomic_rmw_add = 0xfe1f,
    i32_atomic_rmw8_add_u = 0xfe20,
    i32_atomic_rmw16_add_u = 0xfe21,
    i64_atomic_rmw8_add_u = 0xfe22,
    i64_atomic_rmw16_add_u = 0xfe23,
    i64_atomic_rmw32_add_u = 0xfe24,
    i32_atomic_rmw_sub = 0xfe25,
    i64_atomic_rmw_sub = 0xfe26,
    i32_atomic_rmw8_sub_u = 0xfe27,
    i32_atomic_rmw16_sub_u = 0xfe28,
    i64_atomic_rmw8_sub_u = 0xfe29,
    i64_atomic_rmw16_sub_u = 0xfe2a,
    i64_atomic_rmw32_sub_u = 0xfe2b,
    i32_atomic_rmw_and = 0xfe2c,
    i64_atomic_rmw_and = 0xfe2d,
    i32_atomic_rmw8_and_u = 0xfe2e,
    i32_atomic_rmw16_and_u = 0xfe2f,
    i64_atomic_rmw8_and_u = 0xfe30,
    i64_atomic_rmw16_and_u = 0xfe31,
    i64_atomic_rmw32_and_u = 0xfe32,
    i32_atomic_rmw_or = 0xfe33,
    i64_atomic_rmw_or = 0xfe34,
    i32_atomic_rmw8_or_u = 0xfe35,
    i32_atomic_rmw16_or_u = 0xfe36,
    i64_atomic_rmw8_or_u = 0xfe37,
    i64_atomic_rmw16_or_u = 0xfe38,
    i64_atomic_rmw32_or_u = 0xfe39,
    i32_atomic_rmw_xor = 0xfe3a,
    i64_atomic_rmw_xor = 0xfe3b,
    i32_atomic_rmw8_xor_u = 0xfe3c,
    i32_atomic_rmw16_xor_u = 0xfe3d,
    i64_atomic_rmw8_xor_u = 0xfe3e,
    i64_atomic_rmw16_xor_u = 0xfe3f,
    i64_atomic_rmw32_xor_u = 0xfe40,
    i32_atomic_rmw_xchg = 0xfe41,
    i64_atomic_rmw_xchg = 0xfe42,
    i32_atomic_rmw8_xchg_u = 0xfe43,
    i32_atomic_rmw16_xchg_u = 0xfe44,
    i64_atomic_rmw8_xchg_u = 0xfe45,
    i64_atomic_rmw16_xchg_u = 0xfe46,
    i64_atomic_rmw32_xchg_u = 0xfe47,
    i32_atomic_rmw_cmpxchg = 0xfe48,
    i64_atomic_rmw_cmpxchg = 0xfe49,
    i32_atomic_rmw8_cmpxchg_u = 0xfe4a,
    i32_atomic_rmw16_cmpxchg_u = 0xfe4b,
    i64_atomic_rmw8_cmpxchg_u = 0xfe4c,
    i64_atomic_rmw16_cmpxchg_u = 0xfe4d,
    i64_atomic_rmw32_cmpxchg_u = 0xfe4e,

    // 0xfd prefix - SIMD (Single Instruction Multiple Data)
    // Load/Store Operations
    v128_load = 0xfd000,
    i16x8_load8x8_s = 0xfd001,
    i16x8_load8x8_u = 0xfd002,
    i32x4_load16x4_s = 0xfd003,
    i32x4_load16x4_u = 0xfd004,
    i64x2_load32x2_s = 0xfd005,
    i64x2_load32x2_u = 0xfd006,
    v8x16_load_splat = 0xfd007,
    v16x8_load_splat = 0xfd008,
    v32x4_load_splat = 0xfd009,
    v64x2_load_splat = 0xfd00a,
    v128_store = 0xfd00b,
    v128_load32_zero = 0xfd05c,
    v128_load64_zero = 0xfd05d,
    v128_load8_lane = 0xfd054,
    v128_load16_lane = 0xfd055,
    v128_load32_lane = 0xfd056,
    v128_load64_lane = 0xfd057,
    v128_store8_lane = 0xfd058,
    v128_store16_lane = 0xfd059,
    v128_store32_lane = 0xfd05a,
    v128_store64_lane = 0xfd05b,

    // Constant and Shuffle
    v128_const = 0xfd00c,
    i8x16_shuffle = 0xfd00d,
    i8x16_swizzle = 0xfd00e,

    // Splat Operations
    i8x16_splat = 0xfd00f,
    i16x8_splat = 0xfd010,
    i32x4_splat = 0xfd011,
    i64x2_splat = 0xfd012,
    f32x4_splat = 0xfd013,
    f64x2_splat = 0xfd014,

    // Extract Lane Operations
    i8x16_extract_lane_s = 0xfd015,
    i8x16_extract_lane_u = 0xfd016,
    i8x16_replace_lane = 0xfd017,
    i16x8_extract_lane_s = 0xfd018,
    i16x8_extract_lane_u = 0xfd019,
    i16x8_replace_lane = 0xfd01a,
    i32x4_extract_lane = 0xfd01b,
    i32x4_replace_lane = 0xfd01c,
    i64x2_extract_lane = 0xfd01d,
    i64x2_replace_lane = 0xfd01e,
    f32x4_extract_lane = 0xfd01f,
    f32x4_replace_lane = 0xfd020,
    f64x2_extract_lane = 0xfd021,
    f64x2_replace_lane = 0xfd022,

    // i8x16 Comparison Operations
    i8x16_eq = 0xfd023,
    i8x16_ne = 0xfd024,
    i8x16_lt_s = 0xfd025,
    i8x16_lt_u = 0xfd026,
    i8x16_gt_s = 0xfd027,
    i8x16_gt_u = 0xfd028,
    i8x16_le_s = 0xfd029,
    i8x16_le_u = 0xfd02a,
    i8x16_ge_s = 0xfd02b,
    i8x16_ge_u = 0xfd02c,

    // i16x8 Comparison Operations
    i16x8_eq = 0xfd02d,
    i16x8_ne = 0xfd02e,
    i16x8_lt_s = 0xfd02f,
    i16x8_lt_u = 0xfd030,
    i16x8_gt_s = 0xfd031,
    i16x8_gt_u = 0xfd032,
    i16x8_le_s = 0xfd033,
    i16x8_le_u = 0xfd034,
    i16x8_ge_s = 0xfd035,
    i16x8_ge_u = 0xfd036,

    // i32x4 Comparison Operations
    i32x4_eq = 0xfd037,
    i32x4_ne = 0xfd038,
    i32x4_lt_s = 0xfd039,
    i32x4_lt_u = 0xfd03a,
    i32x4_gt_s = 0xfd03b,
    i32x4_gt_u = 0xfd03c,
    i32x4_le_s = 0xfd03d,
    i32x4_le_u = 0xfd03e,
    i32x4_ge_s = 0xfd03f,
    i32x4_ge_u = 0xfd040,

    // f32x4 Comparison Operations
    f32x4_eq = 0xfd041,
    f32x4_ne = 0xfd042,
    f32x4_lt = 0xfd043,
    f32x4_gt = 0xfd044,
    f32x4_le = 0xfd045,
    f32x4_ge = 0xfd046,

    // f64x2 Comparison Operations
    f64x2_eq = 0xfd047,
    f64x2_ne = 0xfd048,
    f64x2_lt = 0xfd049,
    f64x2_gt = 0xfd04a,
    f64x2_le = 0xfd04b,
    f64x2_ge = 0xfd04c,

    // v128 Logical Operations
    v128_not = 0xfd04d,
    v128_and = 0xfd04e,
    v128_andnot = 0xfd04f,
    v128_or = 0xfd050,
    v128_xor = 0xfd051,
    v128_bitselect = 0xfd052,
    v128_any_true = 0xfd053,

    // f32x4/f64x2 Conversion Operations
    f32x4_demote_f64x2_zero = 0xfd05e,
    f64x2_promote_low_f32x4 = 0xfd05f,

    // i8x16 Arithmetic Operations
    i8x16_abs = 0xfd060,
    i8x16_neg = 0xfd061,
    i8x16_popcnt = 0xfd062,
    i8x16_all_true = 0xfd063,
    i8x16_bitmask = 0xfd064,
    i8x16_narrow_i16x8_s = 0xfd065,
    i8x16_narrow_i16x8_u = 0xfd066,
    f32x4_ceil = 0xfd067,
    f32x4_floor = 0xfd068,
    f32x4_trunc = 0xfd069,
    f32x4_nearest = 0xfd06a,
    i8x16_shl = 0xfd06b,
    i8x16_shr_s = 0xfd06c,
    i8x16_shr_u = 0xfd06d,
    i8x16_add = 0xfd06e,
    i8x16_add_sat_s = 0xfd06f,
    i8x16_add_sat_u = 0xfd070,
    i8x16_sub = 0xfd071,
    i8x16_sub_sat_s = 0xfd072,
    i8x16_sub_sat_u = 0xfd073,
    f64x2_ceil = 0xfd074,
    f64x2_floor = 0xfd075,
    i8x16_min_s = 0xfd076,
    i8x16_min_u = 0xfd077,
    i8x16_max_s = 0xfd078,
    i8x16_max_u = 0xfd079,
    f64x2_trunc = 0xfd07a,
    i8x16_avgr_u = 0xfd07b,
    i16x8_extadd_pairwise_i8x16_s = 0xfd07c,
    i16x8_extadd_pairwise_i8x16_u = 0xfd07d,
    i32x4_extadd_pairwise_i16x8_s = 0xfd07e,
    i32x4_extadd_pairwise_i16x8_u = 0xfd07f,

    // i16x8 Arithmetic Operations
    i16x8_abs = 0xfd080,
    i16x8_neg = 0xfd081,
    i16x8_q15mulr_sat_s = 0xfd082,
    i16x8_all_true = 0xfd083,
    i16x8_bitmask = 0xfd084,
    i16x8_narrow_i32x4_s = 0xfd085,
    i16x8_narrow_i32x4_u = 0xfd086,
    i16x8_extend_low_i8x16_s = 0xfd087,
    i16x8_extend_high_i8x16_s = 0xfd088,
    i16x8_extend_low_i8x16_u = 0xfd089,
    i16x8_extend_high_i8x16_u = 0xfd08a,
    i16x8_shl = 0xfd08b,
    i16x8_shr_s = 0xfd08c,
    i16x8_shr_u = 0xfd08d,
    i16x8_add = 0xfd08e,
    i16x8_add_sat_s = 0xfd08f,
    i16x8_add_sat_u = 0xfd090,
    i16x8_sub = 0xfd091,
    i16x8_sub_sat_s = 0xfd092,
    i16x8_sub_sat_u = 0xfd093,
    f64x2_nearest = 0xfd094,
    i16x8_mul = 0xfd095,
    i16x8_min_s = 0xfd096,
    i16x8_min_u = 0xfd097,
    i16x8_max_s = 0xfd098,
    i16x8_max_u = 0xfd099,
    i16x8_avgr_u = 0xfd09b,
    i16x8_extmul_low_i8x16_s = 0xfd09c,
    i16x8_extmul_high_i8x16_s = 0xfd09d,
    i16x8_extmul_low_i8x16_u = 0xfd09e,
    i16x8_extmul_high_i8x16_u = 0xfd09f,

    // i32x4 Arithmetic Operations
    i32x4_abs = 0xfd0a0,
    i32x4_neg = 0xfd0a1,
    i32x4_all_true = 0xfd0a3,
    i32x4_bitmask = 0xfd0a4,
    i32x4_extend_low_i16x8_s = 0xfd0a7,
    i32x4_extend_high_i16x8_s = 0xfd0a8,
    i32x4_extend_low_i16x8_u = 0xfd0a9,
    i32x4_extend_high_i16x8_u = 0xfd0aa,
    i32x4_shl = 0xfd0ab,
    i32x4_shr_s = 0xfd0ac,
    i32x4_shr_u = 0xfd0ad,
    i32x4_add = 0xfd0ae,
    i32x4_sub = 0xfd0b1,
    i32x4_mul = 0xfd0b5,
    i32x4_min_s = 0xfd0b6,
    i32x4_min_u = 0xfd0b7,
    i32x4_max_s = 0xfd0b8,
    i32x4_max_u = 0xfd0b9,
    i32x4_dot_i16x8_s = 0xfd0ba,
    i32x4_extmul_low_i16x8_s = 0xfd0bc,
    i32x4_extmul_high_i16x8_s = 0xfd0bd,
    i32x4_extmul_low_i16x8_u = 0xfd0be,
    i32x4_extmul_high_i16x8_u = 0xfd0bf,

    // i64x2 Arithmetic Operations
    i64x2_abs = 0xfd0c0,
    i64x2_neg = 0xfd0c1,
    i64x2_all_true = 0xfd0c3,
    i64x2_bitmask = 0xfd0c4,
    i64x2_extend_low_i32x4_s = 0xfd0c7,
    i64x2_extend_high_i32x4_s = 0xfd0c8,
    i64x2_extend_low_i32x4_u = 0xfd0c9,
    i64x2_extend_high_i32x4_u = 0xfd0ca,
    i64x2_shl = 0xfd0cb,
    i64x2_shr_s = 0xfd0cc,
    i64x2_shr_u = 0xfd0cd,
    i64x2_add = 0xfd0ce,
    i64x2_sub = 0xfd0d1,
    i64x2_mul = 0xfd0d5,
    i64x2_eq = 0xfd0d6,
    i64x2_ne = 0xfd0d7,
    i64x2_lt_s = 0xfd0d8,
    i64x2_gt_s = 0xfd0d9,
    i64x2_le_s = 0xfd0da,
    i64x2_ge_s = 0xfd0db,
    i64x2_extmul_low_i32x4_s = 0xfd0dc,
    i64x2_extmul_high_i32x4_s = 0xfd0dd,
    i64x2_extmul_low_i32x4_u = 0xfd0de,
    i64x2_extmul_high_i32x4_u = 0xfd0df,

    // f32x4 Arithmetic Operations
    f32x4_abs = 0xfd0e0,
    f32x4_neg = 0xfd0e1,
    f32x4_sqrt = 0xfd0e3,
    f32x4_add = 0xfd0e4,
    f32x4_sub = 0xfd0e5,
    f32x4_mul = 0xfd0e6,
    f32x4_div = 0xfd0e7,
    f32x4_min = 0xfd0e8,
    f32x4_max = 0xfd0e9,
    f32x4_pmin = 0xfd0ea,
    f32x4_pmax = 0xfd0eb,

    // f64x2 Arithmetic Operations
    f64x2_abs = 0xfd0ec,
    f64x2_neg = 0xfd0ed,
    f64x2_sqrt = 0xfd0ef,
    f64x2_add = 0xfd0f0,
    f64x2_sub = 0xfd0f1,
    f64x2_mul = 0xfd0f2,
    f64x2_div = 0xfd0f3,
    f64x2_min = 0xfd0f4,
    f64x2_max = 0xfd0f5,
    f64x2_pmin = 0xfd0f6,
    f64x2_pmax = 0xfd0f7,

    // SIMD Conversion Operations
    i32x4_trunc_sat_f32x4_s = 0xfd0f8,
    i32x4_trunc_sat_f32x4_u = 0xfd0f9,
    f32x4_convert_i32x4_s = 0xfd0fa,
    f32x4_convert_i32x4_u = 0xfd0fb,
    i32x4_trunc_sat_f64x2_s_zero = 0xfd0fc,
    i32x4_trunc_sat_f64x2_u_zero = 0xfd0fd,
    f64x2_convert_low_i32x4_s = 0xfd0fe,
    f64x2_convert_low_i32x4_u = 0xfd0ff,

    // Relaxed SIMD Instructions
    i8x16_relaxed_swizzle = 0xfd100,
    i32x4_relaxed_trunc_f32x4_s = 0xfd101,
    i32x4_relaxed_trunc_f32x4_u = 0xfd102,
    i32x4_relaxed_trunc_f64x2_s_zero = 0xfd103,
    i32x4_relaxed_trunc_f64x2_u_zero = 0xfd104,
    f32x4_relaxed_madd = 0xfd105,
    f32x4_relaxed_nmadd = 0xfd106,
    f64x2_relaxed_madd = 0xfd107,
    f64x2_relaxed_nmadd = 0xfd108,
    i8x16_relaxed_laneselect = 0xfd109,
    i16x8_relaxed_laneselect = 0xfd10a,
    i32x4_relaxed_laneselect = 0xfd10b,
    i64x2_relaxed_laneselect = 0xfd10c,
    f32x4_relaxed_min = 0xfd10d,
    f32x4_relaxed_max = 0xfd10e,
    f64x2_relaxed_min = 0xfd10f,
    f64x2_relaxed_max = 0xfd110,
    i16x8_relaxed_q15mulr_s = 0xfd111,
    i16x8_relaxed_dot_i8x16_i7x16_s = 0xfd112,
    i32x4_relaxed_dot_i8x16_i7x16_add_s = 0xfd113,
};

pub const TagAttribute = enum(u8) {
    Exception = 0,
};

pub const CatchHandlerKind = enum(u32) {
    catch_ = 0,
    catch_ref = 1,
    catch_all = 2,
    catch_all_ref = 3,
};

pub const ModuleHeader = struct {
    magic_number: u32,
    version: u32,
};

pub const ResizableLimits = struct {
    initial: u32,
    maximum: ?u32 = null,
};

pub const TableType = struct {
    element_type: Type,
    limits: ResizableLimits,
};

pub const MemoryType = struct {
    limits: ResizableLimits,
    shared: bool,
};

pub const GlobalType = struct {
    content_type: Type,
    mutability: u8,
};

pub const TagType = struct {
    attribute: TagAttribute,
    type_index: u32,
};

pub const GlobalVariable = struct {
    typ: GlobalType,
    init_expr: []const u8,
};

pub const ElementSegment = struct {
    mode: ElementMode,
    table_index: ?u32 = null,
};

pub const ElementSegmentBody = struct {
    element_type: Type,
    /// Function indices for externval-style elements (e.g. legacy_active_funcref_externval).
    /// Empty for elemexpr-style segments.
    func_indices: []const u32 = &.{},
};

pub const DataSegment = struct {
    mode: DataMode,
    memory_index: ?u32 = null,
};

pub const DataSegmentBody = struct {
    data: []const u8,
};

pub const ImportEntryType = union(enum) {
    table: TableType,
    memory: MemoryType,
    global: GlobalType,
    tag: TagType,
};

pub const ImportEntry = struct {
    module: []const u8,
    field: []const u8,
    kind: ExternalKind,
    func_type_index: ?u32 = null,
    typ: ?ImportEntryType = null,
};

pub const ExportEntry = struct {
    field: []const u8,
    kind: ExternalKind,
    index: u32,
};

pub const NameEntry = struct {
    typ: NameType,
};

pub const Naming = struct {
    index: u32,
    name: []const u8,
};

pub const ModuleNameEntry = struct {
    typ: NameType,
    module_name: []const u8,
};

pub const FunctionNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const LocalName = struct {
    index: u32,
    locals: []const Naming,
};

pub const LocalNameEntry = struct {
    typ: NameType,
    funcs: []const LocalName,
};

pub const TagNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const TypeNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const TableNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const MemoryNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const GlobalNameEntry = struct {
    typ: NameType,
    names: []const Naming,
};

pub const FieldName = struct {
    index: u32,
    fields: []const Naming,
};

pub const FieldNameEntry = struct {
    typ: NameType,
    types: []const FieldName,
};

pub const LinkingEntry = struct {
    typ: LinkingType,
    index: ?u32 = null,
};

pub const RelocHeader = struct {
    id: SectionCode,
    name: []const u8,
};

pub const RelocEntry = struct {
    typ: RelocType,
    offset: u32,
    index: u32,
    addend: ?u32 = null,
};

pub const SourceMappingUrl = struct {
    url: []const u8,
};

pub const StartEntry = struct {
    index: u32,
};

pub const FunctionEntry = struct {
    type_index: u32,
};

// TypeEntry represents a type definition in the WebAssembly module.
// It can be a function type, struct type, or array type
pub const TypeEntry = struct {
    type: TypeKind,
    params: []const Type = &.{},
    returns: []const Type = &.{},
    fields: []const Type = &.{},
    mutabilities: []const bool = &.{},
    element_type: ?Type = null,
    mutability: ?bool = null,
    super_types: []const HeapType = &.{},
    final: ?bool = null,
};

pub const SectionInformation = struct {
    id: SectionCode,
    name: ?[]const u8 = null,
};

pub const Locals = struct {
    count: u32,
    typ: Type,
};

pub const FunctionInformation = struct {
    locals: []const Locals,
    body: []const u8,
};

pub const MemoryAddress = struct {
    flags: u32,
    offset: u32,
};

pub const CatchHandler = struct {
    kind: CatchHandlerKind,
    tag_index: ?u32 = null,
    depth: u32,
};

pub const OperatorLiteral = union(enum) {
    number: i64,
    int64: i64,
    bytes: []const u8,
};

pub const OperatorInformation = struct {
    code: OperatorCode,
    block_type: ?Type = null,
    select_type: ?Type = null,
    ref_type: ?HeapType = null,
    src_type: ?HeapType = null,
    br_depth: ?u32 = null,
    br_table: []const u32 = &.{},
    try_table: []const CatchHandler = &.{},
    relative_depth: ?u32 = null,
    func_index: ?u32 = null,
    type_index: ?HeapType = null,
    table_index: ?u32 = null,
    local_index: ?u32 = null,
    field_index: ?u32 = null,
    global_index: ?u32 = null,
    segment_index: ?u32 = null,
    tag_index: ?u32 = null,
    destination_index: ?u32 = null,
    memory_address: ?MemoryAddress = null,
    literal: ?OperatorLiteral = null,
    len: ?u32 = null,
    lines: ?[]const u8 = null,
    line_index: ?u32 = null,
};

pub const Payload = union(enum) {
    import_entry: ImportEntry,
    export_entry: ExportEntry,
    function_entry: FunctionEntry,
    type_entry: TypeEntry,
    tag_type: TagType,
    module_header: ModuleHeader,
    operator_info: OperatorInformation,
    memory_type: MemoryType,
    table_type: TableType,
    global_variable: GlobalVariable,
    name_entry: NameEntry,
    module_name_entry: ModuleNameEntry,
    function_name_entry: FunctionNameEntry,
    local_name_entry: LocalNameEntry,
    tag_name_entry: TagNameEntry,
    type_name_entry: TypeNameEntry,
    table_name_entry: TableNameEntry,
    memory_name_entry: MemoryNameEntry,
    global_name_entry: GlobalNameEntry,
    field_name_entry: FieldNameEntry,
    element_segment: ElementSegment,
    element_segment_body: ElementSegmentBody,
    data_segment: DataSegment,
    data_segment_body: DataSegmentBody,
    section_info: SectionInformation,
    function_info: FunctionInformation,
    reloc_header: RelocHeader,
    reloc_entry: RelocEntry,
    linking_entry: LinkingEntry,
    source_mapping_url: SourceMappingUrl,
    start_entry: StartEntry,
    bytes: []const u8,
    number: i64,

    // For test and debug purposes only
    pub fn format(self: Payload, writer: anytype) !void {
        switch (self) {
            .module_header => |v| try writer.print(
                "Payload.module_header(version=0x{x})",
                .{v.version},
            ),
            .section_info => |v| try writer.print(
                "Payload.section_info(id={any}, name={s})",
                .{ v.id, v.name orelse "" },
            ),
            .function_entry => |v| try writer.print(
                "Payload.function_entry(type_index={})",
                .{v.type_index},
            ),
            .export_entry => |v| try writer.print(
                "Payload.export_entry(field={s}, kind={any}, index={})",
                .{ v.field, v.kind, v.index },
            ),
            .bytes => |v| try writer.print(
                "Payload.bytes(len={})",
                .{v.len},
            ),
            .number => |v| try writer.print(
                "Payload.number({})",
                .{v},
            ),
            else => try writer.print("Payload.{s}", .{@tagName(self)}),
        }
    }
};
