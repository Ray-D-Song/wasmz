/// platform.zig — Compile-time architecture constants
///
/// Centralizes platform-specific type choices and limits to avoid
/// scattering architecture awareness throughout the codebase.

const std = @import("std");
const builtin = @import("builtin");

pub const ptr_bits = std.Target.ptrBitWidth(&builtin.target);
pub const is_64bit = ptr_bits == 64;
pub const is_32bit = ptr_bits == 32;

pub const max_wasm32_linear_memory_bytes: usize = 0x1_0000_0000;
pub const max_linear_memory_bytes: usize = if (is_64bit)
    1 << 48 // practical host limit for memory64 linear memory
else
    0xFFFF_FFFF;
pub const max_linear_memory_pages: u64 = @divTrunc(@as(u64, max_linear_memory_bytes), std.wasm.page_size);
pub const max_wasm32_linear_memory_pages: u64 = @divTrunc(@as(u64, max_wasm32_linear_memory_bytes), std.wasm.page_size);

pub const AtomicUint = if (is_32bit) u32 else u64;