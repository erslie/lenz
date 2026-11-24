const std = @import("std");
const board = @import("board.zig").current;
const cpu = @import("arch/cpu.zig");
const gic = @import("arch/gic.zig");
const timer = @import("arch/timer.zig");
const display = @import("display.zig");
const sched = @import("sched.zig");
const kheap = @import("kheap.zig");

// Pastel theme: pale lavender + pale sky blue
const bg = 0xf3effa; // background: very pale lavender
const fg = 0x3a3550; // text: dark purple-gray (readable on pale bg)
const accent = 0x8a7fd0; // headings and bar fill: lavender
const bar_bg = 0xd8eaf6; // empty part of bars: pale sky blue
const warn = 0xe8909c; // bar above 80%: soft rose
const header_bg = 0xbfe3f2; // top bar: light aqua
const header_fg = 0x3a3550; // top bar text

pub fn task(_: usize) void {
    display.fill(0, 0, display.width, display.height, bg);
    while (true) {
        draw();
        sched.sleepMs(500);
    }
}

// Bar graph with used out of max filled. Change color above 80%
fn bar(x: usize, y: usize, w: usize, used: u64, max: u64) void {
    const filled: usize = if (max == 0) 0 else @intCast(@min(used, max) * w / max);
    display.fill(x, y, w, 12, bar_bg);
    display.fill(x, y, filled, 12, if (used * 10 > max * 8) warn else accent);
}

fn draw() void {
    const s = 2;
    display.fill(0, 0, display.width, 40, header_bg);
    display.print(16, 12, header_fg, s, "LENZ: {s}", .{board.name});
    const ms = cpu.ticksToNs(cpu.ticks()) / 1_000_000;
    display.fill(400, 12, 230, 16, header_bg);
    display.print(400, 12, header_fg, s, "UP {d}.{d}S", .{ ms / 1000, (ms % 1000) / 100 });

    var y: usize = 56;
    display.fill(0, y, display.width, 24 + 20 * 16, bg);
    display.text(16, y, "TASKS", accent, s);
    y += 24;
    for (sched.list()) |*t| {
        display.print(16, y, fg, s, "{d} {s}", .{ t.id, t.name });
        display.text(176, y, @tagName(t.state), fg, s);
        if (t.stack.len != 0) {
            const used = sched.stackUsed(t);
            bar(296, y + 2, 200, used, t.stack.len);
            display.print(512, y, fg, s, "{d}K", .{(used + 1023) / 1024});
        }
        y += 20;
    }

    // Heap
    y += 12;
    const hs = kheap.heap.stats();
    const total = hs.used_bytes + hs.free_bytes;
    display.fill(0, y, display.width, 44, bg);
    display.text(16, y, "HEAP", accent, s);
    display.print(176, y, fg, s, "{d} BLOCKS {d}K", .{ hs.used_blocks, hs.used_bytes / 1024 });
    bar(16, y + 24, 608, hs.used_bytes, total);
    y += 56;

    display.fill(0, y, display.width, 80, bg);
    display.text(16, y, "IRQ", accent, s);
    y += 24;
    for (gic.counts, 0..) |n, id| {
        if (n == 0) continue;
        display.print(16, y, fg, s, "INTID {d}", .{id});
        display.print(176, y, fg, s, "{d}", .{n});
        display.text(320, y, if (id == timer.intid) "TIMER" else if (id == board.uart_irq) "UART" else "", fg, s);
        y += 20;
    }
}
