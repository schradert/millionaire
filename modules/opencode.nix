{
  canivete.pkgs.allowUnfree = ["claude-code"];
  home = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.sessionVariables = {
        ANTHROPIC_API_KEY = "$(cat ~/.secrets/anthropic)";
        CONTEXT7_API_KEY = "$(cat ~/.secrets/context7)";
        OPENAI_API_KEY = "$(cat ~/.secrets/openai)";
      };
      # FIXME move most of this to per-project devenv (claude.code.*, opencode.*)
      # once we're ready — home-manager is the interim user-global layer.
      programs = {
        claude-code.enable = true;
        claude-code.enableMcpIntegration = true;
        claude-code.settings = {
          model = "opus[1m]";
          alwaysThinkingEnabled = true;
        };
        mcp.enable = true;
        mcp.servers = {
          context7.url = "https://mcp.context7.com/mcp";
          context7.headers.CONTEXT7_API_KEY = "{env:CONTEXT7_API_KEY}";
          gh_grep.url = "https://mcp.grep.app";
        };
        zed-editor.userSettings.agent_servers.OpenCode = {
          command = "opencode";
          args = ["acp"];
        };
        opencode = {
          enable = true;
          enableMcpIntegration = true;
          agents = let
            # NOTE currently passing this to devenv-agents devenv.nix module
            inputs = {
              pkgs = null;
              config = null;
              lib = null;
              inputs = null;
            };
            inherit ((import "${flake.inputs.devenv-agents}/devenv.nix" inputs).claude.code) agents;
          in
            builtins.mapAttrs (_: agent: agent.prompt) agents;
          rules = ''
            When you need to search docs, use `context7` tools.
            If you are unsure how to do something, use `gh_grep` to search code examples from github.
          '';
          settings = {
            autoupdate = false;
            tui.scroll_acceleration.enabled = true;
            permission.edit = "ask";
            permission.bash = "ask";
            provider = {
              anthropic = {
                options.apiKey = "{env:ANTHROPIC_API_KEY}";
              };
              openai = {
                options.apiKey = "{env:OPENAI_API_KEY}";
              };
            };
          };
        };
      };
    };
  };
}
