const std = @import("std");
const board = @import("../board.zig").current;
const cpu = @import("cpu.zig");

//https://github.com/torvalds/linux/blob/05441d697f7f9a927264f4058cbbc6a03dfcac9d/arch/arm64/include/asm/pgtable-hwdef.h#L162
pub const Desc = packed struct(u64) {
    valid: bool = false,
    kind: u1 = 0,
    attr_index: u3 = 0,
    ns: u1 = 0,
    el0: bool = false,
    read_only: bool = false,
    sh: u2 = 0,
    af: bool = false,
    ng: bool = false,
    addr: u36 = 0,
    _res0: u4 = 0,
    contiguous: bool = false,
    pxn: bool = false,
    uxn: bool = false,
    _sw: u9 = 0,

    pub fn phys(d: Desc) u64 {
        return @as(u64, d.addr) << 12;
    }
};

comptime {
    std.debug.assert(@bitOffsetOf(Desc, "attr_index") == 2);
    std.debug.assert(@bitOffsetOf(Desc, "af") == 10);
    std.debug.assert(@bitOffsetOf(Desc, "addr") == 12);
    std.debug.assert(@bitOffsetOf(Desc, "pxn") == 53);
    std.debug.assert(@bitOffsetOf(Desc, "uxn") == 54);
}

const MAIR_DEVICE_nGnRnE: u64 = 0x00;
const MAIR_NORMAL_WB: u64 = 0xff;
const IDX_DEVICE = 0;
const IDX_NORMAL = 1;

pub const Attr = enum { text, rodata, data, device };

fn leaf(attr: Attr, pa: u64, level: u2) Desc {
    var d: Desc = .{ .valid = true, .kind = if (level == 3) 1 else 0, .af = true, .addr = @intCast(pa >> 12) };
    switch (attr) {
        .text => {
            d.attr_index = IDX_NORMAL;
            d.sh = 3;
            d.read_only = true;
            d.uxn = true;
        },
        .rodata => {
            d.attr_index = IDX_NORMAL;
            d.sh = 3;
            d.read_only = true;
            d.pxn = true;
            d.uxn = true;
        },
        .data => {
            d.attr_index = IDX_NORMAL;
            d.sh = 3;
            d.pxn = true;
            d.uxn = true;
        },
        .device => {
            d.attr_index = IDX_DEVICE;
            d.pxn = true;
            d.uxn = true;
        },
    }
    return d;
}

const Table = [512]Desc;
var pool: [64]Table align(4096) = undefined;
var pool_used: usize = 0;
var root: *Table = undefined;

fn newTable() *Table {
    if (pool_used == pool.len) @panic("There is not enough space for the page table.");
    const t = &pool[pool_used];
    pool_used += 1;
    t.* = @splat(.{});
    return t;
}

inline fn shift(level: u2) u6 {
    return 12 + 9 * @as(u6, 3 - level);
}
inline fn index(va: u64, level: u2) usize {
    return @intCast((va >> shift(level)) & 511);
}

pub fn map(va_start: u64, pa_start: u64, size: u64, attr: Attr) void {
    var va = va_start;
    var pa = pa_start;
    const end = va_start + size;
    while (va < end) {
        var level: u2 = 1;
        while (level < 3) : (level += 1) {
            const bs = @as(u64, 1) << shift(level);
            if (va % bs == 0 and pa % bs == 0 and end - va >= bs) break;
        }
        var t = root;
        var l: u2 = 1;
        while (l < level) : (l += 1) {
            const e = &t[index(va, l)];
            if (!e.valid) {
                const nt = newTable();
                e.* = .{ .valid = true, .kind = 1, .addr = @intCast(@intFromPtr(nt) >> 12) };
            } else if (e.kind != 1) {
                std.debug.panic("0x{x} has already been mapped to a larger block", .{va});
            }
            t = @ptrFromInt(e.phys());
        }
        t[index(va, level)] = leaf(attr, pa, level);
        const bs = @as(u64, 1) << shift(level);
        va += bs;
        pa += bs;
    }
}

extern const __kernel_start: u8;
extern const __text_end: u8;
extern const __rodata_end: u8;
extern const __stack_guard: u8;
extern const __stack_bottom: u8;
extern const __stack_top: u8;
extern const __exc_stack_guard: u8;
extern const __exc_stack_bottom: u8;
extern const __exc_stack_top: u8;
extern const __kernel_end: u8;

fn addr(sym: *const u8) u64 {
    return @intFromPtr(sym);
}

