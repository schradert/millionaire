# ESP32-S3 Rust Development Environment

Development environment for the **Lonely Binary ESP32-S3-N16R8** board using Rust and Nix.

## Hardware Specifications

- **MCU**: ESP32-S3 dual-core Xtensa LX7 @ 240 MHz
- **Flash**: 16 MB
- **PSRAM**: 8 MB
- **WiFi**: 2.4 GHz 802.11 b/g/n
- **Bluetooth**: Bluetooth 5 LE
- **USB**: Dual USB-C ports (one for programming, one OTG)
- **GPIO**: 45 programmable pins

## Getting Started

### 1. Enter the Development Shell

From the repository root:

```bash
# Enter the ESP32-S3 development environment
devenv shell esp32-s3

# Or use direnv (create .envrc in esp32-s3/):
# echo "use flake ..#esp32-s3" > .envrc
# direnv allow
```

### 2. Install Xtensa Rust Toolchain (First Time Only)

The ESP32-S3 uses the Xtensa architecture, which requires a special Rust toolchain:

```bash
# Install the Xtensa Rust toolchain
espup install

# Source the environment (add this to your shell rc file)
source ~/export-esp.sh

# Verify installation
rustc --version --verbose | grep host
```

### 3. Install Additional Cargo Tools (First Time Only)

```bash
# Linker proxy required for ESP32 development
cargo install ldproxy
```

### 4. Hardware Connection

#### Wired Connection (USB)

1. **Connect via USB-C**: Use the programming USB-C port
2. **Find the serial port**:
   - **macOS**: `/dev/cu.usbserial-*` or `/dev/cu.usbmodem*`
   - **Linux**: `/dev/ttyUSB*` or `/dev/ttyACM*`
   - Run `lsusb` to see connected USB devices

3. **Update `default.nix`** with your serial port:

   ```nix
   ESPFLASH_PORT = "/dev/cu.usbserial-0001"; # Your actual port
   ```

#### Enter Flash Mode

To flash firmware:

1. **Hold** the **BOOT** button
2. **Tap** the **RESET** button
3. **Release** the **BOOT** button
4. The board is now in flash mode

## Development Workflow

### Creating a New Project

Use the official ESP Rust template:

```bash
# Generate a new project (choose ESP32-S3, no_std, embassy)
cargo generate esp-rs/esp-template -n my-project

cd my-project
```

You'll be prompted for:

- **MCU**: Select `esp32s3`
- **std/no_std**: Select `no` (bare-metal, faster, simpler)
- **Framework**: Select `embassy` (async runtime, recommended)

### Alternative: Manual Template Selection

Or use a specific template variation:

```bash
# ESP32-S3 with Embassy (async, recommended)
cargo generate esp-rs/esp-template -n my-project \
  --git https://github.com/esp-rs/esp-template.git \
  --define mcu=esp32s3

# Bare-metal (no async framework)
cargo generate esp-rs/esp-hal-template -n my-project
```

### Building and Flashing

The generated project includes `.cargo/config.toml` configured for automatic flashing:

```bash
# Build, flash, and monitor in one command
cargo run

# Build only
cargo build
cargo build --release

# Flash manually
espflash flash --monitor target/xtensa-esp32s3-none-elf/debug/my-project

# Monitor only (after flashing)
espflash monitor
```

### Project Structure

```text
my-project/
├── src/
│   └── main.rs          # Your application code
├── Cargo.toml           # Dependencies and project config
├── .cargo/
│   └── config.toml      # Cargo runner configuration (espflash)
└── rust-toolchain.toml  # Rust toolchain specification
```

## Example Projects

### 1. Blinky (LED Blink)

```rust
#![no_std]
#![no_main]

use esp_hal::{delay::Delay, gpio::Io, prelude::*};
use esp_backtrace as _;

#[entry]
fn main() -> ! {
    let peripherals = esp_hal::init(esp_hal::Config::default());
    let io = Io::new(peripherals.GPIO);
    let mut led = io.pins.gpio8.into_push_pull_output();
    let delay = Delay::new();

    loop {
        led.toggle();
        delay.delay_millis(500);
    }
}
```

### 2. WiFi Connection (Requires esp-wifi)

Add to `Cargo.toml`:

```toml
[dependencies]
esp-hal = { version = "0.23", features = ["esp32s3"] }
esp-wifi = { version = "0.12", features = ["esp32s3", "wifi"] }

[profile.dev]
opt-level = 2  # Required for WiFi to work
```

Example WiFi code:

```rust
use esp_wifi::wifi::{WifiController, WifiDevice, WifiStaDevice, WifiState};

// Initialize WiFi
let wifi = esp_wifi::init(
    EspWifiTimerSource::Timg0,
    rng,
    radio_clocks,
).unwrap();

// Connect to AP
wifi.set_configuration(&Configuration::Client(ClientConfiguration {
    ssid: "YourSSID".try_into().unwrap(),
    password: "YourPassword".try_into().unwrap(),
    ..Default::default()
})).unwrap();

wifi.start().unwrap();
wifi.connect().unwrap();
```

