const cpu = @import("arch/cpu.zig");
const uart = @import("uart.zig");
const exception = @import("arch/exception.zig");

//Called from `pub const panic = std.debug.FullPanic(panic_mod.panicFn);` in `main.zig`
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    cpu.disableIrq();
    uart.print("\n\x1b[41m PANIC \x1b[0m {s}\n", .{msg});
    if (first_trace_addr) |a| uart.print(" Event location: 0x{x}\n", .{a});
    halt();
}

pub fn fatalFrame(f: *exception.TrapFrame, why: []const u8) noreturn {
    @branchHint(.cold);
    cpu.disableIrq();
    uart.print("\n\x1b[41m FATAL EXCEPTION \x1b[0m {s}\n", .{why});
    exception.dumpFrame(f);
    halt();
}

pub fn halt() noreturn {
    while (true) cpu.wfi();
}
