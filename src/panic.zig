const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const uart = @import("uart.zig");
const trace = @import("trace.zig");
const symbols = @import("symbols.zig");
const exception = @import("arch/exception.zig");
const qemu = @import("qemu.zig");

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
    if (first_trace_addr) |a| {
        uart.write(" Panic location: ");
        symbols.print(&uart.writer, a);
        uart.write("\n");
    }
    backtrace(@frameAddress());
    trace.dump(&uart.writer, 16);
    halt();
}

fn validFp(fp: usize) bool {
    return fp != 0 and
        fp % 16 == 0 and
        fp >= board.ram_base and
        fp < board.ram_base + board.ram_size;
}

//AAPCS64 frame record: [fp] = the previous fp, [fp+8] = return location (lr)
pub fn backtrace(start_fp: usize) void {
    uart.write("--- backtrace ---\n");
    var fp = start_fp;
    var depth: usize = 0;
    var printed: usize = 0;
    var prev: usize = 0;
    var repeat: usize = 0;

    //Since the chain may be passed from the exception-specific stack to the kernel stack,
    //we do not assume that “addresses increase monotonically.” Instead, we stop at the depth limit.
    while (depth < 4096 and validFp(fp)) : (depth += 1) {
        const rec: *const [2]usize = @ptrFromInt(fp);
        const lr = rec[1];
        if (lr == 0) break;

        //lr stands for “the instruction following the call.” It is calculated by subtracting 4 to point to the line of the calling instruction.
        const pc = lr - 4;
        if (pc == prev) {
            //Group lines together when they are repeated, such as in recursion.
            repeat += 1;
        } else {
            flushRepeat(repeat);
            repeat = 0;
            if (printed < 32) {
                uart.print("  #{d:<4}", .{depth});
                symbols.print(&uart.writer, pc);
                uart.write("\n");
            }
            printed += 1;
            prev = pc;
        }
        if (rec[0] == fp) break;
        fp = rec[0];
    }
    flushRepeat(repeat);
}

fn flushRepeat(n: usize) void {
    if (n > 0) uart.print("(The same line continues for another {d} times)\n", .{n});
}

var exit_tried: bool = false;

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
    if (!exit_tried) {
        exit_tried = true;
        //Terminate QEMU only when building with `-Dsemihosting=true`
        qemu.exit(1);
    }
    while (true) cpu.wfi();
}
