//GICv2 (GIC-400)
//https://github.com/torvalds/linux/blob/v6.12/include/linux/irqchip/arm-gic.h

const std = @import("std");
const board = @import("../board.zig").current;
const exception = @import("exception.zig");
const trace = @import("../trace.zig");

const GICD_CTLR = 0x000;
const GICD_ISENABLER = 0x100;
const GICD_IPRIORITYR = 0x400;
const GICD_ITARGETSR = 0x800;

const GICC_CTLR = 0x00;
const GICC_PMR = 0x04;
const GICC_IAR = 0x0c;
const GICC_EOIR = 0x10;
const SPURIOUS = 1023;

fn d32(off: usize) *volatile u32 {
    return @ptrFromInt(board.gicd_base + off);
}
fn d8(off: usize) *volatile u8 {
    return @ptrFromInt(board.gicd_base + off);
}
fn c32(off: usize) *volatile u32 {
    return @ptrFromInt(board.gicc_base + off);
}

pub const Handler = *const fn (intid: u32) void;
const max_irq = 512;
var handlers: [max_irq]?Handler = @splat(null);
pub var counts: [max_irq]u64 = @splat(0);

pub fn init() void {
    d32(GICD_CTLR).* = 0;
    c32(GICC_PMR).* = 0xf0;
    c32(GICC_CTLR).* = 1;
    d32(GICD_CTLR).* = 1;
    exception.irq_handler = &dispatch;
}

pub fn enable(intid: u32, h: Handler) void {
    handlers[intid] = h;
    d8(GICD_IPRIORITYR + intid).* = 0xa0;
    if (intid >= 32) d8(GICD_ITARGETSR + intid).* = 1;
    d32(GICD_ISENABLER + (intid / 32) * 4).* = @as(u32, 1) << @intCast(intid % 32);
}

fn dispatch(_: *exception.TrapFrame) void {
    const iar = c32(GICC_IAR).*;
    const intid = iar & 0x3ff;
    if (intid == SPURIOUS) return;
    counts[intid] += 1;
    trace.record(.irq, intid, counts[intid], "");
    if (handlers[intid]) |h| h(intid) else std.log.warn("Unregistered Interrupts: {d}", .{intid});
    c32(GICC_EOIR).* = iar;
}
