{
  canivete.pkgs.allowUnfree = ["bws"];
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    user = flake.config.canivete.meta.people.users.${config.home.username};
    inherit (user.profiles.${config.profile}) email sshPubKey;
    # `bws-get <bws key>`: BWS_ACCESS_TOKEN decrypted from the repo's sops
    # file on demand (as devenv.nix does), nothing written to disk. Exits 1
    # quietly without the sops age key or the checkout. Also used by feed
    # readers (modules/feeds.nix).
    bwsGet = pkgs.writeShellApplication {
      name = "bws-get";
      runtimeInputs = with pkgs; [bws jq sops];
      text = ''
        sops_file=${lib.escapeShellArg "${config.home.homeDirectory}/Projects/millionaire/secrets/sops/default.yaml"}
        export SOPS_AGE_KEY_FILE="''${SOPS_AGE_KEY_FILE:-${
          if pkgs.stdenv.hostPlatform.isDarwin
          then "${config.home.homeDirectory}/Library/Application Support"
          else config.xdg.configHome
        }/sops/age/keys.txt}"
        [ -r "$SOPS_AGE_KEY_FILE" ] && [ -r "$sops_file" ] || exit 1
        BWS_ACCESS_TOKEN="$(sops --decrypt --extract '["bitwarden"]' "$sops_file")"
        export BWS_ACCESS_TOKEN
        bws secret list | jq -er --arg k "$1" '.[] | select(.key == $k) | .value'
      '';
    };
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
            gh-stack
          ];
          settings.editor = "hx";
          settings.git_protocol = "ssh";
          settings.aliases.co = "pr checkout";
        };
        programs.gh-dash.enable = true;
        home.packages = [bwsGet pkgs.glab];
      }
      {
        # Other git UIs
        home.packages = with pkgs; [code-maat gitu serie tig];
        programs.gitui.enable = true;
      }
      {
        # Doom: magit + forge
        programs.doom-emacs = {
          extraPackages = e: [e.magit-todos];
          extraBinPackages = [bwsGet];
          tangle.init = {
            tools.magit = ["+forge"];
            ui.vc-gutter = ["+pretty"];
          };
          tangle.config = ''
            (setq! user-full-name "${user.name}"
                   user-mail-address "${email}")
            (after! magit
              (require 'magit-todos) ; only its option is autoloaded, not the mode
              (magit-todos-mode 1)
              (setq! magit-revision-show-gravatars '("^Author:     " . "^Commit:     ")
                     magit-diff-refine-hunk 'all))

            ;; Forge tokens from Bitwarden Secrets Manager (pulumi #257) via the
            ;; bws-get script; fetched on demand, kept in memory only.
            (defvar +forge-token-keys
              '(("api.github.com" . "github/code-review/token")
                ("gitlab.com/api/v4" . "gitlab/code-review/token")))
            (cl-defun +forge-token-search (&rest spec &key host &allow-other-keys)
              (let ((hosts (if (listp host) host (list host))) found)
                (dolist (h hosts found)
                  (when-let* (((not found))
                              (key (cdr (assoc h +forge-token-keys)))
                              (token (car (ignore-errors (process-lines "bws-get" key)))))
                    (setq found (list (list :host h :user (plist-get spec :user)
                                            :secret token)))))))
            (with-eval-after-load 'auth-source
              (add-hook 'auth-source-backend-parser-functions
                        (lambda (entry)
                          (when (eq entry 'forge-token)
                            (auth-source-backend :source "forge-token" :type 'forge-token
                                                 :search-function #'+forge-token-search))))
              (add-to-list 'auth-sources 'forge-token))
          '';
        };
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
