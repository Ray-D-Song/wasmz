pub const TableError = enum {
    /// Tried to allocate more virtual memory than technically possible.
    OutOfSystemMemory,
    /// The minimum size of the table type overflows the system index type.
    MinimumSizeOverflow,
    /// The maximum size of the table type overflows the system index type.
    MaximumSizeOverflow,
    /// If a resource limiter denied allocation or growth of a linear memory.
    ResourceLimiterDeniedAllocation,
    /// Occurs when growing a table out of its set bounds.
    GrowOutOfBounds,
    /// Occurs when initializing a table out of its set bounds.
    InitOutOfBounds,
    /// Occurs when filling a table out of its set bounds.
    FillOutOfBounds,
    /// Occurs when accessing the table out of bounds.
    SetOutOfBounds,
    /// Occur when coping elements of tables out of bounds.
    CopyOutOfBounds,
    /// Occurs when operating with a [`Table`](crate::Table) and mismatching element types.
    ElementTypeMismatch,
    /// The operation ran out of fuel before completion.
    OutOfFuel,
};

pub fn tableErrorMsg(err: TableError) []const u8 {
    return switch (err) {
        .OutOfSystemMemory => "out of system memory",
        .MinimumSizeOverflow => "minimum size of the table type overflows the system index type",
        .MaximumSizeOverflow => "maximum size of the table type overflows the system index type",
        .ResourceLimiterDeniedAllocation => "a resource limiter denied allocation or growth of a linear memory",
        .GrowOutOfBounds => "growing a table out of its set bounds",
        .InitOutOfBounds => "initializing a table out of its set bounds",
        .FillOutOfBounds => "filling a table out of its set bounds",
        .SetOutOfBounds => "accessing the table out of bounds",
        .CopyOutOfBounds => "copying elements of tables out of bounds",
        .ElementTypeMismatch => "operating with a Table and mismatching element types",
        .OutOfFuel => "the operation ran out of fuel before completion",
    };
}
