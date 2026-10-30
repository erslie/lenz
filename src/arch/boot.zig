const std = @import("std");
const board = @import("../board.zig").current;

comptime {
    asm (std.fmt.comptimePrint(
            \\.equ UART_BASE, 0x{x}
        , .{board.uart_base}));
    asm (
        \\.macro crumb ch
        \\      ldr     x9, =UART_BASE
        \\9:    ldr     w10, [x9, #0x18]
        \\      tbnz    w10, #5, 9b
        \\      mov     w10, #\ch
        \\      str     w10, [x9]
        \\.endm
        \\
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        \\      crumb 'A'
        \\1:    wfe
        \\      b     1b
    );
}
