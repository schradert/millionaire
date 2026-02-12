# ESP32-S3 Development TODO

Quick checklist for getting started with your ESP32-S3 board.

## ✅ Initial Setup (One-Time)

- [ ] Enter development environment: `devenv shell esp32-s3`
- [ ] Install Xtensa Rust toolchain: `espup install`
- [ ] Source environment: `source ~/export-esp.sh` (add to shell rc)
- [ ] Install linker proxy: `cargo install ldproxy`
- [ ] Connect board via USB-C
- [ ] Find serial port: `ls /dev/cu.*` (macOS) or `ls /dev/ttyUSB*` (Linux)
- [ ] Update `ESPFLASH_PORT` in `default.nix`
- [ ] Allow direnv: `direnv allow` (optional)

## 📋 First Project

- [ ] Generate project: `cargo generate esp-rs/esp-template -n blinky`
- [ ] Enter project: `cd blinky`
- [ ] Put board in flash mode (hold BOOT, tap RESET)
- [ ] Build and flash: `cargo run`
- [ ] Verify LED blinks or serial output works

## 🎯 Next Steps

- [ ] Read [QUICKSTART.md](QUICKSTART.md) for detailed instructions
- [ ] Review [FRAMEWORKS.md](FRAMEWORKS.md) to understand tool choices
- [ ] Check [HARDWARE.md](HARDWARE.md) for pinout and specifications
- [ ] Try GPIO examples (button, LED)
- [ ] Experiment with WiFi (requires `esp-wifi` crate)
- [ ] Explore [esp-hal examples](https://github.com/esp-rs/esp-hal/tree/main/examples)

## 🐛 Common Issues

- [ ] **Serial port not found**: Run `lsusb` and update `ESPFLASH_PORT`
- [ ] **Permission denied** (Linux): Add user to `dialout` group
- [ ] **Flash mode issues**: Try disconnecting and holding BOOT while connecting
- [ ] **WiFi not working**: Add `opt-level = 2` to `Cargo.toml`
- [ ] **Build errors**: Source environment with `source ~/export-esp.sh`

## 📚 Learning Resources

- [ ] [ESP Rust Book](https://docs.espressif.com/projects/rust/book/)
- [ ] [esp-hal Documentation](https://docs.rs/esp-hal)
- [ ] [Embedded Rust Training](https://docs.espressif.com/projects/rust/no_std-training/)
- [ ] [Awesome ESP Rust](https://github.com/esp-rs/awesome-esp-rust)

## 💡 Project Ideas

- [ ] Blinky LED (GPIO output)
- [ ] Button input (GPIO input with interrupts)
- [ ] Temperature sensor (ADC + conversion)
- [ ] WiFi connection and HTTP request
- [ ] Web server on ESP32
- [ ] MQTT client for IoT
- [ ] Bluetooth LE beacon
- [ ] Smart home device (ESPHome alternative)

---

**Quick Reference Commands:**

```bash
# Enter environment
devenv shell esp32-s3

# Create project
cargo generate esp-rs/esp-template -n my-project

# Build and flash
cargo run

# Monitor only
espflash monitor

# Board info
espflash board-info
```
