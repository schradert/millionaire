{
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    user = flake.config.canivete.meta.people.users.${config.home.username};
    inherit (user.profiles.${config.profile}) email sshPubKey;
  in {
    imports = [
      {
        home.packages = lib.mkIf config.programs.zellij.enable [
          (pkgs.writeShellScriptBin "floating-lazygit" ''
            #!/bin/env bash
            zellij run -c -f --width 95% --height 95% -x 2% -y 2% -- lazygit
          '')
        ];
        programs = {
          git = {
            enable = true;
            lfs.enable = true;
            settings = {
              alias.stash = "stash --all";
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
              user = {
                inherit (user) name;
                inherit email;
              };
            };
          };
          helix.settings.keys.normal.space.g = {
            # TODO https://github.com/helix-editor/helix/issues/3035#issuecomment-1575437988
            l = ":sh floating-lazygit";
            L = [
              ":write-all"
              ":new"
              ":insert-output lazygit"
              ":set mouse false"
              ":set mouse true"
              ":buffer-close!"
              ":redraw"
              ":reload-all"
            ];
            b = builtins.concatStringsSep " " [
              ":sh git log --no-patch --max-count=5"
              "--format='format:%%h (%%an: %%ar) %%s'"
              "-L%{cursor_line},+1:%{buffer_name}"
            ];
          };
          delta.enable = true;
          delta.enableGitIntegration = true;
          delta.options = {
            diff-so-fancy = true;
            hyperlinks = true;
            line-numbers = true;
          };
          lazygit.enable = true;
          lazygit.settings.git = {
            # Allow amending commits in history
            overrideGpg = true;
            pagers = [
              {pager = "delta --paging=never --hyperlinks-file-link-format=\"lazygit-edit://{path}:{line}\"";}
            ];
          };
          zsh.initContent = ''
            # disable sort when completing `git checkout`
            zstyle ':completion:*:git-checkout:*' sort false
          '';
        };
      }
      {
        programs.git.settings.github.user = user.accounts.github;
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
        programs.git.settings = {
          user.signingKey = sshPubKey;
          gpg.format = "ssh";
          gpg.ssh.program = "${pkgs.openssh}/bin/ssh-keygen";
          gpg.ssh.allowedSignersFile = toString (pkgs.writeText "allowed_signers" "* ${sshPubKey}");
          commit.gpgSign = true;
          tag.gpgSign = true;
          push.gpgSign = "if-asked";
        };
      }
      {
        # Theme
        # NOTE stylix doesn't support git
        programs.git.settings.color = {
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
  };
}
