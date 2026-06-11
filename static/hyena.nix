{
  config,
  flake,
  lib,
  pkgs,
  ...
}: let
  inherit (flake.config.canivete.meta) domain;
  user = flake.config.canivete.meta.people.users.tristan;
in {
  imports = [./vps.nix];

  # Hyena is a root-only bootstrap server; opting out of home-manager keeps
  # ungated home modules (helix + tree-sitter parsers, etc.) out of its closure.
  home-manager.users = lib.mkForce {};

  networking.hostName = "hyena";

  # Hetzner x86 VMs boot legacy BIOS only — the fleet default
  # (systemd-boot + ESP, via srvos) can never boot here. GRUB with MBR
  # boot code matches the golden image (static/hetzner-image.nix).
  # KNOWN GAP (tracked by the in-flight disko-image work): the fleet
  # disko layout inherited via vps.nix still describes GPT+ESP+ZFS,
  # which does not match the image's MBR+ext4 disk; deploy-rs switches
  # against an image-booted hyena need the disko layout aligned (or the
  # image built from this very config via system.build.diskoImages)
  # before the first switch is safe across a reboot. The same flow must
  # deliver the sops age key before secrets render.
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
  };

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
      dns = {
        magic_dns = false;
        override_local_dns = false;
      };
    };
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
    '';
  };
  systemd.tmpfiles.rules = [
    "d /var/lib/AdGuardHome 0700 adguardhome adguardhome -"
  ];

  services.adguardhome.enable = true;

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
          - 0.0.0.0
        port: 53
        bootstrap_dns:
          - 1.1.1.1
          - 8.8.8.8
        upstream_dns:
          - 1.1.1.1
          - 8.8.8.8
    '';
  };

  # External: SSH (22), ACME (80), nginx (443), DERP STUN (3478/udp),
  # WireGuard (41641/udp — lets tailnet peers reach hyena directly instead of
  # relaying every DNS query through DERP). AdGuard web UI + DNS tailnet-only.
  networking.firewall = {
    allowedTCPPorts = [22 80 443];
    allowedUDPPorts = [3478 41641];
    interfaces.tailscale0 = {
      allowedTCPPorts = [3000 53];
      allowedUDPPorts = [53];
    };
  };
}
