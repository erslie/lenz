//zig build -Dboard=pi5 -p zig-out-pi5

pub const name = "raspberrypi-5";
//3-Pin Debug UART (PL011) Between HDMI Ports
pub const uart_base: usize = 0x10_7d00_1000;

//https://github.com/raspberrypi/linux/blob/rpi-6.18.y/arch/arm64/boot/dts/broadcom/bcm2712.dtsi
//clk_uart: clk-uart {
//compatible = "fixed-clock";
//#clock-cells = <0>;
//clock-frequency = <9216000>;
//clock-output-names = "uart-clock";
// };
pub const uart_clock_hz: u32 = 44_236_800;

//https://github.com/torvalds/linux/blob/adc218676eef25575469234709c2d87185ca223a/arch/arm64/boot/dts/broadcom/bcm2712.dtsi#L259
pub const gicd_base: usize = 0x10_7fff_9000;
pub const gicc_base: usize = 0x10_7fff_a000;
//uart10 interrupts: https://github.com/torvalds/linux/blob/adc218676eef25575469234709c2d87185ca223a/arch/arm64/boot/dts/broadcom/bcm2712.dtsi#L232
pub const uart_irq: u32 = 32 + 121;

pub const ram_base: usize = 0x0;
pub const ram_size: usize = 0x2800_0000;

//MMIO as a Device (0x7c00_0000 -> 0x10_7c00_0000, 64MiB)
pub const mmio = [_]@import("region.zig").Region{
    .{ .base = 0x10_7c00_0000, .size = 0x0400_0000 },
};
