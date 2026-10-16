# Secrets from Bitwarden Secrets Manager, fetched with the host's own machine token at boot and on every
# switch into /run/secrets. The option surface mirrors sops-nix (`secrets.<name>.{key,path,owner,group,mode}`)
# so a consumer only changes the module name. Off by default; design and migration plan: docs/secrets.md.
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.bwsSecrets;
    sysConfig = config;
    manifest = pkgs.writeText "bws-secrets.json" (builtins.toJSON (lib.mapAttrsToList (name: s: {inherit name;} // lib.getAttrs ["key" "project" "path" "owner" "group" "mode"] s) cfg.secrets));
    package = pkgs.writeShellApplication {
      name = "bws-secrets";
      runtimeInputs = with pkgs; [age bws coreutils jq];
      text = ''
        export BWS_SECRETS_MANIFEST=${manifest}
        export BWS_SECRETS_TOKEN_FILE=${lib.escapeShellArg cfg.tokenFile}
        export BWS_SECRETS_CACHE_DIR=${lib.escapeShellArg cfg.cacheDir}
        export BWS_SECRETS_HOST_KEY=${lib.escapeShellArg cfg.hostKey}
        ${lib.optionalString (cfg.serverUrl != null) "export BWS_SERVER_URL=${lib.escapeShellArg cfg.serverUrl}"}
        ${builtins.readFile ../lib/bws-secrets.sh}
      '';
    };
  in {
    options.bwsSecrets = {
      enable = lib.mkEnableOption "secrets fetched from Bitwarden Secrets Manager (docs/secrets.md)";
      tokenFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bws/token";
        description = "The host's machine access token, root-only. Delivered out of band at install; the one secret that is not in Bitwarden.";
      };
      cacheDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/bws/cache";
        description = "Last fetched values, age-encrypted to hostKey: a Bitwarden outage does not leave a rebooted host without its secrets.";
      };
      hostKey = lib.mkOption {
        type = lib.types.str;
        default = "/etc/ssh/ssh_host_ed25519_key";
        description = "ssh key the cache is encrypted to (its .pub) and decrypted with";
      };
      serverUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Bitwarden server (BWS_SERVER_URL); null is the cloud service";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        internal = true;
        description = "bws-secrets sync|restore";
      };
      secrets = lib.mkOption {
        default = {};
        description = "Secrets to install, by name";
        type = lib.types.attrsOf (lib.types.submodule ({
          config,
          name,
          ...
        }: {
          options = {
            key = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Name (`key`) of the Bitwarden secret; `project` when it exists in more than one readable project";
            };
            project = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Project id; null matches the secret in any project the token can read";
            };
            path = lib.mkOption {
              type = lib.types.str;
              default = "/run/secrets/${name}";
              description = "Where the value is installed. The directory must exist, except /run/secrets.";
            };
            owner = lib.mkOption {
              type = lib.types.str;
              default = "root";
            };
            group = lib.mkOption {
              type = lib.types.str;
              default = let
                group = sysConfig.users.users.${config.owner}.group or "";
              in
                if group == ""
                then "root"
                else group;
            };
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0400";
            };
          };
        }));
      };
    };
    config = lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = builtins.all (name: !(sysConfig.sops.secrets or {} ? ${name})) (builtins.attrNames cfg.secrets);
          message = "bwsSecrets.secrets and sops.secrets both define one of: ${toString (builtins.attrNames cfg.secrets)}";
        }
      ];
      systemd.tmpfiles.rules = ["d /var/lib/bws 0700 root root -"];
      # Early boot and every switch: the cached values, no network needed
      system.activationScripts.bwsSecrets = {
        deps = ["users" "groups"];
        text = "${lib.getExe cfg.package} restore || true";
      };
      # Then Bitwarden itself. Not required by anything: a failure leaves the cached values in place and shows as a failed unit.
      systemd.services.bws-secrets = {
        description = "Fetch secrets from Bitwarden Secrets Manager";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"];
        restartTriggers = [manifest];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe cfg.package} sync";
          TimeoutStartSec = "60";
          Restart = "on-failure";
          RestartSec = "5min";
        };
      };
    };
  };
}
