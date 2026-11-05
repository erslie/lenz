const cpu = @import("arch/cpu.zig");
const uart = @import("uart.zig");

var rx: [256]u8 = undefined;
var rx_head: usize = 0;
var rx_tail: usize = 0;

// UART receive interrupt (registered with `gic.enable`).
// Move all characters in the FIFO to the buffer.
pub fn onUartIrq(_: u32) void {
    while (uart.getc()) |c| {
        if (rx_head - rx_tail < rx.len) {
            rx[rx_head % rx.len] = c;
            rx_head += 1;
        }
    }
    uart.ackIrq();
}

fn readChar() ?u8 {
    cpu.disableIrq();
    defer cpu.enableIrq();
    if (rx_tail == rx_head) return null;
    const c = rx[rx_tail % rx.len];
    rx_tail += 1;
    return c;
}

pub fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (true) {
        const c = readChar() orelse {
            cpu.wfi();
            continue;
        };
        if (c == '\r' or c == '\n') {
            uart.write("\n");
            return buf[0..n];
        }
        if (n < buf.len) {
            buf[n] = c;
            n += 1;
            uart.putc(c);
        }
    }
}
