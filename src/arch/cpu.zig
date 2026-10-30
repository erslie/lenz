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
