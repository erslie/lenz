const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");

comptime {
    _ = @import("arch/boot.zig");
}

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    while (true) asm volatile ("wfe");
}

export fn kmain(dtb: usize) noreturn {
    _ = dtb;
    say("\nlenz: Arrived at kmain (EL");
    putc('0' + @as(u8, cpu.currentEl()));
    say(")\n");
    while (true) asm volatile ("wfe");
}

const UART_DR: *volatile u32 = @ptrFromInt(board.uart_base + 0x00);
const UART_FR: *volatile u32 = @ptrFromInt(board.uart_base + 0x18);

fn putc(c: u8) void {
    while (UART_FR.* & (1 << 5) != 0) {}
    UART_DR.* = c;
}

fn say(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}
