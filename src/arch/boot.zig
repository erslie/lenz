const std = @import("std");
const board = @import("../board.zig").current;

// All values were verified to match those in the Linux v6.12 boot process in terms of both values and meanings.
// HCR_RW = 1 << 31 : https://github.com/torvalds/linux/blob/v6.12/arch/arm64/include/asm/kvm_arm.h
// Set CNTHCTL_EL2 to 3: __init_el2_timers in https://github.com/torvalds/linux/blob/v6.12/arch/arm64/include/asm/el2_setup.h (“Enable EL1 physical timers”)
// Set CPTR_EL2 to 0x33ff: __init_el2_cptr in the same file
// Each bit of SPSR (D=0x200, A=0x100, I=0x80, F=0x40, EL1h=5): https://github.com/torvalds/linux/blob/v6.12/arch/arm64/include/uapi/asm/ptrace.h
// Bit positions in SCTLR_EL1: https://github.com/torvalds/linux/blob/v6.12/arch/arm64/tools/sysreg (register definitions generated from Arm’s official data)
// The official specifications are the Arm Architecture Reference Manual (DDI 0487) and the individual register pages at https://developer.arm.com/documentation/ddi0601/latest/
// Since the pages are rendered using JavaScript, the Linux headers listed above were used for cross-referencing in this asm.
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
        \\      crumb   'A'
        \\      mov     x19, x0
        \\      mrs     x1, CurrentEL
        \\      lsr     x1, x1, #2
        \\      cmp     x1, #2
        \\      b.ne    in_el1
        \\      mov     x1, #(1 << 31)
        \\      msr     hcr_el2, x1
        \\      mov     x1, #3
        \\      msr     cnthctl_el2, x1
        \\      msr     cntvoff_el2, xzr
        \\      mov     x1, #0x33ff
        \\      msr     cptr_el2, x1
        \\      ldr     x1, =0x30d00800
        \\      msr     sctlr_el1, x1
        \\      mov     x1, #0x3c5
        \\      msr     spsr_el2, x1
        \\      adr     x1, in_el1
        \\      msr     elr_el2, x1
        \\      crumb   'B'
        \\      eret
        \\in_el1:
        \\      crumb   'C'
        \\      ldr     x1, =__exc_stack_top
        \\      mov     sp, x1
        \\      ldr     x1, =__stack_top
        \\      msr     sp_el0, x1
        \\      msr     spsel, #0
        \\      crumb   'D'
        \\      ldr     x1, =__bss_start
        \\      ldr     x2, =__bss_end
        \\1:    cmp     x1, x2
        \\      b.hs    2f
        \\      str     xzr, [x1], #8
        \\      b       1b
        \\2:    crumb   'E'
        \\      mov     x0, x19
        // From the “The Frame Pointer” section of AAPCS64 (Arm Function Calling Convention): "The end of the frame record chain is
        // indicated by address 0, located at the address of the previous frame." https://github.com/ARM-software/abi-aa/blob/main/aapcs64/aapcs64.rst
        \\      mov     x29, xzr
        \\      mov     x30, xzr
        \\      bl      kmain
        \\3:    wfe
        \\      b       3b
    );
}
