const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const exception = @import("arch/exception.zig");
const uart = @import("uart.zig");
const log = @import("log.zig");
const panic_mod = @import("panic.zig");
const symbols = @import("symbols.zig");
const trace = @import("trace.zig");
const gic = @import("arch/gic.zig");
const timer = @import("arch/timer.zig");
const console = @import("console.zig");

comptime {
    _ = @import("arch/boot.zig");
}

pub const std_options: std.Options = .{
    .logFn = log.logFn,
    .log_level = .debug,
};

pub const panic = std.debug.FullPanic(panic_mod.panicFn);

export fn kmain(dtb: usize) noreturn {
    const bps = 115200;
    uart.init(bps);
    uart.print("\nlenz: booting on {s} (EL{d}, dtb=0x{x})\n", .{ board.name, cpu.currentEl(), dtb });
    exception.init();
    std.log.info("Exception Vector: VBAR_EL1=0x{x}, symbols count: {d}.", .{ cpu.read("vbar_el1"), symbols.count() });
    gic.init();
    timer.init();
    uart.enableRxIrq();
    gic.enable(board.uart_irq, &console.onUartIrq);
    cpu.enableIrq();
    uart.write(help_text);
    while (true) {
        uart.write("lenz> ");
        var buf: [64]u8 = undefined;
        run(console.readLine(&buf));
    }
}

const help_text = "Command: help / brk / udf / align / panic / overflow / bt / trace / deep / irq / tick\n";

fn run(cmd: []const u8) void {
    if (std.mem.eql(u8, cmd, "help")) {
        uart.write(help_text);
    } else if (std.mem.eql(u8, cmd, "brk")) {
        asm volatile ("brk #1");
        uart.write("Return from brk\n");
    } else if (std.mem.eql(u8, cmd, "udf")) {
        //udf: Instructions Designated as "Definitely Undefined" -> EC=0x00 (Unknown reason)
        asm volatile ("udf #0");
    } else if (std.mem.eql(u8, cmd, "align")) {
        var buf: [16]u8 align(8) = undefined;
        asm volatile ("ldr x0, [%[p]]"
            :
            : [p] "r" (&buf[1]),
            : .{ .x0 = true, .memory = true });
    } else if (std.mem.eql(u8, cmd, "panic")) {
        @panic("Panic for command...");
    } else if (std.mem.eql(u8, cmd, "overflow")) {
        var x: u8 = 255;
        x += one();
        uart.print("x = {d}=\n", .{x});
    } else if (std.mem.eql(u8, cmd, "bt")) {
        panic_mod.backtrace(@frameAddress());
    } else if (std.mem.eql(u8, cmd, "trace")) {
        trace.dump(&uart.writer, 20);
    } else if (std.mem.eql(u8, cmd, "deep")) {
        deep(20);
    } else if (std.mem.eql(u8, cmd, "irq")) {
        for (gic.counts, 0..) |n, id| {
            if (n != 0) uart.print(" INTID {d:>3}: {d} times{s}\n", .{ id, n, if (id == timer.intid) " (timer)" else if (id == board.uart_irq) " (UART)" else "" });
        }
    } else if (std.mem.eql(u8, cmd, "tick")) {
        const ns = cpu.ticksToNs(cpu.ticks());
        uart.print("{d} timer interrupts = {d}ms, counter = {d}ms\n", .{ timer.tick_count, timer.tick_count * 1000 / timer.hz, ns / 1_000_000 });
    } else if (cmd.len > 0) {
        uart.print("Unknown Command: {s}\n", .{cmd});
    }
}

noinline fn deep(n: usize) void {
    if (n == 0) @panic("I've hit rock bottom...");
    deep(n - 1);
    asm volatile ("" ::: .{ .memory = true });
}

noinline fn one() u8 {
    return @intCast(cpu.read("CurrentEL") >> 2);
}

// fn echoLoop() noreturn {
//     var line: [64]u8 = undefined;
//     var n: usize = 0;
//     uart.write("echo> ");
//     while (true) {
//         const c = uart.getc() orelse continue;
//         if (c == '\r' or c == '\n') {
//             uart.print("\n recieved: {d} \"{s}\"\n", .{ n, line[0..n] });
//             n = 0;
//             uart.write("echo> ");
//         } else if (n < line.len) {
//             line[n] = c;
//             n += 1;
//             uart.putc(c);
//         }
//     }
// }

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
