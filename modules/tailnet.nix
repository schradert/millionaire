# Personal Macs join headscale like the NixOS desktops (static/tailnet-personal.nix):
# tailscaled from nix-darwin, plus a root launchd job that logs in with the
# personal preauth key (secrets/sops/personal.yaml, decrypted with tristan's age
# key) whenever the daemon needs a login.
#
# Work Macs keep their employer's tailnet (modules/work) on the system
# tailscaled, so headscale gets a second, userspace tailscaled next to it: own
# state and socket, no utun, reachable only through its SOCKS5 (localhost:1055)
# and HTTP CONNECT (localhost:1056) proxies. `trdos <cmd>` runs a command with
# the proxy env; socks5h and CONNECT hand the hostname to tailscaled. Its dialer
# resolves only IP literals and netmap names (peers, headscale extra_records); any
# other name goes to the daemon's SYSTEM resolver, never to the tailnet DNS
# (net/tsdial userDialResolveAll), which does not know the internal *.trdos.me
# names, so those fail with `Tailscale-Connect-Error: lookup <host>: ...` unless
# the target is an IP. `--accept-dns` does not change this (it is already on).
# `trdos-check` tells the DNS failure from a route failure.
#   honor it: curl, git (https), kubectl, k9s, helm, argocd, tea, opencode (bun), sso-token
#   do not: ssh (use `ssh -o ProxyCommand='nc -X 5 -x localhost:1055 %h %p'`),
#   Node CLIs such as immich, GUI apps and browsers (set a SOCKS proxy per app)
{
  darwin = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta) domain people;
    package = config.services.tailscale.package;
    socket = "/var/run/tailscale-personal.sock";
    # The internal gateway's native tailnet address (static/tailnet.nix gatewayRelay).
    relay = (import ../static/builders.nix).nodes.bonobo.tailnet;
    # `tailscale up` with the personal preauth key whenever the daemon needs a login.
    login = name: tailscale:
      pkgs.writeShellApplication {
        inherit name;
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
    loginJob = program: {
      ProgramArguments = [(lib.getExe program)];
      RunAtLoad = true;
      StartInterval = 300;
    };
    trdos = pkgs.writeShellScriptBin "trdos" ''
      export ALL_PROXY=socks5h://localhost:1055 all_proxy=socks5h://localhost:1055
      export HTTPS_PROXY=http://localhost:1056 https_proxy=http://localhost:1056
      export HTTP_PROXY=http://localhost:1056 http_proxy=http://localhost:1056
      export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
      exec "$@"
    '';
    # One verdict line per check; the exit status is the number of failed checks.
    trdosCheck = pkgs.writeShellApplication {
      name = "trdos-check";
      runtimeInputs = with pkgs; [curl jq];
      # check() calls the functions below through "$@"
      excludeShellChecks = ["SC2329"];
      text = ''
        ts() { ${lib.getExe package} --socket=${socket} "$@"; }
        host=git.${domain}
        failed=0
        check() {
          name=$1
          shift
          if out=$("$@" 2>&1); then
            echo "ok   $name"
          else
            echo "FAIL $name: $(echo "$out" | tail -n 1)"
            failed=$((failed + 1))
          fi
        }
        running() { [ "$(ts status --json | jq -r .BackendState)" = Running ]; }
        resolves() { ts dns query "$host" | grep TypeA >/dev/null; }
        check "tailscaled-personal BackendState Running" running
        check "tailnet DNS resolves $host (tailscale-personal dns query)" resolves
        check "trdos curl https://headscale.${domain}/health" ${trdos}/bin/trdos curl -fsS --max-time 15 -o /dev/null https://headscale.${domain}/health
        check "trdos curl https://$host (the dialer resolves the name)" ${trdos}/bin/trdos curl -fsSI --max-time 15 -o /dev/null "https://$host"
        # The same request with the CONNECT target pinned to the relay: ok here but FAIL above is
        # the dialer's name resolution; FAIL here too is the route, the relay or the ACL.
        check "trdos curl https://$host via relay ${relay}:443" ${trdos}/bin/trdos curl -fsSI --max-time 15 -o /dev/null --connect-to "$host:443:${relay}:443" "https://$host"
        exit "$failed"
      '';
    };
  in {
    config = lib.mkMerge [
      (lib.mkIf (config.profiles.workstation.enable && config.profile == "personal") {
        services.tailscale.enable = true;
        launchd.daemons.tailscale-login.serviceConfig = loginJob (login "tailscale-login" (lib.getExe package));
      })
      (lib.mkIf (config.profiles.workstation.enable && config.profile == "work") {
        launchd.daemons.tailscaled-personal.serviceConfig = {
          ProgramArguments = [
            "${package}/bin/tailscaled"
            "--tun=userspace-networking"
            "--socks5-server=localhost:1055"
            "--outbound-http-proxy-listen=localhost:1056"
            "--statedir=/var/db/tailscale-personal"
            "--socket=${socket}"
            "--port=0"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardErrorPath = "/var/log/tailscaled-personal.log";
        };
        launchd.daemons.tailscale-personal-login.serviceConfig =
          loginJob (login "tailscale-personal-login" "${lib.getExe package} --socket=${socket}");
        environment.systemPackages = [
          trdos
          (pkgs.writeShellScriptBin "tailscale-personal" ''exec ${lib.getExe package} --socket=${socket} "$@"'')
          trdosCheck
        ];
      })
    ];
  };
}
