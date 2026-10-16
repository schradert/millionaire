# LLM/MCP API keys for the shell and agents (modules/opencode.nix), decrypted
# from secrets/sops/personal.yaml (`api/<name>`) to /run/secrets/api-<name>,
# 0400 and owned by the primary user. System-level on purpose: nix-darwin and
# NixOS already run sops-install-secrets, with tristan's age key on the Macs
# (~/Library/Application Support/sops/age/keys.txt) and the ssh host key on
# personal NixOS hosts (.sops.yaml lists the recipients). Replaces the
# hand-placed ~/.secrets/<name> files.
{
  system = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta.people) me;
  in {
    options.apiKeys.enable = lib.mkOption {
      type = lib.types.bool;
      default = config.profiles.workstation.enable && pkgs.stdenv.hostPlatform.isDarwin;
      defaultText = "workstation profile on macOS; NixOS hosts that are recipients of personal.yaml opt in";
      description = "Decrypt the personal API keys (secrets/sops/personal.yaml) for the primary user";
    };
    config = lib.mkIf config.apiKeys.enable {
      sops.secrets = lib.listToAttrs (map (name:
        lib.nameValuePair "api-${name}" {
          key = "api/${name}";
          # by contents, not via the flake source
          sopsFile = builtins.path {
            path = ../secrets/sops/personal.yaml;
            name = "sops-personal.yaml";
          };
          owner = me;
          mode = "0400";
        }) ["anthropic" "context7" "openai"]);
    };
  };
}
