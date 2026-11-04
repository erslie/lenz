const build_options = @import("build_options");

//TARGET_SYS_EXIT = 0x18 、ADP_Stopped_ApplicationExit = 0x20026
//https://gitlab.com/qemu-project/qemu/-/blob/master/semihosting/arm-compat-semi.c
pub fn exit(code: u32) void {
    if (!build_options.semihosting) return;
    const block = [2]u64{ 0x20026, code };
    asm volatile ("hlt #0xf000"
        :
        : [op] "{x0}" (@as(u64, 0x18)),
          [arg] "{x1}" (&block),
        : .{ .memory = true });
}
