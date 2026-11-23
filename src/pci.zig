const std = @import("std");
const board = @import("board.zig").current;

const VENDOR_ID = 0x00;
const DEVICE_ID = 0x02;
const COMMAND = 0x04;
const REVISION_CLASS = 0x08;
const HEADER_TYPE = 0x0e;
const BAR0 = 0x10;
const CAPABILITY_LIST = 0x34;

pub const CMD_MEMORY: u16 = 1 << 1;
pub const CMD_BUS_MASTER: u16 = 1 << 2;

pub const BarKind = enum { none, mem32, mem64, io };
pub const Bar = struct { kind: BarKind = .none, addr: u64 = 0, size: u64 = 0 };

pub const Device = struct {
    bus: u8,
    dev: u5,
    func: u3,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    bars: [6]Bar = @splat(.{}),

    pub fn read32(self: *const Device, off: u12) u32 {
        return cfg(self.bus, self.dev, self.func, off).*;
    }
    pub fn write32(self: *const Device, off: u12, v: u32) void {
        cfg(self.bus, self.dev, self.func, off).* = v;
    }
    pub fn read16(self: *const Device, off: u12) u16 {
        return @truncate(self.read32(off & ~@as(u12, 3)) >> @intCast(8 * (off & 3)));
    }
    pub fn read8(self: *const Device, off: u12) u8 {
        return @truncate(self.read32(off & ~@as(u12, 3)) >> @intCast(8 * (off & 3)));
    }
    // Start of the capability list. 0 if none
    pub fn firstCap(self: *const Device) u8 {
        return self.read8(CAPABILITY_LIST) & 0xfc;
    }
};

fn cfg(bus: u8, dev: u5, func: u3, off: u12) *volatile u32 {
    const p = board.pci.?;
    const a = p.ecam_base + (@as(usize, bus) << 20) + (@as(usize, dev) << 15) + (@as(usize, func) << 12) + (off & ~@as(u12, 3));
    return @ptrFromInt(a);
}

pub var devices: [32]Device = undefined;
pub var count: usize = 0;
// Next address to assign to a BAR (in order from the front of the MMIO window)
var next_mem: u64 = 0;

pub fn scan() void {
    const p = board.pci orelse return;
    next_mem = p.mmio_base;
    count = 0;
    for (0..32) |d| {
        const dev: u5 = @intCast(d);
        if (cfg(0, dev, 0, VENDOR_ID).* & 0xffff == 0xffff) continue;
        const multi = (cfg(0, dev, 0, HEADER_TYPE).* >> 16) & 0x80 != 0;
        for (0..@as(usize, if (multi) 8 else 1)) |f| {
            const func: u3 = @intCast(f);
            const id = cfg(0, dev, func, VENDOR_ID).*;
            if (id & 0xffff == 0xffff) continue;
            if (count == devices.len) return;
            const cls = cfg(0, dev, func, REVISION_CLASS).*;
            devices[count] = .{
                .bus = 0,
                .dev = dev,
                .func = func,
                .vendor = @truncate(id),
                .device = @truncate(id >> 16),
                .class = @truncate(cls >> 24),
                .subclass = @truncate(cls >> 16),
            };
            setupBars(&devices[count]);
            count += 1;
        }
    }
}

fn setupBars(d: *Device) void {
    const p = board.pci.?;
    const cmd = d.read32(COMMAND);
    d.write32(COMMAND, cmd & ~@as(u32, CMD_MEMORY | CMD_BUS_MASTER));
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const off: u12 = @intCast(BAR0 + 4 * i);
        const orig = d.read32(off);
        if (orig & 1 == 1) {
            // 1. Write 0xffff_ffff (all 1s) to the BAR.
            // 2. When you read it back, the “bits that cannot be used as an address” will be returned as 0. For example, for a 16MB BAR, the lower 24 bits will be
            //    0xff00_0000 (the lower 4 bits represent the type, so they are discarded).
            // 3. If you invert that value and add 1, the result is 0x0100_0000.
            d.write32(off, 0xffff_ffff);
            const sz = ~(d.read32(off) & 0xffff_fffc) +% 1;
            d.write32(off, orig);
            if (sz & 0xffff != 0) d.bars[i] = .{ .kind = .io, .size = sz & 0xffff };
            continue;
        }
        const is64 = (orig >> 1) & 3 == 2;
        d.write32(off, 0xffff_ffff);
        var mask: u64 = d.read32(off) & 0xffff_fff0;
        if (is64) {
            d.write32(off + 4, 0xffff_ffff);
            mask |= 0xffff_ffff_0000_0000;
        } else {
            mask |= 0xffff_ffff_0000_0000;
        }
        if (mask & 0xffff_fff0 == 0 and mask >> 32 == 0xffff_ffff) {
            d.write32(off, orig);
            continue;
        }
        const size = ~mask +% 1;
        const addr = std.mem.alignForward(u64, next_mem, size);
        if (addr + size > p.mmio_base + p.mmio_size) {
            std.log.scoped(.pci).warn("{x:0>2}:{x:0>2}.{d} BAR{d} ({d} bytes) does not fit in the window", .{ d.bus, d.dev, d.func, i, size });
            continue;
        }
        next_mem = addr + size;
        d.write32(off, @truncate(addr));
        var mem: BarKind = .mem32;
        if (is64) {
            d.write32(off + 4, @truncate(addr >> 32));
            mem = .mem64;
        }
        d.bars[i] = .{ .kind = mem, .addr = addr, .size = size };
        if (is64) i += 1;
    }
    // I/O space is not used
    d.write32(COMMAND, (cmd & ~@as(u32, 1)) | CMD_MEMORY | CMD_BUS_MASTER);
}

pub fn find(vendor: u16, device: u16) ?*Device {
    for (devices[0..count]) |*d| {
        if (d.vendor == vendor and d.device == device) return d;
    }
    return null;
}

pub fn name(d: *const Device) []const u8 {
    return switch (@as(u32, d.vendor) << 16 | d.device) {
        0x1b36_0008 => "QEMU PCIe host bridge",
        0x1234_1111 => "bochs-display (screen)",
        0x1af4_1000 => "virtio-net (transitional ID: supports both legacy and modern)",
        0x1af4_1041 => "virtio-net",
        0x1b36_000d => "qemu-xhci (USB)",
        else => "?",
    };
}

pub fn dump(w: *std.Io.Writer) void {
    for (devices[0..count]) |*d| {
        w.print("   {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} class {x:0>2}.{x:0>2}   {s}\n", .{ d.bus, d.dev, d.func, d.vendor, d.device, d.class, d.subclass, name(d) }) catch {};
        for (d.bars, 0..) |b, i| {
            switch (b.kind) {
                .none => {},
                .io => w.print("        BAR{d} I/O space {d} bytes (unused)\n", .{ i, b.size }) catch {},
                else => w.print("        BAR{d} {s} 0x{x} - 0x{x} ({d} KiB)\n", .{ i, @tagName(b.kind), b.addr, b.addr + b.size - 1, b.size / 1024 }) catch {},
            }
        }
    }
}
