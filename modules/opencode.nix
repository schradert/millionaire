{config, ...}: let
  inherit (config.canivete.meta) domain;
  # contextforge's virtual server (serverId in nixidy/system/ai/contextforge.nix)
  contextforge = "https://mcp.${domain}/servers/05238f180ea94c7c8c5621976aec4604/mcp";
in {
  canivete.pkgs.allowUnfree = ["claude-code"];
  home = {
    config,
    flake,
    lib,
    osConfig ? null,
    pkgs,
    ...
  }: let
    # Decrypted by the system's sops (modules/api-keys.nix); a host that is not
    # a recipient of personal.yaml simply has no keys instead of a broken shell
    secrets = lib.optionalAttrs (osConfig != null) osConfig.sops.secrets;
    apiKey = name: lib.optionalAttrs (secrets ? "api-${name}") {"${lib.toUpper name}_API_KEY" = "$(cat ${secrets."api-${name}".path})";};
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.sessionVariables = lib.mergeAttrsList (map apiKey ["anthropic" "context7" "openai"]);
      home.packages = [pkgs.opencode-desktop];
      programs = {
        claude-code.enable = true;
        mcp.enable = true;
        mcp.servers = {
          context7.url = "https://mcp.context7.com/mcp";
          context7.headers.CONTEXT7_API_KEY = "{env:CONTEXT7_API_KEY}";
          gh_grep.url = "https://mcp.grep.app";
          # Read-only cluster access through `kubeconfig`'s file (modules/kubernetes.nix)
          kubernetes = {
            command = lib.getExe pkgs.mcp-k8s-go;
            args = ["--readonly" "--allowed-contexts=trdos"];
            env.KUBECONFIG = "${config.home.homeDirectory}/.kube/trdos";
          };
          # Every MCP server registered in contextforge, as Keycloak user tristan
          # (`sso-token mcp`, modules/sso.nix; one-time `sso-token login`).
          contextforge = {
            command = "sso-token";
            args = ["mcp" contextforge];
          };
        };
        zed-editor.userSettings.agent_servers.OpenCode = {
          command = "opencode";
          args = ["acp"];
        };
        opencode = {
          enable = true;
          enableMcpIntegration = true;
          extraPackages = [pkgs.opencode-claude-auth];
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
          context = ''
            When you need to search docs, use `context7` tools.
            If you are unsure how to do something, use `gh_grep` to search code examples from github.
          '';
          tui.scroll_acceleration.enabled = true;
          settings = {
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
