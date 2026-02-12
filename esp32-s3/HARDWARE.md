# ESP32-S3-N16R8 Hardware Reference

Hardware specifications and pinout reference for the Lonely Binary ESP32-S3-N16R8 development board.

## Board Specifications

### Microcontroller

- **MCU**: ESP32-S3 (ESP32-S3FN8)
- **Architecture**: Dual-core Xtensa LX7
- **Clock Speed**: 240 MHz (configurable)
- **FPU**: Single-precision floating-point
- **Cores**: 2 (can be run independently)

### Memory

- **Internal SRAM**: 512 KB
- **ROM**: 384 KB
- **Flash Memory**: 16 MB (N16 = 16MB)
- **PSRAM**: 8 MB Octal SPI (R8 = 8MB)
- **Cache**: Configurable instruction/data cache
- **RTC Memory**: 8 KB slow + 8 KB fast

### Wireless Connectivity

- **WiFi**: 802.11 b/g/n (2.4 GHz only)
  - Max bandwidth: 40 MHz
  - WPA/WPA2/WPA3 support
  - SoftAP and Station modes
- **Bluetooth**: 5.0 LE
  - Long Range support
  - Advertising Extensions
  - Multiple connections

### USB

- **Dual USB-C Ports**:
  - USB Serial JTAG Controller (programming/debugging)
  - USB OTG 1.1 Host/Device
- **Native USB**: No external USB-to-serial chip required

## GPIO and Peripherals

### Digital I/O

- **Total GPIO**: 45 pins available
- **RTC GPIO**: 21 pins (can be used in deep sleep)
- **Voltage**: 3.3V logic level
- **Current**: 40 mA per pin (max)

### ADC (Analog-to-Digital Converter)

- **ADC1**: 10 channels (GPIO 1-10)
- **ADC2**: 10 channels (GPIO 11-20)
- **Resolution**: 12-bit
- **Voltage Range**: 0-3.3V (with attenuation settings)
- **Sampling Rate**: Up to 2 MHz

### DAC (Digital-to-Analog Converter)

⚠️ **Not available** on ESP32-S3 (use PWM instead)

### PWM (Pulse Width Modulation)

- **Channels**: 8 independent channels
- **LED PWM**: Up to 16-bit resolution
- **Timer Groups**: 4 timers

### UART (Serial)

- **Ports**: 3 (UART0, UART1, UART2)
- **Speed**: Up to 5 Mbps
- **Features**: Hardware flow control, DMA support

### SPI

- **Ports**: 4 (SPI0, SPI1, SPI2, SPI3)
  - SPI0/SPI1: Reserved for flash/PSRAM
  - SPI2/SPI3: General purpose
- **Mode**: Master or Slave
- **Speed**: Up to 80 MHz
- **Features**: DMA, Quad SPI

### I2C

- **Ports**: 2 (I2C0, I2C1)
- **Mode**: Master or Slave
- **Speed**: Standard (100 kHz), Fast (400 kHz), Fast+ (1 MHz)

### I2S

- **Channels**: 2 (I2S0, I2S1)
- **Mode**: Master or Slave
- **Formats**: Philips, MSB, PDM
- **Use Cases**: Audio input/output, LCD displays

### Other Peripherals

- **RTC**: Real-time clock with calendar
- **Temperature Sensor**: Internal (±2°C accuracy)
- **Touch Sensor**: 14 capacitive touch pins
- **Hall Sensor**: Not available on S3 variant
- **SD/MMC**: Host controller (SDIO 3.0)
- **Camera Interface**: DVP 8/16-bit
- **LCD Interface**: 8/16-bit parallel

## Pin Mapping (Commonly Used)

### Strapping Pins (Use with caution!)

These pins have boot-mode functions:

- **GPIO0**: Boot mode select
- **GPIO3**: JTAG enable
- **GPIO45**: VDD_SPI voltage
- **GPIO46**: ROM messages

### Safe GPIO Pins (General Purpose)

Recommended for general I/O:

- GPIO4, GPIO5, GPIO6, GPIO7
- GPIO8, GPIO9, GPIO10, GPIO11
- GPIO12, GPIO13, GPIO14, GPIO15
- GPIO16, GPIO17, GPIO18, GPIO21

### ADC-Capable Pins

- GPIO1-GPIO10 (ADC1)
- GPIO11-GPIO20 (ADC2)

### Touch-Capable Pins

- GPIO1-GPIO14

### USB Pins (Reserved)

