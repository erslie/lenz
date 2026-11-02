const cpu = @import("arch/cpu.zig");
const uart = @import("uart.zig");
const exception = @import("arch/exception.zig");

var in_panic: bool = false;

//Called from `pub const panic = std.debug.FullPanic(panic_mod.panicFn);` in `main.zig`
pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    cpu.disableIrq();
    if (in_panic) {
        uart.write("\n!! panic in panic: ");
        uart.write(msg);
        halt();
    }
    in_panic = true;
    uart.print("\n\x1b[41m PANIC \x1b[0m {s}\n", .{msg});
    if (first_trace_addr) |a| uart.print(" Event location: 0x{x}\n", .{a});
    halt();
}

fn rawHex(v: u64) void {
    uart.putc('0');
    uart.putc('x');
    var i: u64 = 60;
    while (true) : (i -= 4) {
        const d: u8 = @truncate((v >> @intCast(i)) & 0xf);
        uart.putc(if (d < 10) '0' + d else 'a' + d - 10);
        if (i == 0) break;
    }
}

pub fn fatalFrame(f: *exception.TrapFrame, why: []const u8) noreturn {
    @branchHint(.cold);
    cpu.disableIrq();
    if (in_panic) {
        uart.write("\n!! Another exception occurred in the middle of the report. ESR=");
        rawHex(f.esr);
        uart.write(" ELR=");
        rawHex(f.elr);
        uart.write(" FAR=");
        rawHex(f.far);
        uart.write("\n");
        halt();
    }
    in_panic = true;
    uart.print("\n\x1b[41m FATAL EXCEPTION \x1b[0m {s}\n", .{why});
    exception.dumpFrame(f);
    halt();
}

pub fn halt() noreturn {
    while (true) cpu.wfi();
}
