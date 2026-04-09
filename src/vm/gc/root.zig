pub const header = @import("./header.zig");
pub const layout = @import("./layout.zig");

pub const GcHeader = header.GcHeader;
pub const GcKind = header.GcKind;
pub const StructLayout = layout.StructLayout;
pub const ArrayLayout = layout.ArrayLayout;
pub const storageTypeSize = layout.storageTypeSize;
pub const valTypeSize = layout.valTypeSize;
pub const isGcRef = layout.isGcRef;
pub const computeStructLayout = layout.computeStructLayout;
pub const computeArrayLayout = layout.computeArrayLayout;
