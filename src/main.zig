const std = @import("std");

comptime {
    _ = @import("arch/boot.zig");
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    while (true) asm volatile ("wfe");
}
