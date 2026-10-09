{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  inherit (flake.config.canivete.meta) domain;
  user = flake.config.canivete.meta.people.users.tristan;
  tailnetIP = "100.64.0.1";
  # Tailnet-only vhosts: no public DNS record, cert via ACME DNS-01.
  ntfyHost = "ntfy.${domain}";
  gatewayProbeHost = "gatus-probe.${domain}";
  statusHost = "status.${domain}";
  tailnetVhost = port: {
    useACMEHost = ntfyHost;
    forceSSL = true;
    # Bind only the tailnet IP (nonlocal_bind is set below, so this is safe
    # before tailscale0 is up), so nothing answers on the public interface.
    listen = [
      {
        addr = tailnetIP;
        port = 443;
        ssl = true;
      }
      {
        addr = tailnetIP;
        port = 80;
      }
    ];
    # Belt and braces if the listen address ever widens.
    extraConfig = ''
      allow 100.64.0.0/10;
      allow 127.0.0.1;
      deny all;
    '';
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
    };
  };
  # AdGuard user rules (the live config is external-dns-managed, so these are
  # merged in on every start rather than living in the first-boot seed only).
  tailnetRewrites = map (host: "|${host}^$dnsrewrite=NOERROR;A;${tailnetIP},important") [ntfyHost statusHost];
