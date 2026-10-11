# Personal Macs join headscale like the NixOS desktops (static/tailnet-personal.nix):
# tailscaled from nix-darwin, plus a root launchd job that logs in with the
# personal preauth key (secrets/sops/personal.yaml, decrypted with tristan's age
# key) whenever the daemon needs a login.
#
# Work Macs keep their employer's tailnet (modules/work) on the system
# tailscaled, so headscale gets a second, userspace tailscaled next to it: own
# state and socket, no utun, reachable only through its SOCKS5 (localhost:1055)
# and HTTP CONNECT (localhost:1056) proxies. `trdos <cmd>` runs a command with
# the proxy env; socks5h and CONNECT hand the hostname to tailscaled, which
# should resolve *.trdos.me with the tailnet DNS (check after the first login).
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
          (pkgs.writeShellScriptBin "trdos" ''
            export ALL_PROXY=socks5h://localhost:1055 all_proxy=socks5h://localhost:1055
            export HTTPS_PROXY=http://localhost:1056 https_proxy=http://localhost:1056
            export HTTP_PROXY=http://localhost:1056 http_proxy=http://localhost:1056
            export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
            exec "$@"
          '')
          (pkgs.writeShellScriptBin "tailscale-personal" ''exec ${lib.getExe package} --socket=${socket} "$@"'')
        ];
      })
    ];
  };
}
