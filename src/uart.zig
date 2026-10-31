const std = @import("std");
const board = @import("board.zig").current;

//Register Description: https://support.arm.com/documentation/ddi0183/g/programmers-model/summary-of-registers
const Reg = enum(usize) {
    dr = 0x00,
    fr = 0x18,
    ibrd = 0x24,
    fbrd = 0x28,
    lcrh = 0x2c,
    cr = 0x30,
    icr = 0x44,
};
const FR_TXFF = 1 << 5;
const FR_RXFE = 1 << 4;

inline fn reg(r: Reg) *volatile u32 {
    return @ptrFromInt(board.uart_base + @intFromEnum(r));
}

pub fn init(baud: u32) void {
    reg(.cr).* = 0;

    //busy
    while (reg(.fr).* & (1 << 3) != 0) {}

    //(FEN=0)
    reg(.lcrh).* = 0;

    //Divider ratio = Clock / (16 × Speed).
    //Store the integer part in IBRD and the fractional part multiplied by 64 in FBRD.
    const div64 = (@as(u64, board.uart_clock_hz) * 4 + baud / 2) / baud;
    reg(.ibrd).* = @intCast(div64 >> 6);
    reg(.fbrd).* = @intCast(div64 & 0x3f);

    //WLEN=8 bit, FEN=FIFO enable
    reg(.lcrh).* = 0x60 | 0x10;

    reg(.icr).* = 0x7ff;

    //Control Register Description: https://support.arm.com/documentation/ddi0183/g/programmers-model/register-descriptions/control-register--uartcr?lang=en
    //UARTEN | TXE | RXE
    reg(.cr).* = (1 << 0) | (1 << 8) | (1 << 9);
}

pub fn putc(c: u8) void {
    while (reg(.fr).* & FR_TXFF != 0) {}
    reg(.dr).* = c;
}

pub fn write(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}

pub fn getc() ?u8 {
    if (reg(.fr).* & FR_RXFE != 0) return null;
    return @truncate(reg(.dr).*);
}

//If I let the data accumulate in the buffer,
//when the system crashes, the last few dozen characters disappear without ever being sent to the UART.
//Even if it’s a little slower, I prefer to send the data as soon as it’s written.
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |d| {
        write(d);
        n += d.len;
    }
    const last = data[data.len - 1];
    for (0..splat) |_| write(last);
    return n + last.len * splat;
}

pub var writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} };

pub fn print(comptime fmt: []const u8, args: anytype) void {
    writer.print(fmt, args) catch {};
}
