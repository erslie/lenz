const std = @import("std");
const build_options = @import("build_options");

pub const size = build_options.syms_size;

export var lenz_syms: [size]u8 linksection(".lenzsyms") = @embedFile("syms").*;

const Entry = extern struct { addr: u64, size: u32, name_off: u32 };

pub const Hit = struct { name: []const u8, offset: u64 };

fn header() ?struct { count: u32, entries: [*]align(1) const Entry, strings: [*]const u8 } {
    const p: [*]const u8 = &lenz_syms;
    if (!std.mem.eql(u8, p[0..4], "LSYM")) return null;
    const n = std.mem.readInt(u32, p[4..8], .little);
    const entries: [*]align(1) const Entry = @ptrCast(p + 8);
    return .{ .count = n, .entries = entries, .strings = p + 8 + @as(usize, n) * @sizeOf(Entry) };
}

pub fn lookup(addr: u64) ?Hit {
    const h = header() orelse return null;
    var lo: usize = 0;
    var hi: usize = h.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (h.entries[mid].addr <= addr) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return null;
    const e = h.entries[lo - 1];
    const off = addr - e.addr;
    if (e.size != 0 and off >= e.size) return null;
    const name: [*:0]const u8 = @ptrCast(h.strings + e.name_off);
    return .{ .name = std.mem.span(name), .offset = off };
}

//Name -> Address(used in the monitor's `b <function name>` command, etc.)
//Since Zig symbol names include the file(namespace), such as "main.kmain", if there is no exact match, it also searches for names ending in ".kmain".
pub fn find(name: []const u8) ?u64 {
    const h = header() orelse return null;
    var suffix_hit: ?u64 = null;
    for (0..h.count) |i| {
        const n = std.mem.span(@as([*:0]const u8, @ptrCast(h.strings + h.entries[i].name_off)));
        if (std.mem.eql(u8, n, name)) return h.entries[i].addr;
        if (suffix_hit == null and n.len > name.len and n[n.len - name.len - 1] == '.' and std.mem.endsWith(u8, n, name)) suffix_hit = h.entries[i].addr;
    }
    return suffix_hit;
}

pub fn count() u32 {
    return if (header()) |h| h.count else 0;
}

pub fn print(w: *std.Io.Writer, addr: u64) void {
    if (lookup(addr)) |hit| {
        w.print("0x{x:0>16} {s}+0x{x}", .{ addr, hit.name, hit.offset }) catch {};
    } else {
        w.print("0x{x:0>16} ??", .{addr}) catch {};
    }
}
