{
  home = {
    config,
    flake,
    lib,
    pinned,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) (let
      skills =
        lib.mapAttrs (name: _: "${flake.inputs.datadog-agent-skills}/${name}")
        (lib.filterAttrs (_: t: t == "directory") (builtins.readDir flake.inputs.datadog-agent-skills));
    in {
      home.packages = [pinned.datadog-pup];
      programs.mcp.servers.datadog = {
        type = "http";
        url = "https://mcp.datadoghq.com/api/mcp?toolsets=core,apm,dbm,error-tracking";
      };
      programs.claude-code.skills = skills;
      programs.opencode.skills = skills;
      # FIXME drop when home-manager's programs.claude-code gains a `plugins` option.
      home.file.".claude/plugins/datadog-api".source = flake.inputs.datadog-api-claude-plugin;
    });
  };
}
