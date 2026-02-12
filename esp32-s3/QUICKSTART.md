# ESP32-S3 Quick Start Guide

Get up and running with your Lonely Binary ESP32-S3-N16R8 in 5 minutes!

## ⚡ Super Quick Start

```bash
# 1. Enter development environment
devenv shell esp32-s3

# 2. Install Rust toolchain (first time only)
espup install
source ~/export-esp.sh

# 3. Install linker proxy (first time only)
cargo install ldproxy

# 4. Create a project
cargo generate esp-rs/esp-template -n blinky
cd blinky

# 5. Connect board via USB-C (hold BOOT, tap RESET)

# 6. Flash and run!
cargo run
```

## 🔌 How to Turn It On

The ESP32-S3 board powers on automatically when you connect it via USB-C.

**USB-C Ports:**

- **Port 1**: Programming and power (use this one!)
- **Port 2**: USB OTG (for advanced use)

Simply plug in the USB-C cable and the board is powered on. No power button needed!

## 🔗 How to Connect

### Wired (USB Serial)

1. **Connect USB-C cable** to the programming port
2. **Find the serial port**:

   ```bash
   # macOS
   ls /dev/cu.usbserial-* /dev/cu.usbmodem*

   # Linux
   ls /dev/ttyUSB* /dev/ttyACM*
   ```

3. **Update the port** in `esp32-s3/default.nix`:

   ```nix
   ESPFLASH_PORT = "/dev/cu.usbserial-XXXX"; # Your port here
   ```

### Wireless (WiFi)

WiFi is configured in your Rust code. Quick example:

```rust
// In Cargo.toml
esp-wifi = { version = "0.12", features = ["esp32s3", "wifi"] }

// In your code
use esp_wifi::wifi::*;

wifi.set_configuration(&Configuration::Client(ClientConfiguration {
    ssid: "YourSSID".try_into().unwrap(),
    password: "YourPassword".try_into().unwrap(),
    ..Default::default()
})).unwrap();

wifi.connect().unwrap();
```

**Note**: WiFi requires `opt-level = 2` in `Cargo.toml`:

```toml
[profile.dev]
opt-level = 2
```

## 🎯 Your First Program (Blinky)

```bash
# Create a project
cargo generate esp-rs/esp-template -n blinky
cd blinky

# When prompted, select:
# - MCU: esp32s3
# - std support: no
# - Framework: embassy
```

Edit `src/main.rs`:

```rust
#![no_std]
#![no_main]

use esp_hal::{delay::Delay, gpio::Io, prelude::*};
use esp_backtrace as _;

#[entry]
fn main() -> ! {
    let peripherals = esp_hal::init(esp_hal::Config::default());
    let io = Io::new(peripherals.GPIO);

    // GPIO8 is often connected to an LED
    let mut led = io.pins.gpio8.into_push_pull_output();
    let delay = Delay::new();

    loop {
        led.toggle();
        delay.delay_millis(500);
    }
}
```

Flash it:

```bash
# Hold BOOT button, tap RESET, then run:
cargo run
```

## 📡 Flash Mode (Important!)

To flash firmware, the board needs to be in **flash mode**:

1. **Hold** the **BOOT** button (don't release yet)
2. **Tap** the **RESET** button (while still holding BOOT)
3. **Release** the **BOOT** button
4. **Run** `cargo run` or `espflash flash`

The board is now in flash mode and ready to receive firmware.

## 🛠️ Essential Commands

```bash
# Build and flash
cargo run                  # All-in-one: build, flash, monitor

# Individual steps
cargo build                # Build only
cargo build --release      # Optimized build
espflash flash --monitor   # Flash and monitor
espflash monitor           # Monitor serial output only

# Board info
espflash board-info        # Show ESP32-S3 details
lsusb                      # Show USB devices

# Troubleshooting
espflash erase-flash       # Erase the entire flash
```

## 🚨 Common Issues

### "Permission denied" (Linux)

```bash
sudo usermod -a -G dialout $USER
# Log out and log back in
```

### "No serial port found"

1. Check USB connection: `lsusb`
2. Update `ESPFLASH_PORT` in `default.nix`
3. Try entering flash mode (BOOT + RESET)

### "WiFi not working"

Add to `Cargo.toml`:

```toml
[profile.dev]
opt-level = 2  # Required for WiFi!
```

### Build errors about "xtensa-esp32s3-none-elf"

```bash
# Re-source the ESP environment
source ~/export-esp.sh

# Verify
rustc --version --verbose | grep xtensa
```

## 📚 Next Steps

1. ✅ **Read the full [README.md](README.md)** for comprehensive docs
2. 🔍 **Explore [esp-hal examples](https://github.com/esp-rs/esp-hal/tree/main/examples)**
3. 🌐 **Try WiFi examples** from [esp-hal WiFi examples](https://github.com/esp-rs/esp-hal/tree/main/examples/wifi)
4. 🎓 **Take the [Embedded Rust training](https://docs.espressif.com/projects/rust/no_std-training/)**
5. 🚀 **Build your own project!**

## 💡 Tips

- **Fast iterations**: Use `cargo run` for immediate feedback
- **Smaller binaries**: Use `--release` flag
- **WiFi debugging**: Check `opt-level = 2` in Cargo.toml
- **Serial monitoring**: Use `espflash monitor` or `picocom`
- **GPIO pins**: Check your board schematic for available pins

## 🆘 Need Help?

- 📖 [Full README](README.md)
- 💬 [ESP Rust Matrix Chat](https://matrix.to/#/#esp-rs:matrix.org)
- 🌟 [Awesome ESP Rust](https://github.com/esp-rs/awesome-esp-rust)
- 🔧 [esp-hal Repository](https://github.com/esp-rs/esp-hal)

Happy hacking! 🎉
