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
const mmu = @import("arch/mmu.zig");
const kheap = @import("kheap.zig");

const heap_size = 32 * 1024 * 1024;

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

    mmu.init();
    std.log.info("MMU has enabled (SCTLR_EL1=0x{x})", .{cpu.read("sctlr_el1")});

    kheap.init(mmu.freeRamStart(), heap_size);
    std.log.info("heap: 0x{x} ~ {d}Mib", .{ mmu.freeRamStart(), heap_size >> 20 });

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

const help_text = "Command: help / brk / udf / align / panic / overflow / bt / trace / deep / irq / tick\n" ++
    "           pt <location|name> / crash <null|wtext|exec|guard>\n" ++
    "           heap / alloc <byte> / list / uaf / dfree\n";

fn run(line: []const u8) void {
    var args = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = args.next() orelse return;
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
        uart.write("It could be read(If MMU is enabled, RAM is treated as normal memory, so it can still be read even if it's misaligned)\n");
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
    } else if (std.mem.eql(u8, cmd, "pt")) {
        const va = parseAddr(args.next()) orelse return uart.write("usage: pt <address:name>\n");
        uart.print("virtual address 0x{x}:\n", .{va});
        mmu.explain(&uart.writer, va);
        if (mmu.probe(va)) |pa| uart.print("CPU (AT S1E1R) answer : physical 0x{x}\n)", .{pa}) else uart.write("CPU (AT S1E1R) answer : Cannot convert\n");
    } else if (std.mem.eql(u8, cmd, "heap")) {
        var it = kheap.heap.iterate();
        while (it.next()) |b| {
            if (!b.used) continue;
            uart.print("0x{x} {d:>7} byte location: ", .{ b.addr, b.req_len });
            symbols.print(&uart.writer, b.ret_addr);
            uart.write("\n");
        }
        const s = kheap.heap.stats();
        uart.print("used {d} block {d} byte / empty {d} block {d} byte (max {d})\n", .{ s.used_blocks, s.used_bytes, s.free_blocks, s.free_bytes, s.largest_free });
    } else if (std.mem.eql(u8, cmd, "alloc")) {
        const n = parseNum(args.next()) orelse return uart.write("usage: alloc <byte>\n");
        const buf = kheap.allocator().alloc(u8, n) catch return uart.write("Not enough\n");
        uart.print("ensure: 0x{x} ({d} byte)\n", .{ @intFromPtr(buf.ptr), buf.len });
    } else if (std.mem.eql(u8, cmd, "list")) {
        listDemo();
    } else if (std.mem.eql(u8, cmd, "uaf")) {
        useAfterFree();
    } else if (std.mem.eql(u8, cmd, "dfree")) {
        const a = kheap.allocator();
        const buf = a.alloc(u8, 100) catch return;
        a.free(buf);
        a.free(buf);
    } else if (std.mem.eql(u8, cmd, "crash")) {
        crash(args.next() orelse "");
    } else {
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

fn parseNum(s: ?[]const u8) ?u64 {
    const t = s orelse return null;
    if (std.mem.startsWith(u8, t, "0x")) return std.fmt.parseInt(u64, t[2..], 16) catch null;
    return std.fmt.parseInt(u64, t, 10) catch null;
}

fn parseAddr(s: ?[]const u8) ?u64 {
    const t = s orelse return null;
    return parseNum(t) orelse symbols.find(t);
}

fn crash(what: []const u8) void {
    if (std.mem.eql(u8, what, "null")) {
        const p: *volatile u64 = @ptrFromInt(8);
        sink = p.*;
    } else if (std.mem.eql(u8, what, "wtext")) {
        // &crash has type *const fn, so @constCast is needed to get a writable pointer type.
        // (This only fools the compiler; the MMU still maps .text as read-only.)
        const p: *volatile u32 = @ptrCast(@alignCast(@constCast(&crash)));
        p.* = 0xd503201f; //nop
    } else if (std.mem.eql(u8, what, "exec")) {
        const f: *const fn () callconv(.c) void = @ptrCast(&code_in_data);
        f();
    } else if (std.mem.eql(u8, what, "guard")) {
        recurse(0);
    } else uart.write("usage: crash <null|wtext|exec|guard>\n");
}

noinline fn recurse(n: u64) void {
    var buf: [512]u8 = undefined;
    buf[n % buf.len] = @truncate(n);
    sink +%= buf[(n * 7) % buf.len];
    recurse(n + 1);
}

// A place to store temporary data. Store the result of a volatile read here so the compiler won't eliminate it.
var sink: u64 = 0;
// For crash exec: Instructions placed in the data area (readable and writable, but not executable)
var code_in_data: [1]u32 align(4) = .{0xd65f03c0}; //ret

fn listDemo() void {
    const a = kheap.allocator();
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(a);
    var last_cap: usize = 0;
    for (0..100) |i| {
        list.append(a, @intCast(i)) catch return uart.write("Not enough\n");
        if (list.capacity != last_cap) {
            uart.print("{d:>3}th item has a size of {d:>3} -> location: 0x{x}\n", .{ i + 1, list.capacity, @intFromPtr(list.items.ptr) });
            last_cap = list.capacity;
        }
    }
    var sum: u64 = 0;
    for (list.items) |x| sum += x;
    uart.print("total {d} (0~99)\n", .{sum});
}

const Point = struct { x: u64, y: u64 };

fn useAfterFree() void {
    const a = kheap.allocator();
    const p = a.create(Point) catch return;
    p.* = .{ .x = 1, .y = 2 };
    uart.print("alloc: 0x{x} x={d} y={d}\n", .{ @intFromPtr(p), p.x, p.y });
    a.destroy(p);
    const q: *volatile Point = p;
    uart.print("after free: x=0x{x} y=0x{x}\n", .{ q.x, q.y });
}

//
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
