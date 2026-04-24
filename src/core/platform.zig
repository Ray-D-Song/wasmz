/// platform.zig — Compile-time architecture constants
///
/// Centralizes platform-specific type choices and limits to avoid
/// scattering architecture awareness throughout the codebase.

const std = @import("std");
const builtin = @import("builtin");

pub const ptr_bits = std.Target.ptrBitWidth(&builtin.target);
pub const is_64bit = ptr_bits == 64;
pub const is_32bit = ptr_bits == 32;

pub const max_linear_memory_bytes: usize = if (is_64bit)
    0x1_0000_0000  // wasm64 max memory (4GB, same as wasm32)
else
    0xFFFF_FFFF;
pub const max_linear_memory_pages: u64 = if (is_64bit)
    0x1_0000_0000 / std.wasm.page_size  // 4GB / 64KB
else
    0xFFFF_FFFF / std.wasm.page_size;

pub const AtomicUint = if (is_32bit) u32 else u64;