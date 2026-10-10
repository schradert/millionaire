{...}: {
  nixidy = {lib, ...}: {
    # In-cluster random secrets (external-secrets Password generator). Created
    # once and never refreshed, so internal-only values (cookie keys, admin and
    # API keys) need no Bitwarden entry. The Secret is named after the entry.
    nixidy.applicationImports = [
      ({config, ...}: {
        options.generatedSecrets = lib.mkOption {
          description = "Random secrets generated in-cluster once; the Secret takes the entry name";
          default = {};
          type = lib.types.attrsOf (lib.types.submodule {
            options = {
              key = lib.mkOption {
                type = lib.types.str;
                description = "Key inside the Secret";
              };
              length = lib.mkOption {
                type = lib.types.int;
                default = 32;
                description = "Value length";
              };
              numeric = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Digits only (always valid hex, for apps that parse the value as hex)";
              };
              upper = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Allow uppercase letters (apps with password complexity rules)";
              };
              bitwarden = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Bitwarden key to push the value to (break-glass admin passwords, e.g. `<app>/admin-password`)";
              };
            };
          });
        };
        config.resources = lib.mkMerge (lib.mapAttrsToList (name: secret: {
            passwords.${name}.spec = {
              inherit (secret) length;
              digits =
                if secret.numeric
                then secret.length
                else 10;
              symbols = 0;
              noUpper = !secret.upper;
              allowRepeat = true;
            };
            externalSecrets.${name}.spec = {
              refreshPolicy = "CreatedOnce";
              dataFrom = lib.toList {
                sourceRef.generatorRef = {
                  apiVersion = "generators.external-secrets.io/v1alpha1";
                  kind = "Password";
                  inherit name;
                };
                rewrite = lib.toList {
                  regexp = {
                    source = "password";
                    target = secret.key;
                  };
                };
              };
            };
            pushSecrets = lib.optionalAttrs (secret.bitwarden != null) {
              ${name}.spec = {
                secretStoreRefs = lib.toList {
                  name = "bitwarden";
                  kind = "ClusterSecretStore";
                };
                selector.secret.name = name;
                data = lib.toList {
                  match = {
                    secretKey = secret.key;
                    remoteRef.remoteKey = secret.bitwarden;
                  };
                };
              };
            };
          })
          config.generatedSecrets);
      })
    ];
  };
}
