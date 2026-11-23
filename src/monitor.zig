const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const mmu = @import("arch/mmu.zig");
const gic = @import("arch/gic.zig");
const timer = @import("arch/timer.zig");
const uart = @import("uart.zig");
const trace = @import("trace.zig");
const symbols = @import("symbols.zig");
const panic_mod = @import("panic.zig");
const kheap = @import("kheap.zig");
const sched = @import("sched.zig");
const debug = @import("arch/debug.zig");
const pci = @import("pci.zig");

// rx buffer
var rx: [256]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

pub fn onUartIrq(_: u32) void {
    while (uart.getc()) |c| {
        if (rx_head - rx_tail < rx.len) {
            rx[rx_head % rx.len] = c;
            rx_head += 1;
        }
    }
    uart.ackIrq();
}

fn readChar() ?u8 {
    cpu.disableIrq();
    defer cpu.enableIrq();
    if (rx_tail == rx_head) return null;
    const c = rx[rx_tail % rx.len];
    rx_tail += 1;
    return c;
}

var line: [128]u8 = undefined;
var line_len: usize = 0;

pub fn prompt() void {
    uart.write("lenz> ");
}

pub fn poll() void {
    while (readChar()) |c| switch (c) {
        '\r', '\n' => {
            uart.write("\n");
            execute(line[0..line_len]);
            line_len = 0;
            prompt();
        },
        0x7f, 0x08 => if (line_len > 0) {
            line_len -= 1;
            uart.write("\x08 \x08");
        },
        else => if (c >= 0x20 and line_len < line.len) {
            line[line_len] = c;
            line_len += 1;
            uart.putc(c);
        },
    };
}

const Command = struct { name: []const u8, help: []const u8, run: *const fn (args: *std.mem.TokenIterator(u8, .scalar)) void };

const commands = [_]Command{
    .{ .name = "help", .help = "commands", .run = cmdHelp },
    .{ .name = "info", .help = "board,EL,Active Time,About Heap", .run = cmdInfo },
    .{ .name = "x", .help = "x <address> [bytes] hexdump of memory", .run = cmdDump },
    .{ .name = "pt", .help = "pt <address> how the page table is walked, and the CPU's translation result", .run = cmdPt },
    .{ .name = "sym", .help = "sym <address|function> address <-> function", .run = cmdSym },
    .{ .name = "trace", .help = "trace [count] record of recent events", .run = cmdTrace },
    .{ .name = "lspci", .help = "list of PCI devices and assigned BARs", .run = cmdLspci },
    .{ .name = "irq", .help = "interrupt counts", .run = cmdIrq },
    .{ .name = "heap", .help = "heap usage and allocated blocks (who allocated them)", .run = cmdHeap },
    .{ .name = "tasks", .help = "list of tasks (state, switches, max stack used)", .run = cmdTasks },
    .{ .name = "bt", .help = "current backtrace", .run = cmdBt },
    .{ .name = "brk", .help = "stop at a BRK instruction, show registers, then resume", .run = cmdBrk },
    .{ .name = "watch", .help = "watch <address|var> [w|r|rw] report the culprit the moment it writes/reads (CPU watchpoint)", .run = cmdWatch },
    .{ .name = "unwatch", .help = "remove the watchpoint", .run = cmdUnwatch },
    .{ .name = "hbreak", .help = "hbreak <address|function> stop right before that instruction and report (CPU breakpoint)", .run = cmdHbreak },
    .{ .name = "unbreak", .help = "remove the breakpoint", .run = cmdUnbreak },
    .{ .name = "dbg", .help = "debug feature state", .run = cmdDbg },
    .{ .name = "uaf", .help = "try reading freed memory (use-after-free) and see what shows up", .run = cmdUaf },
    .{ .name = "dfree", .help = "free the same memory twice (test double-free detection)", .run = cmdDoubleFree },
    .{ .name = "hog", .help = "hog the CPU for 1.5 s without yielding (watchdog check)", .run = cmdHog },
    .{ .name = "crash", .help = "crash <null|wtext|exec|guard|panic|overflow> crash on purpose to check the report", .run = cmdCrash },
};

fn execute(l: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, l, ' ');
    const name = it.next() orelse return;
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.run(&it);
    }
    uart.print("unknown command: {s} (help for a list)\n", .{name});
}

