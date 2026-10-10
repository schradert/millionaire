# chiaki-ng PS5 Remote Play as a Steam shortcut: wake the console, wait until
# it is ready, then stream. Reads the console registered in chiaki-ng's GUI.
# NOTE one console; registration itself is not declarative
{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.programs.steam.external.chiaki;
    conf = "${config.home.homeDirectory}/.config/Chiaki/Chiaki.conf";
    images = pkgs.runCommand "chiaki-ng-images" {} ''
      tar -xf ${cfg.package.src}/assets/chiaki-ngImages.tar.xz
      install -D --mode 644 --target-directory $out chiaki-ng-images/steam_*.png
    '';
    launcher = pkgs.writeShellApplication {
      name = "chiaki-launcher";
      runtimeInputs = [cfg.package];
      text = ''
        conf=${lib.escapeShellArg conf}
        timeout=''${1:-35}
        console="$(grep server_nickname "$conf" | cut -d= -f2)"
        host="$(grep host= "$conf" | cut -d= -f2)"
        key="$(grep regist_key "$conf" | cut -d\( -f2 | cut -d\\ -f1)"
        elapsed=0
        while ! chiaki discover --host "$host" | grep -q ready; do
          if [[ $elapsed -gt $timeout ]]; then
            echo "console did not wake up within ''${timeout}s" >&2
            exit 1
          fi
          chiaki wakeup --ps5 --host "$host" --registkey "$key"
          sleep 5
          elapsed=$((elapsed + 5))
        done
        exec chiaki stream "$console" "$host"
      '';
    };
  in {
    options.programs.steam.external.chiaki = {
      enable = can.enable "chiaki-ng PS5 Remote Play shortcut" {};
      package = can.package "chiaki-ng" {default = pkgs.chiaki-ng;};
    };
    config = lib.mkIf cfg.enable {
      home.packages = [cfg.package];
      programs.steam.external.manual.chiaki-ng = {
        shortcut.exe = lib.getExe launcher;
        assets = {
          icon = images + "/steam_icon.png";
          logo = images + "/steam_logo.png";
          hero = images + "/steam_hero.png";
          banner = images + "/steam_landscape.png";
          portrait = images + "/steam_portrait.png";
        };
      };
    };
  };
}