in {
  imports = [./vps.nix];

  # Hyena is a root-only bootstrap server; opting out of home-manager keeps
  # ungated home modules (helix + tree-sitter parsers, etc.) out of its closure.
  home-manager.users = lib.mkForce {};

  networking.hostName = "hyena";

  # Hetzner x86 VMs boot legacy BIOS only — the fleet default (systemd-boot +
  # ESP, via srvos) can never boot here, so force GRUB. The live host is
  # GPT + ESP + ZFS (BIOS-boot partition + GRUB on /dev/sda), matching the disko
  # layout from vps.nix. Verified 2026-06-22 that the flake config generates this
  # exact fileSystems + bootloader (root = root/system/root zfs, /boot vfat) and
  # the sops age key is present, so deploy-rs switches against hyena are
  # reboot-safe. (An earlier note here claimed an MBR+ext4 golden image that was
  # undeployable until a disko-image alignment — stale; hyena is already on the
  # aligned ZFS layout.)
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # Hetzner cx33: virtio devices, 8GB RAM (cap ZFS ARC at 512MB).
  # Force-load virtio modules in initrd so the root disk is visible before ZFS
  # tries to import; otherwise hardware detection sometimes loses the race and
  # boot stalls in initrd waiting for a disk that never appears.
  boot.initrd.kernelModules = ["virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi"];
  boot.initrd.availableKernelModules = ["virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi"];
  boot.kernelParams = ["zfs.zfs_arc_max=536870912"];

  # Pool is unencrypted — without this, ZFS prompts for credentials at boot
  # and hangs indefinitely on Hetzner's headless console.
  boot.zfs.requestEncryptionCredentials = false;
  # Use partuuid-based device nodes; /dev/disk/by-id can be empty for virtio.
  boot.zfs.devNodes = "/dev/disk/by-partuuid";

  users.users.root.openssh.authorizedKeys.keys = [user.profiles.personal.sshPubKey];

  security.acme = {
    acceptTerms = true;
    defaults.email = user.profiles.personal.email;
    # DNS-01 via Cloudflare so tailnet-only names get real certs. One cert
    # covers both names.
    certs.${ntfyHost} = {
      domain = ntfyHost;
      extraDomainNames = [statusHost];
      dnsProvider = "cloudflare";
      credentialFiles.CLOUDFLARE_DNS_API_TOKEN_FILE = config.sops.secrets.cloudflare-account-token.path;
      # Check propagation against a public resolver, not hyena's own.
      dnsResolver = "1.1.1.1:53";
      group = config.services.nginx.group;
      reloadServices = ["nginx.service"];
    };
  };

  # Provisioned by pulumi (cloudflare_token_sops_write) from BWS
  # cloudflare/account/token, the same token cert-manager uses.
  sops.secrets.cloudflare-account-token.key = "cloudflare/account/token";

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts."headscale.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
    virtualHosts.${ntfyHost} = tailnetVhost 2586;
    virtualHosts.${statusHost} = tailnetVhost 8081;
  };

  services.headscale = {
    enable = true;
    address = "127.0.0.1";
    port = 8080;
    settings = {
      server_url = "https://headscale.${domain}";
      derp.server = {
        enabled = true;
        region_id = 999;
        region_code = "hyena";
        region_name = "Hyena DERP";
        stun_listen_addr = "0.0.0.0:3478";
      };
      # Push AdGuard (hyena's tailnet IP) to tailnet CLIENTS as their resolver —
      # ad-blocking + internal *.trdos.me names for laptop/PC/mobile. magic_dns
      # stays false so no base_domain search domain is pushed (that search-domain
      # leak is what hijacked pod DNS before). Cluster nodes opt out via
      # --accept-dns=false (static/tailnet.nix) so their resolution never routes
      # through hyena/the tailnet.
      dns = {
        magic_dns = false;
        override_local_dns = true;
        nameservers.global = ["100.64.0.1"];
      };
    };
  };

  # Headscale default-allows only when NO policy is loaded; the acls entry
  # preserves that behavior while adding tag/route automation for the
  # cloud-burst cluster tailnet (see static/tailnet.nix).
  services.headscale.settings.policy = {
    mode = "file";
    path = pkgs.writeText "headscale-policy.json" (builtins.toJSON {
      acls = [
        {
          action = "accept";
          src = ["*"];
          dst = ["*:*"];
        }
      ];
      tagOwners."tag:cluster" = ["default@"];
      # Auto-approve advertised subnet routes so cross-site routing never waits on
      # a human. Cluster nodes register under user `default` (untagged); future
      # CAPI workers register tagged `tag:cluster` — cover both. Pods come from
      # Cilium's pool (ipv4NativeRoutingCIDR 10.0.0.0/8), NOT the vestigial RKE2
      # Node.podCIDR (10.42/16); that mismatch left the advertised /24s unapproved.
      autoApprovers.routes = {
        "10.0.0.0/8" = ["tag:cluster" "default@"]; # Cilium pod /24s
        # The internal-gateway VIP is no longer reached via a /32 subnet route —
        # off-LAN clients hit the gateway relays' native tailnet IPs (bonobo/
        # chinchilla, static/tailnet.nix gatewayRelay), so no autoApprover needed.
      };
    });
  };

  # Hyena bootstraps its own headscale preauth key from the local CLI, so
  # tailscaled can join its own tailnet without external coordination. The
  # default user is shared with the K8s tailscale-operator's preauth key.
  systemd.services.tailscale-self-bootstrap = {
    description = "Generate hyena's headscale preauth key for self-registration";
    after = ["headscale.service" "network-online.target"];
    wants = ["network-online.target"];
    before = ["tailscaled-autoconnect.service"];
    wantedBy = ["multi-user.target"];
    path = with pkgs; [headscale jq];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      AUTHKEY_FILE=/var/lib/tailscale/authkey
      if [ ! -s "$AUTHKEY_FILE" ]; then
        mkdir -p "$(dirname "$AUTHKEY_FILE")"
        # headscale is Type=simple, so After= only orders against fork — wait
        # for the CLI socket to actually answer before minting keys.
        for _ in $(seq 30); do
          headscale users list -o json >/dev/null 2>&1 && break
          sleep 2
        done
        headscale users list -o json >/dev/null  # fail loudly if still down
        headscale users create default 2>/dev/null || true
        # headscale >= 0.24 takes a numeric user ID, not a name
        USER_ID=$(headscale users list -o json | jq -r '.[] | select(.name == "default").id')
        headscale preauthkeys create --user "$USER_ID" --reusable \
          --expiration 365d -o json | jq -r .key > "$AUTHKEY_FILE"
        chmod 600 "$AUTHKEY_FILE"
      fi
    '';
  };

  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
    extraUpFlags = ["--login-server=https://headscale.${domain}"];
  };

  # Replace the upstream DynamicUser=true so sops-templates can own the state
  # file with the right uid (DynamicUser hides /var/lib/AdGuardHome behind a
  # bind mount and breaks pre-seeded files).
  users.users.adguardhome = {
    isSystemUser = true;
    group = "adguardhome";
    home = "/var/lib/AdGuardHome";
    createHome = true;
  };
  users.groups.adguardhome = {};
  systemd.services.adguardhome = {
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "adguardhome";
      Group = "adguardhome";
    };
    # Seed the config on first boot only — see the sops template note below.
    preStart = lib.mkBefore ''
      if [ ! -s /var/lib/AdGuardHome/AdGuardHome.yaml ]; then
        cp ${config.sops.templates."AdGuardHome.yaml".path} /var/lib/AdGuardHome/AdGuardHome.yaml
        chown adguardhome:adguardhome /var/lib/AdGuardHome/AdGuardHome.yaml
        chmod 600 /var/lib/AdGuardHome/AdGuardHome.yaml
      fi
      # Idempotently ensure our tailnet rewrites exist; leaves everything else
      # (external-dns rules, UI changes) untouched and in order. Not `yq -i`:
      # it fchowns its temp file, which the unit's syscall filter kills.
      ${lib.concatMapStringsSep "\n" (rule: ''
          RULE='${rule}' ${lib.getExe pkgs.yq-go} \
            '.user_rules = ((.user_rules // []) - [strenv(RULE)]) + [strenv(RULE)]' \
            /var/lib/AdGuardHome/AdGuardHome.yaml > /var/lib/AdGuardHome/AdGuardHome.yaml.tmp
          mv /var/lib/AdGuardHome/AdGuardHome.yaml.tmp /var/lib/AdGuardHome/AdGuardHome.yaml
        '')
        tailnetRewrites}
    '';
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/AdGuardHome 0700 adguardhome adguardhome -"
  ];

  services.adguardhome.enable = true;

  # AdGuard's seed binds the tailnet IP (100.64.0.1), not 0.0.0.0: 0.0.0.0 would
  # also claim 127.0.0.53:53, which systemd-resolved (hyena's own resolver) holds,
  # and AdGuard treats that bind clash as fatal. The catch is 100.64.0.1 only
  # exists once tailscaled has joined headscale, so allow binding it before it is
  # assigned rather than ordering AdGuard behind the whole join chain — the
  # listener just starts serving when tailscale0 comes up (the floating-VIP trick
  # keepalived/HAProxy use).
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

  sops.secrets.adguard-password-hash = {
    key = "adguard/admin/password-hash";
    owner = "adguardhome";
  };

  # Rendered as a SEED, not the live config: AdGuard rewrites its own yaml at
  # runtime (UI changes, external-dns API rewrites), so letting sops-nix own
  # the live path would clobber that state on every activation. The preStart
  # below installs the seed only when no config exists yet.
  sops.templates."AdGuardHome.yaml" = {
    owner = "adguardhome";
    mode = "0600";
    content = ''
      schema_version: ${toString config.services.adguardhome.package.schema_version}
      users:
        - name: admin
          password: ${config.sops.placeholder.adguard-password-hash}
      http:
        address: 0.0.0.0:3000
      dns:
        bind_hosts:
          - 100.64.0.1
        port: 53
        bootstrap_dns:
          - 1.1.1.1
          - 8.8.8.8
        upstream_dns:
          - 1.1.1.1
          - 8.8.8.8
    '';
  };

  # Thin out-of-cluster alerting, independent of the cluster it watches.
  # ntfy takes pushes (tailnet-only, so no auth); Gatus probes the cluster over
  # the tailnet and alerts through ntfy. The cluster's Alertmanager posts real
  # alerts to ntfy and its always-firing Watchdog to Gatus as a dead-man's
  # switch (nixidy/system/observability/alertmanager.nix).
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${ntfyHost}";
      listen-http = ":2586";
      behind-proxy = true;
    };
  };

  services.gatus = {
    enable = true;
    # headscale already holds 8080.
    settings = {
      web.port = 8081;
      alerting.ntfy = {
        url = "http://127.0.0.1:2586";
        topic = "alerts";
        priority = 4;
        default-alert = {
          enabled = true;
          failure-threshold = 3;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };
      endpoints = let
        probe = name: url: conditions: {
          inherit name url conditions;
          group = "cluster";
          interval = "1m";
          client.insecure = true;
          alerts = [{type = "ntfy";}];
        };
      in
        [
          # Internal gateway via bonobo's relay; an unrouted host answers 404
          # from Envoy, which proves the relay and the gateway without
          # depending on any app behind it. Needs a hostname: without SNI the
          # gateway drops the handshake.
          (probe "internal-gateway" "https://${gatewayProbeHost}" ["[STATUS] == 404"])
        ]
        # etcd metrics only listen on the nodes' LAN IPs, so probe each server's
        # apiserver instead (401 = serving; anonymous auth is off).
        ++ lib.mapAttrsToList (node: ip: probe "apiserver-${node}" "https://${ip}:6443/readyz" ["[STATUS] == 401"]) {
          sirver = "100.64.0.2";
          octopus = "100.64.0.3";
          dingo = "100.64.0.6";
        };
      # Heartbeat from the cluster's Alertmanager Watchdog; alerts if it stops.
      external-endpoints = [
        {
          name = "watchdog";
          group = "cluster";
          # Not secret: only reachable on the tailnet. Must match the credential
          # in nixidy/system/observability/alertmanager.nix.
          token = "cluster-watchdog-heartbeat";
          heartbeat.interval = "6m";
          alerts = [
            {
              type = "ntfy";
              failure-threshold = 1;
            }
          ];
        }
      ];
    };
  };

  # External: SSH (22), ACME (80), nginx (443), DERP STUN (3478/udp),
  # WireGuard (41641/udp — lets tailnet peers reach hyena directly instead of
  # relaying every DNS query through DERP). AdGuard web UI + DNS, ntfy (2586) and Gatus (8081) tailnet-only.
  networking.hosts."100.64.0.4" = [gatewayProbeHost];
  networking.firewall = {
    allowedTCPPorts = [22 80 443];
    allowedUDPPorts = [3478 41641];
    interfaces.tailscale0 = {
      allowedTCPPorts = [3000 53 2586 8081];
      allowedUDPPorts = [53];
    };
  };
}
