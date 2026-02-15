{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    exitBindings = rec {
      enter = "mode main";
      esc = enter;
    };
    directional = cmd: {
      h = "${cmd} left";
      j = "${cmd} down";
      k = "${cmd} up";
      l = "${cmd} right";
    };
    sequential = cmd: {prefix ? ""}: {
      a = "${cmd} ${prefix}prev";
      f = "${cmd} ${prefix}next";
    };
    workspaces = cmd:
      lib.pipe (lib.range 1 9) [
        (map toString)
        (lib.flip lib.genAttrs lib.id)
        (lib.mergeAttrs {"0" = "10";})
        (builtins.mapAttrs (_: n: "${cmd} ${n}"))
      ];

    mkMode = bindings: {binding = exitBindings // bindings;};

    focus-monitor = "focus-monitor --wrap-around";
    move-node-to-monitor = "move-node-to-monitor --focus-follows-window --wrap-around";
    move-node-to-workspace = "move-node-to-workspace --focus-follows-window";
    move-workspace-to-monitor = "move-workspace-to-monitor --wrap-around";
    swap = "swap --wrap-around";
  in {
    config = lib.mkIf (config.profiles.workstation.enable && pkgs.stdenv.hostPlatform.isDarwin) {
      programs.aerospace = {
        enable = true;
        launchd.enable = true;
        # NOTE https://nikitabobko.github.io/AeroSpace/guide
        settings = {
          automatically-unhide-macos-hidden-apps = true;
          on-focused-monitor-changed = ["move-mouse monitor-lazy-center"];
          on-focus-changed = ["move-mouse window-lazy-center"];

          gaps = {
            inner.horizontal = 8;
            inner.vertical = 8;
            outer.left = 8;
            outer.right = 8;
            outer.top = 8;
            outer.bottom = 8;
          };

          mode = {
            main.binding = {
              cmd-shift-equal = "balance-sizes";
              cmd-shift-w = "close --quit-if-last-window";
              cmd-shift-q = "close-all-windows-but-current --quit-if-last-window";
              cmd-shift-esc = "enable toggle";
              cmd-shift-minus = "flatten-workspace-tree";
              cmd-shift-tab = "exec-and-forget aerospace focus-back-and-forth || aerospace workspace-back-and-forth";
              cmd-shift-enter = "fullscreen";

              cmd-shift-f = "mode focus";
              cmd-shift-g = "mode focus-monitor";
              cmd-shift-j = "mode join";
              cmd-shift-l = "mode layout";
              cmd-shift-m = "mode move";
              cmd-shift-comma = "mode move-node-to-monitor";
              cmd-shift-period = "mode move-node-to-workspace";
              cmd-shift-slash = "mode move-workspace-to-monitor";
              cmd-shift-r = "mode resize";
              cmd-shift-s = "mode swap";
              cmd-shift-d = "mode summon-workspace";
              cmd-shift-e = "mode workspace";
            };

            focus = mkMode (
              directional "focus --boundaries all-monitors-outer-frame --boundaries-action wrap-around-all-monitors"
              // sequential "focus --boundaries-action wrap-around-the-workspace" {prefix = "dfs-";}
            );
            focus-monitor = mkMode (directional focus-monitor // sequential focus-monitor {});
            join = mkMode (directional "join-with");
            layout = mkMode {
              slash = "layout tiles horizontal vertical";
              comma = "layout accordion horizontal vertical";
            };
            move = mkMode (directional "move --boundaries all-monitors-outer-frame --boundaries-action create-implicit-container");
            move-node-to-monitor = mkMode (directional move-node-to-monitor // sequential move-node-to-monitor {});
            move-node-to-workspace = mkMode (sequential "${move-node-to-workspace} --wrap-around" {} // workspaces move-node-to-workspace);
            move-workspace-to-monitor = mkMode (directional move-workspace-to-monitor // sequential move-workspace-to-monitor {});
            resize = mkMode {
              h = "resize width -50";
              j = "resize height +50";
              k = "resize height -50";
              l = "resize width +50";
            };
            swap = mkMode (directional swap // sequential swap {prefix = "dfs-";});
            summon-workspace = mkMode (workspaces "summon-workspace");
            workspace = mkMode (sequential "workspace --wrap-around" {} // workspaces "workspace");
          };
        };
      };
    };
  };
}
