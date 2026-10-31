const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const uart = @import("uart.zig");
const log = @import("log.zig");

comptime {
    _ = @import("arch/boot.zig");
}

pub const std_options: std.Options = .{
    .logFn = log.logFn,
    .log_level = .debug,
};

pub const panic = std.debug.FullPanic(panicFn);

fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = msg;
    _ = first_trace_addr;
    while (true) asm volatile ("wfe");
}

export fn kmain(dtb: usize) noreturn {
    const bps = 115200;
    uart.init(bps);
    uart.print("\nlenz: booting on {s} (EL{d}, dtb=0x{x})\n", .{ board.name, cpu.currentEl(), dtb });
    std.log.info("UART clock: {d}Hz, speed: {d}bps", .{ board.uart_clock_hz, bps });
    std.log.debug("Counter's frequency: cntfrq_el0={d}Hz", .{cpu.read("cntfrq_el0")});
    std.log.scoped(.demo).warn("If you add a \"scope\", you can tell where the log came from.", .{});
    echoLoop();
}

fn echoLoop() noreturn {
    var line: [64]u8 = undefined;
    var n: usize = 0;
    uart.write("echo> ");
    while (true) {
        const c = uart.getc() orelse continue;
        if (c == '\r' or c == '\n') {
            uart.print("\n recieved: {d} \"{s}\"\n", .{ n, line[0..n] });
            n = 0;
            uart.write("echo> ");
        } else if (n < line.len) {
            line[n] = c;
            n += 1;
            uart.putc(c);
        }
    }
}

// const UART_DR: *volatile u32 = @ptrFromInt(board.uart_base + 0x00);
// const UART_FR: *volatile u32 = @ptrFromInt(board.uart_base + 0x18);

// fn putc(c: u8) void {
//     while (UART_FR.* & (1 << 5) != 0) {}
//     UART_DR.* = c;
// }

// fn say(s: []const u8) void {
//     for (s) |c| {
//         if (c == '\n') putc('\r');
//         putc(c);
//     }
// }
