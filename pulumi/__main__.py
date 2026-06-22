import pulumi
import pulumi_bitwarden as bw
import pulumi_cloudflare as cf
import pulumi_command as command
import pulumi_hcloud as hcloud
import pulumi_random as rand
import pulumi_tls as tls

import millionaire


def Secret(key: str, value: pulumi.Input[str], note: str = "") -> bw.Secret:
    return bw.Secret(
        key,
        key=key,
        value=value,
        note=note,
        organization_id="ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf",
        project_id="baf88382-abda-41b2-8d0f-b30e014c2db9",
    )


class Millionaire:
    def __init__(self) -> None:
        # --- Hetzner VPS (hyena) — bootstrap server: headscale + AdGuard ---
        # Hyena is the bootstrap. It depends on nothing in the rest of the
        # fleet; everything else depends on hyena.refresh so headscale exists
        # by the time other consumers (e.g. the K8s tailscale-operator) need it.
        ssh_key = hcloud.SshKey(
            "millionaire",
            public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire",
        )
        hyena_firewall = hcloud.Firewall(
            "hyena",
            rules=[
                hcloud.FirewallRuleArgs(
                    direction="in",
                    protocol="tcp",
                    port="22",
                    source_ips=["0.0.0.0/0", "::/0"],
                ),
                hcloud.FirewallRuleArgs(
                    direction="in",
                    protocol="tcp",
                    port="80",
                    source_ips=["0.0.0.0/0", "::/0"],
                ),
                hcloud.FirewallRuleArgs(
                    direction="in",
                    protocol="tcp",
                    port="443",
                    source_ips=["0.0.0.0/0", "::/0"],
                ),
                hcloud.FirewallRuleArgs(
                    direction="in",
                    protocol="udp",
                    port="3478",
                    source_ips=["0.0.0.0/0", "::/0"],
                ),
                # WireGuard — direct tailnet paths to hyena instead of DERP relay
                hcloud.FirewallRuleArgs(
                    direction="in",
                    protocol="udp",
                    port="41641",
                    source_ips=["0.0.0.0/0", "::/0"],
                ),
            ],
        )
        hyena_server = hcloud.Server(
            "hyena",
            # cx33 (Intel 4c/8GB) — bumped from cx23 (4GB) because the kexec'd
            # installer's tmpfs needs room to build hyena's own closure with
            # --build-on remote.
            server_type="cx33",
            image="ubuntu-24.04",
            location="nbg1",
            ssh_keys=[ssh_key.id],
            firewall_ids=[hyena_firewall.id],
            # The live VM was rebuilt onto the golden BIOS snapshot (image id
            # 396270192) 2026-06-11; `image` only matters at creation, so ignore
            # its drift rather than let an untargeted `up` rebuild headscale's host.
            opts=pulumi.ResourceOptions(ignore_changes=["image"]),
        )
        # AdGuard admin password — bcrypt hash must be in SOPS before hyena
        # deploys, so its sops-templated AdGuardHome.yaml renders correctly.
        # The plaintext password also lands in BWS for the external-dns webhook.
        adguard_admin_password = rand.RandomPassword(
            "adguard_admin_password", length=24, special=False
        )
        Secret(
            "adguard/admin/password",
            adguard_admin_password.result,
            "AdGuard Home admin password (plaintext for external-dns webhook)",
        )
        adguard_password_hash_sops_write = command.local.Command(
            "adguard_password_hash_sops_write",
            create=(
                f'cd "{millionaire.Nix.root}" && '
                "printf '%s' \"$ADGUARD_HASH\" | jq -Rs . | "
                'sops set secrets/sops/default.yaml \'["adguard"]["admin"]["password-hash"]\' --value-stdin'
            ),
            environment={"ADGUARD_HASH": adguard_admin_password.bcrypt_hash},
        )

        hyena = millionaire.NixOS(
            "hyena",
            hyena_server.ipv4_address.apply(lambda ip: f"root@{ip}"),
            deploy_hostname=hyena_server.ipv4_address,
            depends_on=[hyena_server, adguard_password_hash_sops_write],
        )

        # Public DNS for headscale (the only hyena service that needs to be
        # reachable from outside the tailnet — tailscale clients must hit it
        # over the public internet to bootstrap). AdGuard stays tailnet-only.
        account_id = "73c86a33c82d5c90d0feb68269932302"
        zone = cf.get_zone_output(
            filter={"account": {"id": account_id}, "name": "trdos.me"}
        )
        cf.DnsRecord(
            "headscale",
            zone_id=zone.zone_id,
            type="A",
            name="headscale",
            content=hyena_server.ipv4_address,
            proxied=False,
            ttl=1,
        )

        # Headscale user + pre-auth keys (idempotent; only re-runs if hyena
        # is replaced — i.e. headscale state on disk was lost).
        ssh_to_hyena = hyena_server.ipv4_address.apply(
            lambda ip: (
                f"ssh -i ~/.ssh/personal -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@{ip}"
            )
        )
        headscale_user = command.local.Command(
            "headscale_user_default",
            create=ssh_to_hyena.apply(
                lambda s: f"{s} 'headscale users create default 2>/dev/null || true'"
            ),
            triggers=[hyena_server.id],
            opts=pulumi.ResourceOptions(depends_on=[hyena.refresh]),
        )
        # headscale >= 0.24 takes a numeric user ID, not a name — resolve it.
        # NOTE: the key expires after 90d and only rotates when the VPS is
        # replaced; to rotate manually, taint this resource
        # (`pulumi up --target-replace ...headscale_preauthkey_k8s`).
        headscale_preauth_k8s = command.local.Command(
            "headscale_preauthkey_k8s",
            create=ssh_to_hyena.apply(
                lambda s: (
                    f"{s} 'headscale preauthkeys create --user \"$(headscale users list -o json"
                    " | jq -r '\\''.[] | select(.name == \"default\").id'\\'')\""
                    " --reusable --ephemeral --expiration 90d -o json' | jq -r .key"
                )
            ),
            triggers=[hyena_server.id],
            opts=pulumi.ResourceOptions(depends_on=[headscale_user]),
        )
        Secret(
            "headscale/preauth-key/k8s",
            headscale_preauth_k8s.stdout.apply(str.strip),
            "Headscale pre-auth key for the K8s tailscale-operator (reusable, ephemeral, 90d)",
        )

        # --- Cluster tailnet keys (cloud-burst) ---
        # Home nodes join headscale with a shared reusable key from SOPS;
        # CAPI burst workers get a reusable+ephemeral key from BWS (ephemeral
        # means headscale drops the peer when it goes offline — that is the
        # scale-down cleanup story). Both carry tag:cluster so the headscale
        # policy (static/hyena.nix) auto-approves their pod-CIDR subnet
        # routes. Tagged key creation requires that policy to be live, hence
        # depends_on hyena.refresh. headscale 0.28 takes --user by ID.
        headscale_cluster_node_key = command.local.Command(
            "headscale_preauthkey_cluster_node",
            create=ssh_to_hyena.apply(
                lambda s: (
                    f"{s} 'headscale preauthkeys create --user 1 --reusable --tags tag:cluster --expiration 8760h -o json' | jq -r .key"
                )
            ),
            triggers=[hyena_server.id],
            opts=pulumi.ResourceOptions(depends_on=[headscale_user, hyena.refresh]),
        )
        headscale_cluster_node_key_sops = command.local.Command(
            "headscale_cluster_node_key_sops",
            create=(
                f'cd "{millionaire.Nix.root}" && '
                "printf '%s' \"$TS_AUTHKEY\" | jq -Rs . | "
                'sops set secrets/sops/default.yaml \'["headscale"]["preauth-key"]["cluster-node"]\' --value-stdin'
            ),
            environment={
                "TS_AUTHKEY": headscale_cluster_node_key.stdout.apply(str.strip)
            },
            opts=pulumi.ResourceOptions(depends_on=[headscale_cluster_node_key]),
        )
        headscale_worker_key = command.local.Command(
            "headscale_preauthkey_cloud_worker",
            create=ssh_to_hyena.apply(
                lambda s: (
                    f"{s} 'headscale preauthkeys create --user 1 --reusable --ephemeral --tags tag:cluster --expiration 8760h -o json' | jq -r .key"
                )
            ),
            triggers=[hyena_server.id],
            opts=pulumi.ResourceOptions(depends_on=[headscale_user, hyena.refresh]),
        )
        Secret(
            "headscale/preauth-key/k8s-cloud-worker",
            headscale_worker_key.stdout.apply(str.strip),
            "Headscale pre-auth key for CAPI burst workers (reusable, ephemeral, tag:cluster)",
        )

        # RKE2 agent join token, mirrored from SOPS so the in-cluster
        # ExternalSecrets stack can template it into worker bootstrap data.
        rke2_agent_token = command.local.Command(
            "rke2_agent_token_read",
            create=(
                f'cd "{millionaire.Nix.root}" && '
                'sops --decrypt --extract \'["passwords"]["k8s-token"]\' secrets/sops/default.yaml'
            ),
        )
        Secret(
            "rke2/agent-token",
            rke2_agent_token.stdout.apply(str.strip),
            "RKE2 agent join token (mirror of SOPS passwords.k8s-token for cloud workers)",
        )

        # --- Cloud-burst worker snapshot (CAPI machine image) ---
        # Requires a DEDICATED hcloud project ("millionaire-capi") so the CAPI
        # token can never touch hyena. Hetzner projects cannot be created via
        # API: create the project in the console once, generate a token, then
        #   pulumi config set --secret hcloudCapiToken <token>
        # Everything downstream is automated. Snapshots are project-scoped, so
        # the image upload must use this same token.
        capi_token = pulumi.Config().get_secret("hcloudCapiToken")
        if capi_token is not None:
            Secret(
                "hetzner/api-token/capi",
                capi_token,
                "Hetzner millionaire-capi project token (CAPH + image upload)",
            )
            # SSH key registered in the capi project — referenced by
            # HetznerCluster.spec.sshKeys for rescue/debug access to workers.
            capi_provider = hcloud.Provider("hcloud-capi", token=capi_token)
            hcloud.SshKey(
                "millionaire-capi",
                name="millionaire-capi",
                public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire",
                opts=pulumi.ResourceOptions(provider=capi_provider),
            )
            cloud_worker_toplevel = (
                millionaire.Nix.attr(
                    "nixosConfigurations.cloud-worker.config.system.build.toplevel.outPath"
                )
                .impure()
                .value()
                .strip()
            )
            # Replace-on-change: triggers on the worker toplevel, so a config
            # change rebuilds + re-uploads. CAPH matches snapshots by the
            # caph-image-name label and errors on ambiguity — delete stale
            # snapshots carrying the label before uploading the new one.
            command.local.Command(
                "cloud_worker_snapshot",
                create=(
                    "hcloud image list -t snapshot -l caph-image-name=cloud-worker -o json "
                    "| jq -r '.[].id' | xargs -r -n1 hcloud image delete && "
                    "IMG=$(nix build --no-pure-eval --no-link --print-out-paths "
                    f'"{millionaire.Nix.root}#nixosConfigurations.cloud-worker.config.system.build.cloudWorkerImage") && '
                    'hcloud-upload-image upload --architecture x86 --image-path "$IMG/nixos.img" '
                    "--labels caph-image-name=cloud-worker --description cloud-worker"
                ),
                environment={"HCLOUD_TOKEN": capi_token},
                triggers=[cloud_worker_toplevel],
            )

        # --- Attic binary cache (must exist before sirver deploy) ---
        attic_server_key = command.local.Command(
            "attic_server_key",
            create=(
                "openssl genrsa -traditional 4096 2>/dev/null | base64 | tr -d '\\n'"
            ),
        )
        attic_sops_write = command.local.Command(
            "attic_sops_write",
            create=(
                f'cd "{millionaire.Nix.root}" && '
                "printf '%s' \"$ATTIC_VALUE\" | jq -Rs . | "
                'sops set secrets/sops/default.yaml \'["attic"]["server-key"]\' --value-stdin'
            ),
            environment={
                "ATTIC_VALUE": pulumi.Output.concat(
                    "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=", attic_server_key.stdout
                )
            },
            opts=pulumi.ResourceOptions(depends_on=[attic_server_key]),
        )

        # --- NixOS nodes (cluster) — all depend on hyena.refresh ---
        # The cluster-node tailnet key must be in SOPS before any node deploy
        # (tailnet.nix reads it via sops-nix at activation).
        sirver = millionaire.NixOS(
            "sirver",
            "root@nixos",
            depends_on=[
                attic_sops_write,
                hyena.refresh,
                headscale_cluster_node_key_sops,
            ],
        )

        # Cloud-burst workers pin `sirver` to its tailnet IP in /etc/hosts;
        # capture it once sirver's deploy (tailnet.nix) brings tailscale up.
        sirver_tailnet_ip = command.local.Command(
            "sirver_tailnet_ip",
            create="ssh -i ~/.ssh/personal sirver tailscale ip -4",
            opts=pulumi.ResourceOptions(depends_on=[sirver.refresh]),
        )
        Secret(
            "headscale/node-ip/sirver",
            sirver_tailnet_ip.stdout.apply(str.strip),
            "sirver tailnet IPv4 (pinned by cloud-burst workers)",
        )

        # --- Attic post-deploy setup (after sirver has atticd running) ---
        # Generate admin token, then use attic client to create/configure cache
        attic_token = command.local.Command(
            "attic_token",
            create=(
                "ssh -i ~/.ssh/personal sirver '"
                'sudo atticd-atticadm make-token --sub admin --validity "10y" '
                '--push "*" --pull "*" --delete "*" '
                '--create-cache "*" --configure-cache "*" --configure-cache-retention "*" --destroy-cache "*"'
                "'"
            ),
            opts=pulumi.ResourceOptions(depends_on=[sirver.refresh]),
        )
        Secret(
            "attic/auth-token",
            attic_token.stdout,
            "Attic client auth token for push/pull",
        )

        attic_setup = command.local.Command(
            "attic_setup",
            create=attic_token.stdout.apply(
                lambda token: (
                    f"ssh -i ~/.ssh/personal sirver '"
                    f'nix-shell -p attic-client --run "'
                    f"attic login local http://localhost:8199 {token.strip()} && "
                    f"(attic cache create main 2>/dev/null; true) && "
                    f"attic cache configure main --public"
                    f"\"'"
                )
            ),
            opts=pulumi.ResourceOptions(depends_on=[attic_token]),
        )

        # Save the auth token to SOPS for the post-build hook on all nodes
        attic_auth_sops_write = command.local.Command(
            "attic_auth_sops_write",
            create=(
                f'cd "{millionaire.Nix.root}" && '
                "printf '%s' \"$ATTIC_AUTH_TOKEN\" | jq -Rs . | "
                'sops set secrets/sops/default.yaml \'["attic"]["auth-token"]\' --value-stdin'
            ),
            environment={"ATTIC_AUTH_TOKEN": attic_token.stdout},
            opts=pulumi.ResourceOptions(depends_on=[attic_token]),
        )

        # Get the cache public key and save to a committed JSON file
        attic_public_key = command.local.Command(
            "attic_public_key",
            create=attic_token.stdout.apply(
                lambda token: (
                    "ssh -i ~/.ssh/personal sirver "
                    "'nix-shell -p attic-client --run \""
                    f"attic login local http://localhost:8199 {token.strip()} && "
                    "attic cache info main"
                    "\"' 2>&1"
                    " | sed -n 's/.*Public Key: //p'"
                )
            ),
            triggers=[attic_setup.stdout],
            opts=pulumi.ResourceOptions(depends_on=[attic_setup]),
        )
        command.local.Command(
            "attic_public_key_file",
            create=pulumi.Output.concat(
                'FILE="',
                str(millionaire.Nix.root),
                '/static/generated.json" && ',
                '[ -f "$FILE" ] && EXISTING=$(cat "$FILE") || EXISTING="{}" && ',
                'echo "$EXISTING" | jq --arg key \'',
                attic_public_key.stdout.apply(str.strip),
                "' '.attic_pubkey = $key' > \"$FILE\"",
            ),
            triggers=[attic_public_key.stdout],
            opts=pulumi.ResourceOptions(depends_on=[attic_public_key]),
        )

        # Other nodes depend on attic being fully set up (auth token in SOPS + public key file)
        # plus hyena being up (for headscale to exist when ArgoCD syncs the operator).
        other_node_deps = [
            attic_auth_sops_write,
            hyena.refresh,
            headscale_cluster_node_key_sops,
        ]
        millionaire.NixOS("octopus", "root@nixos", depends_on=other_node_deps)
        millionaire.NixOS("dingo", "root@nixos", depends_on=other_node_deps)
        millionaire.NixOS("bonobo", "root@nixos", depends_on=other_node_deps)
        millionaire.NixOS("chinchilla", "root@nixos", depends_on=other_node_deps)

        # RPI doesn't support kexec
        # millionaire.NixOS("piper", "piper", "--phases disko,install,reboot")

        tunnel = cf.ZeroTrustTunnelCloudflared(
            "main", account_id=account_id, name="main", config_src="local"
        )
        tunnel_token = cf.get_zero_trust_tunnel_cloudflared_token_output(
            account_id=account_id, tunnel_id=tunnel.id
        )
        Secret(
            "cloudflare/tunnel/token", tunnel_token.token, "Cloudflared Tunnel token"
        )

        ceph_dashboard_password = rand.RandomPassword(
            "ceph_dashboard_password", length=24, special=False
        )
        Secret(
            "ceph/dashboard/password",
            ceph_dashboard_password.result,
            "Rook Ceph builtin dashboard password",
        )

        bucket_name = f"{millionaire.Nix.attr('canivete.meta.domain').value().replace('.', '-')}--volsync"
        bucket = command.local.Command(
            "b2-bucket",
            create=f"b2 bucket create {bucket_name} allPrivate",
            delete=f"b2 bucket delete {bucket_name}",
        )
        b2_app_key = command.local.Command(
            "b2-app-key",
            create=f"b2 key create --bucket {bucket_name} {bucket_name} listBuckets,listFiles,readFiles,writeFiles,deleteFiles",
            # FIXME how to get this to delete with the generated key id?
            # FIXME how to store key as a secret so as to avoid dumping raw in logs
            # delete=f"b2 key delete {bucket_name}",
            opts=pulumi.ResourceOptions(depends_on=[bucket]),
        )
        # key create outputs: "keyId applicationKey" on one line
        Secret(
            "backblaze/bucket/application_key_id",
            b2_app_key.stdout.apply(lambda s: s.strip().split()[0]),
            "Backblaze Application Key ID for VolSync Bucket",
        )
        Secret(
            "backblaze/bucket/application_key",
            b2_app_key.stdout.apply(lambda s: s.strip().split()[1]),
            "Backblaze Application Key for VolSync Bucket",
        )

        restic_password = rand.RandomPassword(
            "restic_password", length=24, special=False
        )
        Secret(
            "volsync/restic/password", restic_password.result, "VolSync Restic password"
        )

        firefly_app_key = rand.RandomBytes("firefly_app_key", length=32)
        Secret(
            "firefly/app_key",
            firefly_app_key.base64.apply(lambda b: f"base64:{b}"),
            "Firefly-III Laravel APP_KEY",
        )

        stalwart_admin_password = rand.RandomPassword(
            "stalwart_admin_password", length=24, special=False
        )
        Secret(
            "stalwart/admin/password",
            stalwart_admin_password.result,
            "Stalwart Mail admin password",
        )

        bulwark_session_secret = rand.RandomPassword(
            "bulwark_session_secret", length=32, special=False
        )
        Secret(
            "bulwark/session-secret",
            bulwark_session_secret.result,
            "Bulwark webmail session encryption secret",
        )

        grafana_admin_password = rand.RandomPassword(
            "grafana_admin_password", length=21, special=False
        )
        Secret("grafana", grafana_admin_password.result, "Grafana admin password")

        actualbudget_admin_password = rand.RandomPassword(
            "actualbudget_admin_password", length=24, special=False
        )
        Secret(
            "actualbudget/admin/password",
            actualbudget_admin_password.result,
            "ActualBudget admin password",
        )

        # --- Oathkeeper (kept as auth proxy for Keycloak) ---
        jwks = millionaire.OryJwks("ory_oathkeeper_jwks")
        Secret(
            "ory/oathkeeper/mutator-id-token-jwks",
            jwks.jwks_json,
            "Oathkeeper JWKS for ID token signing",
        )

        # AdGuard Home: password-hash is delivered via SOPS earlier in this
        # file (so hyena's sops-template renders correctly); plaintext is in
        # BWS for the external-dns webhook.

        # --- Keycloak ---
        keycloak_admin_password = rand.RandomPassword(
            "keycloak_admin_password", length=24, special=False
        )
        Secret(
            "keycloak/admin/password",
            keycloak_admin_password.result,
            "Keycloak bootstrap admin password",
        )

        oauth2_proxy_client_secret = rand.RandomPassword(
            "oauth2_proxy_client_secret", length=32, special=False
        )
        Secret(
            "oauth2-proxy/client-secret",
            oauth2_proxy_client_secret.result,
            "OAuth2 Proxy OIDC client secret",
        )

        oauth2_proxy_cookie_secret = rand.RandomPassword(
            "oauth2_proxy_cookie_secret", length=32, special=False
        )
        Secret(
            "oauth2-proxy/cookie-secret",
            oauth2_proxy_cookie_secret.result,
            "OAuth2 Proxy cookie encryption secret (must be 16/24/32 bytes)",
        )

        sure_secret_key_base = rand.RandomPassword(
            "sure_secret_key_base", length=128, special=False
        )
        Secret(
            "sure/secret_key_base",
            sure_secret_key_base.result,
            "Sure Finance Rails SECRET_KEY_BASE",
        )

        # --- Home Assistant ---
        ha_admin_password = rand.RandomPassword(
            "ha_admin_password", length=24, special=False
        )
        Secret(
            "ha/admin/password",
            ha_admin_password.result,
            "Home Assistant initial admin password",
        )

        # --- Harbor ---
        harbor_robot_secret = rand.RandomPassword(
            "harbor_robot_secret", length=32, special=False
        )
        Secret(
            "harbor/robot/secret",
            harbor_robot_secret.result,
            "Harbor system robot account secret for CI/local push",
        )

        harbor_cosign_password = rand.RandomPassword(
            "harbor_cosign_password", length=32, special=False
        )
        Secret(
            "harbor/cosign/password",
            harbor_cosign_password.result,
            "Cosign private key encryption password",
        )
        harbor_cosign_keypair = command.local.Command(
            "harbor_cosign_keypair",
            create=pulumi.Output.concat(
                "tmpdir=$(mktemp -d) && cd $tmpdir && COSIGN_PASSWORD='",
                harbor_cosign_password.result,
                "' cosign generate-key-pair 2>/dev/null && "
                "printf '%s:::%s' \"$(base64 < cosign.key | tr -d '\\n')\" \"$(base64 < cosign.pub | tr -d '\\n')\" && "
                "rm -rf $tmpdir",
            ),
        )
        Secret(
            "harbor/cosign/key",
            harbor_cosign_keypair.stdout.apply(lambda s: s.split(":::")[0]),
            "Cosign private key (base64-encoded PEM)",
        )
        Secret(
            "harbor/cosign/pub",
            harbor_cosign_keypair.stdout.apply(lambda s: s.split(":::")[1]),
            "Cosign public key (base64-encoded PEM)",
        )

        harbor_admin_password = rand.RandomPassword(
            "harbor_admin_password", length=24, special=False
        )
        Secret(
            "harbor/admin/password",
            harbor_admin_password.result,
            "Harbor admin password",
        )

        harbor_secret_key = rand.RandomPassword(
            "harbor_secret_key", length=16, special=False
        )
        Secret(
            "harbor/secret-key",
            harbor_secret_key.result,
            "Harbor encryption secret key (16 chars)",
        )

        harbor_core_csrf = rand.RandomPassword(
            "harbor_core_csrf", length=32, special=False
        )
        Secret(
            "harbor/core/csrf-key", harbor_core_csrf.result, "Harbor core CSRF/XSRF key"
        )

        harbor_core_secret = rand.RandomPassword(
            "harbor_core_secret", length=16, special=False
        )
        Secret(
            "harbor/core/secret",
            harbor_core_secret.result,
            "Harbor core component communication secret",
        )

        harbor_token_key = tls.PrivateKey(
            "harbor_token_key", algorithm="RSA", rsa_bits=2048
        )
        harbor_token_cert = tls.SelfSignedCert(
            "harbor_token_cert",
            private_key_pem=harbor_token_key.private_key_pem,
            subject=tls.SelfSignedCertSubjectArgs(common_name="harbor-token-ca"),
            validity_period_hours=87600,
            allowed_uses=["cert_signing", "digital_signature", "key_encipherment"],
            is_ca_certificate=True,
        )
        # Base64-encode PEM values to avoid bws CLI multiline/dash issues
        import base64

        Secret(
            "harbor/core/tls-cert",
            harbor_token_cert.cert_pem.apply(
                lambda pem: base64.b64encode(pem.encode()).decode()
            ),
            "Harbor token service TLS certificate (base64-encoded PEM)",
        )
        Secret(
            "harbor/core/tls-key",
            harbor_token_key.private_key_pem.apply(
                lambda pem: base64.b64encode(pem.encode()).decode()
            ),
            "Harbor token service TLS private key (base64-encoded PEM)",
        )

        harbor_jobservice_secret = rand.RandomPassword(
            "harbor_jobservice_secret", length=16, special=False
        )
        Secret(
            "harbor/jobservice/secret",
            harbor_jobservice_secret.result,
            "Harbor jobservice communication secret",
        )

        harbor_registry_http_secret = rand.RandomPassword(
            "harbor_registry_http_secret", length=16, special=False
        )
        Secret(
            "harbor/registry/http-secret",
            harbor_registry_http_secret.result,
            "Harbor registry HTTP secret",
        )

        harbor_registry_password = rand.RandomPassword(
            "harbor_registry_password", length=16, special=False
        )
        Secret(
            "harbor/registry/password",
            harbor_registry_password.result,
            "Harbor internal registry credential password",
        )
        Secret(
            "harbor/registry/htpasswd",
            harbor_registry_password.bcrypt_hash.apply(
                lambda h: f"harbor_registry_user:{h}"
            ),
            "Harbor registry htpasswd entry (bcrypt)",
        )

        # Embedded microcontrollers are deployed via canivete + deploy-rs, not
        # pulumi. See static/falcon.nix (lands with the embedded/ workspace PR)
        # for per-board profiles; `deploy '.#falcon'` flashes all reachable
        # boards, `deploy '.#falcon.<board>'` one.


if __name__ == "__main__":
    Millionaire()
