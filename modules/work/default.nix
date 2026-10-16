{
  canivete.pkgs.allowUnfree = ["ngrok" "snowsql"];
  system = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profile == "work") {
      services.tailscale.enable = true;
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      home.packages = with pkgs;
        lib.mkMerge [
          [lazydocker ngrok]
          (lib.mkIf pkgs.stdenv.hostPlatform.isLinux [slack snowsql])
        ];
      home.sessionPath = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin [
        "/Applications/SnowSQL.app/Contents/MacOS"
      ];
    };
  };
  nixos = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      virtualisation.docker.enable = true;
    };
  };
  darwin = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      homebrew.casks = [
        "docker-desktop"
        # Slack is installed and owned by the employer's MDM (Iru); adopting it as a cask fails.
        "snowflake-snowsql"
      ];
      # TODO get this to work without homebrew
      homebrew.brews = [
        # ChewieAPI
        "fop"
        "openssl"
        "unixodbc"
        "openjdk"
        # wxmac was renamed to wxwidgets upstream.
        "wxwidgets"
      ];
    };
  };
}
