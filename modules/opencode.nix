{
  canivete.pkgs.allowUnfree = ["claude-code"];
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.sessionVariables = {
        ANTHROPIC_API_KEY = "$(cat ~/.secrets/anthropic)";
        CONTEXT7_API_KEY = "$(cat ~/.secrets/context7)";
        OPENAI_API_KEY = "$(cat ~/.secrets/openai)";
      };
      # opencode-claude-auth was previously programs.opencode.extraPackages,
      # which home-manager removed; the plugin itself is still activated via
      # settings.plugin below.
      home.packages = [pkgs.opencode-desktop pkgs.opencode-claude-auth];
      programs = {
        claude-code.enable = true;
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
          # home-manager renamed context -> rules and dropped the dedicated
          # tui option (tui config lives in settings/opencode.json now).
          rules = ''
            When you need to search docs, use `context7` tools.
            If you are unsure how to do something, use `gh_grep` to search code examples from github.
          '';
          settings = {
            tui.scroll_acceleration.enabled = true;
            autoupdate = false;
            permission.edit = "ask";
            permission.bash = "ask";
            plugin = ["opencode-claude-auth"];
            agent.build.enable1mContext = true;
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
