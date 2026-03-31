pub const DataRange = struct {
    start: usize,
    end: usize,

    pub fn offset(self: *DataRange, shift: isize) void {
        const shifted_start = @as(isize, @intCast(self.start)) + shift;
        const shifted_end = @as(isize, @intCast(self.end)) + shift;
        self.start = @intCast(@max(shifted_start, 0));
        self.end = @intCast(@max(shifted_end, 0));
    }
};
