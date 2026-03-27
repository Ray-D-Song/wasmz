const std = @import("std");

const ty_mode = @import("./type.zig");
const TableType = ty_mode.TableType;
const RefType = ty_mode.RefType;

const raw_mode = @import("./raw.zig");
const RawRef = raw_mode.RawRef;
const TypedRawRef = raw_mode.TypedRawRef;

const limiter_mode = @import("../limiter.zig");
const StoreLimits = limiter_mode.StoreLimits;
const LimiterError = limiter_mode.LimiterError;

const err_mode = @import("./error.zig");
const TableError = err_mode.TableError;

const Table = struct {
    ty: TableType,
    elements: []RawRef,

    pub fn init(
        allocator: std.mem.Allocator,
        ty: TableType,
        init_ref: TypedRawRef,
        limiter: ?*StoreLimits,
    ) (LimiterError || std.mem.Allocator.Error || TableError)!Table {
        try ty.ensureElementTypeMatches(init_ref.ty);

        const min_size = std.math.cast(usize, ty.min) orelse
            return TableError.MinimumSizeOverflow;

        const max_size = if (ty.max) |maximum|
            std.math.cast(usize, maximum) orelse return TableError.MaximumSizeOverflow
        else
            null;

        if (limiter) |l| {
            const allowed = try l.tableGrowing(0, min_size, max_size);
            if (!allowed) {
                return TableError.ResourceLimiterDeniedAllocation;
            }
        }

        var elements = std.ArrayList(RawRef).init(allocator);
        errdefer elements.deinit();

        elements.ensureTotalCapacity(min_size) catch {
            const err = TableError.OutOfSystemMemory;
            if (limiter) |l| {
                try l.tableGrowFailed(err);
            }
            return err;
        };

        for (0..min_size) |_| {
            elements.appendAssumeCapacity(init_ref.raw);
        }

        return .{
            .ty = ty,
            .elements = elements,
        };
    }

    pub fn deinit(self: *Table) void {
        self.elements.deinit();
    }

    pub fn getCurrentSize(self: *Table) u64 {
        return @as(u64, self.elements.len);
    }

    pub fn getDynType(self: *Table) TableType {
        return TableType.initImpl(self.ty.element, self.ty.index_type, self.getCurrentSize(), self.ty.max);
    }

    fn unwrapTyped(self: Table, value: TypedRawRef) TableError!RawRef {
        try self.ty.ensureElementTypeMatches(value.ty);
        return value.raw;
    }

    pub fn grow(self: *Table, delta: u64, init_ref: TypedRawRef, limiter: ?*StoreLimits) TableError!void {
        const current_size = self.getCurrentSize();
        const desired_size = current_size + delta;

        try self.ty.ensureElementTypeMatches(init_ref.ty);

        const max_size = if (self.ty.max) |maximum|
            std.math.cast(usize, maximum) orelse return TableError.MaximumSizeOverflow
        else
            null;

        if (limiter) |l| {
            const allowed = try l.tableGrowing(current_size, desired_size, max_size);
            if (!allowed) {
                return TableError.ResourceLimiterDeniedAllocation;
            }
        }

        self.elements.ensureTotalCapacity(desired_size) catch {
            const err = TableError.OutOfSystemMemory;
            if (limiter) |l| {
                try l.tableGrowFailed(err);
            }
            return err;
        };

        for (current_size..desired_size) |_| {
            self.elements.appendAssumeCapacity(init_ref.raw);
        }
    }
};
