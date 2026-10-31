//! QEMU `-M virt,gic-version=2`
pub const name = "qemu-virt";
pub const uart_base: usize = 0x0900_0000;

//uart clock-frequency in https://gitlab.com/qemu-project/qemu/-/blob/master/hw/arm/virt.c
//qemu_fdt_setprop_cell(fdt, "/apb-pclk", "clock-frequency", 24000000);
pub const uart_clock_hz: u32 = 24_000_000;
