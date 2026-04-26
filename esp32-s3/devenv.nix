{
  inputs,
  pkgs,
  ...
}: {
  imports = inputs.canivete.canivete.${builtins.currentSystem}.devenv.modules;

  name = "ESP32-S3 Rust Development";

  packages = with pkgs; [
    espup
    espflash
    esptool
    cargo-generate
    picocom
    minicom
    usbutils
    pkg-config
    gcc
    gnumake
    openocd
  ];

  env = {
    LIBCLANG_PATH = "${pkgs.llvmPackages_18.libclang.lib}/lib";
    CARGO_PROFILE_DEV_OPT_LEVEL = "2";
    ESPFLASH_PORT = "/dev/cu.usbserial-0001";
  };

  enterShell = ''
    cat << 'EOF'
    ╔════════════════════════════════════════════════════════════════╗
    ║  ESP32-S3 Rust Development Environment                        ║
    ║  Lonely Binary ESP32-S3-N16R8 Board                           ║
    ╠════════════════════════════════════════════════════════════════╣
    ║                                                                ║
    ║  Pure Rust Development with esp-hal (no_std)                   ║
    ║                                                                ║
    ║  Quick Start:                                                  ║
    ║  1. Install Xtensa toolchain (first time only):               ║
    ║     $ espup install                                            ║
    ║     $ source ~/export-esp.sh                                   ║
    ║                                                                ║
    ║  2. Install Cargo tools (first time only):                    ║
    ║     $ cargo install ldproxy                                    ║
    ║                                                                ║
    ║  3. Create a new project:                                     ║
    ║     $ cargo generate esp-rs/esp-template -n my-project        ║
    ║     (Select: ESP32-S3, no_std, embassy)                       ║
    ║                                                                ║
    ║  4. Build and flash:                                          ║
    ║     $ cd my-project                                            ║
    ║     $ cargo run  # Builds, flashes, and monitors              ║
    ║                                                                ║
    ║  Flashing Instructions:                                       ║
    ║  - Hold BOOT button, tap RESET to enter flash mode            ║
    ║  - USB-C port connects to serial (check with: lsusb)          ║
    ║  - Update ESPFLASH_PORT in devenv.nix if needed               ║
    ║                                                                ║
    ║  Useful Commands:                                              ║
    ║  - espflash board-info   - Show board information             ║
    ║  - espflash flash        - Flash firmware manually            ║
    ║  - espflash monitor      - Serial monitor                     ║
    ║  - cargo build --release - Build optimized                    ║
    ║                                                                ║
    ║  Resources:                                                    ║
    ║  - https://github.com/esp-rs/esp-hal                          ║
    ║  - https://docs.espressif.com/projects/rust/                   ║
    ║  - https://docs.espressif.com/projects/rust/book/              ║
    ║                                                                ║
    ╚════════════════════════════════════════════════════════════════╝
    EOF

    # Check if espup toolchain is installed
    if [ ! -f "$HOME/export-esp.sh" ]; then
      echo ""
      echo "WARNING: Xtensa Rust toolchain not found. Run: espup install"
    else
      # Source the ESP environment
      source "$HOME/export-esp.sh" 2>/dev/null || true
    fi

    # Find USB serial ports
    echo ""
    echo "Detected USB serial devices:"
    if command -v lsusb &> /dev/null; then
      lsusb | grep -i "serial\|cp210\|ch340\|ftdi" || echo "  No common USB-to-serial adapters found"
    fi

    # List serial ports (macOS)
    if [ "$(uname)" = "Darwin" ]; then
      echo ""
      echo "Serial ports on macOS:"
      ls -l /dev/cu.* 2>/dev/null | grep -E "usbserial|usbmodem" || echo "  No USB serial ports found"
      echo "  Update ESPFLASH_PORT in devenv.nix with the correct port"
    fi

    # List serial ports (Linux)
    if [ "$(uname)" = "Linux" ]; then
      echo ""
      echo "Serial ports on Linux:"
      ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  No USB serial ports found"
      echo "  Update ESPFLASH_PORT in devenv.nix with the correct port"
    fi

    echo ""
  '';

  # Note: xtensa-esp32s3-none-elf target is added by `espup install`, not rust-overlay
  languages.rust = {
    enable = true;
    channel = "stable";
    components = ["rustc" "cargo" "clippy" "rustfmt" "rust-analyzer"];
  };

  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy.enable = true;
  };
}
