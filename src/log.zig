const std = @import("std");
const uart = @import("uart.zig");
const cpu = @import("arch/cpu.zig");

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const color = comptime switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[90m",
    };
    const us = cpu.ticksToNs(cpu.ticks()) / 1000;
    const prefix = comptime std.fmt.comptimePrint("{s}[{s}]\x1b[0m ({s})", .{ color, level.asText(), @tagName(scope) });
    uart.print("{d:>8}us " ++ prefix ++ format ++ "\n", .{us} ++ args);
}
