{
  imports = [./apps ./system];
  devenv = {
    git-hooks.excludes = ["nixidy/generated"];
    git-hooks.hooks.lychee.toml.exclude = ["^.+\\.svc$"];
  };
  nixidy = {config, ...}: {
    nixidy.target = {
      repository = "https://github.com/schradert/millionaire.git";
      rootPath = "./nixidy/generated/${config.nixidy.env}";
      branch = "main";
    };
  };
}
