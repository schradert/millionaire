# Personal Macs join headscale like the NixOS desktops (static/tailnet-personal.nix):
# tailscaled from nix-darwin, plus a root launchd job that logs in with the
# personal preauth key (secrets/sops/personal.yaml, decrypted with tristan's age
# key) whenever the daemon needs a login. Work Macs keep their employer's
# tailnet (modules/work), so this stays off there.
{
  darwin = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta) domain people;
    tailscale = lib.getExe config.services.tailscale.package;
    login = pkgs.writeShellApplication {
      name = "tailscale-login";
      runtimeInputs = with pkgs; [jq sops];
      text = ''
        state=$(${tailscale} status --json | jq -r .BackendState)
        [ "$state" = NeedsLogin ] || [ "$state" = NoState ] || exit 0
        export SOPS_AGE_KEY_FILE="/Users/${people.me}/Library/Application Support/sops/age/keys.txt"
        [ -r "$SOPS_AGE_KEY_FILE" ] || exit 0
        key=$(sops --decrypt --extract '["headscale"]["preauth-key"]["personal"]' ${builtins.path {
          path = ../secrets/sops/personal.yaml;
          name = "sops-personal.yaml";
        }})
        ${tailscale} up --login-server=https://headscale.${domain} --auth-key="$key"
      '';
    };
  in {
    config = lib.mkIf (config.profiles.workstation.enable && config.profile == "personal") {
      services.tailscale.enable = true;
      launchd.daemons.tailscale-login.serviceConfig = {
        ProgramArguments = [(lib.getExe login)];
        RunAtLoad = true;
        StartInterval = 300;
      };
    };
  };
}
