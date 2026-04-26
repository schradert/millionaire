{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  system = builtins.currentSystem;
  linuxSystem = builtins.replaceStrings ["darwin"] ["linux"] system;
  n2c = inputs.nix2container.packages.${linuxSystem}.nix2container;
  linuxPkgs = import inputs.nixpkgs {system = linuxSystem;};
  domain = "trdos.me";
in {
  imports = inputs.canivete.canivete.${system}.devenv.modules;

  options.images = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = {};
    description = "nix2container image derivations keyed by name, pushed to Harbor via push-image CLI";
  };

  config = lib.mkMerge [
    (lib.mkIf (config.images != {}) (let
      registry = "harbor.${domain}";
      imageNames = lib.attrNames config.images;
      imageBase = ".#legacyPackages.${system}.images";
    in {
      packages = [pkgs.skopeo pkgs.cosign];
      scripts.image.exec = ''
        subcmd="''${1:---help}"
        shift 2>/dev/null || true

        case "$subcmd" in
          list|-l)
            echo "Available images:"
            ${builtins.concatStringsSep "\n" (map (name: ''echo "  ${name}"'') imageNames)}
            ;;
          build)
            if [ -z "''${1:-}" ]; then
              echo "Usage: image build <name>"
              echo "Available: ${builtins.concatStringsSep ", " imageNames}"
              exit 1
            fi
            echo "==> Building $1..."
            nix build "${imageBase}.$1" --no-pure-eval --no-link --print-out-paths
            ;;
          publish)
            target="''${1:---help}"
            case "$target" in
              --all)
                ${builtins.concatStringsSep "\n" (map (name: ''
                  echo "==> Publishing ${name}..."
                  nix run "${imageBase}.${name}.copyToRegistry" --no-pure-eval
                  tag=$(skopeo list-tags "docker://${registry}/library/${name}" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.Tags[0] // empty')
                  digest=$(skopeo inspect "docker://${registry}/library/${name}:$tag" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.Digest // empty')
                  if [ -n "$digest" ]; then
                    echo "    Digest: $digest"
                    echo "    Signing..."
                    cosign sign --yes --key "$COSIGN_KEY" --signing-config "$COSIGN_SIGNING_CONFIG" "${registry}/library/${name}@$digest" \
                      && echo "    Signed." \
                      || echo "    Signing skipped (no COSIGN_KEY or signing failed)"
                  fi
                '') imageNames)}
                echo "Done."
                ;;
              --help|-h|"")
                echo "Usage: image publish <name|--all>"
                echo "Available: ${builtins.concatStringsSep ", " imageNames}"
                exit 1
                ;;
              *)
                echo "==> Publishing $target..."
                nix run "${imageBase}.$target.copyToRegistry" --no-pure-eval
                tag=$(skopeo list-tags "docker://${registry}/library/$target" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.Tags[0] // empty')
                digest=$(skopeo inspect "docker://${registry}/library/$target:$tag" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.Digest // empty')
                if [ -n "$digest" ]; then
                  echo "    Digest: $digest"
                  echo "    Signing..."
                  cosign sign --yes --key "$COSIGN_KEY" --signing-config "$COSIGN_SIGNING_CONFIG" "${registry}/library/$target@$digest" \
                    && echo "    Signed." \
                    || echo "    Signing skipped (no COSIGN_KEY or signing failed)"
                fi
                ;;
            esac
            ;;
          *)
            echo "Usage: image <list|build|publish> [name|--all]"
            ;;
        esac
      '';
    }))

    {
      # Git hooks
      git-hooks.excludes = ["nixidy/generated"];
      git-hooks.hooks = {
        lychee.toml.accept = [200 403 405 406];
        lychee.toml.exclude = [
          "^.+\\.svc$"
          "https://kubernetes-sigs.github.io/descheduler"
          "https://api.bitwarden.com"
          "https://identity.bitwarden.com"
          "^.+/dns-query$"
        ];
        no-commit-to-branch.enable = lib.mkForce false;
        ruff.excludes = ["pulumi/sdks/**"];
      };

      # Scripts
      scripts.sync.exec = ''
        subcmd="$1"; shift
        IFS='/' read -r namespace name <<< "$1"
        case "$subcmd" in
          secret) kubectl annotate externalsecret "$name" -n "$namespace" force-sync="$(date +%s)" --overwrite ;;
          app)    kubectl annotate application "$name" -n cicd argocd.argoproj.io/refresh=hard --overwrite ;;
          both)   kubectl annotate externalsecret "$name" -n "$namespace" force-sync="$(date +%s)" --overwrite && kubectl annotate application "$name" -n cicd argocd.argoproj.io/refresh=hard --overwrite ;;
          *)      echo "Usage: sync <secret|app> <namespace/name>"; exit 1 ;;
        esac
      '';
      scripts.keycloak-reset-password.exec = ''
        email="''${1:?Usage: keycloak-reset-password <email>}"
        realm="''${2:-default}"
        base_url="https://keycloak.${domain}"

        admin_password=$(kubectl get secret keycloak -n identity -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d)

        token=$(curl -sf -X POST "$base_url/realms/master/protocol/openid-connect/token" \
          -d "client_id=admin-cli" \
          -d "grant_type=password" \
          -d "username=admin" \
          -d "password=$admin_password" | jq -r '.access_token')

        user_id=$(curl -sf -H "Authorization: Bearer $token" \
          "$base_url/admin/realms/$realm/users?email=$email&exact=true" | jq -r '.[0].id')

        if [ "$user_id" = "null" ] || [ -z "$user_id" ]; then
          echo "No user found with email: $email"
          exit 1
        fi

        curl -sf -X PUT -H "Authorization: Bearer $token" \
          -H "Content-Type: application/json" \
          -d '["UPDATE_PASSWORD"]' \
          "$base_url/admin/realms/$realm/users/$user_id/execute-actions-email"

        echo "Password reset email sent to $email"
      '';

      # Pulumi / Python
      enterShell = ''
        export PULUMI_ACCESS_TOKEN="$(cat "${config.devenv.root}/secrets/pulumi_token.txt")"
        export CLOUDFLARE_API_TOKEN="$(cat "${config.devenv.root}/secrets/cloudflare_token.txt")"
        export BWS_ACCESS_TOKEN="$(cd "${config.devenv.root}" && sops --decrypt --extract '["bitwarden"]' "secrets/sops/default.yaml")"
        export B2_APPLICATION_KEY="$(cd "${config.devenv.root}" && sops --decrypt --extract '["b2"]["key"]' "secrets/sops/default.yaml")"
        export B2_APPLICATION_KEY_ID="$(cd "${config.devenv.root}" && sops --decrypt --extract '["b2"]["id"]' "secrets/sops/default.yaml")"
        (cd "${config.devenv.root}/pulumi" && pulumi stack select prod)

        # Personal attic cache (only in this project, not system-wide)
        ATTIC_PUBKEY=$(cat "${config.devenv.root}/static/generated.json" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.attic_pubkey // empty' 2>/dev/null)
        if [ -n "$ATTIC_PUBKEY" ]; then
          export NIX_CONFIG="extra-substituters = http://sirver:8199/main
extra-trusted-public-keys = $ATTIC_PUBKEY"
        fi

        # Project-local registry auth + cosign state
        export REGISTRY_AUTH_FILE="${config.devenv.root}/.docker/auth.json"
        export DOCKER_CONFIG="${config.devenv.root}/.docker"
        mkdir -p "$(dirname "$REGISTRY_AUTH_FILE")"
        [ -f "$REGISTRY_AUTH_FILE" ] || echo '{"auths":{}}' > "$REGISTRY_AUTH_FILE"
        ln -sf auth.json "${config.devenv.root}/.docker/config.json"

        BWS_SECRETS=$(bws secret list 2>/dev/null || true)

        # Harbor auto-login
        if curl -sf --connect-timeout 5 "https://harbor.${domain}/api/v2.0/health" &>/dev/null; then
          if skopeo login --get-login harbor.${domain} &>/dev/null; then
            echo "Harbor: authenticated as $(skopeo login --get-login harbor.${domain} 2>/dev/null)"
          else
            ROBOT_SECRET=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "harbor/robot/secret") | .value // empty' 2>/dev/null)
            if [ -n "$ROBOT_SECRET" ]; then
              echo "$ROBOT_SECRET" | skopeo login harbor.${domain} --username "robot\$push" --password-stdin &>/dev/null \
                && echo "Harbor: logged in as robot\$push" \
                || echo "Harbor: login failed (robot account may not exist yet)"
            else
              echo "Harbor: not logged in (could not fetch robot secret from Bitwarden)"
            fi
          fi
        else
          echo "Harbor: not reachable (skipping login)"
        fi

        # Cosign signing key
        COSIGN_KEY_B64=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "harbor/cosign/key") | .value // empty' 2>/dev/null)
        COSIGN_PASSWORD_VAL=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "harbor/cosign/password") | .value // empty' 2>/dev/null)
        if [ -n "$COSIGN_KEY_B64" ] && [ -n "$COSIGN_PASSWORD_VAL" ]; then
          export COSIGN_KEY="${config.devenv.root}/.docker/cosign.key"
          export COSIGN_DOCKER_MEDIA_TYPES="1"
          COSIGN_SIGNING_CONFIG="${config.devenv.root}/.docker/cosign-signing-config.json"
          cosign signing-config create > "$COSIGN_SIGNING_CONFIG" 2>/dev/null
          export COSIGN_SIGNING_CONFIG
          echo "$COSIGN_KEY_B64" | base64 -d > "$COSIGN_KEY"
          export COSIGN_PASSWORD="$COSIGN_PASSWORD_VAL"
          echo "Cosign: signing key loaded"
        else
          echo "Cosign: no signing key (images will not be signed)"
        fi
      '';
      languages.python.enable = true;
      languages.python.directory = "./pulumi";
      editors.zed.enable = true;
      editors.helix.enable = true;
      treefmt.config.settings.global.walk = "filesystem";
      treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];

      # Packages
      packages = with pkgs; [
        sops
        bws
        backblaze-b2
        (writeShellScriptBin "b2" ''exec b2v4 "$@"'')
        (pulumi.withPackages (ps: [ps.pulumi-python]))
        argocd
        deploy-rs
        cilium-cli
      ];

      # Home Assistant image
      images.ha = let
        customComponents = with linuxPkgs.home-assistant-custom-components; [
          adaptive_lighting
          alarmo
          auth_oidc
          better_thermostat
          frigate
          gpio
          moonraker
          ntfy
          prometheus_sensor
          samsungtv-smart
          scene_presets
          smartir
          spook
          versatile_thermostat
          waste_collection_schedule
        ];
        customComponentsDir = linuxPkgs.runCommand "ha-custom-components" {} (
          ''
            mkdir -p $out/custom_components
          ''
          + builtins.concatStringsSep "\n" (map (
              comp: ''
                for dir in ${comp}/lib/python*/site-packages/custom_components/*/; do
                  name=$(basename "$dir")
                  ln -s "$dir" "$out/custom_components/$name"
                done
              ''
            )
            customComponents)
        );
      in
        n2c.buildImage {
          name = "harbor.${domain}/library/ha";
          tag = "2026.3.4-custom";
          config = {
            Cmd = ["${linuxPkgs.home-assistant}/bin/hass" "--config" "/config"];
            ExposedPorts."8123/tcp" = {};
            Volumes."/config" = {};
          };
          layers = [
            (n2c.buildLayer {deps = [linuxPkgs.home-assistant];})
            (n2c.buildLayer {
              deps = customComponents;
              copyToRoot = [customComponentsDir];
            })
          ];
        };
    }
  ];
}
