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
pub const uart_clock_hz: u32 = 9_216_000;
