{
  config,
  lib,
  pkgs,
  ...
}: let
  key = lib.fileContents ../me.pub;
in {
  imports = [
    {
      programs = {
        git = {
          enable = true;
          userName = "Tristan Schrader";
          userEmail = "tristan@mill.com";
          aliases.stash = "stash --all";
          delta.enable = true;
          delta.options = {
            diff-so-fancy = true;
            hyperlinks = true;
            line-numbers = true;
          };
          extraConfig = {
            branch.sort = "-committerdate";
            column.ui = "auto";
            core.fsmonitor = true;
            core.hooksPath = "${config.xdg.stateHome}/git/hooks";
            core.untrackedCache = true;
            diff.noprefix = true;
            fetch.writeCommitGraph = true;
            init.defaultBranch = "trunk";
            maintenance.auto = false;
            maintenance.strategy = "incremental";
            push.autoSetupRemote = true;
            rebase.autoSquash = true;
            rebase.autoStash = true;
            rebase.updateRefs = true;
            rerere.enabled = true;
          };
          lfs.enable = true;
        };
        lazygit.enable = true;
        lazygit.settings.git.paging.pager = "delta --paging=never --hyperlinks-file-link-format=\"lazygit-edit://{path}:{line}\"";
        zsh.initContent = ''
          # disable sort when completing `git checkout`
          zstyle ':completion:*:git-checkout:*' sort false
        '';
      };
    }
    {
      programs.git.extraConfig.github.user = "schradert";
      programs.gh = {
        enable = true;
        extensions = with pkgs; [
          gh-f
          gh-poi
          gh-gei
          gh-eco
          gh-notify
          gh-skyline
          gh-signoff
        ];
        settings.editor = "hx";
        settings.git_protocol = "ssh";
        settings.aliases.co = "pr checkout";
      };
      programs.gh-dash.enable = true;
    }
    {
      # Signing
      programs.gpg.enable = true;
      programs.gpg.homedir = "${config.xdg.dataHome}/gnupg";
      programs.git.extraConfig = {
        user.signingKey = key;
        gpg.format = "ssh";
        gpg.ssh.program = "${pkgs.openssh}/bin/ssh-keygen";
        gpg.ssh.allowedSignersFile = toString (pkgs.writeText "allowed_signers" "* ${key}");
        commit.gpgSign = true;
        tag.gpgSign = true;
        push.gpgSign = "if-asked";
      };
    }
    {
      # Theme
      # NOTE stylix doesn't support git
      programs.git.extraConfig.color = {
        ui = "auto";
        branch = {
          current = "cyan bold reverse";
          local = "white";
          plain = "";
          remote = "cyan";
        };
        diff = {
          commit = "";
          func = "cyan";
          plain = "";
          whitespace = "magenta reverse";
          meta = "white";
          frag = "cyan bold reverse";
          old = "red";
          new = "green";
        };
        grep = {
          context = "";
          filename = "";
          function = "";
          linenumber = "white";
          match = "";
          selected = "";
          separator = "";
        };
        interactive = {
          error = "";
          header = "";
          help = "";
          prompt = "";
        };
        status = {
          added = "green";
          changed = "yellow";
          header = "";
          localBranch = "";
          nobranch = "";
          remoteBranch = "cyan bold";
          unmerged = "magenta bold reverse";
          untracked = "red";
          updated = "green bold";
        };
      };
    }
  ];
}
