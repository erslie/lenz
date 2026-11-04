const std = @import("std");
const cpu = @import("arch/cpu.zig");

pub const Kind = enum(u8) { log, exception, irq, task_switch, watch, mark };

pub const Event = struct {
    t: u64,
    kind: Kind,
    a: u64,
    b: u64,
    text: []const u8,
};

const N = 512;
var ring: [N]Event = undefined;
var head: u64 = 0;

pub fn record(kind: Kind, a: u64, b: u64, text: []const u8) void {
    const was_on = cpu.irqEnabled();
    cpu.disableIrq();
    defer if (was_on) cpu.enableIrq();
    ring[head % N] = .{ .t = cpu.ticks(), .kind = kind, .a = a, .b = b, .text = text };
    head += 1;
}

pub fn count() u64 {
    return head;
}

pub fn recent(max: usize, out: []Event) []Event {
    const avail: usize = @intCast(@min(head, N));
    const n = @min(max, avail, out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        out[i] = ring[(head - n + i) % N];
    }
    return out[0..n];
}

pub fn dump(w: *std.Io.Writer, max: usize) void {
    var buf: [64]Event = undefined;
    const evs = recent(max, &buf);
    w.print("--- trace ({d}/{d}) ---\n", .{ evs.len, head }) catch {};
    for (evs) |e| {
        const us = cpu.ticksToNs(e.t) / 1000;
        w.print("{d:>10}us {s:<11} a=0x{x:<12} b=0x{x:8} {s}\n", .{ us, @tagName(e.kind), e.a, e.b, firstLine(e.text) }) catch {};
    }
}

fn firstLine(s: []const u8) []const u8 {
    var end = @min(std.mem.findScalar(u8, s, '\n') orelse s.len, 48);
    while (end < s.len and end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}
