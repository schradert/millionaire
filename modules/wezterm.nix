# Unported from old/old/dev/shells/wezterm.nix: darwin launchd autostart agent.
{
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      programs.wezterm.enable = true;
      # Keep SSH_AUTH_SOCK from the ssh-agent service.
      programs.wezterm.extraConfig = "return {mux_enable_ssh_agent = false}";
    };
  };
}
