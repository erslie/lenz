const cpu = @import("cpu.zig");
const gic = @import("gic.zig");

//https://gitlab.com/qemu-project/qemu/-/blob/master/include/hw/arm/bsa.h#L33
//ARCH_TIMER_NS_EL1_IRQ = 30
pub const intid = 30;

pub const hz = 100;

pub var tick_count: u64 = 0;
var interval: u64 = 0;
var next: u64 = 0;

pub fn init() void {
    interval = cpu.read("cntfrq_el0") / hz;
    gic.enable(intid, &handle);
    next = cpu.ticks() + interval;
    cpu.write("cntp_cval_el0", next);
    //ENABLE=1,IMASK=0
    cpu.write("cntp_ctl_el0", 1);
}

//Reschedule the next alarm time
fn handle(_: u32) void {
    tick_count += 1;

    //Make a reservation using "Previous Schedule + Interval"(CVAL)
    //With TVAL, the delay before an interrupt is received accumulates each time, causing the clock to gradually fall behind.
    next += interval;

    //If you reschedule, the conditions for skipping your turn this time will also be cleared.
    cpu.write("cntp_cval_el0", next);
}
