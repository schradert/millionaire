# systeamadeck (Steam Deck OLED "Galileo") on NixOS via Jovian: Gaming Mode
# on boot, Plasma as the desktop session, Decky Loader with mynur's plugins.
{
  flake,
  lib,
  pinned,
  pkgs,
  ...
}: {
  imports = [
    ./facter
    flake.inputs.srvos.nixosModules.desktop
    flake.inputs.jovian.nixosModules.jovian
    flake.inputs.mynur.nixosModules.decky
  ];
  profiles.client.enable = true;
  profiles.gaming.enable = true;
  # Installed by the old dotfiles repo (home stateVersion with the games below)
  system.stateVersion = "25.11";
  # node hostname is the LAN IP (ssh target)
  networking.hostName = lib.mkForce "systeamadeck";

  # Disk layout as OBSERVED on the live device 2026-10-11 (nvme0n1, GPT; no ZFS
  # pool exists): 500M vfat ESP, 952G ext4 root, 1G swap, by partlabel from the
  # old dotfiles disko `base` disk. The fleet's ZFS layout (modules/disko.nix,
  # static/zfs-legacy.nix) does not match this device, so disko is switched off
  # entirely: it generates no fileSystems here and has no devices to format, so
  # nixos-anywhere / disko can never wipe the Deck. The host is slated for the
  # standard layout (modules/disko.nix) on reinstall, once its data is restored
  # from the cluster; drop this block then.
  disko.enableConfig = false;
  disko.devices.disk = lib.mkForce {};
  disko.devices.zpool = lib.mkForce {};
  boot.supportedFilesystems = lib.mkForce ["ext4" "vfat"];
  services.zfs.autoScrub.enable = lib.mkForce false;
  services.zfs.trim.enable = lib.mkForce false;
  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/disk-base-root";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/disk-base-ESP";
    fsType = "vfat";
    options = ["umask=0077"];
  };
  swapDevices = [{device = "/dev/disk/by-partlabel/disk-base-swap";}];

  # The Deck's patched kernel over srvos' latest-zfs-kernel (modules/disko.nix)
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_jovian;
  environment.systemPackages = with pkgs; [maliit-keyboard maliit-framework];

  # Decky plugins and their options (mynur)
  nixpkgs.overlays = with flake.inputs.mynur.overlays; [
    decky
    decky-plugins
    # mynur's plugins need pnpm 8/9, both dropped from nixpkgs 26.11
    (_: _: {
      pnpm_8 = pinned.pnpm-8;
      pnpm_9 = pinned.pnpm-9;
    })
  ];

  jovian.devices.steamdeck = {
    enable = true;
    autoUpdate = true;
    enableGyroDsuService = true;
  };
  jovian.steam = {
    enable = true;
    autoStart = true;
    desktopSession = "plasma";
    user = flake.config.canivete.meta.people.me;
  };

  # TODO galileo mura correction images? Jovian-NixOS#227, #229
  jovian.decky-loader = {
    enable = true;
    package = pkgs.decky-loader-prerelease;
    # Volume Boost talks to pipewire-pulse over TCP
    extraPackages = [pkgs.pulseaudio];
    plugins = {
      animation-changer.enable = true;
      css-loader.enable = true;
      game-theme-music.enable = true;
      game-theme-music.settings.settings = {
        defaultMuted = false;
        volume = 0.52;
      };
      hltb.enable = true;
      vibrant-deck.enable = true;
      volume-boost.enable = true;
    };
  };
  # TODO cookie auth instead of anonymous (loopback only)
  services.pipewire.extraConfig.pipewire-pulse."11-decky-volume-boost"."pulse.cmd" = lib.toList {
    cmd = "load-module";
    args = "module-native-protocol-tcp listen=127.0.0.1 auth-anonymous=true";
  };
  systemd.services.decky-loader.environment.PULSE_SERVER = "tcp:127.0.0.1:4713";

  home-manager.sharedModules = [
    {home.stateVersion = "25.11";}
    ({
      config,
      lib,
      pinned,
      pkgs,
      ...
    }: {
      programs.steam.external = {
        chiaki.enable = true;
        kingsisle.enable = true;
        tlopo.enable = true;
        runescape = {
          rscplus.enable = true;
          runelite.enable = true;
          hdos.enable = true;
        };
        # World of Warcraft through Battle.net, ConsolePort for the controller
        manual."Battle.Net" = lib.mkIf config.programs.steam.external.library {shortcut.exe = pinned.game-installers."Battle.net-Setup.exe";};
        # TODO XB360 (xenia-canary), Switch (ryujinx), PSV (vita3k)
        consoles = {
          NES.titles = [
            "Legend of Zelda, The (USA)"
            "Zelda II - The Adventure of Link (USA)"
          ];
          SNES.titles = [
            "Legend of Zelda, The - A Link to the Past (USA)"
            "Chrono Trigger (USA)"
            "Shin Megami Tensei (Japan)"
            "Shin Megami Tensei II (Japan)"
            "Shin Megami Tensei if... (Japan)"
            "Rudra no Hihou (Japan)"
          ];
          GB.titles = [
            "Legend of Zelda, The - Link's Awakening (USA, Europe)"
          ];
          GBC.titles = [
            "Legend of Zelda, The - Link's Awakening DX (USA, Europe) (SGB Enhanced) (GB Compatible)"
            "Legend of Zelda, The - Oracle of Seasons (USA, Australia)"
            "Legend of Zelda, The - Oracle of Ages (USA, Australia)"
          ];
          GBA.titles = [
            "Legend of Zelda, The - A Link to the Past & Four Swords (USA)"
            "Legend of Zelda, The - The Minish Cap (USA)"
            "Kingdom Hearts - Chain of Memories (USA)"
          ];
          N64.titles = [
            "Legend of Zelda, The - Ocarina of Time (USA)"
            "Legend of Zelda, The - Majora's Mask (USA)"
            "Paper Mario (USA)"
          ];
          GC.titles = [
            "Legend of Zelda, The - The Wind Waker (USA)"
            "Legend of Zelda, The - Four Swords Adventures (USA)"
            "Legend of Zelda, The - Twilight Princess (USA)"
            "Paper Mario - The Thousand-Year Door (USA)"
          ];
          Wii.titles = [
            "Legend of Zelda, The - Skyward Sword (USA) (En,Fr,Es)"
            "Super Paper Mario (USA)"
          ];
          DS.titles = [
            "Legend of Zelda, The - Phantom Hourglass (USA) (En,Fr,Es)"
            "Legend of Zelda, The - Spirit Tracks (USA, Australia) (En,Fr,Es)"
            "World Ends with You, The (USA)"
            "Kingdom Hearts - Re-coded (USA) (En,Fr,Es)"
            "Kingdom Hearts - 358-2 Days (USA) (En,Fr)"
            "Shin Megami Tensei - Strange Journey (USA)"
          ];
          "3DS".titles = [
            "Legend of Zelda, The - A Link Between Worlds (USA) (En,Fr,Es)"
            "Legend of Zelda, The - Tri Force Heroes (USA) (En,Fr,Es)"
            "Kingdom Hearts 3D - Dream Drop Distance (USA) (En,Fr)"
            "Paper Mario - Sticker Star (USA) (En,Fr,Es)"
            "Shin Megami Tensei IV (USA)"
            "Shin Megami Tensei IV - Apocalypse (USA)"
          ];
          WiiU.titles = [
            "Paper Mario - Color Splash (USA) (En,Fr,Es)"
          ];
          PS1.biosNames = ["ps-41a"];
          PS1.titles = [
            "Chrono Cross (USA) (Disc 1)"
            "Chrono Cross (USA) (Disc 2)"
            "Legacy of Kain - Soul Reaver (USA)"
            "Persona (USA)"
            "Persona 2 - Tsumi - Innocent Sin (Japan)"
            "Persona 2 - Eternal Punishment (USA)"
          ];
          PS2.titles = [
            "Kingdom Hearts (USA)"
            "Kingdom Hearts II (USA)"
            "Shin Megami Tensei - Nocturne (USA)"
            "Shin Megami Tensei - Persona 3 (USA)"
            "Shin Megami Tensei - Persona 4 (USA)"
            "Shin Megami Tensei - Digital Devil Saga (USA)"
            "Shin Megami Tensei - Digital Devil Saga 2 (USA)"
            "Ookami (USA)"
          ];
          PS3.titles = [
            "Persona 5 (USA)"
          ];
          PSP.titles = [
            "Kingdom Hearts - Birth by Sleep (USA) (En,Fr,Es)"
          ];
          XB.titles = [
            "Shin Megami Tensei - Nine (Japan)"
          ];
        };
      };
      # Battle.net's wine prefix only exists once Steam has run the shortcut
      home.activation.wow-console-port = lib.hm.dag.entryAfter ["writeBoundary"] ''
        appid=$(${lib.getExe config.programs.steam.external.nostatoo} list-non-steam-games | ${lib.getExe pkgs.gawk} -F': ' '/Battle.Net/ {print $2}')
        if [ -n "$appid" ]; then
          dest="${config.home.homeDirectory}/.local/share/Steam/steamapps/compatdata/$appid/pfx/drive_c/Program Files (x86)/World of Warcraft/_retail_/Interface/AddOns"
          mkdir -p "$(dirname "$dest")"
          ln -sfn ${pinned.consoleport} "$dest"
        fi
      '';
    })
  ];
}
