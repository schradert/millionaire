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
    torrentPort = 6881;
  in {
    gatus.endpoints.qbittorrent = {
      url = "https://${hostname}";
      group = "internal";
      conditions = ["[STATUS] == any(200, 302, 401)"];
    };
    applications.qbittorrent = {
      namespace = "media";
      volsync.pvcs.qbittorrent.title = "qbittorrent";
      generatedSecrets.qbittorrent-admin = {
        key = "password";
        bitwarden = "qbittorrent/admin-password";
      };
      helm.releases.qbittorrent = {
        chart = charts.bjw-s-labs.app-template-patched;
        values = {
          controllers.qbittorrent = {
            annotations."reloader.stakater.com/auto" = "true";
            # Declarative WebUI admin: (re)write username + PBKDF2-SHA512 hash into
            # qBittorrent.conf before start, only when the stored hash does not verify.
            # Runs in the app image (python3 is in it). Break-glass: the image's default
            # config whitelists 10/8, 172.16/12, 192.168/16 (no login), so the password
            # only matters from outside those ranges.
            initContainers.admin = {
              image = pinned.images.qbittorrent;
              command = ["python3" "-c" ''
            import base64, hashlib, hmac, os, re, shutil
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
            want = {"WebUI\\Username": "admin"}
            if not verifies():
                salt = os.urandom(16)
                dk = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
                b64 = lambda b: base64.b64encode(b).decode()
                want[key] = '"@ByteArray(%s:%s)"' % (b64(salt), b64(dk))
            lines = text.split("\n")
            if "[Preferences]" not in lines:
                lines += ["", "[Preferences]"]
            i = lines.index("[Preferences]") + 1
            for k, v in want.items():
                new = k + "=" + v
                for j, l in enumerate(lines):
                    if l.startswith(k + "="):
                        lines[j] = new
                        break
                else:
                    lines.insert(i, new)
            open(conf, "w").write("\n".join(lines))
          ''];
            };
            containers.qbittorrent = {
              image = pinned.images.qbittorrent;
              probes.liveness.enabled = true;
              probes.readiness.enabled = true;
              probes.startup.enabled = true;
            };
            containers.gluetun = {
              image = pinned.images.gluetun;
              env = {
                VPN_SERVICE_PROVIDER = "custom";
                VPN_TYPE = "wireguard";
              };
              envFrom = [{secretRef.name = "qbittorrent-vpn";}];
              securityContext.capabilities.add = ["NET_ADMIN"];
              # /dev/net/tun from generic-device-plugin.
              resources.limits."squat.ai/tun" = 1;
            };
          };
          service.qbittorrent = {
            primary = true;
            ports.http.port = port;
          };
          service.torrent = {
            type = "LoadBalancer";
            annotations."lbipam.cilium.io/ips" = "192.168.50.253";
            ports.torrent.port = torrentPort;
            ports.torrent.protocol = "TCP";
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
      resources.externalSecrets.qbittorrent-vpn.spec = {
        secretStoreRef.name = "bitwarden";
        secretStoreRef.kind = "ClusterSecretStore";
        data = [
          {
            secretKey = "WIREGUARD_PRIVATE_KEY";
            remoteRef.key = "vpn/wireguard/private-key";
          }
          {
            secretKey = "WIREGUARD_ADDRESSES";
            remoteRef.key = "vpn/wireguard/addresses";
          }
        ];
      };
    };
    oauth2Proxy.upstreams."${hostname}" = {
      url = "http://qbittorrent.media.svc.cluster.local:${builtins.toString port}";
      namespace = "media";
    };
  };
}