- **GPIO19**: USB D- (don't use for GPIO)
- **GPIO20**: USB D+ (don't use for GPIO)

### SPI Flash/PSRAM Pins (Reserved)

- GPIO26-GPIO32: Used for flash/PSRAM
- **Do not use** these for GPIO!

### UART0 (USB Serial)

- **TX**: GPIO43
- **RX**: GPIO44

## Power Specifications

### Supply

- **Input Voltage**: 5V via USB-C
- **Operating Voltage**: 3.3V (regulated on-board)
- **USB Current**: Up to 500 mA (USB 2.0 spec)

### Power Consumption

- **Active Mode**: ~50-160 mA (CPU + WiFi)
- **Modem Sleep**: ~20-40 mA (CPU active, WiFi off)
- **Light Sleep**: ~1.5 mA (CPU paused, RTC active)
- **Deep Sleep**: ~5-150 µA (RTC only)
- **Hibernation**: ~2.5 µA (RTC slow)

### Power Modes

```rust
// Deep sleep example
use esp_hal::rtc_cntl::sleep::{RtcioWakeupSource, TimerWakeupSource};

// Sleep for 5 seconds
rtc.sleep_deep(&[
    &TimerWakeupSource::new(Duration::from_secs(5))
]);
```

## Boot Modes

### Normal Boot (Flash Boot)

- GPIO0 = HIGH (floating or pull-up)
- Board boots from flash memory

### UART Download Mode (Flashing)

- GPIO0 = LOW (hold BOOT button)
- Used for flashing firmware via USB

### Entering Flash Mode

1. Hold **BOOT** button
2. Tap **RESET** button
3. Release **BOOT** button
4. Board is in flash mode

## GPIO Configuration Examples

### Digital Output (LED)

```rust
use esp_hal::gpio::{Io, Level, Output};

let io = Io::new(peripherals.GPIO);
let mut led = Output::new(io.pins.gpio8, Level::Low);

led.set_high();
led.set_low();
led.toggle();
```

### Digital Input (Button)

```rust
use esp_hal::gpio::{Input, Pull};

let io = Io::new(peripherals.GPIO);
let button = Input::new(io.pins.gpio9, Pull::Up);

if button.is_low() {
    // Button pressed (active low)
}
```

### ADC (Analog Input)

```rust
use esp_hal::adc::{Adc, AdcConfig, Attenuation};

let adc = Adc::new(peripherals.ADC1, AdcConfig::default());
let mut pin = adc_config.enable_pin(
    io.pins.gpio1,
    Attenuation::Attenuation11dB  // 0-3.3V range
);

let reading: u16 = nb::block!(adc.read(&mut pin)).unwrap();
let voltage = (reading as f32 / 4095.0) * 3.3;
```

### PWM (LED Dimming)

```rust
use esp_hal::ledc::{Ledc, LowSpeed, timer};

let mut ledc = Ledc::new(peripherals.LEDC);
ledc.set_global_slow_clock(LSGlobalClkSource::APBClk);

let mut lstimer0 = ledc.timer::<LowSpeed>(timer::Number::Timer0);
lstimer0.configure(timer::config::Config {
    duty: timer::config::Duty::Duty8Bit,
    clock_source: timer::LSClockSource::APBClk,
    frequency: 1.kHz(),
}).unwrap();

let mut channel = ledc.channel(channel::Number::Channel0, io.pins.gpio8);
channel.configure(channel::config::Config {
    timer: &lstimer0,
    duty_pct: 50, // 50% duty cycle
}).unwrap();
```

## Hardware Limitations

### WiFi + ADC2 Conflict

⚠️ **Cannot use ADC2 (GPIO11-20) when WiFi is active**

- Use ADC1 (GPIO1-10) for WiFi projects
- Or disable WiFi when reading ADC2

### SPI Flash Pins

⚠️ **GPIO26-32 are used for flash/PSRAM**

- Do not configure these as GPIO
- Will cause boot failures

### USB Pins

⚠️ **GPIO19-20 are USB D-/D+**

- Don't use for GPIO when USB is active
- Can reclaim in USB-disabled projects

### Strapping Pins

⚠️ **GPIO0, GPIO3, GPIO45, GPIO46 affect boot**

- Avoid pull-downs on GPIO0 (prevents boot)
- Be careful with startup state

## Hardware Debugging

### Serial Monitor

```bash
# espflash monitor
espflash monitor

# picocom
picocom /dev/cu.usbserial-0001 -b 115200

# minicom
minicom -D /dev/cu.usbserial-0001 -b 115200
```

### Board Information

```bash
# Get board details
espflash board-info

# Expected output:
# Chip type: ESP32-S3 (revision 0)
# Flash size: 16MB
# Features: WiFi, BLE
```

### USB Troubleshooting

```bash
# macOS: List USB devices
lsusb
system_profiler SPUSBDataType

# Check serial ports
ls -l /dev/cu.*

# Linux: USB devices
lsusb -v
dmesg | tail
```

## Pinout Diagram

```text
                     ESP32-S3-N16R8
                   ┌─────────────────┐
                   │                 │
        3V3 ──────┤ 3V3         GND ├────── GND
        RST ──────┤ EN          IO0 ├────── GPIO0 (BOOT)
        GPIO1 ────┤ IO1         IO2 ├────── GPIO2
        GPIO3 ────┤ IO3         IO4 ├────── GPIO4
        GPIO5 ────┤ IO5         IO6 ├────── GPIO6
        GPIO7 ────┤ IO7         IO8 ├────── GPIO8 (LED)
        GPIO9 ────┤ IO9        IO10 ├────── GPIO10
       GPIO11 ────┤ IO11       IO12 ├────── GPIO12
       GPIO13 ────┤ IO13       IO14 ├────── GPIO14
       GPIO15 ────┤ IO15       IO16 ├────── GPIO16
       GPIO17 ────┤ IO17       IO18 ├────── GPIO18
    USB D- (19) ──┤ IO19       IO20 ├────── GPIO20 (USB D+)
       GPIO21 ────┤ IO21       IO43 ├────── TX0 (USB Serial)
          GND ────┤ GND        IO44 ├────── RX0 (USB Serial)
                   │                 │
                   │   USB-C   USB-C │
                   │   (Prog)  (OTG) │
                   └─────────────────┘
```

## References

- [ESP32-S3 Datasheet](https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf)
- [ESP32-S3 Technical Reference Manual](https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf)
- [Lonely Binary Product Page](https://lonelybinary.com/en-us/products/s3)
- [esp-hal GPIO Documentation](https://docs.rs/esp-hal)

---

**💡 Tip**: Always check the [esp-hal documentation](https://docs.rs/esp-hal) for the latest peripheral support and API changes!
