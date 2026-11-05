//! QEMU `-M virt,gic-version=2`
pub const name = "qemu-virt";
pub const uart_base: usize = 0x0900_0000;

//uart clock-frequency in https://gitlab.com/qemu-project/qemu/-/blob/master/hw/arm/virt.c
//qemu_fdt_setprop_cell(fdt, "/apb-pclk", "clock-frequency", 24000000);
pub const uart_clock_hz: u32 = 24_000_000;

//base_memmap -> VIRT_GIC_DIST=0x08000000, VIRT_GIC_CPU=0x08010000
//https://gitlab.com/qemu-project/qemu/-/blob/master/hw/arm/virt.c#L174
pub const gicd_base: usize = 0x0800_0000;
pub const gicc_base: usize = 0x0801_0000;

//SPI1:VIRT_UART0 = 1 -> INTID 32 + 1
//https://gitlab.com/qemu-project/qemu/-/blob/master/hw/arm/virt.c#L262
pub const uart_irq: u32 = 33;

pub const ram_base: usize = 0x4000_0000;
pub const ram_size: usize = 512 * 1024 * 1024;
