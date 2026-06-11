{
  home = {...}: {
    programs.vdirsyncer.enable = true;

    # systemd timer for Linux
    services.vdirsyncer = {
      enable = true;
      frequency = "*:0/5";
    };
  };

  darwin = {
    lib,
    pkgs,
    ...
  }: {
    launchd.agents.vdirsyncer = {
      serviceConfig = {
        ProgramArguments = ["${lib.getExe pkgs.vdirsyncer}" "sync"];
        StartInterval = 300;
        RunAtLoad = true;
      };
    };
  };
}
