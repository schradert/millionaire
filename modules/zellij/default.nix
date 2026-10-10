{
  system = {flake, ...}: {
    nixpkgs.overlays = with flake.inputs.mynur; [
      overlays.zellij
      overlays.zellij-plugins
      inputs.fenix.overlays.default
    ];
  };
  # FIXME avoid IFD building other systems
  darwin.home-manager.sharedModules = [
    ({
      lib,
      config,
      pkgs,
      ...
    }: {
      # system.kdl (#266) stays a file until it is ported to `layouts`.
      xdg.configFile."zellij/layouts/system.kdl" = lib.mkIf config.profiles.workstation.enable {source = ./layouts/system.kdl;};
      programs.zellij = {
        enable = true;
        # Auto-starts a zellij session in every interactive zsh shell
        # outside an existing session; start zellij explicitly instead.
        enableZshIntegration = false;
        plugins = with pkgs.zellijPlugins; [
          room
          monocle
          zellij-forgot
          zj-quit
          zellij-choose-tree
          zjstatus
        ];
        layouts = lib.mkIf config.profiles.workstation.enable {
          project.layout._children = [
            {
              default_tab_template.children = [
                {
                  pane.size = 1;
                  pane.borderless = true;
                  pane.plugin.location = "zellij:tab-bar";
                }
              ];
            }
            {
              tab._props.name = "edit";
              tab._children = [
                {
                  pane.size = "80%";
                  pane.name = "hx";
                  pane.command = "hx";
                }
                {
                  pane.size = "20%";
                  pane.name = "yazi";
                  pane.command = "y";
                }
              ];
            }
            {
              tab._props.name = "git";
              tab._children = [
                {
                  pane.size = "100%";
                  pane.name = "lazygit";
                  pane.command = "lazygit";
                }
              ];
            }
            {
              tab._props.name = "agent";
              tab._children = [
                {
                  pane.size = "100%";
                  pane.name = "opencode";
                  pane.command = "opencode";
                }
              ];
            }
            {
              tab._props.name = "term";
              tab._children = [
                {
                  pane.size = "100%";
                  pane.name = "term";
                }
              ];
            }
          ];
        };
        settings.keybinds._children = [
          {
            shared_except._args = ["locked"];
            shared_except._children = [
              {
                bind._args = ["Ctrl y"];
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["room"];
                      _children = [
                        {floating = true;}
                        {ignore_case = true;}
                        {quick_jump = true;}
                      ];
                    };
                  }
                ];
              }
              {
                bind._args = ["Ctrl f"];
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["monocle"];
                      _children = [
                        {floating = true;}
                      ];
                    };
                    SwitchToMode._args = ["Normal"];
                  }
                ];
              }
              {
                bind._args = ["Ctrl F"];
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["monocle"];
                      _children = [
                        {in_place = true;}
                        {kiosk = true;}
                      ];
                    };
                    SwitchToMode._args = ["Normal"];
                  }
                ];
              }
              {
                bind._args = ["Ctrl H"];
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["zellij_forgot"];
                      _children = [
                        {floating = true;}
                      ];
                    };
                  }
                ];
              }
              {
                bind._args = ["Ctrl q"];
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["zj-quit"];
                      _children = [
                        {floating = true;}
                      ];
                    };
                  }
                ];
              }
            ];
          }
          {
            tmux._children = [
              {
                bind._args = "s";
                bind._children = [
                  {
                    LaunchOrFocusPlugin = {
                      _args = ["zellij-choose-tree"];
                      _children = [
                        {floating = true;}
                        {move_to_focused_tab = true;}
                        {show_plugins = true;}
                      ];
                    };
                  }
                ];
              }
            ];
          }
        ];
      };
    })
  ];
}