fn parseNum(s: ?[]const u8) ?u64 {
    const t = s orelse return null;
    return std.fmt.parseInt(u64, t, 0) catch null;
}

fn parseAddr(s: ?[]const u8) ?u64 {
    const t = s orelse return null;
    return parseNum(t) orelse symbols.find(t);
}

fn cmdHelp(_: *std.mem.TokenIterator(u8, .scalar)) void {
    for (commands) |c| uart.print("{s:<6} {s}\n", .{ c.name, c.help });
}

fn cmdInfo(_: *std.mem.TokenIterator(u8, .scalar)) void {
    const up_ms = cpu.ticksToNs(cpu.ticks()) / 1_000_000;
    uart.print("board={s} EL{d} uptime={d}.{d:0>3}s ticks={d} symbols={d} trace={d}\n", .{ board.name, cpu.currentEl(), up_ms / 1000, up_ms % 1000, timer.tick_count, symbols.count(), trace.count() });
    const s = kheap.heap.stats();
    uart.print("heap: used {d} blocks {d} bytes / free {d} blocks {d} bytes (largest {d})\n", .{ s.used_blocks, s.used_bytes, s.free_blocks, s.free_bytes, s.largest_free });
}

fn cmdDump(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const start = parseAddr(args.next()) orelse return uart.write("usage: x <addr> [bytes]\n");
    const len = @min(parseNum(args.next()) orelse 64, 4096);
    var a = start & ~@as(u64, 15);
    const end = start +| len;
    while (a < end) : (a +|= 16) {
        if (mmu.probe(a) == null) {
            uart.print("0x{x:0>16}: (address not in the map. Reading it would fault, so not reading)\n", .{a});
            return;
        }
        const p: [*]const volatile u8 = @ptrFromInt(a);
        uart.print("0x{x:0>16}: ", .{a});
        for (0..16) |i| uart.print("{x:0>2}{s}", .{ p[i], if (i == 7) "  " else " " });
        uart.write(" |");
        for (0..16) |i| {
            const c = p[i];
            uart.putc(if (c >= 0x20 and c < 0x7f) c else '.');
        }
        uart.write("|\n");
    }
}

fn cmdPt(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const va = parseAddr(args.next()) orelse return uart.write("usage: pt <address>\n");
    uart.print("walking virtual address 0x{x} through the tables:\n", .{va});
    mmu.explain(&uart.writer, va);
    if (mmu.probe(va)) |pa| uart.print("CPU (AT S1E1R) answer: phys 0x{x}\n", .{pa}) else uart.write("CPU (AT S1E1R) answer: cannot translate\n");
}

fn cmdSym(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const t = args.next() orelse return uart.write("usage: sym <address|function>\n");
    if (parseNum(t)) |a| {
        symbols.print(&uart.writer, a);
        uart.write("\n");
    } else if (symbols.find(t)) |a| {
        uart.print("{s} = 0x{x}\n", .{ t, a });
    } else uart.write("not found\n");
}

fn cmdTrace(args: *std.mem.TokenIterator(u8, .scalar)) void {
    trace.dump(&uart.writer, parseNum(args.next()) orelse 20);
}

fn cmdLspci(_: *std.mem.TokenIterator(u8, .scalar)) void {
    if (board.pci == null) return uart.write("this board does not handle PCI\n");
    pci.dump(&uart.writer);
}

fn cmdIrq(_: *std.mem.TokenIterator(u8, .scalar)) void {
    for (gic.counts, 0..) |n, id| {
        if (n != 0) uart.print("INTID {d:>3}: {d} times{s}\n", .{ id, n, if (id == timer.intid) " (timer)" else if (id == board.uart_irq) " (UART)" else "" });
    }
}

fn cmdHeap(_: *std.mem.TokenIterator(u8, .scalar)) void {
    var it = kheap.heap.iterate();
    var shown: usize = 0;
    while (it.next()) |b| {
        if (!b.used) continue;
        if (shown == 32) {
            uart.write(" ... (rest omitted)\n");
            break;
        }
        uart.print("0x{x} {d:>7} bytes allocated at: ", .{ b.addr, b.req_len });
        symbols.print(&uart.writer, b.ret_addr);
        uart.write("\n");
        shown += 1;
    }
    cmdInfo(undefined);
}

