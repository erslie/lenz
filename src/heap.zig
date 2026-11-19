const std = @import("std");
const Alignment = std.mem.Alignment;

pub const Header = extern struct {
    magic: u32,
    _pad: u32 = 0,
    size: usize,
    ret_addr: usize,
    req_len: usize,
};
pub const unit = 32;
comptime {
    std.debug.assert(@sizeOf(Header) == unit);
}

//"LZUS"
const MAGIC_USED: u32 = 0x4c5a_5553;
//"LZFR"
const MAGIC_FREE: u32 = 0x4c5a_4652;

pub const POISON: u8 = 0xde;

pub const Heap = struct {
    start: usize,
    end: usize,
    on_corruption: *const fn (msg: []const u8, addr: usize, ret_addr: usize) noreturn = defaultCorruption,

    pub fn init(region: []u8) Heap {
        const start = std.mem.alignForward(usize, @intFromPtr(region.ptr), unit);
        const end = std.mem.alignBackward(usize, @intFromPtr(region.ptr) + region.len, unit);
        std.debug.assert(end - start >= 2 * unit);
        const h: *Header = @ptrFromInt(start);
        h.* = .{ .magic = MAGIC_FREE, .size = end - start, .ret_addr = 0, .req_len = 0 };
        return .{ .start = start, .end = end };
    }

    pub fn allocator(self: *Heap) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn hdr(addr: usize) *Header {
        return @ptrFromInt(addr);
    }

    fn checkHeader(self: *Heap, a: usize) *Header {
        const h = hdr(a);
        if ((h.magic != MAGIC_USED and h.magic != MAGIC_FREE) or
            h.size < unit or
            h.size % unit != 0 or
            a + h.size > self.end)
        {
            self.on_corruption("The heap header is corrupted", a, 0);
        }
        return h;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const body = std.mem.alignForward(usize, @max(len, 1), unit);
        var a = self.start;
        while (a < self.end) {
            const h = self.checkHeader(a);
            if (h.magic == MAGIC_FREE) {
                const payload = alignment.forward(a + unit);
                const pad = payload - (a + unit);
                const need = pad + unit + body;
                if (h.size >= need) {
                    var b = a;
                    if (pad > 0) {
                        const rest = h.size - pad;
                        h.size = pad;
                        b = a + pad;
                        hdr(b).* = .{ .magic = MAGIC_FREE, .size = rest, .ret_addr = 0, .req_len = 0 };
                    }
                    const bh = hdr(b);
                    if (bh.size - (unit + body) >= 2 * unit) {
                        const tail = b + unit + body;
                        hdr(tail).* = .{ .magic = MAGIC_FREE, .size = bh.size - (unit + body), .ret_addr = 0, .req_len = 0 };
                        bh.size = unit + body;
                    }
                    bh.magic = MAGIC_USED;
                    bh.ret_addr = ret_addr;
                    bh.req_len = len;
                    return @ptrFromInt(b + unit);
                }
            }
            a += h.size;
        }
        return null;
    }

    fn headerOf(self: *Heap, memory: []u8) *Header {
        const a = @intFromPtr(memory.ptr) - unit;
        if (a < self.start or a >= self.end) self.on_corruption("Attempted to free a pointer outside the heap", @intFromPtr(memory.ptr), 0);
        const h = self.checkHeader(a);
        if (h.magic != MAGIC_USED) self.on_corruption("double free. once free:", @intFromPtr(memory.ptr), h.ret_addr);
        return h;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const h = self.headerOf(memory);
        if (new_len <= h.size - unit) {
            h.req_len = new_len;
            return true;
        }
        return false;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        _ = alignment;
        const self: *Heap = @ptrCast(@alignCast(ctx));
        const h = self.headerOf(memory);
        const payload: [*]u8 = @ptrFromInt(@intFromPtr(h) + unit);
        @memset(payload[0 .. h.size - unit], POISON);
        h.magic = MAGIC_FREE;
        // For a free brock, ret_addr records the caller that freed it,
        // so a double free can report who did the first free.
        // (Coalescing with an adjacent free block removes this header, and the record is lost.)
        h.ret_addr = ret_addr;
        h.req_len = 0;
        self.coalesce();
    }

    fn coalesce(self: *Heap) void {
        var a = self.start;
        while (a < self.end) {
            const h = self.checkHeader(a);
            if (h.magic == MAGIC_FREE) {
                while (a + h.size < self.end) {
                    const n = self.checkHeader(a + h.size);
                    if (n.magic != MAGIC_FREE) break;
                    h.size += n.size;
                }
            }
            a += h.size;
        }
    }

    pub const Stats = struct {
        used_blocks: usize,
        used_bytes: usize,
        free_blocks: usize,
        free_bytes: usize,
        largest_free: usize,
    };

    pub fn stats(self: *Heap) Stats {
        var s: Stats = .{ .used_blocks = 0, .used_bytes = 0, .free_blocks = 0, .free_bytes = 0, .largest_free = 0 };
        var it = self.iterate();
        while (it.next()) |b| {
            if (b.used) {
                s.used_blocks += 1;
                s.used_bytes += b.size;
            } else {
                s.free_blocks += 1;
                s.free_bytes += b.size;
                s.largest_free = @max(s.largest_free, b.size);
            }
        }
        return s;
    }

    pub const Block = struct { addr: usize, size: usize, used: bool, ret_addr: usize, req_len: usize };
    pub const Iterator = struct {
        heap: *Heap,
        a: usize,
        pub fn next(it: *Iterator) ?Block {
            if (it.a >= it.heap.end) return null;
            const h = it.heap.checkHeader(it.a);
            const b: Block = .{ .addr = it.a + unit, .size = h.size, .used = h.magic == MAGIC_USED, .ret_addr = h.ret_addr, .req_len = h.req_len };
            it.a += h.size;
            return b;
        }
    };
    pub fn iterate(self: *Heap) Iterator {
        return .{ .heap = self, .a = self.start };
    }
};

