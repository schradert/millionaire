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
        key, key=key, value=value, note=note,
        organization_id="ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf",
        project_id="baf88382-abda-41b2-8d0f-b30e014c2db9",
    )


class Millionaire:
    def __init__(self) -> None:
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
                "sops set secrets/sops/default.yaml '[\"attic\"][\"server-key\"]' --value-stdin"
            ),
            environment={
                "ATTIC_VALUE": pulumi.Output.concat(
                    "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=", attic_server_key.stdout
                )
            },
            opts=pulumi.ResourceOptions(depends_on=[attic_server_key]),
        )

        # --- NixOS nodes ---
        sirver = millionaire.NixOS("sirver", "root@nixos", depends_on=[attic_sops_write])

        # --- Attic post-deploy setup (after sirver has atticd running) ---
        # Generate admin token, then use attic client to create/configure cache
        attic_token = command.local.Command(
            "attic_token",
            create=(
                "ssh -i ~/.ssh/personal sirver '"
                "sudo atticd-atticadm make-token --sub admin --validity \"10y\" "
                "--push \"*\" --pull \"*\" --delete \"*\" "
                "--create-cache \"*\" --configure-cache \"*\" --configure-cache-retention \"*\" --destroy-cache \"*\""
                "'"
            ),
            opts=pulumi.ResourceOptions(depends_on=[sirver.refresh]),
        )
        Secret("attic/auth-token", attic_token.stdout, "Attic client auth token for push/pull")

        attic_setup = command.local.Command(
            "attic_setup",
            create=attic_token.stdout.apply(
                lambda token: (
                    f"ssh -i ~/.ssh/personal sirver '"
                    f"nix-shell -p attic-client --run \""
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
                "sops set secrets/sops/default.yaml '[\"attic\"][\"auth-token\"]' --value-stdin"
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
                'FILE="', str(millionaire.Nix.root), '/static/generated.json" && ',
                '[ -f "$FILE" ] && EXISTING=$(cat "$FILE") || EXISTING="{}" && ',
                "echo \"$EXISTING\" | jq --arg key '", attic_public_key.stdout.apply(str.strip),
                "' '.attic_pubkey = $key' > \"$FILE\"",
            ),
            triggers=[attic_public_key.stdout],
            opts=pulumi.ResourceOptions(depends_on=[attic_public_key]),
        )

        # Other nodes depend on attic being fully set up (auth token in SOPS + public key file)
        other_node_deps = [attic_auth_sops_write]
        octopus = millionaire.NixOS("octopus", "root@nixos", depends_on=other_node_deps)
        dingo = millionaire.NixOS("dingo", "root@nixos", depends_on=other_node_deps)
        bonobo = millionaire.NixOS("bonobo", "root@nixos", depends_on=other_node_deps)
        chinchilla = millionaire.NixOS("chinchilla", "root@nixos", depends_on=other_node_deps)

        # RPI doesn't support kexec
        # millionaire.NixOS("piper", "piper", "--phases disko,install,reboot")

        # --- Hetzner VPS (hyena) ---
        ssh_key = hcloud.SshKey(
            "millionaire",
            public_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFBq/GWgq0+wAbRS53AqDdgXhyqpQtvcwlsPEguTPzL9 tristan@millionaire",
        )
        hyena_firewall = hcloud.Firewall(
            "hyena",
            rules=[
                hcloud.FirewallRuleArgs(direction="in", protocol="tcp", port="22", source_ips=["0.0.0.0/0", "::/0"]),
                hcloud.FirewallRuleArgs(direction="in", protocol="tcp", port="443", source_ips=["0.0.0.0/0", "::/0"]),
                hcloud.FirewallRuleArgs(direction="in", protocol="udp", port="3478", source_ips=["0.0.0.0/0", "::/0"]),
                hcloud.FirewallRuleArgs(direction="in", protocol="udp", port="41641", source_ips=["0.0.0.0/0", "::/0"]),
            ],
        )
        hyena_server = hcloud.Server(
            "hyena",
            server_type="cx22",
            image="ubuntu-24.04",
            location="nbg1",
            ssh_keys=[ssh_key.id],
            firewall_ids=[hyena_firewall.id],
        )
        hyena = millionaire.NixOS(
            "hyena",
            hyena_server.ipv4_address.apply(lambda ip: f"root@{ip}"),
            depends_on=[hyena_server],
        )

        headscale_noise_key = rand.RandomPassword("headscale_noise_key", length=64, special=False)
        Secret("headscale/noise-private-key", headscale_noise_key.result, "Headscale noise private key")

        # DNS record for headscale on the VPS
        account_id = "73c86a33c82d5c90d0feb68269932302"
        zone = cf.get_zone_output(account_id=account_id, name="trdos.me")
        cf.Record(
            "headscale",
            zone_id=zone.zone_id,
            type="A",
            name="headscale",
            content=hyena_server.ipv4_address,
            proxied=False,
        )
        tunnel = cf.ZeroTrustTunnelCloudflared(
            "main", account_id=account_id, name="main", config_src="local"
        )
        tunnel_token = cf.get_zero_trust_tunnel_cloudflared_token_output(
            account_id=account_id, tunnel_id=tunnel.id
        )
        Secret("cloudflare/tunnel/token", tunnel_token.token, "Cloudflared Tunnel token")

        ceph_dashboard_password = rand.RandomPassword("ceph_dashboard_password", length=24, special=False)
        Secret("ceph/dashboard/password", ceph_dashboard_password.result, "Rook Ceph builtin dashboard password")

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

        restic_password = rand.RandomPassword("restic_password", length=24, special=False)
        Secret("volsync/restic/password", restic_password.result, "VolSync Restic password")

        firefly_app_key = rand.RandomBytes("firefly_app_key", length=32)
        Secret("firefly/app_key", firefly_app_key.base64.apply(lambda b: f"base64:{b}"), "Firefly-III Laravel APP_KEY")

        stalwart_admin_password = rand.RandomPassword("stalwart_admin_password", length=24, special=False)
        Secret("stalwart/admin/password", stalwart_admin_password.result, "Stalwart Mail admin password")

        bulwark_session_secret = rand.RandomPassword("bulwark_session_secret", length=32, special=False)
        Secret("bulwark/session-secret", bulwark_session_secret.result, "Bulwark webmail session encryption secret")

        grafana_admin_password = rand.RandomPassword("grafana_admin_password", length=21, special=False)
        Secret("grafana", grafana_admin_password.result, "Grafana admin password")

        actualbudget_admin_password = rand.RandomPassword("actualbudget_admin_password", length=24, special=False)
        Secret("actualbudget/admin/password", actualbudget_admin_password.result, "ActualBudget admin password")

        # --- Oathkeeper (kept as auth proxy for Keycloak) ---
        jwks = millionaire.OryJwks("ory_oathkeeper_jwks")
        Secret("ory/oathkeeper/mutator-id-token-jwks", jwks.jwks_json, "Oathkeeper JWKS for ID token signing")

        # --- AdGuard Home ---
        adguard_admin_password = rand.RandomPassword("adguard_admin_password", length=24, special=False)
        Secret("adguard/admin/password", adguard_admin_password.result, "AdGuard Home admin password (plaintext for external-dns webhook)")
        Secret("adguard/admin/password-hash", adguard_admin_password.bcrypt_hash, "AdGuard Home admin password (bcrypt hash for config)")

        # --- Keycloak ---
        keycloak_admin_password = rand.RandomPassword("keycloak_admin_password", length=24, special=False)
        Secret("keycloak/admin/password", keycloak_admin_password.result, "Keycloak bootstrap admin password")

        oauth2_proxy_client_secret = rand.RandomPassword("oauth2_proxy_client_secret", length=32, special=False)
        Secret("oauth2-proxy/client-secret", oauth2_proxy_client_secret.result, "OAuth2 Proxy OIDC client secret")

        oauth2_proxy_cookie_secret = rand.RandomPassword("oauth2_proxy_cookie_secret", length=32, special=False)
        Secret("oauth2-proxy/cookie-secret", oauth2_proxy_cookie_secret.result, "OAuth2 Proxy cookie encryption secret (must be 16/24/32 bytes)")

        sure_secret_key_base = rand.RandomPassword("sure_secret_key_base", length=128, special=False)
        Secret("sure/secret_key_base", sure_secret_key_base.result, "Sure Finance Rails SECRET_KEY_BASE")

        # --- Home Assistant ---
        ha_admin_password = rand.RandomPassword("ha_admin_password", length=24, special=False)
        Secret("ha/admin/password", ha_admin_password.result, "Home Assistant initial admin password")

        # --- Harbor ---
        harbor_robot_secret = rand.RandomPassword("harbor_robot_secret", length=32, special=False)
        Secret("harbor/robot/secret", harbor_robot_secret.result, "Harbor system robot account secret for CI/local push")

        harbor_cosign_password = rand.RandomPassword("harbor_cosign_password", length=32, special=False)
        Secret("harbor/cosign/password", harbor_cosign_password.result, "Cosign private key encryption password")
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

        harbor_admin_password = rand.RandomPassword("harbor_admin_password", length=24, special=False)
        Secret("harbor/admin/password", harbor_admin_password.result, "Harbor admin password")

        harbor_secret_key = rand.RandomPassword("harbor_secret_key", length=16, special=False)
        Secret("harbor/secret-key", harbor_secret_key.result, "Harbor encryption secret key (16 chars)")

        harbor_core_csrf = rand.RandomPassword("harbor_core_csrf", length=32, special=False)
        Secret("harbor/core/csrf-key", harbor_core_csrf.result, "Harbor core CSRF/XSRF key")

        harbor_core_secret = rand.RandomPassword("harbor_core_secret", length=16, special=False)
        Secret("harbor/core/secret", harbor_core_secret.result, "Harbor core component communication secret")

        harbor_token_key = tls.PrivateKey("harbor_token_key", algorithm="RSA", rsa_bits=2048)
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
            harbor_token_cert.cert_pem.apply(lambda pem: base64.b64encode(pem.encode()).decode()),
            "Harbor token service TLS certificate (base64-encoded PEM)",
        )
        Secret(
            "harbor/core/tls-key",
            harbor_token_key.private_key_pem.apply(lambda pem: base64.b64encode(pem.encode()).decode()),
            "Harbor token service TLS private key (base64-encoded PEM)",
        )

        harbor_jobservice_secret = rand.RandomPassword("harbor_jobservice_secret", length=16, special=False)
        Secret("harbor/jobservice/secret", harbor_jobservice_secret.result, "Harbor jobservice communication secret")

        harbor_registry_http_secret = rand.RandomPassword("harbor_registry_http_secret", length=16, special=False)
        Secret("harbor/registry/http-secret", harbor_registry_http_secret.result, "Harbor registry HTTP secret")

        harbor_registry_password = rand.RandomPassword("harbor_registry_password", length=16, special=False)
        Secret("harbor/registry/password", harbor_registry_password.result, "Harbor internal registry credential password")
        Secret(
            "harbor/registry/htpasswd",
            harbor_registry_password.bcrypt_hash.apply(lambda h: f"harbor_registry_user:{h}"),
            "Harbor registry htpasswd entry (bcrypt)",
        )

if __name__ == "__main__":
    Millionaire()