fn cmdWatch(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const a = parseAddr(args.next()) orelse return uart.write("usage: watch <address|var> [w|r|rw]\n");
    if (mmu.probe(a) == null) return uart.write("address not in the map, so it cannot be watched\n");
    const k = args.next() orelse "w";
    const kind: debug.Kind = if (std.mem.eql(u8, k, "r")) .load else if (std.mem.eql(u8, k, "rw")) .both else .store;
    debug.watch(a, kind);
    uart.print("watching 0x{x} ({s})\n", .{ a & ~@as(u64, 7), @tagName(kind) });
}

fn cmdUnwatch(_: *std.mem.TokenIterator(u8, .scalar)) void {
    debug.unwatch();
}

fn cmdHbreak(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const a = parseAddr(args.next()) orelse return uart.write("usage: hbreak <address|function>\n");
    debug.hbreak(a);
    uart.write("breakpoint: ");
    symbols.print(&uart.writer, a);
    uart.write("\n");
}

fn cmdUnbreak(_: *std.mem.TokenIterator(u8, .scalar)) void {
    debug.unbreak();
}

fn cmdDbg(_: *std.mem.TokenIterator(u8, .scalar)) void {
    debug.status(&uart.writer);
}

const Point = struct { x: u64, y: u64 };

fn cmdUaf(_: *std.mem.TokenIterator(u8, .scalar)) void {
    const a = kheap.allocator();
    const p = a.create(Point) catch return;
    p.* = .{ .x = 1, .y = 2 };
    uart.print("allocated: 0x{x} x={d} y={d}\n", .{ @intFromPtr(p), p.x, p.y });
    a.destroy(p);
    const q: *volatile Point = p;
    uart.print("read after free: x=0x{x} y=0x{x}\n", .{ q.x, q.y });
}

fn cmdDoubleFree(_: *std.mem.TokenIterator(u8, .scalar)) void {
    const a = kheap.allocator();
    const buf = a.alloc(u8, 100) catch return;
    a.free(buf);
    // Second time: the heap should notice and stop
    a.free(buf);
}

fn cmdTasks(_: *std.mem.TokenIterator(u8, .scalar)) void {
    sched.dump(&uart.writer);
}

fn cmdHog(_: *std.mem.TokenIterator(u8, .scalar)) void {
    const end = cpu.ticks() + cpu.read("cntfrq_el0") * 3 / 2;
    while (cpu.ticks() < end) {}
    uart.write("hog: done\n");
}

fn cmdBt(_: *std.mem.TokenIterator(u8, .scalar)) void {
    panic_mod.backtrace(@frameAddress());
}

fn cmdBrk(_: *std.mem.TokenIterator(u8, .scalar)) void {
    asm volatile ("brk #1");
}

var sink: u64 = 0;

fn cmdCrash(args: *std.mem.TokenIterator(u8, .scalar)) void {
    const what = args.next() orelse return uart.write("usage: crash <null|wtext|exec|guard|panic|overflow>\n");
    if (std.mem.eql(u8, what, "null")) {
        const p: *volatile u64 = @ptrFromInt(8);
        sink = p.*;
    } else if (std.mem.eql(u8, what, "wtext")) {
        // Write to our own code (read-only)
        // A function pointer is const (assumed not writable), so the type also needs @constCast
        const p: *volatile u32 = @ptrCast(@alignCast(@constCast(&cmdCrash)));
        // nop
        p.* = 0xd503201f;
    } else if (std.mem.eql(u8, what, "exec")) {
        // Execute instructions placed on the heap (not executable)
        const code = kheap.allocator().alloc(u32, 1) catch return;
        // ret
        code[0] = 0xd65f03c0;
        const f: *const fn () callconv(.c) void = @ptrCast(code.ptr);
        f();
    } else if (std.mem.eql(u8, what, "guard")) {
        recurse(0);
    } else if (std.mem.eql(u8, what, "panic")) {
        @panic("panic requested from the monitor");
    } else if (std.mem.eql(u8, what, "overflow")) {
        // Zig safety check: integer overflow is a panic, not undefined behavior (Debug/ReleaseSafe)
        var x: u8 = 250;
        x += @truncate(timer.tick_count | 10);
        sink = x;
    } else uart.write("unknown type\n");
}

noinline fn recurse(n: u64) void {
    var buf: [512]u8 = undefined;
    buf[n % buf.len] = @truncate(n);
    sink +%= buf[(n * 7) % buf.len];
    recurse(n + 1);
}