pub fn freeRamStart() u64 {
    return addr(&__kernel_end);
}

pub fn guardOwner(far: u64) ?[]const u8 {
    if (far >= stackGuard() and far < stackGuard() + 4096) return "Stack at Startup";
    if (far >= addr(&__exc_stack_guard) and far < addr(&__exc_stack_guard) + 4096) return "Exception-Only Stack";
    return null;
}

pub fn stackGuard() u64 {
    return addr(&__stack_guard);
}

pub fn init() void {
    root = newTable();
    const ram_end = board.ram_base + board.ram_size;
    const ram_lo = if (board.ram_base == 0) 4096 else board.ram_base;

    for (board.mmio) |r| map(r.base, r.base, r.size, .device);

    map(ram_lo, ram_lo, addr(&__kernel_start) - ram_lo, .data);
    map(addr(&__kernel_start), addr(&__kernel_start), addr(&__text_end) - addr(&__kernel_start), .text);
    map(addr(&__text_end), addr(&__text_end), addr(&__rodata_end) - addr(&__text_end), .rodata);
    map(addr(&__rodata_end), addr(&__rodata_end), addr(&__stack_guard) - addr(&__rodata_end), .data);
    map(addr(&__stack_bottom), addr(&__stack_bottom), addr(&__stack_top) - addr(&__stack_bottom), .data);
    map(addr(&__exc_stack_bottom), addr(&__exc_stack_bottom), addr(&__exc_stack_top) - addr(&__exc_stack_bottom), .data);
    map(addr(&__exc_stack_top), addr(&__exc_stack_top), addr(&__kernel_end) - addr(&__exc_stack_top), .rodata);
    map(addr(&__kernel_end), addr(&__kernel_end), ram_end - addr(&__kernel_end), .data);

    cpu.write("mair_el1", (MAIR_DEVICE_nGnRnE << (8 * IDX_DEVICE)) | (MAIR_NORMAL_WB << (8 * IDX_NORMAL)));

    const parange: u64 = @min(cpu.read("id_aa64mmfr0_el1") & 0xf, 0b0101);
    const tcr: u64 = 25 | (1 << 8) | (1 << 10) | (3 << 12) | (0 << 14) | (1 << 23) | (parange << 32);
    cpu.write("tcr_el1", tcr);
    cpu.write("ttbr0_el1", @intFromPtr(root));
    cpu.dsbSy();
    cpu.isb();

    var sctlr = cpu.read("sctlr_el1");
    sctlr |= (1 << 0) | (1 << 2) | (1 << 3) | (1 << 12);
    cpu.write("sctlr_el1", sctlr);
    cpu.isb();
}

// AT S1E1R: Ask the CPU itself, “Can this address be read from EL1?”
// The result is stored in PAR_EL1; if bit 0 (F) is 1, the conversion failed.
pub fn probe(va: u64) ?u64 {
    asm volatile ("at s1e1r, %[va]"
        :
        : [va] "r" (va),
        : .{ .memory = true });
    cpu.isb();
    const par = cpu.read("par_el1");
    if (par & 1 != 0) return null;
    return (par & 0x0000_ffff_ffff_f000) | (va & 0xfff);
}

pub fn explain(w: *std.Io.Writer, va: u64) void {
    var t = root;
    var level: u2 = 1;
    while (true) : (level += 1) {
        const i = index(va, level);
        const d = t[i];
        w.print(" L{d}[{d:>3}] @0x{x} = 0x{x:0>16}", .{ level, i, @intFromPtr(&t[i]), @as(u64, @bitCast(d)) }) catch {};
        if (!d.valid) {
            w.print(" -> invalid (not found in this map)\n", .{}) catch {};
            return;
        }
        if (level < 3 and d.kind == 1) {
            w.print(" -> next table 0x{x}\n", .{d.phys()}) catch {};
            t = @ptrFromInt(d.phys());
            continue;
        }
        const bs = @as(u64, 1) << shift(level);
        w.print("\n -> {s} 0x{x} ({s}{s}{s}{s})\n", .{
            if (level == 3) "4KB page" else if (level == 2) "2MB block" else "1GB block",
            d.phys() + (va & (bs - 1)),
            if (d.attr_index == IDX_DEVICE) "Device" else "Normal",
            if (d.read_only) " readOnly" else " readWrite",
            if (d.pxn) " unexecutable" else " executable",
            if (d.af) "" else " AF=0",
        }) catch {};
        return;
    }
}
