const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const exception = @import("arch/exception.zig");
const gic = @import("arch/gic.zig");
const timer = @import("arch/timer.zig");
const mmu = @import("arch/mmu.zig");
const uart = @import("uart.zig");
const log = @import("log.zig");
const panic_mod = @import("panic.zig");
const symbols = @import("symbols.zig");
const kheap = @import("kheap.zig");
const monitor = @import("monitor.zig");

comptime {
    _ = @import("arch/boot.zig");
}

pub const std_options: std.Options = .{
    .logFn = log.logFn,
    .log_level = .debug,
};

pub const panic = std.debug.FullPanic(panic_mod.panicFn);

const heap_size = 32 * 1024 * 1024;

export fn kmain(dtb: usize) noreturn {
    const bps = 115200;
    uart.init(bps);
    uart.print("\nlenz: booting on {s} (EL{d}, dtb=0x{x})\n", .{ board.name, cpu.currentEl(), dtb });
    exception.init();
    std.log.info("Exception Vector: VBAR_EL1=0x{x}, symbols count: {d}.", .{ cpu.read("vbar_el1"), symbols.count() });

    mmu.init();
    std.log.info("MMU has enabled (SCTLR_EL1=0x{x})", .{cpu.read("sctlr_el1")});

    kheap.init(mmu.freeRamStart(), heap_size);
    std.log.info("heap: 0x{x} ~ {d}Mib", .{ mmu.freeRamStart(), heap_size >> 20 });

    gic.init();
    timer.init();
    uart.enableRxIrq();
    gic.enable(board.uart_irq, &monitor.onUartIrq);
    cpu.enableIrq();
    monitor.prompt();
    while (true) {
        monitor.poll();
        cpu.wfi();
    }
}
