{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  system = builtins.currentSystem;
  domain = "trdos.me";
  # Runs `cargo <args>` in each crate named on the command line (directory basename), else in
  # all of them. One shared target dir, so common dependencies compile once.
  cargoEach = pkgs.writeShellScript "cargo-each" ''
    set -euo pipefail
    root="${config.devenv.root}"
    sub="$1"; shift
    crates=()
    pass=()
    for a in "$@"; do
      if [ -f "$root/apps/$a/Cargo.toml" ] || [ -f "$root/tools/$a/Cargo.toml" ]; then crates+=("$a"); else pass+=("$a"); fi
    done
    if [ ''${#crates[@]} -eq 0 ]; then
      for d in "$root"/apps/*/ "$root"/tools/*/; do [ -f "$d/Cargo.toml" ] && crates+=("$(basename "$d")"); done
    fi
    export CARGO_TARGET_DIR="''${CARGO_TARGET_DIR:-${config.devenv.state}/cargo-target}"
    rc=0
    for c in "''${crates[@]}"; do
      dir="$root/apps/$c"; [ -f "$dir/Cargo.toml" ] || dir="$root/tools/$c"
      echo "==> cargo $sub ($c)" >&2
      (cd "$dir" && cargo "$sub" ''${CARGO_ARGS:-} "''${pass[@]}") || rc=1
    done
    exit $rc
  '';
in {
  imports = inputs.canivete.canivete.${system}.devenv.modules;

  # Name -> description for the `image` CLI. The images themselves are
  # legacyPackages.<system>.images (modules/images.nix), built on demand, so
  # entering the shell no longer instantiates a linux nixpkgs.
  options.images = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Image names known to the `image` CLI, keyed by name, valued by a short description";
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
          '')
          imageNames)}
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
      # embedded/templates holds cargo-generate templates whose .rs/.toml
      # files contain Liquid syntax — not parseable by rustfmt/taplo/etc.
      # pulumi/sdks (pulumi-bitwarden) and apps/sveltekit-demo/bun.nix are
      # code-generated (pulumi-language-python / bun2nix). Linting them is
      # noise (dict()-vs-{}, unused lambda args, README heading style, an
      # upstream comment typo) and any hand-edit is overwritten on regen,
      # so exclude them tree-wide like nixidy/generated.
      # old/ is the imported schradert/dotfiles history, kept verbatim as a
      # reference while it is migrated piece by piece; it is never evaluated.
      git-hooks.excludes = [
        "^old/"
        "nixidy/generated"
        "embedded/templates"
        "pulumi/sdks"
        "apps/sveltekit-demo/bun.nix"
      ];
      # Fast checks on commit, everything on push. canivete defaults every hook
      # to pre-commit+pre-push, which made each commit run the whole tree's
      # ty/statix/lychee.
      git-hooks.default_stages = lib.mkForce ["pre-push" "manual"];
      # devenv wires `prek run -a` (every hook, whole tree) into enterTest, and
      # its `after = [git-hooks:install]` edge makes the runner schedule it on
      # every shell entry too — 10+ minutes per direnv load (verified: every
      # `direnv exec` spawned prek → lychee/ty). Hooks belong to git, not to
      # the shell: detach the task from both edges.
      # `prek install` (no -f) moves a foreign hook aside as <hook>.legacy and
      # chains it ("migration mode"). When that hook is itself an older prek
      # shim (another worktree's or a stale devenv's prek), every push fails
      # with "prek's Git shim is installed in migration mode". Drop .legacy
      # files that are prek shims before installing; real legacy hooks stay.
      tasks."millionaire:git-hooks:drop-stale-shims" = {
        exec = ''
          hooks=$(${lib.getExe pkgs.git} rev-parse --git-common-dir 2>/dev/null)/hooks
          for f in "$hooks"/*.legacy; do
            [ -f "$f" ] && grep -q "File generated by prek" "$f" && rm -f "$f"
          done
          true
        '';
        before = ["devenv:git-hooks:install"];
      };
      tasks."devenv:git-hooks:run" = {
        after = lib.mkForce [];
        before = lib.mkForce [];
      };
      git-hooks.hooks = let
        onCommit = {stages = ["pre-commit" "pre-push" "manual"];};
      in {
        alejandra = onCommit;
        check-added-large-files = onCommit;
        check-case-conflicts = onCommit;
        check-executables-have-shebangs = onCommit;
        check-merge-conflicts = onCommit;
        check-symlinks = onCommit;
        end-of-file-fixer = onCommit;
        fix-byte-order-marker = onCommit;
        forbid-new-submodules = onCommit;
        gitleaks = onCommit;
        mixed-line-endings = onCommit;
        python-debug-statements = onCommit;
        # Regex (search semantics), not a glob — the previous "pulumi/sdks/**"
        # is an invalid pattern ("repeat of a repeat") and the hook runner
        # refuses to parse the whole config, blocking every commit in the repo.
        ruff = onCommit // {excludes = ["pulumi/sdks/"];};
        ruff-format = onCommit;
        trim-trailing-whitespace = onCommit;
        # sops files are ciphertext
        typos = onCommit // {excludes = ["^secrets/sops/"];};
        # Hashes, revs and image digests live in pkgs/**/pin.json only.
        pin-lint =
          onCommit
          // {
            enable = true;
            name = "pin-lint";
            entry = "tools/pin-lint";
            language = "system";
            pass_filenames = false;
            always_run = true;
          };
        lychee.toml.accept = [200 403 405 406];
        lychee.toml.exclude = [
          # In-cluster service DNS (lychee normalizes with a trailing slash)
          "\\.svc(:[0-9]+)?/?$"
          # Cluster-internal hostnames are unreachable from the dev machine
          "\\.svc\\.cluster\\.local"
          # Single-label hosts (sirver, harbor, keycloak, hyena…) are LAN/tailnet
          # names or artifacts of ''${domain} interpolation — never public links.
          # Tradeoff: a dotless typo of a public host (https://githubcom/…) is
          # also skipped; acceptable since interpolation artifacts are far more
          # common here than typos.
          "^https?://[^./]+(:[0-9]+)?(/.*)?$"
          # Loopback proxy targets and link-local metadata endpoints in NixOS
          # configs are wiring, not links — unreachable from the dev machine.
          "^https?://127\\.0\\.0\\.1"
          "^https?://169\\.254\\."
          # RFC1918 private ranges and *.internal hosts are LAN/cluster wiring
          # (router admin UIs, moonraker, etc.) — unreachable from the dev box.
          "^https?://10\\."
          "^https?://192\\.168\\."
          "^https?://172\\.(1[6-9]|2[0-9]|3[01])\\."
          "^https?://[^/]+\\.internal(:[0-9]+)?"
          # pkgs/**/pin.json url-template/url-set sources ({version}, {name}).
          "%7B[a-z]+%7D"
          # *.trdos.me apps sit on the tailnet-only internal gateway.
          "^https?://([^/]+\\.)?trdos\\.me"
          # Helm chart repos serve index.yaml, not the bare repo URL, so a plain
          # GET 404s even though the repo is valid (same as descheduler below).
          "https://kubernetes-sigs.github.io/descheduler"
          "https://helm.ngc.nvidia.com/nvidia"
          "https://maximhq.github.io/bifrost/helm-charts"
          "https://api.bitwarden.com"
          "https://identity.bitwarden.com"
          "^.+/dns-query$"
        ];
        no-commit-to-branch.enable = lib.mkForce false;
        # statix walks the whole tree, so pre-existing findings anywhere block
        # every commit. Keep the hook, but disable the two codes the existing
        # codebase trips tree-wide (empty_pattern ×41, manual_inherit_from ×6)
        # on top of canivete's repeated_keys, and skip .claude/ (agent
        # worktrees hold stale tree copies). Re-enabling a code means fixing
        # its findings tree-wide first (statix fix).
        statix.entry = lib.mkForce "${lib.getExe pkgs.statix} check --config ${(pkgs.formats.toml {}).generate "statix.toml" {
          disabled = ["repeated_keys" "empty_pattern" "manual_inherit_from"];
          ignore = [".claude" "old"];
        }} --format errfmt";
        # tagref: disabled — the repo uses no tag/ref annotations, and the
        # generated tailscale CRDs contain literal bracketed tag:k8s strings
        # that its whole-tree scan reads as duplicate tag definitions (it
        # ignores the pre-commit exclude). If tag annotations are ever
        # adopted, override tagref.entry with --path flags instead.
        tagref.enable = lib.mkForce false;
      };

      # Scripts
      # `update` — check/bump pins (pkgs/**/pin.json) and every lockfile
      # (flake, devenv, cargo, uv, bun) with validation gates; see
      # tools/update. Built on first use, not on shell entry.
      scripts.update.exec = ''
        exec nix run "${config.devenv.root}#update" --no-pure-eval -- "$@"
      '';
      # `msf [msfconsole args]` — metasploit on demand from the flake's locked
      # nixpkgs (heavy closure, never installed): fetched on first use.
      scripts.msf.exec = ''
        exec nix shell --inputs-from "${config.devenv.root}" nixpkgs#metasploit --command msfconsole "$@"
      '';
      # `build-all [--system <sys>]...` — build legacyPackages.<sys>.build-all
      # (modules/build-all.nix; linux evaluated on falcon, which also fans builds
      # out to the cluster nodes, results left there; darwin locally) plus the
      # native devenv shells, then print a pass/fail matrix. The pool is
      # static/builders.nix, spelled as a `builders` option for falcon's daemon:
      # nodes by LAN IP, authenticated with falcon's ssh host key (authorized on
      # the nodes by static/builder.nix), host keys pinned inline. Env:
      # BUILD_ALL_REMOTE (falcon), BUILD_ALL_JOBS (8; falcon's own slots),
      # BUILD_ALL_CORES (4).
      scripts.build-all.exec = ''
        set -uo pipefail
        jq=${lib.getExe pkgs.jq}
        systems=()
        while [ $# -gt 0 ]; do
          case "$1" in
            -s|--system) systems+=("$2"); shift 2 ;;
            *) echo "Usage: build-all [--system aarch64-darwin|x86_64-linux|aarch64-linux]..." >&2; exit 2 ;;
          esac
        done
        [ ''${#systems[@]} -gt 0 ] || systems=(aarch64-darwin x86_64-linux aarch64-linux)
        out=$(mktemp -d -t build-all.XXXXXX)
        pool=$(echo '${builtins.toJSON (import ./static/builders.nix).nodes}' | $jq -r 'to_entries | map(.value |
          "ssh-ng://\(.user)@\(.lan) \(.systems | join(",")) /etc/ssh/ssh_host_ed25519_key \(.jobs) \(.speedFactor) \(.features | join(",")) - \(.hostKey | @base64)") | join(";")')
        cd "${config.devenv.root}"
        for sys in "''${systems[@]}"; do
          remote=()
          [[ $sys == *-linux ]] && remote=(--remote "''${BUILD_ALL_REMOTE:-falcon}" --no-download
            --option accept-flake-config true --option builders "$pool" --option builders-use-substitutes true
            -j "''${BUILD_ALL_JOBS:-8}" --option cores "''${BUILD_ALL_CORES:-4}")
          ${lib.getExe pkgs.nix-fast-build} --flake ".#legacyPackages.$sys.build-all" --impure --no-nom --skip-cached \
            --eval-workers 4 "''${remote[@]}" --result-format json --result-file "$out/$sys.json" >&2
          [ -s "$out/$sys.json" ] || echo '{"results":[{"attr":"<flake>","type":"EVAL","success":false}]}' > "$out/$sys.json"
          [ "$sys" = aarch64-darwin ] || continue
          for dir in . embedded org-bridge apps/sveltekit-demo; do
            ok=true; (cd "$dir" && devenv build shell) >&2 || ok=false
            echo "{\"attr\":\"devenv.$dir\",\"type\":\"BUILD\",\"success\":$ok}"
          done | $jq -s '{results: .}' > "$out/$sys-devenv.json"
        done
        for f in "$out"/*.json; do
          sys=$(basename "$f" .json)
          $jq -r --arg sys "''${sys%-devenv}" '.results | group_by(.attr)[] |
            [$sys, .[0].attr, (if all(.success) then (if any(.type == "BUILD") then "built" else "cached" end)
              else (map(select(.success | not))[0].type | ascii_downcase) + "-FAIL" end)] | @tsv' "$f"
        done | sort | tee "$out/matrix.tsv" | column -t
        echo "results: $out" >&2
        ! grep -q FAIL "$out/matrix.tsv"
      '';
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
      # Platform e2e tests (apps/e2e) as Jobs from the CronJobs (which also run nightly), one per runner:
      #   media    media/media-e2e   the media and games families (mount the media volumes)
      #   cluster  e2e/e2e           every other family (HTTP only)
      #   e2e                          default tier of every runner (no qBittorrent/VPN needed)
      #   e2e run --family identity    only that family (comma list); --flow <name,...> narrows further
      #   e2e run --full               adds the long flows (media: VPN leak tests, downloads over the VPN)
      #   e2e cleanup --run <id> [--dry-run] | cleanup --all [--dry-run]   (add --family to narrow)
      #   e2e list                     families and flows (runs the crate locally)
      # `media-e2e <args>` is `e2e <cmd> --family media <args>`.
      # KUBECTL overrides kubectl, e.g. off-LAN:
      #   KUBECTL="ssh 192.184.168.248 sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
      # HOME_IP is the home egress IP the VPN leak tests must never see; unset, it is taken from
      # E2E_HOME_IP_HOST (ssh host on the home network, e.g. 192.184.168.248: `curl ifconfig.me`
      # there), else the Job's own egress. Log and report per runner: $E2E_OUT/<run>/<runner>.{log,json}.
      scripts.e2e.exec = ''
        set -euo pipefail
        k=''${KUBECTL:-kubectl}
        [ $# -gt 0 ] || set -- run
        if [ "$1" = list ]; then
          exec cargo run -q --manifest-path "${config.devenv.root}/apps/e2e/Cargo.toml" -- list
        fi
        run_id=''${E2E_RUN_ID:-$(date -u +%Y%m%d-%H%M%S)-$(od -An -N2 -tx2 /dev/urandom | tr -d ' ')}
        out="''${E2E_OUT:-''${TMPDIR:-/tmp}/e2e}/$run_id"
        mkdir -p "$out"
        args=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
        fam=""; prev=""
        for a in "$@"; do [ "$prev" = --family ] && fam=$a; prev=$a; done
        # Which runners the families need; no --family: media, plus cluster once its CronJob exists.
        runners=()
        if [ -z "$fam" ]; then
          runners=(media)
          $k -n e2e get cronjob e2e >/dev/null 2>&1 && runners+=(cluster)
        else
          # `games` runs on the media runner too (it mounts the games volume).
          case ",$fam," in *,media,*|*,games,*) runners+=(media) ;; esac
          if [ -n "$(printf '%s' "$fam" | tr ',' '\n' | grep -vxE 'media|games' || true)" ]; then runners+=(cluster); fi
        fi
        home_ip=''${HOME_IP:-}
        if [ -z "$home_ip" ] && [ -n "''${E2E_HOME_IP_HOST:-}" ]; then
          home_ip=$(ssh -o ConnectTimeout=10 "$E2E_HOME_IP_HOST" curl -s -m 10 ifconfig.me || true)
        fi
        printf '%s' "$home_ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || home_ip=""
        rc=0
        for runner in "''${runners[@]}"; do
          case "$runner" in
            media) ns=media; cj=media-e2e ;;
            *)     ns=e2e;   cj=e2e ;;
          esac
          job="$cj-$run_id"
          $k -n "$ns" get cronjob "$cj" -o json \
            | jq --arg job "$job" --arg ns "$ns" --arg cj "$cj" --arg run "$run_id" --arg home "$home_ip" --argjson args "$args" '{
                apiVersion: "batch/v1", kind: "Job",
                metadata: {name: $job, namespace: $ns, labels: {"app.kubernetes.io/name": $cj}},
                spec: (.spec.jobTemplate.spec
                  | .template.spec.containers[0].args = $args
                  | .template.spec.containers[0].env += [{name: "E2E_RUN_ID", value: $run}]
                  | .template.spec.containers[0].env += (if $home != "" then [{name: "HOME_IP", value: $home}] else [] end))
              }' \
            | $k create -f -
          echo "job $job (run $run_id, runner $runner); log and report in $out" >&2
          # `kubectl wait pod -l` returns at once while the Job's pod does not exist yet, and `logs -f` fails
          # on a pod still pulling its image (a new tag): poll the phase instead.
          for _ in $(seq 120); do
            phase=$($k -n "$ns" get pod -l "job-name=$job" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
            case "$phase" in Running|Succeeded|Failed) break ;; esac
            sleep 5
          done
          $k -n "$ns" logs -f "job/$job" | tee "$out/$runner.log"
          sed -n '/=== E2E REPORT JSON BEGIN ===/,/=== E2E REPORT JSON END ===/p' "$out/$runner.log" | sed '1d;$d' > "$out/$runner.json"
          # The pod can exit a moment before the Job's status says so: wait for the condition.
          $k -n "$ns" wait --for=condition=complete "job/$job" --timeout=60s >/dev/null || rc=1
        done
        jq -rs '.[].flows[] | [.family, .flow, .status, (.ms/1000|tostring), (.error.app // ""), (.error.step // "")] | @tsv' "$out"/*.json | column -t -s "$(printf '\t')" || true
        exit $rc
      '';
      scripts.media-e2e.exec = ''
        [ $# -gt 0 ] || set -- run
        cmd=$1; shift
        E2E_OUT=''${E2E_OUT:-''${TMPDIR:-/tmp}/media-e2e} exec e2e "$cmd" --family media "$@"
      '';
      # Rust toolchain from the locked nixpkgs (no extra flake input; nothing is built on entry)
      # for the standalone crates: apps/{e2e,app-bootstrap,jellyfin-bootstrap}, tools/*.
      # Hooks stay off the shell (see the tasks above); run checks explicitly:
      #   cargo-check [crate...]   cargo check --all-targets      (default: every crate)
      #   cargo-test  [crate...]   cargo test
      # `crate` is the directory name, e.g. e2e. Extra cargo args: CARGO_ARGS="--release".
      languages.rust = {
        enable = true;
        components = ["rustc" "cargo" "clippy" "rustfmt"];
      };
      scripts.cargo-check.exec = ''
        exec ${cargoEach} check --all-targets "$@"
      '';
      scripts.cargo-test.exec = ''
        exec ${cargoEach} test "$@"
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

      # Bare `deploy` would `nix flake check` every host first; skip it unless asked (`deploy-raw` is the plain tool)
      scripts.deploy.exec = ''
        case " $* " in
          *" --skip-checks "*) exec ${pkgs.deploy-rs}/bin/deploy "$@" ;;
          *) exec ${pkgs.deploy-rs}/bin/deploy --skip-checks "$@" ;;
        esac
      '';

      # A Syncthing device ID is the hash of the device's TLS certificate, so a device's identity is
      # declared like any config: the key pair is generated once here, encrypted to the host
      # (.sops.yaml: secrets/sops/syncthing-<host>.yaml) and installed by modules/syncthing.nix; the ID is
      # public and goes in `syncthing.devices.<host>.id`. Never regenerate for a host in use (its ID changes).
      scripts.syncthing-identity.exec = ''
        set -euo pipefail
        host="''${1:?Usage: syncthing-identity <host> [--force]}"
        file="${config.devenv.root}/secrets/sops/syncthing-$host.yaml"
        if [ -e "$file" ] && [ "''${2:-}" != "--force" ]; then
          echo "$file exists: showing its ID (--force replaces the identity, and the ID changes)" >&2
          dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
          sops --decrypt --extract '["cert"]' "$file" > "$dir/cert.pem"
          sops --decrypt --extract '["key"]' "$file" > "$dir/key.pem"
          syncthing device-id --home "$dir" 2>/dev/null || syncthing --device-id --home "$dir"
          exit 0
        fi
        dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
        syncthing generate --home "$dir" >/dev/null 2>&1
        {
          echo "cert: |"; sed 's/^/    /' "$dir/cert.pem"
          echo "key: |"; sed 's/^/    /' "$dir/key.pem"
        } > "$file"
        # encrypt in place; the creation rule in .sops.yaml picks the recipients (the host and tristan)
        sops --encrypt --in-place "$file"
        echo "wrote $file" >&2
        syncthing device-id --home "$dir" 2>/dev/null || syncthing --device-id --home "$dir"
      '';

      # Pulumi / Python
      enterShell = ''
                # Bootstrap creds from SOPS — needed before bws can be queried
                export BWS_ACCESS_TOKEN="$(cd "${config.devenv.root}" && sops --decrypt --extract '["bitwarden"]' "secrets/sops/default.yaml")"
                export B2_APPLICATION_KEY="$(cd "${config.devenv.root}" && sops --decrypt --extract '["b2"]["key"]' "secrets/sops/default.yaml")"
                export B2_APPLICATION_KEY_ID="$(cd "${config.devenv.root}" && sops --decrypt --extract '["b2"]["id"]' "secrets/sops/default.yaml")"

                # Surface total fetch failure (offline, expired BWS token) loudly —
                # otherwise the first symptom is a confusing pulumi auth error
                # far from the cause.
                if ! BWS_SECRETS=$(bws secret list 2>/dev/null); then
                  echo "BWS: secret fetch failed — PULUMI/CLOUDFLARE/HCLOUD tokens unset"
                  BWS_SECRETS=""
                fi

                # Tokens fetched from BWS
                PULUMI_ACCESS_TOKEN=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "pulumi/access_token") | .value // empty' 2>/dev/null)
                [ -n "$PULUMI_ACCESS_TOKEN" ] && export PULUMI_ACCESS_TOKEN
                CLOUDFLARE_API_TOKEN=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "cloudflare/api_token") | .value // empty' 2>/dev/null)
                [ -n "$CLOUDFLARE_API_TOKEN" ] && export CLOUDFLARE_API_TOKEN
                HCLOUD_TOKEN=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "hcloud/token") | .value // empty' 2>/dev/null)
                [ -n "$HCLOUD_TOKEN" ] && export HCLOUD_TOKEN

                # Doomed without a token — skip rather than hang on a network call
                [ -n "$PULUMI_ACCESS_TOKEN" ] && (cd "${config.devenv.root}/pulumi" && pulumi stack select prod)

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
                # The jq selector below is a BWS secret *name*, not a credential.
                COSIGN_KEY_B64=$(echo "$BWS_SECRETS" | ${lib.getExe pkgs.jq} -r '.[] | select(.key == "harbor/cosign/key") | .value // empty' 2>/dev/null) # gitleaks:allow
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
      treefmt.config.settings.global.excludes = ["old/**"];
      treefmt.config.settings.formatter.dprint.options = ["--allow-no-files"];

      # Packages
      packages = with pkgs; [
        sops
        bws
        backblaze-b2
        (writeShellScriptBin "b2" ''exec b2v4 "$@"'')
        (pulumi.withPackages (ps: [ps.pulumi-python]))
        argocd
        (writeShellScriptBin "deploy-raw" ''exec ${deploy-rs}/bin/deploy "$@"'') # unwrapped deploy-rs, flake checks included
        cilium-cli
        hcloud
        hcloud-upload-image
        android-tools # adb for the Android fleet (docs/android.md)
        syncthing # `syncthing-identity` generates device certificates
      ];

      images.ha = "Home Assistant with custom components";
    }
  ];
}
