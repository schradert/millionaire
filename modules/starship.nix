{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    programs = {
      elvish.initExtra = "eval (${lib.getExe config.programs.starship.package} init elvish)";
      yazi.initLua = "require(\"starship\"):setup()";
      yazi.plugins = {inherit (pkgs.yaziPlugins) starship;};
      starship.enable = true;
      starship.settings = {
        format = lib.concatStrings [
          "$container"
          "$os "
          "$username@$hostname "

          "$directory"

          "$git_branch"
          "$git_commit"
          "$git_state"
          "$git_status"
          "$git_metrics"

          "$package"
          "$bun"
          "$dart"
          "$deno"
          "$go"
          "$gradle"
          "$haskell"
          "$helm"
          "$java"
          "$julia"
          "$kotlin"
          "$lua"
          "$nodejs"
          "$pulumi"
          "$python"
          "$rust"
          "$scala"
          "$terraform"
          "$typst"
          "$zig"

          "$docker_context"
          "$gcloud"
          "$kubernetes"

          "$line_break"

          "$shell"
          "$direnv"
          "$nix_shell"
          "$character"
        ];
        right_format = lib.concatStrings [
          "$status"
          "$cmd_duration"
          "$time"
          "$line_break"
        ];
        container.symbol = "󰆧 ";
        os.disabled = false;
        os.symbols = {
          NixOS = "";
          Windows = "";
          Raspbian = "󰐿";
          Macos = "󰀵";
          Linux = "󰌽";
          Alpine = "";
          Android = "";
          Debian = "󰣚";
        };
        username.format = "[$user]($style)";
        username.show_always = true;
        hostname.format = "[$ssh_symbol$hostname]($style)";
        hostname.ssh_only = false;
        hostname.ssh_symbol = "󱫋 ";
        directory = {
          fish_style_pwd_dir_length = 1;
          substitutions = {
            "~/Documents" = "󰈙";
            "~/Downloads" = "";
            "~/Games" = "󰊗";
            "~/Music" = "󰝚";
            "~/Pictures" = "";
            "~/Projects" = "󰲋";
          };
          truncation_symbol = ".../";
          truncate_to_repo = false;
        };
        direnv.symbol = " ";
        nix_shell.symbol = "󰜗 ";
        shell = {
          bash_indicator = " ";
          fish_indicator = "󰈺 ";
          zsh_indicator = "󰬇 ";
          powershell_indicator = " ";
          elvish_indicator = "🧝";
          xonsh_indicator = "🐚";
          cmd_indicator = " ";
          nu_indicator = " ";
          unknown_indicator = "󰞋 ";
          disabled = false;
        };
        git_metrics.disabled = false;
        bun.symbol = " ";
        dart.symbol = " ";
        deno.symbol = " ";
        golang.symbol = " ";
        gradle.symbol = " ";
        haskell.symbol = " ";
        helm.symbol = " ";
        java.symbol = "";
        julia.symbol = " ";
        kotlin.symbol = " ";
        lua.symbol = " ";
        nodejs.symbol = "󰎙 ";
        pulumi.symbol = " ";
        python.symbol = " ";
        rust.symbol = " ";
        scala.symbol = " ";
        terraform.symbol = " ";
        typst.symbol = " ";
        zig.symbol = " ";
        docker_context.symbol = " ";
        gcloud.symbol = "󱇶 ";
        kubernetes.disabled = false;
        kubernetes.symbol = " ";
        cmd_duration = {
          min_time = 0;
          show_milliseconds = true;
          show_notifications = true;
          min_time_to_notify = 15000;
        };
        status.disabled = false;
        time.disabled = false;
      };
    };
  };
}
