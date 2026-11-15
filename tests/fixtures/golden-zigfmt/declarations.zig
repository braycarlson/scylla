const std = @import("std");
const builtin = @import("builtin");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,
};

const Colour = enum(u8) {
    red,
    green,
    blue,
};

const Payload = union(enum) {
    none,
    one: u32,
    many: []const u32,
};

const Plain = union {
    left: u32,
    right: u32,
};

const Packed = packed struct {
    low: u4,
    high: u4,
};

const Extern = extern struct {
    handle: u64,
};

const Opaque = opaque {};

const Failure = error{
    OutOfRange,
    Malformed,
};

pub var counter: usize = 0;
threadlocal var scratch: [16]u8 = undefined;

pub extern "c" fn write(handle: i32, buffer: [*]const u8, length: usize) isize;

const Alias = std.ArrayList(u8);

/// A doc comment on a declaration.
export fn exported() void {}

noinline fn cold() void {}

fn noaliased(noalias held: *u32) void {
    _ = held;
}

fn volatiled(held: *volatile u32) void {
    _ = held;
}

var located: u32 linksection(".data") = 0;

var addressed: *addrspace(.generic) u32 = undefined;

var relaxed: [*]allowzero u32 = undefined;
