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
  # Git-hook entry: `cargo-hook <subcommand> [cargo args...] -- <files...>` → cargoEach for the
  # crates (apps/<c>, tools/<c>) those files belong to.
  cargoHook = pkgs.writeShellScript "cargo-hook" ''
    set -euo pipefail
    sub="$1"; shift
    args=()
    while [ $# -gt 0 ] && [[ "$1" == -* ]]; do args+=("$1"); shift; done
    crates=$(printf '%s\n' "$@" | sed -nE 's#^(apps|tools)/([^/]+)/.*#\2#p' | sort -u)
    [ -n "$crates" ] || exit 0
    # shellcheck disable=SC2086
    CARGO_ARGS="''${args[*]:-}" exec ${cargoEach} "$sub" $crates
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

        # Push one image, then sign the digest of the tag just pushed (the image's own tag, not
        # whichever tag the registry lists first). A failed build stops here.
        publish_one() {
          echo "==> Publishing $1..."
          nix run "${imageBase}.$1.copyToRegistry" --no-pure-eval || { echo "    FAILED: $1 was not pushed" >&2; return 1; }
          tag=$(nix eval --raw "${imageBase}.$1.imageTag" --no-pure-eval) || return 1
          digest=$(skopeo inspect "docker://${registry}/library/$1:$tag" 2>/dev/null | ${lib.getExe pkgs.jq} -r '.Digest // empty')
          [ -n "$digest" ] || { echo "    FAILED: no ${registry}/library/$1:$tag after the push" >&2; return 1; }
          echo "    Tag: $tag"
          echo "    Digest: $digest"
          echo "    Signing..."
          cosign sign --yes --key "$COSIGN_KEY" --signing-config "$COSIGN_SIGNING_CONFIG" "${registry}/library/$1@$digest" \
            && echo "    Signed." \
            || echo "    Signing skipped (no COSIGN_KEY or signing failed)"
        }

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
            publish_one ${name} || exit 1
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
                publish_one "$target" || exit 1
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
      git-hooks.excludes = [
        "nixidy/generated"
        "embedded/templates"
        "pulumi/sdks"
        "apps/sveltekit-demo/bun.nix"
        # upstream Grafana dashboards, kept byte-for-byte (a formatter change re-renders every ConfigMap)
        "nixidy/system/observability/dashboards/"
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
        # The stock clippy/rustfmt hooks run cargo at the repo root, which has no Cargo.toml
        # (every push touching Rust failed). Run them per crate, only for the crates the pushed
        # files belong to. embedded/ and org-bridge/ have their own toolchains and devenvs.
        clippy = {
          files = lib.mkForce "^(apps|tools)/[^/]+/.*\\.rs$";
          pass_filenames = lib.mkForce true;
          entry = lib.mkForce "${cargoHook} clippy --all-targets";
        };
        rustfmt = {
          files = lib.mkForce "^(apps|tools)/[^/]+/.*\\.rs$";
          pass_filenames = lib.mkForce true;
          # Formats only the pushed files (not `cargo fmt --all`): most of the code predates the hook,
          # so it gets formatted as it is touched rather than in one repo-wide churn.
          entry = lib.mkForce "${lib.getExe' pkgs.rustfmt "rustfmt"} --config skip_children=true";
        };
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
        # Every hostname in the rendered HTTPRoutes needs an entry in docs/client-matrix.json (the
        # client-matrix artifact's data). always_run: the global `nixidy/generated` exclude would
        # otherwise hide route changes from a files filter; the script reads ~100 small files.
        client-matrix-lint =
          onCommit
          // {
            enable = true;
            name = "client-matrix-lint";
            entry = "${lib.getExe pkgs.python3} tools/client-matrix-lint";
            language = "system";
            pass_filenames = false;
            always_run = true;
          };
        # nixidy/generated must equal what the nix sources render to. Renders happen on falcon
        # (never here); tools/render-check returns at once when the push touches no render input.
        # Pre-push only: it needs the network and a few minutes when inputs did change.
        render-check = {
          enable = true;
          name = "render-check";
          entry = "${lib.getExe pkgs.python3} tools/render-check";
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
          "^https?://([^/@]*@)?127\\.0\\.0\\.1"
          "^https?://169\\.254\\."
          # RFC1918 private ranges and *.internal hosts are LAN/cluster wiring
          # (router admin UIs, moonraker, etc.) — unreachable from the dev box.
          "^https?://10\\."
          "^https?://192\\.168\\."
          # Tailnet (CGNAT) addresses, e.g. AdGuard on hyena
          "^https?://100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\."
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
          "https://otwld.github.io/ollama-helm"
          "https://angelnu.github.io/helm-charts"
          # XML namespace URIs (Atom etc.) are identifiers, not pages
          "^https?://www\\.w3\\.org/"
          # Kubernetes service env var shapes in comments (`tcp://ip:port`)
          "ip:port"
          "https://maximhq.github.io/bifrost/helm-charts"
          "https://helm.coder.com/v2"
          "https://api.bitwarden.com"
          "https://identity.bitwarden.com"
          "^.+/dns-query$"
        ];
        no-commit-to-branch.enable = lib.mkForce false;
        # MD029: README todos keep stable numbers with gaps (docs cite "todo 55"); MD060 (new in
        # markdownlint-cli 0.48) flags every compact table in the repo.
        markdownlint.settings.configuration = {
          MD029 = false;
          MD060 = false;
        };
        # statix walks the whole tree, so pre-existing findings anywhere block
        # every commit. Keep the hook, but disable the two codes the existing
        # codebase trips tree-wide (empty_pattern ×41, manual_inherit_from ×6)
        # on top of canivete's repeated_keys, and skip .claude/ (agent
        # worktrees hold stale tree copies). Re-enabling a code means fixing
        # its findings tree-wide first (statix fix).
        statix.entry = lib.mkForce "${lib.getExe pkgs.statix} check --config ${(pkgs.formats.toml {}).generate "statix.toml" {
          disabled = ["repeated_keys" "empty_pattern" "manual_inherit_from"];
          ignore = [".claude"];
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
      # BUILD_ALL_CORES (4). `--systems` is explicit: nix-fast-build silently drops drvs
      # not of the builder's native system (aarch64-linux on falcon) and reports them cached.
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
        pool=$(echo '${builtins.toJSON (let p = import ./static/builders.nix; in p.builders // {inherit (p) morgenmuffelVm;})}' | $jq -r 'to_entries | map(.value |
          "ssh-ng://\(.user)@\(.lan)\(if .port then ":\(.port)" else "" end) \(.systems | join(",")) /etc/ssh/ssh_host_ed25519_key \(.jobs) \(.speedFactor) \(.features | join(",")) - \(.hostKey | @base64)") | join(";")')
        cd "${config.devenv.root}"
        for sys in "''${systems[@]}"; do
          remote=()
          [[ $sys == *-linux ]] && remote=(--remote "''${BUILD_ALL_REMOTE:-falcon}" --no-download
            --option accept-flake-config true --option builders "$pool" --option builders-use-substitutes true
            -j "''${BUILD_ALL_JOBS:-8}" --option cores "''${BUILD_ALL_CORES:-4}")
          ${lib.getExe pkgs.nix-fast-build} --flake ".#legacyPackages.$sys.build-all" --impure --no-nom --skip-cached \
            --systems "$sys" --eval-workers 4 "''${remote[@]}" --result-format json --result-file "$out/$sys.json" >&2
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
      #   KUBECTL="ssh -J 192.184.168.248 dingo sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
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

      # Take a node out for hardware work and bring it back: gates, cordon, (OSD hosts: ceph noout), drain, stop rke2,
      # then it stops at "ready to power off". Procedure and why: docs/node-standard.md, "Taking a node down for hardware work".
      #   node-maintenance falcon down --dry-run    every read-only check, prints what it would change
      #   node-maintenance falcon down [--poweroff]
      #   node-maintenance falcon up
      scripts.node-maintenance.exec = ''
        set -uo pipefail
        usage() {
          cat >&2 <<'USAGE'
        Usage: node-maintenance <host> down|up [--dry-run] [--poweroff] [--timeout <minutes>]

          down   gates, cordon, (OSD hosts: ceph noout), drain, stop rke2, then stop at "ready to power off"
          up     after the hardware work: wait Ready, check the LAN address, uncordon, unset noout,
                 wait for Ceph and for the node-bound pods
          --dry-run   run every read-only check and print what would be changed; change nothing
          --poweroff  (down only) also run `systemctl poweroff` over ssh; never done without it
          --timeout   minutes each wait may take on `up` (default 20)

        Uses $KUBECONFIG (or $KUBECTL, as `e2e` does). Nodes are reached as tristan@<node address> with
        ~/.ssh/personal; NODE_SSH_USER, NODE_SSH_KEY and NODE_SSH_OPTS (e.g. "-J 192.184.168.248") override.
        Procedure and reasons: docs/node-standard.md, "Taking a node down for hardware work".
        USAGE
          exit 2
        }

        k=''${KUBECTL:-kubectl}
        host=""; action=""; dry=0; poweroff=0; wait_min=20
        while [ $# -gt 0 ]; do
          case "$1" in
            --dry-run) dry=1 ;;
            --poweroff) poweroff=1 ;;
            --timeout) wait_min=''${2:-}; shift ;;
            -h|--help) usage ;;
            -*) echo "unknown option $1" >&2; usage ;;
            *) if [ -z "$host" ]; then host=$1; elif [ -z "$action" ]; then action=$1; else usage; fi ;;
          esac
          shift
        done
        case "$action" in down|up) ;; *) usage ;; esac
        [ -n "$host" ] || usage
        case "$wait_min" in '''|*[!0-9]*) echo "--timeout takes whole minutes" >&2; exit 2 ;; esac
        if [ "$action" = up ] && [ "$poweroff" = 1 ]; then echo "--poweroff only applies to down" >&2; exit 2; fi

        fails=0
        step() { printf '\n==> %s\n' "$*"; }
        info() { printf '    %s\n' "$*"; }
        pass() { printf '  [PASS] %s\n' "$*"; }
        warn() { printf '  [WARN] %s\n' "$*"; }
        fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
        die() { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }
        # A change: printed, and run unless --dry-run.
        # ACT_AS=<text> shows that instead of the function call.
        act() {
          if [ "$dry" = 1 ]; then printf '  [dry-run] would run: %s\n' "''${ACT_AS:-$*}"; return 0; fi
          printf '  + %s\n' "''${ACT_AS:-$*}"
          "$@"
        }
        # waitfor <what> <minutes> <cmd...>: poll every 10 s. --dry-run only evaluates it once.
        waitfor() {
          local what=$1 mins=$2 end; shift 2
          if "$@" >/dev/null 2>&1; then pass "$what"; return 0; fi
          if [ "$dry" = 1 ]; then warn "$what: not true now, would wait up to $mins min"; return 0; fi
          end=$(( $(date +%s) + mins * 60 ))
          while [ "$(date +%s)" -lt "$end" ]; do
            sleep 10
            if "$@" >/dev/null 2>&1; then pass "$what"; return 0; fi
          done
          warn "$what: still not true after $mins min"
          return 1
        }

        # ---- cluster state -------------------------------------------------------------------------------------------------
        getnodes() { nodes=$($k get nodes -o json) || return 1; }
        getnodes || { echo "cannot reach the API server (KUBECONFIG=''${KUBECONFIG:-unset})" >&2; exit 1; }
        nodejson() { jq -c --arg n "$host" '.items[] | select(.metadata.name == $n)' <<<"$nodes"; }
        [ -n "$(nodejson)" ] || { echo "no node $host; nodes: $(jq -r '[.items[].metadata.name] | join(" ")' <<<"$nodes")" >&2; exit 1; }
        nodeprop() { nodejson | jq -r "$1"; }
        ip=$(nodeprop '[.status.addresses[] | select(.type == "InternalIP") | .address] | first // empty')
        is_ready() { [ "$(nodeprop '[.status.conditions[] | select(.type == "Ready") | .status] | first')" = True ]; }
        is_cordoned() { [ "$(nodeprop '.spec.unschedulable // false')" = true ]; }
        nodelabel() { jq -r --arg n "$host" --arg l "$1" '.items[] | select(.metadata.name == $n) | .metadata.labels[$l] // empty' <<<"$nodes"; }
        ann() { jq -r --arg n "$host" --arg a "node-maintenance.trdos.me/$1" '.items[] | select(.metadata.name == $n) | .metadata.annotations[$a] // empty' <<<"$nodes"; }

        servers=$(jq -r '.items[] | select(.metadata.labels | has("node-role.kubernetes.io/etcd")) | .metadata.name' <<<"$nodes")
        is_server=0; grep -qx "$host" <<<"$servers" && is_server=1
        osd_hosts=$($k -n storage get pods -l app=rook-ceph-osd -o json 2>/dev/null | jq -r '[.items[].spec.nodeName] | unique | .[]' 2>/dev/null)
        is_osd=0; grep -qx "$host" <<<"$osd_hosts" && is_osd=1
        monpods=$($k -n storage get pods -l app=rook-ceph-mon -o json 2>/dev/null)
        [ -n "$monpods" ] || monpods='{"items":[]}'
        mons_here=$(jq -r --arg n "$host" '.items[] | select(.spec.nodeName == $n) | .metadata.labels.mon' <<<"$monpods" | paste -sd' ' -)
        class=$(nodelabel node.trdos.me/class)
        drives_json=$($k get drives.dvd.trdos.me -o json 2>/dev/null || true)
        [ -n "$drives_json" ] || drives_json='{"items":[]}'
        drives_here=$(jq -r --arg n "$host" '.items[] | select(.status.node == $n) | .metadata.name' <<<"$drives_json" | paste -sd' ' -)

        roles="agent"
        [ "$is_server" = 1 ] && roles="server (etcd + apiserver)"
        [ -n "$class" ] && roles="$roles, class=$class"
        [ "$is_osd" = 1 ] && roles="$roles, OSD host"
        [ -n "$mons_here" ] && roles="$roles, ceph mon ''${mons_here}"
        [ -n "$drives_here" ] && roles="$roles, DVD drive ''${drives_here}"
        [ -n "$(nodelabel nvidia.com/gpu.present)" ] && roles="$roles, GPU"

        # ---- helpers: ceph, etcd, ssh --------------------------------------------------------------------------------------
        # The rook operator image carries the ceph CLI and the admin keyring (there is no toolbox Deployment).
        cephc() {
          $k -n storage exec deploy/rook-ceph-operator -c rook-ceph-operator -- \
            ceph -c /var/lib/rook/storage/storage.config --keyring /var/lib/rook/storage/client.admin.keyring "$@"
        }
        ceph_health() { cephc status -f json 2>/dev/null | jq -r '.health.status'; }
        ceph_pgs_clean() { cephc status -f json 2>/dev/null | jq -e '.pgmap as $p | ($p.pgs_by_state | map(select(.state_name == "active+clean") | .count) | add // 0) == $p.num_pgs' >/dev/null; }
        ceph_noout() { cephc osd dump -f json 2>/dev/null | jq -e '.flags_set | index("noout")' >/dev/null; }
        # OSDs of every host except $1 that are not up
        osds_down_elsewhere() {
          cephc osd tree -f json 2>/dev/null | jq -r --arg n "$1" '
            . as $t | [$t.nodes[] | select(.type == "host" and .name != $n) | .children[]] as $ids
            | [$t.nodes[] | select(.type == "osd" and (.id as $i | $ids | index($i))) | select(.status != "up") | .name] | join(" ")'
        }
        osds_down_here() {
          cephc osd tree -f json 2>/dev/null | jq -r --arg n "$1" '
            . as $t | [$t.nodes[] | select(.type == "host" and .name == $n) | .children[]] as $ids
            | [$t.nodes[] | select(.type == "osd" and (.id as $i | $ids | index($i))) | select(.status != "up") | .name] | join(" ")'
        }
        witness=$(grep -vx "$host" <<<"$servers" | head -1)
        etcdctl_on() {
          local p=$1 t=/var/lib/rancher/rke2/server/tls/etcd; shift
          $k -n kube-system exec "etcd-$p" -- etcdctl --endpoints=https://127.0.0.1:2379 \
            --cacert=$t/server-ca.crt --cert=$t/server-client.crt --key=$t/server-client.key "$@"
        }
        # `endpoint status --cluster` as JSON (health, leader) and as text (the member ids in hex, for move-leader)
        etcd_json() { etcdctl_on "$witness" endpoint status --cluster -w json 2>/dev/null; }
        etcd_rows() { etcdctl_on "$witness" endpoint status --cluster 2>/dev/null; }
        etcd_members() { etcd_json | jq 'length' 2>/dev/null; }
        etcd_all_healthy() {
          etcd_json | jq -e --argjson want "$(wc -l <<<"$servers" | tr -d ' ')" \
            'length == $want and all(.[]; ((.Status.errors // []) | length) == 0)' >/dev/null
        }
        etcd_leader_ip() { etcd_json | jq -r '.[] | select(.Status.leader == .Status.header.member_id) | .Endpoint | sub("https://"; "") | sub(":2379"; "")'; }
        # a state change over ssh, printed as the command it is
        actssh() {
          local shown="ssh ''${NODE_SSH_OPTS:+$NODE_SSH_OPTS }''${NODE_SSH_USER:-tristan}@$ip sudo $*"
          if [ "$dry" = 1 ]; then printf '  [dry-run] would run: %s\n' "$shown"; return 0; fi
          printf '  + %s\n' "$shown"
          rssh sudo "$@"
        }
        rssh() {
          # shellcheck disable=SC2086
          ssh -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 ''${NODE_SSH_OPTS:-} \
            -i "''${NODE_SSH_KEY:-$HOME/.ssh/personal}" "''${NODE_SSH_USER:-tristan}@$ip" "$@"
        }

        # Pods whose nodeSelector no other Ready, schedulable node satisfies: they go (or stay) Pending while $host is out.
        # mode "on": the pods running on $host; mode "any": also unscheduled ones (for `up`).
        bound_pods() {
          $k get pods -A -o json | jq -r --argjson nodes "$nodes" --arg n "$host" --arg mode "$1" '
            ($nodes.items | map(select(.metadata.name != $n)
               | select(.spec.unschedulable != true)
               | select(([.status.conditions[] | select(.type == "Ready") | .status] | first) == "True"))) as $others
            | ($nodes.items | map(select(.metadata.name == $n)) | first | .metadata.labels) as $mine
            | .items[]
            | select(.status.phase == "Running" or .status.phase == "Pending")
            | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet")
            | select(.spec.nodeSelector != null)
            | . as $p
            | select(if $mode == "on" then .spec.nodeName == $n else (.spec.nodeName == $n or .spec.nodeName == null) end)
            | select(all($p.spec.nodeSelector | to_entries[]; $mine[.key] == .value))
            | select(($others | map(select(.metadata.labels as $l | all($p.spec.nodeSelector | to_entries[]; $l[.key] == .value))) | length) == 0)
            | "\(.metadata.namespace)/\(.metadata.name)\t\(.status.phase)\t\(.spec.nodeSelector | to_entries | map("\(.key)=\(.value)") | join(","))"'
        }
        # Pods on $host that a drain would evict (everything but DaemonSet pods; finished pods are deleted too).
        evictable() {
          $k get pods -A -o json --field-selector "spec.nodeName=$host" | jq -r '
            .items[] | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet")
            | select(.metadata.annotations["kubernetes.io/config.mirror"] == null)
            | "\(.metadata.namespace)/\(.metadata.name)\t\(.status.phase)"'
        }
        # of those, the ones a PodDisruptionBudget with 0 allowed disruptions blocks right now
        pdb_blocked() {
          local pdbs; pdbs=$($k get pdb -A -o json)
          $k get pods -A -o json --field-selector "spec.nodeName=$host,status.phase=Running" | jq -r --argjson pdbs "$pdbs" '
            .items[] | . as $p
            | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet")
            | ($pdbs.items | map(select(.metadata.namespace == $p.metadata.namespace and .status.disruptionsAllowed == 0
                and (.spec.selector.matchLabels != null)
                and all(.spec.selector.matchLabels | to_entries[]; $p.metadata.labels[.key] == .value))) | first | .metadata.name) as $b
            | select($b != null) | "\(.metadata.namespace)/\(.metadata.name)\t\($b)"'
        }
        single_instance_pods() { # "<ns> <pod>" of single-instance CNPG primaries on $host
          local single; single=$($k get clusters.postgresql.cnpg.io -A -o json 2>/dev/null | jq -c '[.items[] | select(.spec.instances == 1) | .metadata.namespace + "/" + .metadata.name]' 2>/dev/null)
          [ -n "$single" ] || single='[]'
          $k get pods -A -l cnpg.io/instanceRole=primary --field-selector "spec.nodeName=$host" -o json 2>/dev/null | jq -r --argjson s "$single" '
            .items[] | select((.metadata.namespace + "/" + .metadata.labels["cnpg.io/cluster"]) as $c | $s | index($c))
            | "\(.metadata.namespace) \(.metadata.name)"'
        }
        multi_instance_primaries() {
          local single; single=$($k get clusters.postgresql.cnpg.io -A -o json 2>/dev/null | jq -c '[.items[] | select(.spec.instances == 1) | .metadata.namespace + "/" + .metadata.name]' 2>/dev/null)
          [ -n "$single" ] || single='[]'
          $k get pods -A -l cnpg.io/instanceRole=primary --field-selector "spec.nodeName=$host" -o json 2>/dev/null | jq -r --argjson s "$single" '
            .items[] | select((.metadata.namespace + "/" + .metadata.labels["cnpg.io/cluster"]) as $c | ($s | index($c)) == null)
            | "\(.metadata.namespace)/\(.metadata.labels["cnpg.io/cluster"])"'
        }

        printf 'node-maintenance %s %s%s\n' "$host" "$action" "$([ "$dry" = 1 ] && echo ' (dry run: nothing is changed)')"
        printf 'node %s  address %s  Ready=%s  cordoned=%s\nroles: %s\n' "$host" "$ip" "$(is_ready && echo yes || echo NO)" "$(is_cordoned && echo yes || echo no)" "$roles"

        # =====================================================================================================================
        if [ "$action" = down ]; then

        step "Pre-checks"
        is_ready && pass "$host is Ready" || fail "$host is not Ready: \`down\` is for a healthy node (use \`up\` once it is back)"
        if [ -n "$(ann down-since)" ]; then fail "$host is already in maintenance since $(ann down-since) (run \`up\`)"; fi

        srv=$($k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        case "$srv" in
          "") ;;
          *"//$ip:"*|*"//$ip") fail "the kubeconfig talks to $srv, which is $host: point KUBECONFIG at another server first" ;;
          *) pass "kubeconfig server $srv is not $host" ;;
        esac

        strict=0; { [ "$is_server" = 1 ] || [ "$is_osd" = 1 ] || [ -n "$mons_here" ]; } && strict=1
        notready=$(jq -r --arg n "$host" '[.items[] | select(.metadata.name != $n) | select(([.status.conditions[] | select(.type == "Ready") | .status] | first) != "True") | .metadata.name] | join(" ")' <<<"$nodes")
        if [ -z "$notready" ]; then pass "every other node is Ready"
        elif [ "$strict" = 1 ]; then fail "other nodes not Ready: $notready (this node carries etcd, OSDs or a mon)"
        else warn "other nodes not Ready: $notready"; fi
        cordoned=$(jq -r --arg n "$host" '[.items[] | select(.metadata.name != $n and .spec.unschedulable == true) | .metadata.name] | join(" ")' <<<"$nodes")
        [ -z "$cordoned" ] || info "already cordoned (left alone): $cordoned"

        if [ "$is_server" = 1 ]; then
          others=$(grep -vx "$host" <<<"$servers" | paste -sd' ' -)
          bad=""; for s in $others; do
            [ "$(jq -r --arg n "$s" '.items[] | select(.metadata.name == $n) | [.status.conditions[] | select(.type == "Ready") | .status] | first' <<<"$nodes")" = True ] || bad="$bad $s"
          done
          [ -z "$bad" ] && pass "the other servers ($others) are Ready" || fail "server(s) not Ready:$bad: never take two servers down"
          if etcd_all_healthy; then
            pass "etcd: $(etcd_members)/$(wc -l <<<"$servers" | tr -d ' ') members healthy (read through etcd-$witness)"
          else
            fail "etcd is not 3/3 healthy (members answering: $(etcd_members)); re-read \`etcdctl endpoint status --cluster\` before touching a server"
          fi
        fi

        health=$(ceph_health)
        case "$health" in
          HEALTH_OK) pass "ceph HEALTH_OK" ;;
          "") if [ "$strict" = 1 ]; then fail "cannot read ceph status (rook-ceph-operator pod)"; else warn "cannot read ceph status"; fi ;;
          *) if [ "$strict" = 1 ]; then fail "ceph is $health (detail: \`ceph health detail\`), and $host carries ceph daemons"; else warn "ceph is $health; $host carries no ceph daemon, so this does not change"; fi ;;
        esac

        if [ -n "$mons_here" ]; then
          q=$(cephc quorum_status -f json 2>/dev/null)
          total=$(jq -r '.monmap.mons | length' <<<"$q" 2>/dev/null); total=''${total:-0}
          left=$(jq -r --arg here "$mons_here" '[.quorum_names[] | select(. as $m | ($here | split(" ") | index($m)) == null)] | length' <<<"$q" 2>/dev/null); left=''${left:-0}
          if [ "$total" -gt 0 ] && [ $((left * 2)) -gt "$total" ]; then pass "mon quorum: $left of $total mons stay in quorum without mon ''${mons_here}"
          else fail "mon quorum: only $left of $total mons would stay in quorum without mon ''${mons_here} (all mons must be in quorum first)"; fi
        fi

        if [ "$is_osd" = 1 ]; then
          other_osd=$(grep -vx "$host" <<<"$osd_hosts" | paste -sd' ' -)
          down_else=$(osds_down_elsewhere "$host")
          [ -z "$down_else" ] && pass "the OSDs on the other host(s) ($other_osd) are all up" || fail "OSDs down on another host: $down_else: never take both OSD hosts down"
          for oh in $other_osd; do
            [ "$(jq -r --arg n "$oh" '.items[] | select(.metadata.name == $n) | [.status.conditions[] | select(.type == "Ready") | .status] | first' <<<"$nodes")" = True ] || fail "OSD host $oh is not Ready"
          done
          ceph_pgs_clean && pass "all PGs active+clean" || fail "PGs are not all active+clean"
          if ceph_noout; then info "noout is already set (it will be left set by \`up\`)"; fi
        fi

        # DVD drive: never interrupt a disc being read
        busy=$(jq -r --arg n "$host" '.items[] | select(.status.node == $n) | select(.status.state == "Reading" or .status.state == "BackingUp" or .status.state == "Uploading" or .status.state == "Ejecting") | "\(.metadata.name)=\(.status.state)"' <<<"$drives_json" | paste -sd' ' -)
        [ -z "$busy" ] || fail "a disc is being read ($busy): wait for the drive to go Waiting (\`kubectl get drives\`)"
        jobs=$($k get pods -A -l dvd.trdos.me/disc --field-selector "spec.nodeName=$host,status.phase=Running" -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"' | paste -sd' ' -)
        [ -z "$jobs" ] || fail "dvdrip encode/publish Jobs are running here: $jobs (an interrupted Job restarts from the start)"
        { [ -n "$drives_here" ] && [ -z "$busy" ] && [ -z "$jobs" ]; } && pass "no disc is being read or encoded on $host"

        pending=$($k get pods -A --field-selector status.phase=Pending -o json | jq -r '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")')
        [ -z "$pending" ] && pass "no Pending pods cluster-wide" || warn "Pending pods before starting: $pending"

        if rssh 'sudo -n true' >/dev/null 2>&1; then pass "ssh and passwordless sudo on $host ($ip)"; else fail "cannot ssh to $ip and run \`sudo -n true\` (NODE_SSH_USER / NODE_SSH_KEY / NODE_SSH_OPTS)"; fi

        step "What this takes down"
        bound=$(bound_pods on)
        ev=$(evictable | grep -vc 'Succeeded\|Failed' || true)
        info "$ev running pods are evicted and recreated on other nodes (RBD/CephFS volumes follow them)."
        if [ -n "$bound" ]; then
          info "pods no other node can run (nodeSelector); they stay Pending until $host is back:"
          while IFS=$'\t' read -r p _ sel; do info "  $p   ($sel)"; done <<<"$bound"
        else info "no pod is bound to $host by a nodeSelector."; fi
        blocked=$(pdb_blocked)
        if [ -n "$blocked" ]; then
          info "blocked by a PodDisruptionBudget with 0 allowed disruptions right now (the drain retries them):"
          while IFS=$'\t' read -r p b; do info "  $p   (pdb $b)"; done <<<"$blocked"
        fi
        [ -z "$drives_here" ] || info "DVD drive(s) $drives_here: paused for the duration (re-enabled by \`up\`)."
        vips=$($k -n kube-system get lease -o json | jq -r --arg n "$host" '[.items[] | select(.metadata.name | startswith("cilium-l2announce-")) | select(.spec.holderIdentity == $n) | .metadata.name | sub("cilium-l2announce-"; "")] | join(" ")')
        [ -z "$vips" ] || info "L2 announcements held now: $vips; another node takes each over once its 15 s lease lapses."
        if [ "$is_osd" = 1 ]; then info "OSDs here: $($k -n storage get pods -l app=rook-ceph-osd --field-selector "spec.nodeName=$host" --no-headers | wc -l | tr -d ' '); with size 2 and min_size 1 Ceph stays writable but every PG is degraded."; fi

        if [ "$fails" -gt 0 ]; then
          if [ "$dry" = 1 ]; then printf '\nDRY RUN: %s gate(s) FAILED, a real run would refuse. Plan below is for reference.\n' "$fails"
          else die "$fails gate(s) failed; nothing was changed"; fi
        fi

        step "Plan"
        step_no=0
        n() { step_no=$((step_no + 1)); printf '%s. ' "$step_no"; }

        n; echo "record the starting state on the node (annotations node-maintenance.trdos.me/*)"
        act $k annotate node "$host" --overwrite \
          "node-maintenance.trdos.me/down-since=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "node-maintenance.trdos.me/lan-ip=$ip" \
          "node-maintenance.trdos.me/was-cordoned=$(is_cordoned && echo true || echo false)" \
          "node-maintenance.trdos.me/noout-before=$(if [ "$is_osd" = 1 ] && ceph_noout; then echo true; else echo false; fi)" \
          "node-maintenance.trdos.me/excluded-by-us=$([ -z "$(nodelabel remediation.medik8s.io/exclude-from-remediation)" ] && echo true || echo false)"

        if [ -z "$(nodelabel remediation.medik8s.io/exclude-from-remediation)" ]; then
          n; echo "exclude the node from medik8s remediation (it would read as unhealthy after 15 min NotReady)"
          act $k label node "$host" remediation.medik8s.io/exclude-from-remediation=true
        fi

        if [ -n "$drives_here" ]; then
          n; echo "pause the DVD drive(s) (a new disc is not started during the work)"
          for d in $drives_here; do
            if [ "$(jq -r --arg d "$d" '.items[] | select(.metadata.name == $d) | .spec.enabled // true' <<<"$drives_json")" = true ]; then
              act $k annotate drives.dvd.trdos.me "$d" --overwrite node-maintenance.trdos.me/paused=true
              act $k patch drives.dvd.trdos.me "$d" --type merge -p '{"spec":{"enabled":false}}'
            else info "$d is already disabled; left as it is"; fi
          done
        fi

        n; echo "cordon (CNPG switches the Postgres primaries off the node by itself)"
        act $k cordon "$host"

        if [ "$is_osd" = 1 ]; then
          n; echo "ceph osd set noout (the OSDs go down with the node; do not mark them out and remap after 10 min)"
          ACT_AS="ceph osd set noout   (in the rook-ceph-operator pod)" act cephc osd set noout
        fi

        sp=$(single_instance_pods)
        if [ -n "$sp" ]; then
          n; echo "delete the single-instance Postgres primaries (their PDB allows no eviction; recreated elsewhere)"
          while read -r ns p; do act $k -n "$ns" delete pod "$p"; done <<<"$sp"
        fi
        mp=$(multi_instance_primaries | sort -u | paste -sd' ' -)
        [ -z "$mp" ] || info "(replicated primaries here, moved by the switchover after the cordon: $mp)"

        if [ "$is_server" = 1 ]; then
          n; echo "move the etcd leader off $host if it is the leader"
          leader_ip=$(etcd_leader_ip)
          if [ "$leader_ip" = "$ip" ]; then
            # servers (space separated) to keep the leadership off, e.g. one on a failing disk; none now
            avoid=''${NODE_MAINT_AVOID_LEADER:-}
            target_row=""
            for pass_avoid in no yes; do
              for cand in $(grep -vx "$host" <<<"$servers"); do
                [ -z "$target_row" ] || break
                case " $avoid " in *" $cand "*) [ "$pass_avoid" = yes ] || continue ;; esac
                cip=$(jq -r --arg n "$cand" '.items[] | select(.metadata.name == $n) | [.status.addresses[] | select(.type == "InternalIP") | .address] | first' <<<"$nodes")
                row=$(etcd_rows | awk -F', ' -v ip="$cip" 'index($1, "//" ip ":") {print $2}')
                [ -n "$row" ] && target_row="$row:$cand"
              done
            done
            [ -n "$target_row" ] || die "$host is the etcd leader and no other member answers"
            info "$host is the etcd leader; handing it to ''${target_row#*:} (member ''${target_row%%:*})"
            ACT_AS="kubectl -n kube-system exec etcd-$host -- etcdctl move-leader ''${target_row%%:*}" act etcdctl_on "$host" move-leader "''${target_row%%:*}"
          else info "$host is not the etcd leader (leader is at ''${leader_ip:-unknown}); nothing to move"; fi
        fi

        n; echo "drain: kubectl drain $host --ignore-daemonsets --delete-emptydir-data"
        if [ "$dry" = 1 ]; then
          act $k drain "$host" --ignore-daemonsets --delete-emptydir-data --timeout=15m
        else
          printf '  + %s drain %s --ignore-daemonsets --delete-emptydir-data --timeout=15m\n' "$k" "$host"
          $k drain "$host" --ignore-daemonsets --delete-emptydir-data --timeout=15m || die "drain did not finish (a PDB is blocking?). $host is cordoned; fix it and rerun, or back out with \`$k uncordon $host\`$([ "$is_osd" = 1 ] && echo " and \`ceph osd unset noout\`")"
          left=$(evictable | grep -v 'Succeeded\|Failed' | paste -sd' ' -)
          [ -z "$left" ] && pass "no workload pod is left on $host" || warn "still on $host: $left"
          if [ "$is_osd" = 1 ]; then ceph_noout && pass "ceph noout is set" || warn "noout is NOT set after the drain (rook may have cleared it): ceph osd set noout"; fi
        fi

        n; echo "stop rke2 on the node"
        if [ "$is_server" = 1 ]; then unit=rke2-server; else unit=rke2-agent; fi
        actssh systemctl stop "$unit"
        if [ "$is_server" = 1 ] && [ "$dry" != 1 ]; then
          sleep 15
          healthy=$(etcd_json | jq '[.[] | select(((.Status.errors // []) | length) == 0)] | length')
          info "etcd from etcd-$witness: ''${healthy:-0} of $(wc -l <<<"$servers" | tr -d ' ') members answer (quorum needs 2)"
        fi

        if [ "$poweroff" = 1 ]; then
          n; echo "power off"
          actssh systemctl poweroff
          [ "$dry" = 1 ] || printf '\n%s powering off. After the hardware work: boot it, then `node-maintenance %s up`.\n' "$host" "$host"
        else
          printf '\nREADY TO POWER OFF %s.' "$host"
          printf '\n  ssh %s%s@%s sudo systemctl poweroff     (or rerun with --poweroff)\n  After the hardware work: boot it, then `node-maintenance %s up`.\n' "''${NODE_SSH_OPTS:+$NODE_SSH_OPTS }" "''${NODE_SSH_USER:-tristan}" "$ip" "$host"
        fi
        [ "$dry" = 1 ] && { [ "$fails" -gt 0 ] && exit 1 || { printf '\nDRY RUN: all gates pass; nothing was changed.\n'; exit 0; }; }
        exit 0
        fi

        # =====================================================================================================================
        step "Where the node is"
        since=$(ann down-since)
        if [ -n "$since" ]; then info "in maintenance since $since (recorded by \`down\`)"; else info "no maintenance record on the node (\`down\` was not run, or was done by hand)"; fi
        is_cordoned && info "cordoned" || info "schedulable"

        step "Boot and join"
        info "Power the machine on if it is off. Waiting for it to rejoin (up to $wait_min min)."
        node_ready() { getnodes && is_ready; }
        waitfor "$host is Ready" "$wait_min" node_ready
        getnodes; ip_now=$(nodeprop '[.status.addresses[] | select(.type == "InternalIP") | .address] | first // empty')
        want=$(ann lan-ip)
        if [ -z "$want" ]; then
          info "address now $ip_now (no record of the one before; the declared one is \`lan\` in static/builders.nix)"
        elif [ "$ip_now" = "$want" ]; then pass "LAN address unchanged: $ip_now"
        else fail "address changed from $want to ''${ip_now:-none}: the router did not honour RequestAddress. Fix the lease, then restart rke2 and delete the cilium pods on the node (\"What the roll found\" 2 in docs/node-standard.md)"; fi
        if [ "$fails" -gt 0 ]; then
          if [ "$dry" = 1 ]; then printf '\nDRY RUN: a gate FAILED, a real run would stop here.\n'; else die "the node is up with a different address; nothing else was done"; fi
        fi

        if [ "$is_server" = 1 ]; then
          step "etcd"
          waitfor "etcd 3/3 healthy" "$wait_min" etcd_all_healthy
        fi

        step "Uncordon, ceph, drives"
        if [ "$(ann was-cordoned)" = true ]; then info "$host was already cordoned before \`down\`: left cordoned"
        elif is_cordoned; then act $k uncordon "$host"
        else info "already schedulable"; fi

        if [ "$is_osd" = 1 ]; then
          osds_up() { [ -z "$(osds_down_here "$host")" ]; }
          waitfor "every OSD on $host is up" "$wait_min" osds_up
          if ceph_noout; then
            if [ "$(ann noout-before)" = true ]; then info "noout was set before \`down\`: left set"
            else ACT_AS="ceph osd unset noout   (in the rook-ceph-operator pod)" act cephc osd unset noout; fi
          else info "noout is not set"; fi
          ceph_ok() { [ "$(ceph_health)" = HEALTH_OK ]; }
          waitfor "ceph HEALTH_OK" "$wait_min" ceph_ok
        else
          h=$(ceph_health); info "ceph: ''${h:-unreadable} (no ceph daemon is bound to $host)"
        fi

        for d in $drives_here; do
          if [ "$(jq -r --arg d "$d" '.items[] | select(.metadata.name == $d) | .metadata.annotations["node-maintenance.trdos.me/paused"] // empty' <<<"$drives_json")" = true ]; then
            act $k patch drives.dvd.trdos.me "$d" --type merge -p '{"spec":{"enabled":true}}'
            act $k annotate drives.dvd.trdos.me "$d" node-maintenance.trdos.me/paused-
          fi
        done

        step "Node-bound pods"
        nb_ok() { ! bound_pods any | awk -F'\t' '$2 != "Running"' | grep -q .; }
        bp=$(bound_pods any)
        if [ -z "$bp" ]; then info "no pod is bound to $host by a nodeSelector"
        else
          waitfor "every pod bound to $host is Running" "$wait_min" nb_ok
          while IFS=$'\t' read -r p ph sel; do info "  $p $ph ($sel)"; done < <(bound_pods any)
        fi
        rest=$($k get pods -A --field-selector status.phase=Pending -o json | jq -r '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"] | join(" ")')
        [ -z "$rest" ] && pass "no Pending pods cluster-wide" || warn "Pending pods: $rest (the node's DaemonSet pods take 5 to 15 min: cilium rate-limits endpoint creation)"

        step "Clear the maintenance record"
        if [ "$(ann excluded-by-us)" = true ]; then act $k label node "$host" remediation.medik8s.io/exclude-from-remediation-; fi
        if [ -n "$since" ]; then
          act $k annotate node "$host" node-maintenance.trdos.me/down-since- node-maintenance.trdos.me/lan-ip- node-maintenance.trdos.me/was-cordoned- node-maintenance.trdos.me/noout-before- node-maintenance.trdos.me/excluded-by-us-
        fi
        if [ "$dry" = 1 ]; then printf '\nDRY RUN: nothing was changed.\n'; else printf '\n%s is back.\n' "$host"; fi
        [ "$fails" -gt 0 ] && exit 1
        exit 0
      '';

      # A Syncthing device ID is the hash of the device's TLS certificate, so a device's identity is
      # declared like any config: the key pair is generated once here, encrypted to the host
      # (.sops.yaml: secrets/sops/syncthing-<host>.yaml) and installed by modules/syncthing.nix; the ID is
      # public and goes in `syncthing.users.<person>.devices.<host>.id`. Never regenerate for a host in use (its ID changes).
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

      # Restore test for the weekly Bitwarden Secrets Manager backup (nixidy/system/security/bws-backup.nix):
      # fetches the newest object from the VolSync B2 bucket, decrypts it with the private key held in
      # secrets/sops/personal.yaml (`age.bws-backup`, never in the cluster) and checks it parses and still
      # holds the restic password and the B2 keys. Prints counts only, never values.
      scripts.bws-backup-restore-test.exec = ''
        set -euo pipefail
        dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
        secrets=$(bws secret list -o json)
        field() { jq -r --arg k "$1" '.[] | select(.key == $k) | .value' <<<"$secrets"; }
        export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=https://s3.us-west-004.backblazeb2.com RCLONE_S3_NO_CHECK_BUCKET=true
        RCLONE_S3_ACCESS_KEY_ID=$(field backblaze/bucket/application_key_id); export RCLONE_S3_ACCESS_KEY_ID
        RCLONE_S3_SECRET_ACCESS_KEY=$(field backblaze/bucket/application_key); export RCLONE_S3_SECRET_ACCESS_KEY
        src=":s3:${builtins.replaceStrings ["."] ["-"] domain}--volsync/bws-backup"
        newest=$(rclone lsf --files-only "$src" | sort | tail -n 1)
        [ -n "$newest" ] || { echo "no object under $src" >&2; exit 1; }
        echo "newest: $newest ($(rclone lsf --files-only --format sp "$src" | grep -F "$newest" | cut -d';' -f1) bytes)"
        rclone copyto "$src/$newest" "$dir/backup.age"
        umask 077
        sops decrypt --extract '["age"]["bws-backup"]' "${config.devenv.root}/secrets/sops/personal.yaml" > "$dir/key"
        age -d -i "$dir/key" -o "$dir/backup.json" "$dir/backup.age"
        jq -e 'type == "array" and length > 0' "$dir/backup.json" >/dev/null
        for k in volsync/restic/password backblaze/bucket/application_key_id backblaze/bucket/application_key; do
          jq -e --arg k "$k" 'any(.[]; .key == $k and (.value | length) > 0)' "$dir/backup.json" >/dev/null || { echo "missing or empty: $k" >&2; exit 1; }
        done
        echo "OK: $(jq length "$dir/backup.json") secrets in $newest"
        # live vs backup: keys present in Bitwarden now but absent from the backup (new since the backup)
        echo "keys added since the backup: $(jq -n --slurpfile b "$dir/backup.json" --argjson l "$secrets" '[$l[].key] - [$b[0][].key] | length')"
      '';

      # Restore rehearsal for the off-site etcd snapshots (static/etcd-snapshot.nix): restores the newest
      # `etcd/offsite-*` object from the VolSync B2 bucket into a throwaway etcd + kube-apiserver on falcon
      # and lists its namespaces. Never touches the live cluster; docs/etcd-restore.md.
      scripts.etcd-restore-test.exec = ''
        exec "${config.devenv.root}/tools/etcd-restore-test" "$@"
      '';

      # Restore test for the nightly headscale backup (static/headscale-backup.nix): fetches the newest object
      # from the VolSync B2 bucket, decrypts it with the same offline key as the Bitwarden backup
      # (`age.bws-backup` in secrets/sops/personal.yaml), checks the database and lists the registered nodes.
      # Prints names and counts only, never key material.
      scripts.headscale-backup-restore-test.exec = ''
        set -euo pipefail
        dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
        secrets=$(bws secret list -o json)
        field() { jq -r --arg k "$1" '.[] | select(.key == $k) | .value' <<<"$secrets"; }
        export RCLONE_S3_PROVIDER=Other RCLONE_S3_ENDPOINT=https://s3.us-west-004.backblazeb2.com RCLONE_S3_NO_CHECK_BUCKET=true
        RCLONE_S3_ACCESS_KEY_ID=$(field backblaze/bucket/application_key_id); export RCLONE_S3_ACCESS_KEY_ID
        RCLONE_S3_SECRET_ACCESS_KEY=$(field backblaze/bucket/application_key); export RCLONE_S3_SECRET_ACCESS_KEY
        src=":s3:${builtins.replaceStrings ["."] ["-"] domain}--volsync/headscale-backup"
        newest=$(rclone lsf --files-only "$src" | sort | tail -n 1)
        [ -n "$newest" ] || { echo "no object under $src" >&2; exit 1; }
        echo "newest: $newest ($(rclone lsf --files-only --format sp "$src" | grep -F "$newest" | cut -d';' -f1) bytes)"
        rclone copyto "$src/$newest" "$dir/backup.age"
        umask 077
        sops decrypt --extract '["age"]["bws-backup"]' "${config.devenv.root}/secrets/sops/personal.yaml" > "$dir/key"
        mkdir "$dir/state"
        age -d -i "$dir/key" "$dir/backup.age" | tar -xz -C "$dir/state"
        for f in db.sqlite noise_private.key derp_server_private.key; do
          [ -s "$dir/state/$f" ] || { echo "missing or empty: $f" >&2; exit 1; }
        done
        [ "$(sqlite3 "$dir/state/db.sqlite" "PRAGMA integrity_check")" = ok ] || { echo "integrity_check failed" >&2; exit 1; }
        echo "OK: integrity ok, $(sqlite3 "$dir/state/db.sqlite" "SELECT count(*) FROM nodes WHERE deleted_at IS NULL") nodes, $(sqlite3 "$dir/state/db.sqlite" "SELECT count(*) FROM users") users"
        sqlite3 -separator ' ' "$dir/state/db.sqlite" "SELECT hostname, ipv4 FROM nodes WHERE deleted_at IS NULL ORDER BY ipv4"
      '';

      # `android <device> [apply | pair <ip:port> <code> | productivity [app...] [--dry-run]]`: compares a phone with
      # android.devices.<device> over adb on the tailnet (docs/android-fleet.md). adb runs on bonobo, which
      # holds the paired key; `pair` pairs that key once (Android 11+ wireless debugging drops an unpaired key
      # with no prompt) from the phone's "Pair device with pairing code" dialog, then runs the audit. The
      # audit also checks the notes and calendar stack (Syncthing-Fork, Orgzly Revived, DAVx5, Fossify
      # Calendar) when the device declares `productivity`. `apply` opens Obtainium's
      # import of the missing apps. `productivity` configures those four apps as far as Android allows
      # (tools/android-productivity, static/android-adb.sh) and says exactly what to tap; `--dry-run` runs
      # the same script against a stand-in phone and prints what it would do. Nothing is ever uninstalled.
      scripts.android.exec = let
        inherit ((import ./static/builders.nix).nodes) bonobo;
      in ''
        set -euo pipefail
        dev=''${1:?Usage: android <device> [apply | pair <ip:port> <code> | productivity [syncthing orgzly davx5 fossify] [--dry-run] [--wait 20m]]}
        mode=''${2:-status}
        shift; [ $# -eq 0 ] || shift
        extra=("$@")
        root="${config.devenv.root}"
        want=$(nix eval --no-pure-eval --json "$root#legacyPackages.${system}.android.devices.$dev")
        rev=$(jq -r .nodes.nixpkgs.locked.rev "$root/flake.lock")
        host=$(jq -r .hostname <<<"$want")
        key=(); [ -r "$HOME/.ssh/personal" ] && key=(-o IdentitiesOnly=yes -i "$HOME/.ssh/personal")
        # variables the remote script reads (productivity spec, secrets): through ssh's stdin, never an argument
        hdr=""
        dry=""
        for x in ''${extra[@]+"''${extra[@]}"}; do [ "$x" != --dry-run ] || dry=1; done
        if [ "$mode" = pair ]; then
          # the code is good for one pairing; it travels in the script header on ssh's stdin, never in an argument list
          pargs=(); for x in ''${extra[@]+"''${extra[@]}"}; do [ "$x" = --dry-run ] || pargs+=("$x"); done
          [ "''${#pargs[@]}" -eq 2 ] && [[ "''${pargs[0]}" =~ ^[0-9.]+:[0-9]+$ ]] && [[ "''${pargs[1]}" =~ ^[0-9]+$ ]] \
            || { echo "Usage: android $dev pair <ip:pairing-port> <code> (Developer options > Wireless debugging > Pair device with pairing code)" >&2; exit 64; }
          hdr=$(printf 'pair_addr=%q\npair_code=%q\n' "''${pargs[0]}" "''${pargs[1]}")
        fi
        hdr=$(printf 'dev=%q\n%s' "$dev" "$hdr")
        script() { cat "$root/static/android-adb.sh"; }
        if [ "$mode" = productivity ]; then
          ph=$("$root/tools/android-productivity" apply "$dev" ''${extra[@]+"''${extra[@]}"} <<<"$want")
          hdr="$hdr"$'\n'"$ph"
        elif [ "$(jq '.productivity != null' <<<"$want")" = true ]; then
          ph=$("$root/tools/android-productivity" audit "$dev" <<<"$want") \
            || ph=$(printf 'spec=%q\n' "$(jq -c .productivity <<<"$want")")
          hdr="$hdr"$'\n'"$ph"
        fi
        if [ -n "$dry" ]; then
          { printf '%s\n' "$hdr"; echo 'dry=1'; script; } | bash -s -- "$host"
          exit
        fi
        # LAN first, else the edge box (sirver) as a jump to bonobo's tailnet IP
        via=(''${ANDROID_ADB_VIA:-tristan@${bonobo.lan}})
        ssh "''${key[@]}" -o ConnectTimeout=5 "''${via[@]}" true 2>/dev/null \
          || via=(-J tristan@192.184.168.248 tristan@${bonobo.tailnet})
        remote() {
          { printf '%s\n' "$hdr"; [ -z "''${1:-}" ] || printf 'link=%q\n' "$1"; script; } \
            | ssh "''${key[@]}" "''${via[@]}" \
              nix shell "github:NixOS/nixpkgs/$rev#android-tools" "github:NixOS/nixpkgs/$rev#nmap" "github:NixOS/nixpkgs/$rev#curl" "github:NixOS/nixpkgs/$rev#jq" \
              -c bash -s -- "$host"
        }
        if [ "$mode" = productivity ]; then
          remote
          exit
        fi
        have=$(remote)
        report=$(jq -n --argjson want "$want" --arg have "$have" '
          ($have | split("\n") | map(select(. != "") | capture("^(?<k>[a-z_]+) (?<v>.*)$"))) as $l
          | ($l | map(select(.k != "pkg" and .k != "prod") | {key: .k, value: .v}) | from_entries) as $s
          | ($l | map(select(.k == "pkg") | .v | split(" ")) | map({key: .[0], value: .[1]}) | from_entries) as $pkgs
          | ($want.apps | map(.id)) as $ids
          | ($l | map(select(.k == "prod") | .v)) as $prod
          | {
              device: $s, vpn: $want.vpn, prod: $prod,
              prodDrift: ($prod | map(select(startswith("DRIFT"))) | length),
              vpnDrift: (($s.vpn_app == "com.tailscale.ipn") != $want.vpn.alwaysOn
                or ($want.vpn.alwaysOn and (($s.vpn_lockdown == "1") != $want.vpn.lockdown))),
              missing: [$want.apps[] | select($pkgs[.id] == null)],
              foreign: [$ids[] | select($pkgs[.] != null and $pkgs[.] != "dev.imranr.obtainium") | "\(.) (\($pkgs[.]))"],
              extra: [$pkgs | to_entries[] | select(.value == "dev.imranr.obtainium" and (.key | IN($ids[]) | not)) | .key]
            }')
        jq -r --arg dev "$dev" '
          "\($dev): \(.device.serial), Android \(.device.release)",
          "vpn: always-on=\(.device.vpn_app) lockdown=\(.device.vpn_lockdown) (want alwaysOn=\(.vpn.alwaysOn) lockdown=\(.vpn.lockdown))\(if .vpnDrift then "  DRIFT: Settings > Network > VPN > Tailscale" else "" end)",
          "missing (\(.missing | length)): \(.missing | map(.name) | join(", "))",
          "installed outside Obtainium (\(.foreign | length)): \(.foreign | join(", "))",
          "Obtainium installs not declared (\(.extra | length)): \(.extra | join(", "))",
          (if (.prod | length) > 0 then "notes and calendar (\(.prodDrift) drifted):", (.prod[] | "  \(.)") else empty end)' <<<"$report"
        if [ "$mode" = apply ] && [ "$(jq '.missing | length' <<<"$report")" -gt 0 ]; then
          remote "obtainium://apps/$(jq -r '.missing | tojson | @uri' <<<"$report")" | grep -x 'opened import'
          echo "confirm the import in Obtainium on the phone"
        fi
        jq -e '.vpnDrift or (.missing | length) > 0 or .prodDrift > 0' <<<"$report" >/dev/null && exit 2 || exit 0
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
                  export NIX_CONFIG="extra-substituters = http://chinchilla:8199/main
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
        age # age-keygen; `bws-backup-restore-test` decrypts the Bitwarden backup
        rclone # `bws-backup-restore-test` downloads it
        sqlite # `headscale-backup-restore-test` checks the headscale database
      ];

      images.ha = "Home Assistant with custom components";
    }
  ];
}
