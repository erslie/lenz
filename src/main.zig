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
const sched = @import("sched.zig");
const debug = @import("arch/debug.zig");
const pci = @import("pci.zig");

pub export var demo_counter: u64 = 0;

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

    mmu.init(heap_size);
    std.log.info("MMU has enabled (SCTLR_EL1=0x{x})", .{cpu.read("sctlr_el1")});

    kheap.init(mmu.freeRamStart(), heap_size);
    std.log.info("heap: 0x{x} ~ {d}Mib", .{ mmu.freeRamStart(), heap_size >> 20 });

    if (board.pci != null) {
        pci.scan();
        std.log.info("PCI: {d} devices", .{pci.count});
    }

    gic.init();
    timer.init();
    uart.enableRxIrq();
    gic.enable(board.uart_irq, &monitor.onUartIrq);
    cpu.enableIrq();
    std.log.info("interrupts started: tiemr {d}Hz (cntfrq={d})", .{ timer.hz, cpu.read("cntfrq_el0") });

    debug.init();
    sched.init(kheap.allocator());
    _ = sched.spawn("count1s", countTask, 1000, 16 * 1024) catch unreachable;
    _ = sched.spawn("count2s", countTask, 2000, 16 * 1024) catch unreachable;
    _ = sched.spawn("monitor", monitorTask, 0, 32 * 1024) catch unreachable;

    while (true) sched.sleepMs(60_000);
}

fn countTask(interval_ms: usize) void {
    const t0 = cpu.ticks();
    for (0..4) |i| {
        bump();
        std.log.info("[{s}] #{d} elapsed {d}ms", .{ sched.currentTask().name, i, cpu.ticksToNs(cpu.ticks() - t0) / 1_000_000 });
        sched.sleepMs(interval_ms);
    }
}

noinline fn bump() void {
    demo_counter += 1;
}

fn monitorTask(_: usize) void {
    monitor.prompt();
    while (true) {
        monitor.poll();
        sched.sleepMs(10);
    }
}
