{config, ...}: {
  nixidy = {
    charts,
    lib,
    pinned,
    ...
  }: let
    inherit (config.canivete.meta) domain;
    hostname = "qbittorrent.${domain}";
    port = 8080;
    # false: no ExternalSecret, no pod (replicas 0), no gatus check. The chosen provider's
    # Bitwarden items below must exist (docs/manual-steps.md).
    credentials = true;
    vpn = {
      # One of the `providers` below. protonvpn: NAT-PMP port forwarding, synced into
      # qBittorrent. custom: any WireGuard config file, no inbound port.
      provider = "protonvpn";
      # gluetun SERVER_COUNTRIES (e.g. ["Switzerland" "Netherlands"]); empty lets gluetun pick
      # any P2P server.
      countries = [];
    };
    # DHT, PeX and LSD find peers without a tracker, which public torrents need. Private
    # trackers ban clients that use them; turn this off if one is added. On: the indexers are public (1337x).
    peerDiscovery = true;

    providers = {
      protonvpn = {
        env = {
          VPN_SERVICE_PROVIDER = "protonvpn";
          # P2P servers only: the ones that forward a port (NAT-PMP).
          PORT_FORWARD_ONLY = "on";
          VPN_PORT_FORWARDING = "on";
          VPN_PORT_FORWARDING_PROVIDER = "protonvpn";
        };
        secrets.WIREGUARD_PRIVATE_KEY = "vpn/protonvpn/wireguard-private-key";
      };
      custom = {
        env.VPN_SERVICE_PROVIDER = "custom";
        secrets = {
          WIREGUARD_PRIVATE_KEY = "vpn/wireguard/private-key";
          WIREGUARD_ADDRESSES = "vpn/wireguard/addresses";
          WIREGUARD_PUBLIC_KEY = "vpn/wireguard/public-key";
          VPN_ENDPOINT_IP = "vpn/wireguard/endpoint-ip";
          VPN_ENDPOINT_PORT = "vpn/wireguard/endpoint-port";
        };
      };
    };
    provider = providers.${vpn.provider};
    nobody = {
      runAsUser = 65534;
      runAsGroup = 65534;
    };

    # gluetun runs this once a port is forwarded (and the DOWN one when it goes away):
    # set qBittorrent's listening port and re-bind it to the tunnel through the WebUI API
    # on localhost (LocalHostAuth is off, and only this pod can reach 127.0.0.1).
    # The chart runs env values through `tpl`, so gluetun's {{PORT}} placeholders are escaped
    # as Go raw strings.
    setPrefs = prefs: let
      json =
        builtins.replaceStrings [''"{{PORT}}"'' ''"'' "{{VPN_INTERFACE}}"] ["{{`{{PORT}}`}}" ''\"'' "{{`{{VPN_INTERFACE}}`}}"]
        (builtins.toJSON prefs);
    in "/bin/sh -c 'wget -q -O /dev/null --retry-connrefused --post-data \"json=${json}\" http://127.0.0.1:${toString port}/api/v2/app/setPreferences'";

    # Applied to qBittorrent.conf by the init container on every start, before qBittorrent
    # reads it, so the config file can't drift from this.
    settings = {
      BitTorrent = {
        "Session\\Interface" = "tun0";
        "Session\\InterfaceName" = "tun0";
        "Session\\AnonymousModeEnabled" = "true";
        "Session\\DHTEnabled" = lib.boolToString peerDiscovery;
        "Session\\PeXEnabled" = lib.boolToString peerDiscovery;
        "Session\\LSDEnabled" = lib.boolToString peerDiscovery;
        # 1 = require encryption.
        "Session\\Encryption" = "1";
      };
      Network.PortForwardingEnabled = "false";
      Preferences = {
        "WebUI\\Username" = "admin";
        "WebUI\\UseUPnP" = "false";
        "WebUI\\LocalHostAuth" = "false";
        # The image whitelists 10/8, 172.16/12 and 192.168/16 (no login). Every pod is in
        # 10/8, so require the password; oauth2-proxy and the arr apps both have it.
        "WebUI\\AuthSubnetWhitelistEnabled" = "false";
      };
    };
  in {
    portal.apps = lib.optionalAttrs credentials {qbittorrent.groups = ["admin"];};
    gatus.endpoints = lib.optionalAttrs credentials {
      qbittorrent = {
        url = "https://${hostname}";
        group = "internal";
        conditions = ["[STATUS] == any(200, 302, 401)"];
      };
    };
    applications.qbittorrent = {
      namespace = "media";
      volsync.pvcs.qbittorrent.title = "qbittorrent";
      generatedSecrets.qbittorrent-admin = {
        key = "password";
        bitwarden = "qbittorrent/admin-password";
      };
      # WebUI only from oauth2-proxy, the arr apps, their bootstrap and the e2e Job.
      # Peer traffic never touches eth0: it goes through gluetun's tunnel.
      resources.ciliumNetworkPolicies.qbittorrent.spec = {
        endpointSelector.matchLabels."app.kubernetes.io/name" = "qbittorrent";
        ingress = [
          {fromEntities = ["host"];}
          {
            fromEndpoints =
              [
                {
                  matchLabels = {
                    "k8s:io.kubernetes.pod.namespace" = "identity";
                    "app.kubernetes.io/name" = "oauth2-proxy";
                  };
                }
                {matchLabels."batch.kubernetes.io/job-name" = "prowlarr-bootstrap";}
                {matchLabels."app.kubernetes.io/name" = "media-e2e";}
              ]
              ++ map (app: {matchLabels."app.kubernetes.io/name" = app;}) ["radarr" "sonarr" "lidarr" "prowlarr" "autobrr"];
            toPorts = lib.toList {
              ports = lib.toList {
                port = toString port;
                protocol = "TCP";
              };
            };
          }
        ];
      };
      helm.releases.qbittorrent = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.qbittorrent = {
            replicas =
              if credentials
              then 1
              else 0;
            # gluetun leaves ip rules behind on an unclean exit; never run two pods at once.
            strategy = "Recreate";
            annotations."reloader.stakater.com/auto" = "true";
            pod = {
              # The config PVC mounts root-owned. qBittorrent runs as nobody (the arr apps' uid, so
              # /media/downloads is shared); gluetun stays root for NET_ADMIN.
              securityContext = {
                fsGroup = 65534;
                fsGroupChangePolicy = "OnRootMismatch";
              };
              # Everything in the pod resolves through gluetun's DNS-over-TLS server on
              # 127.0.0.1, which only talks through the tunnel. No cluster DNS, no search domains.
              dnsPolicy = "None";
              dnsConfig.nameservers = ["127.0.0.1"];
            };
            # Declarative config: (re)write the WebUI admin hash (only when the stored one does
            # not verify) and `settings` into qBittorrent.conf before start.
            initContainers.admin = {
              image = pinned.images.qbittorrent;
              securityContext = nobody;
              env.QBT_SETTINGS = builtins.toJSON settings;
              command = [
                "python3"
                "-c"
                ''
                  import base64, hashlib, hmac, json, os, re, shutil
                  conf = "/config/qBittorrent/qBittorrent.conf"
                  if not os.path.exists(conf):
                      os.makedirs(os.path.dirname(conf), exist_ok=True)
                      shutil.copy("/defaults/qBittorrent.conf", conf)
                  pw = open("/secrets/admin/password", "rb").read().strip()
                  text = open(conf).read()
                  key = "WebUI\\Password_PBKDF2"
                  m = re.search(r"^" + re.escape(key) + r'="?@ByteArray\(([^:]+):([^)]+)\)"?\s*$', text, re.M)
                  def verifies():
                      if not m:
                          return False
                      salt = base64.b64decode(m.group(1))
                      want = base64.b64decode(m.group(2))
                      got = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, len(want))
                      return hmac.compare_digest(got, want)
                  settings = json.loads(os.environ["QBT_SETTINGS"])
                  if not verifies():
                      salt = os.urandom(16)
                      dk = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
                      b64 = lambda b: base64.b64encode(b).decode()
                      settings["Preferences"][key] = '"@ByteArray(%s:%s)"' % (b64(salt), b64(dk))
                  lines = text.split("\n")
                  for section, values in settings.items():
                      header = "[" + section + "]"
                      if header not in lines:
                          lines += ["", header]
                      start = lines.index(header) + 1
                      end = next((j for j in range(start, len(lines)) if lines[j].startswith("[")), len(lines))
                      for k, v in values.items():
                          new = k + "=" + v
                          for j in range(start, end):
                              if lines[j].startswith(k + "="):
                                  lines[j] = new
                                  break
                          else:
                              lines.insert(start, new)
                              end += 1
                  open(conf, "w").write("\n".join(lines))
                ''
              ];
            };
            containers.qbittorrent = {
              image = pinned.images.qbittorrent;
              securityContext = nobody;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
            containers.gluetun = {
              image = pinned.images.gluetun;
              env =
                {
                  VPN_TYPE = "wireguard";
                  # Kill switch: gluetun's firewall drops everything that isn't the tunnel
                  # (this is its default; set so a default change can't silently turn it off).
                  FIREWALL_ENABLED_DISABLING_IT_SHOOTS_YOU_IN_YOUR_FOOT = "on";
                  # The WebUI, for the Service. Nothing else comes in on eth0.
                  FIREWALL_INPUT_PORTS = toString port;
                  # Replies to in-cluster WebUI clients must leave via eth0, not the tunnel: pods
                  # (Cilium hands each node a /24 from 10.0.0.0/8, sequentially from 10.0.0.0) and
                  # services (10.43.0.0/16). NOT all of 10.0.0.0/8: ProtonVPN's gateway is 10.2.0.1,
                  # and routing it out eth0 made every NAT-PMP port-forward request time out.
                  FIREWALL_OUTBOUND_SUBNETS = "10.0.0.0/16,10.43.0.0/16";
                  # DNS over TLS through the tunnel; no plaintext DNS, no IPv6 upstreams.
                  DNS_SERVER = "on";
                  DNS_UPSTREAM_RESOLVER_TYPE = "DoT";
                  DNS_UPSTREAM_IPV6 = "off";
                  DNS_KEEP_NAMESERVER = "off";
                  BLOCK_MALICIOUS = "on";
                  # No GitHub version check from the pod.
                  VERSION_INFORMATION = "off";
                  HEALTH_RESTART_VPN = "on";
                }
                // lib.optionalAttrs (vpn.countries != []) {SERVER_COUNTRIES = lib.concatStringsSep "," vpn.countries;}
                // lib.optionalAttrs ((provider.env.VPN_PORT_FORWARDING or "off") == "on") {
                  VPN_PORT_FORWARDING_UP_COMMAND = setPrefs {
                    listen_port = "{{PORT}}";
                    current_network_interface = "{{VPN_INTERFACE}}";
                    random_port = false;
                    upnp = false;
                  };
                  # Park qBittorrent on loopback while the tunnel is down.
                  VPN_PORT_FORWARDING_DOWN_COMMAND = setPrefs {
                    listen_port = 0;
                    current_network_interface = "lo";
                  };
                }
                // provider.env;
              envFrom = [{secretRef.name = "qbittorrent-vpn";}];
              securityContext.capabilities.add = ["NET_ADMIN"];
              # Clean up the WireGuard ip rules an unclean exit leaves behind (gluetun wiki, Kubernetes).
              lifecycle.postStart.exec.command = ["/bin/sh" "-c" "(ip rule del table 51820; ip -6 rule del table 51820) || true"];
              # /dev/net/tun from generic-device-plugin (nixidy/system/cluster).
              resources.limits."devic.es/tun" = 1;
            };
          };
          service.qbittorrent = {
            primary = true;
            ports.http.port = port;
          };
          persistence.config = {
            type = "persistentVolumeClaim";
            accessMode = "ReadWriteOnce";
            size = "1Gi";
          };
          persistence.admin-secret = {
            type = "secret";
            name = "qbittorrent-admin";
            advancedMounts.qbittorrent.admin = [{path = "/secrets/admin";}];
          };
          persistence.tmp.type = "emptyDir";
          persistence.media-downloads = {
            type = "persistentVolumeClaim";
            existingClaim = "media-downloads";
            advancedMounts.qbittorrent.qbittorrent = [{path = "/media/downloads";}];
          };
          route.qbittorrent = {
            hostnames = [hostname];
            parentRefs = lib.toList {
              name = "internal";
              namespace = "kube-system";
              sectionName = "https";
            };
            rules = lib.toList {
              backendRefs = lib.toList {
                name = "oauth2-proxy";
                namespace = "identity";
                port = 4180;
              };
            };
          };
        };
      };
      # The chosen provider's WireGuard credentials (Bitwarden items, one value each, see
      # docs/manual-steps.md).
      resources.externalSecrets = lib.optionalAttrs credentials {
        qbittorrent-vpn.spec = {
          secretStoreRef.name = "bitwarden";
          secretStoreRef.kind = "ClusterSecretStore";
          data =
            lib.mapAttrsToList (secretKey: key: {
              inherit secretKey;
              remoteRef.key = key;
            })
            provider.secrets;
        };
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://qbittorrent.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
