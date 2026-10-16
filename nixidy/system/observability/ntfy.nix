# Token for the in-cluster publishers to hyena's ntfy, which denies anonymous access once its users exist
# (static/ntfy.nix). Off until the pulumi step and the hyena deploy of docs/manual-steps.md 18 are done: ntfy
# answers 401 to a token it does not know even on an open topic, so nothing may send one earlier, and the
# publishers' images must carry the token support (app-bootstrap >= 0.49.0, e2e >= 0.17.3, dvdrip >= 0.1.6,
# backup-verify >= 0.2.1) before the flip. An Application that sets `ntfySecret` (the ntfy user) gets the ExternalSecret
# `<app>-ntfy` (key `token`, Bitwarden `ntfy/<user>/token`); `ntfyToken.env "<app>"` is its `NTFY_TOKEN` env.
{...}: {
  nixidy = {
    can,
    config,
    lib,
    ...
  }: let
    cfg = config.ntfy;
  in {
    options.ntfy.auth = can.bool "Publishers send their ntfy token" {default = false;};
    config = {
      _module.args.ntfyToken = {
        enable = cfg.auth;
        env = app:
          lib.optional cfg.auth {
            name = "NTFY_TOKEN";
            valueFrom.secretKeyRef = {
              name = "${app}-ntfy";
              key = "token";
            };
          };
      };
      nixidy.applicationImports = [
        ({
          config,
          name,
          ...
        }: {
          options.ntfySecret = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["publisher" "e2e"]);
            default = null;
            description = "ntfy user whose token the Application gets as Secret `<app>-ntfy`";
          };
          config.resources.externalSecrets = lib.mkIf (cfg.auth && config.ntfySecret != null) {
            "${name}-ntfy".spec.data = lib.toList {
              secretKey = "token";
              remoteRef.key = "ntfy/${config.ntfySecret}/token";
              sourceRef.storeRef = {
                name = "bitwarden";
                kind = "ClusterSecretStore";
              };
            };
          };
        })
      ];
    };
  };
}
