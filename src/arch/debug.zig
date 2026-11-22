const std = @import("std");
const cpu = @import("cpu.zig");
const exception = @import("exception.zig");
const uart = @import("../uart.zig");
const trace = @import("../trace.zig");
const symbols = @import("../symbols.zig");

// Software step
const MDSCR_SS: u64 = 1 << 0;
// Allow debug exceptions to EL1 itself
const MDSCR_KDE: u64 = 1 << 13;
// Enable breakpoints/watchpoints
const MDSCR_MDE: u64 = 1 << 15;
const SPSR_SS: u64 = 1 << 21;
const SPSR_I: u64 = 1 << 7;

pub const Kind = enum(u2) { load = 1, store = 2, both = 3 };

// Contents of DBGWCR / DBGBCR
fn ctrl(len_bas: u8, kind: u2) u64 {
    return (@as(u64, len_bas) << 5) // BAS: which bytes to watch
    | (@as(u64, kind) << 3) // LSC: read/write (0 for breakpoints)
    | (1 << 1) // PAC/PMC = 0b01: EL1 accesses only
    | 1; // E: enabled
}

var wp_addr: u64 = 0;
var wp_kind: Kind = .store;
var wp_active = false;
var wp_old_value: u64 = 0;
var bp_active = false;
var bp_addr: u64 = 0;
// Cleanup while stepping
var stepping: enum { none, rearm_wp, rearm_bp } = .none;
var saved_irq_masked = false;
pub var hits: u64 = 0;

pub fn init() void {
    cpu.write("osdlr_el1", 0);
    cpu.write("oslar_el1", 0);
    cpu.isb();
    cpu.write("mdscr_el1", cpu.read("mdscr_el1") | MDSCR_MDE | MDSCR_KDE);
    asm volatile ("msr daifclr, #8" ::: .{ .memory = true });
    cpu.isb();
    exception.debug_hook = &onDebug;
}

pub fn watch(addr: u64, kind: Kind) void {
    wp_addr = addr & ~@as(u64, 7);
    wp_kind = kind;
    wp_old_value = @as(*const volatile u64, @ptrFromInt(wp_addr)).*;
    armWatch();
    wp_active = true;
}

pub fn unwatch() void {
    cpu.write("dbgwcr0_el1", 0);
    cpu.isb();
    wp_active = false;
}

fn armWatch() void {
    cpu.write("dbgwvr0_el1", wp_addr);
    cpu.write("dbgwcr0_el1", ctrl(0xff, @intFromEnum(wp_kind)));
    cpu.isb();
}

pub fn hbreak(addr: u64) void {
    bp_addr = addr;
    cpu.write("dbgbvr0_el1", addr);
    cpu.write("dbgbcr0_el1", ctrl(0xf, 0)); // AArch64 instructions are 4 bytes, so BAS=0b1111
    cpu.isb();
    bp_active = true;
}

pub fn unbreak() void {
    cpu.write("dbgbcr0_el1", 0);
    cpu.isb();
    bp_active = false;
}

// Set it up to advance one instruction and come back
fn stepOnce(f: *exception.TrapFrame, then: @TypeOf(stepping)) void {
    stepping = then;
    saved_irq_masked = f.spsr & SPSR_I != 0;
    f.spsr |= SPSR_SS | SPSR_I;
    cpu.write("mdscr_el1", cpu.read("mdscr_el1") | MDSCR_SS);
}

fn onDebug(f: *exception.TrapFrame, ec: exception.Ec) bool {
    switch (ec) {
        .watchpt_cur => {
            hits += 1;
            trace.record(.watch, f.far, f.elr, "watchpoint");
            uart.print("\n[watch] 0x{x}: detected a {s} (FAR=0x{x})\n   culprit: ", .{ wp_addr, if ((f.esr >> 6) & 1 == 1) "write" else "read", f.far });
            symbols.print(&uart.writer, f.elr);
            uart.print("\n  caller: ", .{});
            symbols.print(&uart.writer, f.x[30] -% 4);
            uart.print("\n  value (before): 0x{x}\n", .{wp_old_value});
            cpu.write("dbgwcr0_el1", 0);
            stepOnce(f, .rearm_wp);
            return true;
        },
        .breakpt_cur => {
            hits += 1;
            trace.record(.watch, f.elr, 0, "breakpoint");
            uart.print("\n[hbreak] ", .{});
            symbols.print(&uart.writer, f.elr);
            uart.print("    x0=0x{x} x1=0x{x} x2=0x{x} lr=", .{ f.x[0], f.x[1], f.x[2] });
            symbols.print(&uart.writer, f.x[30] -% 4);
            uart.write("\n");
            cpu.write("dbgbcr0_el1", 0);
            stepOnce(f, .rearm_bp);
            return true;
        },
        .softstep_cur => {
            cpu.write("mdscr_el1", cpu.read("mdscr_el1") & ~MDSCR_SS);
            f.spsr &= ~SPSR_SS;
            if (!saved_irq_masked) f.spsr &= ~SPSR_I;
            switch (stepping) {
                .rearm_wp => {
                    const now = @as(*const volatile u64, @ptrFromInt(wp_addr)).*;
                    uart.print("    value (after): 0x{x}\n", .{now});
                    wp_old_value = now;
                    if (wp_active) armWatch();
                },
                .rearm_bp => if (bp_active) hbreak(bp_addr),
                .none => {},
            }
            stepping = .none;
            return true;
        },
        else => return false,
    }
}

pub fn status(w: *std.Io.Writer) void {
    w.print("   OSLSR_EL1=0x{x} MDSCR_EL1=0x{x} hits {d}\n", .{ cpu.read("oslsr_el1"), cpu.read("mdscr_el1"), hits }) catch {};
    if (wp_active) w.print("    watch  0x{x} ({s})\n", .{ wp_addr, @tagName(wp_kind) }) catch {};
    if (bp_active) {
        w.print("   hbreak ", .{}) catch {};
        symbols.print(w, bp_addr);
        w.print("\n", .{}) catch {};
    }
}
