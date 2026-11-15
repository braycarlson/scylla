const std = @import("std");
const assert = std.debug.assert;

pub const FileID = enum(u32) {
    _,

    pub fn of(file_index: u32) FileID {
        assert(file_index != std.math.maxInt(u32));

        const file: FileID = @fromBackingInt(file_index);

        assert(@backingInt(file) == file_index);

        return file;
    }

    pub fn index(file: FileID) u32 {
        assert(@backingInt(file) != std.math.maxInt(u32));

        const value = @backingInt(file);

        assert(value != std.math.maxInt(u32));
        assert(@as(FileID, @fromBackingInt(value)) == file);

        return value;
    }
};

test FileID {
    const file = FileID.of(7);

    try std.testing.expectEqual(@as(u32, 7), file.index());
    try std.testing.expect(file != FileID.of(8));
}
