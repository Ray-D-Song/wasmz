pub const header = @import("./header.zig");
pub const layout = @import("./layout.zig");
pub const heap = @import("./heap.zig");

pub const GcHeader = header.GcHeader;
pub const GcKind = header.GcKind;
pub const StructLayout = layout.StructLayout;
pub const ArrayLayout = layout.ArrayLayout;
pub const storageTypeSize = layout.storageTypeSize;
pub const valTypeSize = layout.valTypeSize;
pub const isGcRef = layout.isGcRef;
pub const computeStructLayout = layout.computeStructLayout;
pub const computeArrayLayout = layout.computeArrayLayout;
pub const GcHeap = heap.GcHeap;
pub const FreeBlock = heap.FreeBlock;
pub const FreeList = heap.FreeList;
pub const NULL_INDEX = heap.NULL_INDEX;
pub const INITIAL_HEAP_SIZE = heap.INITIAL_HEAP_SIZE;
