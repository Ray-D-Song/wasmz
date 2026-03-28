pub const DataRange = struct {
    start: usize,
    end: usize,

    pub fn offset(self: *DataRange, shift: isize) void {
        self.start = @intCast(@as(isize, @intCast(self.start)) + shift);
        self.end = @intCast(@as(isize, @intCast(self.end)) + shift);
    }
};
