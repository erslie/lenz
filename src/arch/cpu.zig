pub inline fn read(comptime name: []const u8) u64 {
    return asm volatile ("mrs %[r], " ++ name
        : [r] "=r" (-> u64),
    );
}

pub inline fn write(comptime name: []const u8, value: u64) void {
    asm volatile ("msr " ++ name ++ ", %[v]"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn isb() void {
    asm volatile ("isb" ::: .{ .memory = true });
}

pub fn currentEl() u2 {
    return @truncate(read("CurrentEL") >> 2);
}

//Counter value since startup (ARM generic timer)
pub inline fn ticks() u64 {
    return read("cntpct_el0");
}
//The frequency is cntfrq_el0
pub fn ticksToNs(t: u64) u64 {
    const f = read("cntfrq_el0");
    return @intCast(@as(u128, t) * 1_000_000_000 / f);
}
