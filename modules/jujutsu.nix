{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    git = config.programs.git.settings;
    jj = lib.getExe config.programs.jujutsu.package;
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [jj-fzf watchman];
      programs = {
        jujutsu.enable = true;
        jujutsu.settings = {
          core.fsmonitor = "watchman";
          # Same ssh signing key as git (modules/git.nix).
          signing = {
            backend = "ssh";
            backends.ssh.allowed-signers = git.gpg.ssh.allowedSignersFile;
            backends.ssh.program = git.gpg.ssh.program;
            behavior = "own";
            key = git.user.signingKey;
          };
          ui.conflict-marker-style = "git";
          ui.diff-formatter = ":git";
          ui.pager = "delta";
          user = {inherit (git.user) email name;};
        };
        jjui.enable = true;
        bash.initExtra = "source <(COMPLETE=bash ${jj})";
        zsh.initContent = "source <(COMPLETE=zsh ${jj})";
        nushell.sources.jj = "${jj} util completion nushell";
        doom-emacs.extraPackages = e: [e.vc-jj e.jjdescription];
      };
    };
  };
}