### 3. GPIO Input/Output

```rust
use esp_hal::gpio::{Input, Output, Pull};

let mut button = Input::new(io.pins.gpio9, Pull::Up);
let mut led = Output::new(io.pins.gpio8, Level::Low);

loop {
    if button.is_low() {
        led.set_high();
    } else {
        led.set_low();
    }
    delay.delay_millis(10);
}
```

## Framework Comparison

This environment uses **esp-hal (no_std)** for pure Rust development:

| Feature | esp-hal (no_std) | esp-idf-hal (std) |
| ------- | ---------------- | ----------------- |
| Language | 🦀 Pure Rust | 🦀 Rust + C/C++ |
| Build Speed | ⚡ Fast | 🐢 Slow |
| Binary Size | 📦 Small | 📦 Large |
| Complexity | ✅ Simple | ⚠️ Complex |
| Features | 🔨 Growing | ✅ Complete |
| RTOS | ❌ No (bare-metal) | ✅ FreeRTOS |
| std Library | ❌ No | ✅ Yes |

**Use esp-hal when:**

- You prefer pure Rust
- You want fast compile times
- You need small binaries
- You don't need FreeRTOS features

**Use esp-idf-hal when:**

- You need specific ESP-IDF features
- You require full RTOS capabilities
- You need the Rust std library

## Peripheral Support (esp-hal)

Built-in peripherals supported by esp-hal:

- ✅ GPIO (digital I/O, interrupts)
- ✅ UART (serial communication)
- ✅ SPI (master/slave)
- ✅ I2C (master/slave)
- ✅ PWM (LED control, motor control)
- ✅ ADC (analog input)
- ✅ WiFi (with esp-wifi crate)
- ✅ Bluetooth (with esp-wifi crate)
- ✅ Timers
- ✅ RTC (real-time clock)
- ✅ USB OTG
- ⏳ I2S (audio, in progress)
- ⏳ Camera (experimental)

## Troubleshooting

### Board Not Detected

```bash
# Check USB connection
lsusb

# Check serial ports (macOS)
ls -l /dev/cu.*

# Check serial ports (Linux)
ls -l /dev/ttyUSB* /dev/ttyACM*
```

### Flash Mode Issues

If the board won't enter flash mode:

1. Disconnect USB
2. Hold BOOT button
3. Connect USB while holding BOOT
4. Tap RESET
5. Release BOOT

### Permission Denied (Linux)

```bash
# Add user to dialout group
sudo usermod -a -G dialout $USER

# Log out and log back in
```

### WiFi Not Working

WiFi requires optimization level 2 or higher:

```toml
[profile.dev]
opt-level = 2
```

### Compilation Errors

Ensure you've sourced the ESP environment:

```bash
source ~/export-esp.sh
```

## Useful Commands

```bash
# Board information
espflash board-info

# Flash firmware
espflash flash --monitor target/xtensa-esp32s3-none-elf/release/my-project

# Monitor serial output
espflash monitor

# Serial terminal (alternative)
picocom /dev/cu.usbserial-0001 -b 115200

# Erase flash
espflash erase-flash

# Check ESP environment
echo $LIBCLANG_PATH
rustup show
```

## Resources

### Official Documentation

- [ESP Rust Documentation](https://docs.espressif.com/projects/rust/)
- [ESP Rust Book](https://docs.espressif.com/projects/rust/book/)
- [esp-hal Repository](https://github.com/esp-rs/esp-hal)
- [esp-hal API Docs](https://docs.rs/esp-hal)

### Examples

- [esp-hal Examples](https://github.com/esp-rs/esp-hal/tree/main/examples)
- [ESP WiFi Examples](https://github.com/esp-rs/esp-hal/tree/main/examples/wifi)

### Community

- [ESP Rust Matrix Chat](https://matrix.to/#/#esp-rs:matrix.org)
- [Awesome ESP Rust](https://github.com/esp-rs/awesome-esp-rust)
- [ESP32 Forums](https://www.esp32.com/)

### Hardware

- [Lonely Binary ESP32-S3 Product Page](https://lonelybinary.com/en-us/products/s3)
- [ESP32-S3 Datasheet](https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf)
- [ESP32-S3 Technical Reference](https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf)

## Next Steps

1. **Create your first project**: `cargo generate esp-rs/esp-template`
2. **Try the blinky example**: LED on GPIO8
3. **Connect to WiFi**: Add esp-wifi dependency
4. **Explore peripherals**: UART, I2C, SPI examples
5. **Build something awesome!** 🚀
