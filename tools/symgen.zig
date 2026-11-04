// Why not use std.elf? While the ELF format is fixed by the specification, the API of Zig’s standard library changes
// with each version. Since symgen is a tool that runs during every build, we want to minimize the number of places that could break
// when upgrading Zig. Therefore, we directly read the fixed offsets specified in the specification
// (64 bytes for section headers and 24 bytes for symbols).
const std = @import("std");

const Section = struct {
    name: u32,
    typ: u32,
    flags: u64,
    addr: u64,
    offset: u64,
    size: u64,
    link: u32,
};

const Sym = struct {
    addr: u64,
    size: u64,
    name: []const u8,
};

const SHT_SYMTAB = 2;
const STT_NOTYPE = 0;
const STT_OBJECT = 1;
const STT_FUNC = 2;
const SHF_EXECINSTR = 0x4;

fn rd(comptime T: type, buf: []const u8, off: usize) T {
    return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
}

fn sections(gpa: std.mem.Allocator, elf: []const u8) ![]Section {
    if (!std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2 or elf[5] != 1)
        return error.NotElf64LittleEndian;

    const shoff = rd(u64, elf, 0x28);
    const shentsize = rd(u16, elf, 0x3a);
    const shnum = rd(u16, elf, 0x3c);
    const out = try gpa.alloc(Section, shnum);

    for (out, 0..) |*s, i| {
        const b = shoff + i * shentsize;
        s.* = .{
            .name = rd(u32, elf, b + 0),
            .typ = rd(u32, elf, b + 4),
            .flags = rd(u64, elf, b + 8),
            .addr = rd(u64, elf, b + 16),
            .offset = rd(u64, elf, b + 24),
            .size = rd(u64, elf, b + 32),
            .link = rd(u32, elf, b + 40),
        };
    }
    return out;
}

fn sectionByName(elf: []const u8, secs: []const Section, name: []const u8) ?Section {
    const shstr = secs[rd(u16, elf, 0x3e)];
    for (secs) |s| {
        const n = std.mem.sliceTo(elf[shstr.offset + s.name ..], 0);
        if (std.mem.eql(u8, n, name)) return s;
    }
    return null;
}

fn lessThan(_: void, a: Sym, b: Sym) bool {
    return a.addr < b.addr;
}

fn funcSymbols(gpa: std.mem.Allocator, elf: []const u8) ![]Sym {
    const secs = try sections(gpa, elf);
    var list: std.ArrayList(Sym) = .empty;

    for (secs) |s| {
        if (s.typ != SHT_SYMTAB) continue;

        const strtab = secs[s.link];
        var off = s.offset;

        while (off < s.offset + s.size) : (off += 24) {
            const name_off = rd(u32, elf, off);
            const info = elf[off + 4];
            const value = rd(u64, elf, off + 8);
            const shndx = rd(u16, elf, off + 6);
            const size = rd(u64, elf, off + 16);

            if (value == 0) continue;

            const name = std.mem.sliceTo(elf[strtab.offset + name_off ..], 0);
            const is_func = info & 0xf == STT_FUNC;

            const is_asm_label = info & 0xf == STT_NOTYPE and
                shndx != 0 and
                shndx < secs.len and
                secs[shndx].flags & SHF_EXECINSTR != 0 and
                name.len > 0 and
                !std.mem.startsWith(u8, name, "__") and
                !std.mem.startsWith(u8, name, "$");

            const is_object = info & 0xf == STT_OBJECT and
                size > 0 and
                std.mem.find(u8, name, "__anon") == null and
                std.mem.find(u8, name, ".str") == null;

            if (!is_func and !is_asm_label and !is_object) continue;

            try list.append(gpa, .{ .addr = value, .size = size, .name = name });
        }
    }
    std.mem.sort(Sym, list.items, {}, lessThan);
    return list.items;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.Usage;
    const cwd = std.Io.Dir.cwd();

    if (std.mem.eql(u8, args[1], "gen")) {
        const elf = try cwd.readFileAlloc(io, args[2], arena, .limited(64 << 20));
        const size = try std.fmt.parseInt(usize, args[4], 0);
        const syms = try funcSymbols(arena, elf);

        //Consolidate aliases for the same address into a single entry.
        var uniq: std.ArrayList(Sym) = .empty;
        for (syms) |s| {
            if (uniq.items.len > 0 and uniq.items[uniq.items.len - 1].addr == s.addr) continue;
            try uniq.append(arena, s);
        }

        var strings: std.ArrayList(u8) = .empty;
        var table: std.ArrayList(u8) = .empty;
        try table.appendSlice(arena, "LSYM");
        try appendInt(arena, &table, u32, @intCast(uniq.items.len));

        for (uniq.items) |s| {
            try appendInt(arena, &table, u64, s.addr);
            try appendInt(arena, &table, u32, @intCast(@min(s.size, std.math.maxInt(u32))));
            try appendInt(arena, &table, u32, @intCast(strings.items.len));
            try strings.appendSlice(arena, s.name);
            try strings.append(arena, 0);
        }

        try table.appendSlice(arena, strings.items);
        if (table.items.len > size) {
            std.debug.print("symgen: The Table is {d} bytes long, and it does not fit within the reserved {d} bytes", .{ table.items.len, size });
            return error.TableTooLarge;
        }

        try table.appendNTimes(arena, 0, size - table.items.len);
        try cwd.writeFile(io, .{ .sub_path = args[3], .data = table.items });
    } else if (std.mem.eql(u8, args[1], "verify")) {
        const a = try cwd.readFileAlloc(io, args[2], arena, .limited(64 << 20));
        const b = try cwd.readFileAlloc(io, args[3], arena, .limited(64 << 20));
        const sa = try funcSymbols(arena, a);
        const sb = try funcSymbols(arena, b);
        if (sa.len != sb.len) return fail("The number of functions is different");

        for (sa, sb) |x, y| {
            if (x.addr != y.addr or x.size != y.size) {
                std.debug.print("symgen: {s} @0x{x} and {s} @0x{x} do not match.\n", .{ x.name, x.addr, y.name, y.addr });
                return error.Mismatch;
            }
        }
        //check .text
        const ta = sectionByName(a, try sections(arena, a), ".text") orelse return fail(".text not found.");
        const tb = sectionByName(b, try sections(arena, b), ".text") orelse return fail(".text not found.");
        if (!std.mem.eql(u8, a[ta.offset..][0..ta.size], b[tb.offset..][0..tb.size])) return fail("The contents of .text are different");
    } else return error.Usage;
}

fn appendInt(gpa: std.mem.Allocator, l: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try l.appendSlice(gpa, &buf);
}

fn fail(msg: []const u8) error{Mismatch} {
    std.debug.print("symgen verify: {s}\n", .{msg});
    return error.Mismatch;
}
