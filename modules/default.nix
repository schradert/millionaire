{
  canivete.pkgs.allowUnfree = ["beeper" "slack" "spotify"];
  system = {
    flake,
    lib,
    ...
  }: {
    nix.settings.trusted-users = ["root"];
    nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) flake.config.canivete.pkgs.allowUnfree;
    time.timeZone = "America/Los_Angeles";
    home-manager.useGlobalPkgs = true;
  };
  darwin = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      homebrew.casks = [
        "beeper"
        "brave-browser"
        # "discord"
        # "orca-slicer"
        "siyuan"
      ];
    };
  };
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable (lib.mkMerge [
      {
        # Agency-agents: 100+ AI agent personas for OpenCode/Claude Code
        # Patched so OpenCode accepts them:
        #   - Named colors (`color: green`) → hex codes (`color: "#22C55E"`)
        #   - Comma-separated `tools:` string → YAML record
        home.file.".opencode/agents".source = pkgs.runCommand "agency-agents-patched" {
          nativeBuildInputs = [pkgs.gnused pkgs.gawk];
        } ''
          cp -r ${flake.inputs.agency-agents}/. $out
          chmod -R u+w $out
          find $out -name "*.md" | while IFS= read -r f; do
            sed -i \
              -e 's/^color: purple$/color: "#9333EA"/' \
              -e 's/^color: violet$/color: "#7C3AED"/' \
              -e 's/^color: orange$/color: "#F97316"/' \
              -e 's/^color: green$/color: "#22C55E"/' \
              -e 's/^color: red$/color: "#EF4444"/' \
              -e 's/^color: cyan$/color: "#06B6D4"/' \
              -e 's/^color: teal$/color: "#14B8A6"/' \
              -e 's/^color: blue$/color: "#3B82F6"/' \
              -e 's/^color: yellow$/color: "#EAB308"/' \
              -e 's/^color: pink$/color: "#EC4899"/' \
              -e 's/^color: fuchsia$/color: "#D946EF"/' \
              -e 's/^color: rose$/color: "#F43F5E"/' \
              -e 's/^color: lime$/color: "#84CC16"/' \
              -e 's/^color: indigo$/color: "#6366F1"/' \
              -e 's/^color: amber$/color: "#F59E0B"/' \
              -e 's/^color: slate$/color: "#64748B"/' \
              -e 's/^color: gray$/color: "#6B7280"/' \
              -e 's/^color: gold$/color: "#D97706"/' \
              -e 's/^color: neon-cyan$/color: "#00FFFF"/' \
              -e 's/^color: metallic-blue$/color: "#60A5FA"/' \
              -e 's/^color: neon-green$/color: "#39FF14"/' \
              "$f"
            awk '
              BEGIN { fm = 0 }
              /^---$/ { fm++; print; next }
              fm == 1 && /^tools: / {
                sub(/^tools: /, "")
                n = split($0, arr, /, */)
                print "tools:"
                for (i = 1; i <= n; i++) print "  " arr[i] ": true"
                next
              }
              { print }
            ' "$f" > "$f.new" && mv "$f.new" "$f"
          done
        '';
        home.packages = with pkgs; [
          bottom
          gping
          hwatch
          iftop
          klipper-estimator
          lnav
          lsof
          procps
          trippy
          zenith
        ];
        programs = {
          bat.enable = true;
          btop.enable = true;
          btop.settings.vim_keys = true;
          carapace.enable = true;
          dircolors.enable = true;
          elvish.initExtra = "eval (${lib.getExe config.programs.carapace.package} _carapace elvish | slurp)";
          eza = {
            enable = true;
            git = true;
            icons = "auto";
            extraOptions = ["--color=always" "--group-directories-first"];
          };
          fd.enable = true;
          fzf.enable = true;
          home-manager.enable = true;
          jq.enable = true;
          jqp.enable = true;
          ripgrep.enable = true;
          ssh.enable = true;
          ssh.enableDefaultConfig = false;
          zoxide.enable = true;
        };
      }
      (lib.mkIf config.profiles.workstation.enable {
        home.packages = with pkgs;
          lib.mkMerge [
            [
              bitwarden-desktop
              spotify
            ]
            (lib.mkIf stdenv.hostPlatform.isLinux [
              beeper
              discord
              brave
              siyuan
            ])
          ];
        programs = {
          elvish.enable = true;
          navi.enable = true;
          rbw.enable = true;
          spotify-player.enable = true;
          wezterm.enable = true;
          # FIXME why do I keep having to rebuild this?!
          # zed-editor.enable = true;
        };
      })
    ]);
  };
}
