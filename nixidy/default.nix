{
  imports = [./apps ./system];
  perSystem.canivete.devenv.shells.default.git-hooks.excludes = ["nixidy/generated"];
  nixidy = {config, ...}: {
    nixidy.target = {
      repository = "https://github.com/schradert/millionaire.git";
      rootPath = "./nixidy/generated/${config.nixidy.env}";
    };
  };
}
