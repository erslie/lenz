const std = @import("std");
const cpu = @import("cpu.zig");
const uart = @import("../uart.zig");
const trace = @import("../trace.zig");
const panic_mod = @import("../panic.zig");
const mmu = @import("mmu.zig");

pub const TrapFrame = extern struct {

    //
    //x0..x30
    x: [31]u64,
    elr: u64,
    spsr: u64,
    esr: u64,
    far: u64,
    kind: u64,
    sp_el0: u64,
    _pad: u64,

    //The stack location used by the interrupted code
    pub fn sp(self: *const TrapFrame) u64 {
        return if (self.kind < 4) self.sp_el0 else @intFromPtr(self) + @sizeOf(TrapFrame);
    }
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) == 304);
    std.debug.assert(@offsetOf(TrapFrame, "elr") == 248);
    std.debug.assert(@offsetOf(TrapFrame, "sp_el0") == 288);
}

fn genVectors() []const u8 {
    comptime {
        var s: []const u8 =
            \\.section .text.vectors, "ax"
            \\.balign 2048
            \\.global exception_vectors
            \\exception_vectors:
            \\
        ;
        for (0..16) |i| {
            s = s ++ std.fmt.comptimePrint(
                \\.balign 0x80
                \\      sub     sp, sp, #304
                \\      stp     x0, x1, [sp, #0]
                \\      mov     x1, #{d}
                \\      b       exception_common
                \\
            , .{i});
        }
        return s;
    }
}

comptime {
    asm (genVectors());
    asm (
        \\.section .text, "ax"
        \\exception_common:
        \\      stp     x2, x3, [sp, #16]
        \\      stp     x4, x5, [sp, #32]
        \\      stp     x6, x7, [sp, #48]
        \\      stp     x8, x9, [sp, #64]
        \\      stp     x10, x11, [sp, #80]
        \\      stp     x12, x13, [sp, #96]
        \\      stp     x14, x15, [sp, #112]
        \\      stp     x16, x17, [sp, #128]
        \\      stp     x18, x19, [sp, #144]
        \\      stp     x20, x21, [sp, #160]
        \\      stp     x22, x23, [sp, #176]
        \\      stp     x24, x25, [sp, #192]
        \\      stp     x26, x27, [sp, #208]
        \\      stp     x28, x29, [sp, #224]
        \\      mrs     x2, elr_el1
        \\      stp     x30, x2, [sp, #240]
        \\      mrs     x3, spsr_el1
        \\      mrs     x4, esr_el1
        \\      stp     x3, x4, [sp, #256]
        \\      mrs     x5, far_el1
        \\      stp     x5, x1, [sp, #272]
        \\      mrs     x6, sp_el0
        \\      str     x6, [sp, #288]
        \\      mov     x0, sp
        \\      bl      exceptionHandler
        \\      //If the handler has modified elr/spsr (e.g., to skip a break), that change will be reflected.
        \\      ldp     x30, x2, [sp, #240]
        \\      ldr     x3, [sp, #256]
        \\      msr     elr_el1, x2
        \\      msr     spsr_el1, x3
        \\      ldp     x0, x1, [sp, #0]
        \\      ldp     x2, x3, [sp, #16]
        \\      ldp     x4, x5, [sp, #32]
        \\      ldp     x6, x7, [sp, #48]
        \\      ldp     x8, x9, [sp, #64]
        \\      ldp     x10, x11, [sp, #80]
        \\      ldp     x12, x13, [sp, #96]
        \\      ldp     x14, x15, [sp, #112]
        \\      ldp     x16, x17, [sp, #128]
        \\      ldp     x18, x19, [sp, #144]
        \\      ldp     x20, x21, [sp, #160]
        \\      ldp     x22, x23, [sp, #176]
        \\      ldp     x24, x25, [sp, #192]
        \\      ldp     x26, x27, [sp, #208]
        \\      ldp     x28, x29, [sp, #224]
        \\      add     sp, sp, #304
        \\      eret
    );
}

extern const exception_vectors: u8;

pub fn init() void {
    cpu.write("vbar_el1", @intFromPtr(&exception_vectors));
    cpu.isb();
}

//Exception Syndrome Register
//https://github.com/torvalds/linux/blob/master/arch/arm64/include/asm/esr.h
pub const Ec = enum(u6) {
    unknown = 0x00,
    wfx = 0x01,
    fp_asimd = 0x07,
    illegal = 0x0e,
    svc64 = 0x15,
    sys64 = 0x18,
    iabt_low = 0x20,
    iabt_cur = 0x21,
    pc_align = 0x22,
    dabt_low = 0x24,
    dabt_cur = 0x25,
    sp_align = 0x26,
    serror = 0x2f,
    breakpt_low = 0x30,
    breakpt_cur = 0x31,
    softstep_low = 0x32,
    softstep_cur = 0x33,
    watchpt_low = 0x34,
    watchpt_cur = 0x35,
    brk64 = 0x3c,
    _,

    pub fn of(esr: u64) Ec {
        return @enumFromInt(@as(u6, @truncate(esr >> 26)));
    }

    pub fn describe(self: Ec) []const u8 {
        return switch (self) {
            .unknown => "Undefined instruction (cause unknown)",
            .wfx => "WFI/WFE Trap",
            .fp_asimd => "FP/SIMD Instruction Trap",
            .illegal => "Illegal Exection State",
            .svc64 => "SVC (System Call)",
            .sys64 => "MSR/MRS Trap",
            .iabt_low, .iabt_cur => "Instruction Abort",
            .pc_align => "PC Alignment Violation",
            .dabt_low, .dabt_cur => "Data Abort",
            .sp_align => "SP Alignment Violation",
            .serror => "SError (Asynchronous External Error)",
            .breakpt_low, .breakpt_cur => "Hardware Breakpoint",
            .softstep_low, .softstep_cur => "Software Step",
            .watchpt_low, .watchpt_cur => "Hardware Watchpoint",
            .brk64 => "BRK Instruction",
            _ => "(EC not listed in this table)",
        };
    }
};

//Data/Instruction Abort ISS[5:0] (DFSC/IFSC)
pub fn describeFsc(fsc: u6) []const u8 {
    return switch (fsc) {
        0x00...0x03 => "Address size violation",
        0x04...0x07 => "Translation error (page not found)",
        0x08...0x0b => "Access flag violation",
        0x0c...0x0f => "Permission Violation",
        0x10 => "Synchronous External Abort",
        0x21 => "Alignment Violation",
        else => "(Other. See the ARM DFSC table)",
    };
}

pub var irq_handler: ?*const fn (*TrapFrame) void = null;

//handler
const kind_names = [4][]const u8{ "Sync", "IRQ", "FIQ", "SError" };
const from_names = [4][]const u8{ "EL1/SP0", "EL1/SPx", "EL0/A64", "EL0/A32" };

export fn exceptionHandler(f: *TrapFrame) callconv(.c) void {
    const kind = f.kind & 3;

    //IRQ
    if (kind == 1) {
        if (irq_handler) |h| return h(f);
        panic_mod.fatalFrame(f, "IRQ handler not registered");
    }

    if (kind != 0) panic_mod.fatalFrame(f, kind_names[kind]);

    const ec = Ec.of(f.esr);
    switch (ec) {
        .brk64 => {
            const imm: u16 = @truncate(f.esr);
            uart.print("\n== BRK #{d} @ 0x{x} ==\n", .{ imm, f.elr });
            dumpFrame(f);
            //If thread survives, skip over the BUG instruction and continue: arm64_skip_faulting_instruction(regs, AARCH64_INSN_SIZE); AARCH64_INSN_SIZE=4
            //(= regs->pc += 4 )
            //https://github.com/torvalds/linux/blob/v6.12/arch/arm64/kernel/traps.c
            f.elr += 4;
        },
        else => panic_mod.fatalFrame(f, ec.describe()),
    }
}

pub fn dumpFrame(f: *const TrapFrame) void {
    const ec = Ec.of(f.esr);

    trace.record(.exception, f.elr, f.esr, ec.describe());

    uart.print(" Entrance: {s} from {s}  EC=0x{x:0>2} {s}\n", .{ kind_names[f.kind & 3], from_names[(f.kind >> 2) & 3], @intFromEnum(ec), ec.describe() });
    uart.print(" ESR=0x{x:0>8} ELR=0x{x:0>16} FAR=0x{x:0>16} SPSR=0x{x:0>8}\n", .{ f.esr, f.elr, f.far, f.spsr });
    switch (ec) {
        .dabt_cur, .dabt_low, .iabt_cur, .iabt_low => {
            const fsc: u6 = @truncate(f.esr);
            const wnr = (f.esr >> 6) & 1 == 1;
            uart.print(" -> {s}: who:0x{x} when:{s} what:{s} (FSC=0x{x:0>2})\n", .{
                if (ec == .iabt_cur or ec == .iabt_low) "instruction" else "data",
                f.far,
                if (ec == .iabt_cur or ec == .iabt_low) "Tried to execute" else if (wnr) "Tried to write" else "Tried to read",
                describeFsc(fsc),
                fsc,
            });
            if (mmu.guardOwner(f.far)) |who|
                uart.print("  * Hit the guard page of \"{s}\" = stack overflow (e.g. recursion too deep)\n", .{who});
            if (f.far < 4096) uart.print("  * Address near 0 = likely a null pointer dereference\n", .{});
            //Only when FSC is 0x00..0x0f (size/conversion/access flags/permissions) do the lower 2 bits represent the number of rows in the table
            if (fsc <= 0x0f) uart.print("  (Occurs at page table level {d})\n", .{fsc & 3});
        },
        else => {},
    }
    var i: usize = 0;
    while (i < 31) : (i += 1) {
        uart.print("  x{d:<2}=0x{x:0>16}", .{ i, f.x[i] });
        if (i % 3 == 2) uart.print("\n", .{});
    }
    uart.print("  sp =0x{x:0>16}\n", .{f.sp()});
}