fn defaultCorruption(msg: []const u8, addr: usize, ret_addr: usize) noreturn {
    std.debug.panic("{s}: addr=0x{x} ret=0x{x}", .{ msg, addr, ret_addr });
}

//--test--
const testing = std.testing;

test "reconnect" {
    var buf: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&buf);
    const a = heap.allocator();
    const before = heap.stats();
    const p = try a.alloc(u8, 100);
    const q = try a.alloc(u64, 10);
    try testing.expectEqual(@as(usize, 2), heap.stats().used_blocks);
    a.free(p);
    a.free(q);
    const after = heap.stats();
    try testing.expectEqual(@as(usize, 0), after.used_blocks);
    try testing.expectEqual(@as(usize, 1), after.free_blocks);
    try testing.expectEqual(before.free_bytes, after.free_bytes);
}

test "alignedAlloc" {
    var buf: [64 * 1024]u8 align(64) = undefined;
    var heap = Heap.init(&buf);
    const a = heap.allocator();
    inline for (.{ 1, 2, 8, 16, 32, 64, 256, 4096 }) |al| {
        const m = try a.alignedAlloc(u8, .fromByteUnits(al), 123);
        try testing.expect(@intFromPtr(m.ptr) % al == 0);
        a.free(m);
    }
    try testing.expectEqual(@as(usize, 1), heap.stats().free_blocks);
}

test "record" {
    var buf: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&buf);
    const a = heap.allocator();
    const p = try a.create(u32);
    var it = heap.iterate();
    const b = it.next().?;
    try testing.expect(b.used);
    try testing.expect(b.ret_addr != 0);
    try testing.expectEqual(@as(usize, 4), b.req_len);
    a.destroy(p);
}

test "repeatAllocDealloc" {
    var buf: [256 * 1024]u8 align(64) = undefined;
    var heap = Heap.init(&buf);
    const a = heap.allocator();
    var prng = std.Random.DefaultPrng.init(12345);
    const r = prng.random();
    var live: [64]?[]u8 = @splat(null);
    for (0..5000) |_| {
        const i = r.uintLessThan(usize, live.len);
        if (live[i]) |m| {
            for (m) |byte| try testing.expectEqual(@as(u8, @truncate(i)), byte);
            a.free(m);
            live[i] = null;
        } else {
            const len = r.uintLessThan(usize, 2000) + 1;
            const m = a.alloc(u8, len) catch continue;
            @memset(m, @truncate(i));
            live[i] = m;
        }
    }
    for (&live) |*m| if (m.*) |x| a.free(x);
    try testing.expectEqual(@as(usize, 1), heap.stats().free_blocks);
}

test "poison" {
    var buf: [4096]u8 align(64) = undefined;
    var heap = Heap.init(&buf);
    const a = heap.allocator();
    const p = try a.alloc(u8, 64);
    @memset(p, 0x11);
    const raw = p.ptr;
    a.free(p);
    try testing.expectEqual(POISON, raw[0]);
    try testing.expectEqual(POISON, raw[63]);
}
