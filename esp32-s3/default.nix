{
  perSystem.canivete.devenv.shells.esp32-s3 = {pkgs, ...}: {
    name = "ESP32-S3 Rust Development";

    packages = with pkgs; [
      # Rust ESP32 toolchain management
      espup # Installs and manages Xtensa Rust toolchain

      # Flashing and monitoring tools
      espflash # Rust-based serial flasher (integrates with cargo)
      esptool # Python-based flasher (industry standard, used by ESP-IDF)

      # Project generation
      cargo-generate # Generate projects from templates
      cargo-espflash # Alias for espflash with cargo integration

      # Serial monitoring
      picocom # Lightweight serial terminal
      minicom # Alternative serial terminal

      # USB utilities
      usbutils # lsusb for debugging USB connections

      # Build tools
      pkg-config
      gcc
      gnumake

      # Optional: for debugging
      openocd-esp32 # On-chip debugger for ESP32
    ];

    env = {
      # Rust ESP environment (set by espup install, but we define here)
      LIBCLANG_PATH = "${pkgs.llvmPackages_18.libclang.lib}/lib";

      # Optimization level required for WiFi to work
      CARGO_PROFILE_DEV_OPT_LEVEL = "2";

      # Serial port (adjust as needed for your system)
      # macOS: /dev/cu.usbserial-*
      # Linux: /dev/ttyUSB* or /dev/ttyACM*
      ESPFLASH_PORT = "/dev/cu.usbserial-0001"; # Update this for your device
    };

    enterShell = ''
      cat << 'EOF'
      ╔════════════════════════════════════════════════════════════════╗
      ║  ESP32-S3 Rust Development Environment                        ║
      ║  Lonely Binary ESP32-S3-N16R8 Board                           ║
      ╠════════════════════════════════════════════════════════════════╣
      ║                                                                ║
      ║  🦀 Pure Rust Development with esp-hal (no_std)               ║
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
      ║  • Hold BOOT button, tap RESET to enter flash mode            ║
      ║  • USB-C port connects to serial (check with: lsusb)          ║
      ║  • Update ESPFLASH_PORT in default.nix if needed              ║
      ║                                                                ║
      ║  Useful Commands:                                              ║
      ║  • espflash board-info   - Show board information             ║
      ║  • espflash flash        - Flash firmware manually            ║
      ║  • espflash monitor      - Serial monitor                     ║
      ║  • cargo build --release - Build optimized                    ║
      ║                                                                ║
      ║  Resources:                                                    ║
      ║  • https://github.com/esp-rs/esp-hal                          ║
      ║  • https://docs.espressif.com/projects/rust/                   ║
      ║  • https://docs.espressif.com/projects/rust/book/              ║
      ║                                                                ║
      ╚════════════════════════════════════════════════════════════════╝
      EOF

      # Check if espup toolchain is installed
      if [ ! -f "$HOME/export-esp.sh" ]; then
        echo ""
        echo "⚠️  Xtensa Rust toolchain not found. Run: espup install"
      else
        # Source the ESP environment
        source "$HOME/export-esp.sh" 2>/dev/null || true
      fi

      # Find USB serial ports
      echo ""
      echo "🔌 Detected USB serial devices:"
      if command -v lsusb &> /dev/null; then
        lsusb | grep -i "serial\|cp210\|ch340\|ftdi" || echo "  No common USB-to-serial adapters found"
      fi

      # List serial ports (macOS)
      if [ "$(uname)" = "Darwin" ]; then
        echo ""
        echo "📡 Serial ports on macOS:"
        ls -l /dev/cu.* 2>/dev/null | grep -E "usbserial|usbmodem" || echo "  No USB serial ports found"
        echo "  Update ESPFLASH_PORT in default.nix with the correct port"
      fi

      # List serial ports (Linux)
      if [ "$(uname)" = "Linux" ]; then
        echo ""
        echo "📡 Serial ports on Linux:"
        ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "  No USB serial ports found"
        echo "  Update ESPFLASH_PORT in default.nix with the correct port"
      fi

      echo ""
    '';

    # Languages
    languages.rust = {
      enable = true;
      channel = "stable";
      components = ["rustc" "cargo" "clippy" "rustfmt" "rust-analyzer"];
      targets = [
        "xtensa-esp32s3-none-elf" # Will be added by espup
      ];
    };

    # Pre-commit hooks for Rust
    git-hooks.hooks = {
      rustfmt.enable = true;
      clippy.enable = true;
    };

    # Add starship prompt customization
    # starship.enable = true;
  };
}
