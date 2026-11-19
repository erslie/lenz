const std = @import("std");
const heap_mod = @import("heap.zig");

pub var heap: heap_mod.Heap = undefined;

pub fn init(start: usize, size: usize) void {
    const region: [*]u8 = @ptrFromInt(start);
    heap = heap_mod.Heap.init(region[0..size]);
    heap.on_corruption = corruption;
}

pub fn allocator() std.mem.Allocator {
    return heap.allocator();
}

fn corruption(msg: []const u8, addr: usize, ret_addr: usize) noreturn {
    const symbols = @import("symbols.zig");
    const uart = @import("uart.zig");
    uart.print("\nHeap Error (0x{x}): {s}", .{ addr, msg });
    if (ret_addr != 0) {
        uart.write(": ");
        symbols.print(&uart.writer, ret_addr);
    }
    uart.write("\n");
    @panic("heap corruption");
}
