# Terminal DoomEmacs (nix-doom-emacs-unstraightened) beside helix (helix stays
# EDITOR). Org-node knowledge base + helix-mode keys instead of evil.
#
# `programs.doom-emacs.tangle.{init,config,packages,raw}` is a literate-config
# DSL tangled to init.el/config.el/packages.el: any module can contribute Doom
# modules/config the same way it contributes helix settings.
{
  system = {flake, ...}: {
    home-manager.sharedModules = [flake.inputs.nix-doom-emacs-unstraightened.homeModule];
  };
  home = {
    config,
    lib,
    pinned,
    pkgs,
    ...
  }: let
    inherit (builtins) concatStringsSep isBool isList;
    inherit (config.programs) doom-emacs;
    inherit (lib) mapAttrsToList mkDefault mkIf mkOption types;
    surround = target: value: concatStringsSep "\n" ["#+begin_src emacs-lisp ${target}" value "#+end_src"];
    # Nested attrset -> `doom!` block: categories (`lang`) -> modules (`nix`) ->
    # `true` (no flags) or a list of flags.
    toInit = attrs:
      lib.concatLines (
        ["(doom!"]
        ++ mapAttrsToList (cat: modules:
          lib.concatLines (
            [":${cat}"]
            ++ mapAttrsToList (mod: value:
              if isBool value
              then mod
              else if isList value
              then "(${mod} ${concatStringsSep " " value})"
              else abort "${lib.toPretty {} value} not supported")
            modules
          ))
        attrs
        ++ [")"]
      );
    nullOr = type:
      mkOption {
        type = types.nullOr type;
        default = null;
      };
  in {
    options.programs.doom-emacs = {
      files = mkOption {
        type = with types; attrsOf (either str path);
        default = {};
        description = "Extra files placed in the generated DOOMDIR.";
      };
      tangle = mkOption {
        default = {};
        description = "Literate Doom config, tangled to init.el/config.el/packages.el.";
        type = types.submodule ({config, ...}: {
          options = {
            init = nullOr (with types; attrsOf (attrsOf (either bool (listOf str))));
            raw = mkOption {
              type = types.lines;
              default = "";
            };
            config = nullOr types.lines;
            packages = nullOr types.lines;
          };
          config = lib.mkMerge [
            (mkIf (config.config != null) {raw = surround ":tangle config.el" config.config;})
            (mkIf (config.packages != null) {raw = surround ":tangle packages.el" config.packages;})
            (mkIf (config.init != null) {
              raw = surround ":tangle init.el" (concatStringsSep "\n" [
                # :app and :config only work at the end.
                (toInit (removeAttrs config.init ["app" "config"]))
                "(doom! :os (:if (featurep :system 'macos) macos))"
                (toInit (lib.filterAttrs (n: _: n == "app" || n == "config") config.init))
              ]);
            })
          ];
        });
      };
    };
    config = lib.mkMerge [
      {
        programs.doom-emacs = {
          files."tangle.org" = mkDefault doom-emacs.tangle.raw;
          tangleArgs = mkDefault "tangle.org";
          doomDir = lib.pipe doom-emacs.files [
            (mapAttrsToList (name: source: ''
              mkdir -p "$out/$(dirname "${name}")"
              ${
                if builtins.isPath source || lib.isStorePath source
                then "cp -rL ${source} \"$out/${name}\""
                else "echo ${lib.escapeShellArg source} > \"$out/${name}\""
              }
            ''))
            (concatStringsSep "\n")
            (pkgs.runCommand "doom-config" {})
            mkDefault
          ];
        };
      }
      (mkIf config.profiles.workstation.enable {
        home.packages = [pkgs.nerd-fonts.symbols-only];
        programs.doom-emacs = lib.mkMerge [
          {
            enable = true;
            # Cached on cache.nixos.org; emacs-overlay's emacs-unstable-nox is
            # not, and native-comp from source takes hours on the Mac.
            emacs = pkgs.emacs-nox;
            extraBinPackages = with config.programs; [ripgrep.package git.package fd.package];
            tangle.config = ''
              ;; org-directory must be set before org loads.
              (setq org-directory "${config.home.homeDirectory}/Projects/sabedoria")
              (setq! delete-by-moving-to-trash t)
            '';
            tangle.init = {
              completion = {
                vertico = ["+icons"];
                corfu = ["+orderless" "+dabbrev"];
              };
              config.default = true;
              editor = {
                fold = true;
                snippets = true;
                word-wrap = true;
              };
              emacs = {
                undo = ["+tree"];
                vc = true;
              };
              lang.emacs-lisp = true;
              os.tty = ["+osc"];
              ui = {
                doom-dashboard = true;
                hl-todo = true;
                modeline = true;
                ophints = true;
                popup = ["+defaults"];
              };
            };
          }
          {
            tangle.init.ui.doom = true;
            tangle.config = "(setq doom-theme 'doom-dracula)";
          }
          {
            # org-node knowledge base. org-roam (+roam2) stays only so org-mem's
            # roamy-db can feed org-roam-ui's graph without org-roam-db-sync.
            extraPackages = e: with e; [org-node org-mem org-ql org-roam-ui];
            extraBinPackages = with pkgs; [gnuplot sqlite pandoc];
            tangle.raw = builtins.readFile ./org.org;
            tangle.init.lang.org = ["+dragndrop" "+gnuplot" "+journal" "+pandoc" "+pomodoro" "+pretty" "+roam2"];
          }
          {
            tangle.init.checkers.spell = ["+aspell" "+flyspell"];
            extraBinPackages = [(pkgs.aspellWithDicts (d: [d.en]))];
          }
          {
            # helix keys instead of evil. Repo is helix-mode, package/feature is
            # `helix`; not on MELPA, so explicit recipe + pin (unstraightened
            # rejects unpinned github packages). Commit lives in pkgs/helix-mode.
            tangle.packages = ''(package! helix :recipe (:host github :repo "mgmarlow/helix-mode") :pin "${pinned.helix-mode.pin.version}")'';
            tangle.config = "(use-package! helix :config (helix-mode 1))";
          }
        ];
      })
    ];
  };
}
