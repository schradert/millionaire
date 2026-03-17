import pulumi
import pulumi_bitwarden as bw
import pulumi_cloudflare as cf
import pulumi_command as command
import pulumi_random as rand

import millionaire


def Secret(key: str, value: pulumi.Input[str], note: str = "") -> bw.Secret:
    return bw.Secret(
        key, key=key, value=value, note=note,
        organization_id="ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf",
        project_id="baf88382-abda-41b2-8d0f-b30e014c2db9",
    )


class Millionaire:
    def __init__(self) -> None:
        millionaire.NixOS("sirver", "root@nixos")
        millionaire.NixOS("octopus", "root@nixos")
        millionaire.NixOS("dingo", "root@nixos")
        millionaire.NixOS("bonobo", "root@nixos")
        millionaire.NixOS("chinchilla", "root@nixos")

        # RPI doesn't support kexec
        # millionaire.NixOS("piper", "piper", "--phases disko,install,reboot")

        account_id = "73c86a33c82d5c90d0feb68269932302"
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

        firefly_admin_password = rand.RandomPassword("firefly_admin_password", length=24, special=False)
        Secret("firefly/admin/password", firefly_admin_password.result, "Firefly-III admin password")

        grafana_admin_password = rand.RandomPassword("grafana_admin_password", length=21, special=False)
        Secret("grafana", grafana_admin_password.result, "Grafana admin password")

        actualbudget_admin_password = rand.RandomPassword("actualbudget_admin_password", length=24, special=False)
        Secret("actualbudget/admin/password", actualbudget_admin_password.result, "ActualBudget admin password")

        # --- Ory Identity Platform ---
        domain = millionaire.Nix.attr("canivete.meta.domain").value()

        # Kratos secrets
        kratos_cookie = rand.RandomPassword("ory_kratos_cookie", length=32, special=False)
        Secret("ory/kratos/secret", kratos_cookie.result, "Ory Kratos cookie/session secret")

        kratos_cipher = rand.RandomPassword("ory_kratos_cipher", length=32, special=False)
        Secret("ory/kratos/cipher", kratos_cipher.result, "Ory Kratos cipher secret")

        # Hydra secrets
        hydra_system = rand.RandomPassword("ory_hydra_system", length=32, special=False)
        Secret("ory/hydra/system-secret", hydra_system.result, "Ory Hydra system secret")

        hydra_salt = rand.RandomPassword("ory_hydra_salt", length=32, special=False)
        Secret("ory/hydra/oidc-subject-salt", hydra_salt.result, "Ory Hydra OIDC subject salt")

        # UI secrets
        ui_cookie = rand.RandomPassword("ory_ui_cookie", length=32, special=False)
        Secret("ory/ui/cookie-secret", ui_cookie.result, "Ory Kratos UI cookie secret")

        ui_csrf = rand.RandomPassword("ory_ui_csrf", length=32, special=False)
        Secret("ory/ui/csrf-secret", ui_csrf.result, "Ory Kratos UI CSRF secret")

        # Oathkeeper JWKS (RSA key pair for ID token signing)
        jwks = millionaire.OryJwks("ory_oathkeeper_jwks")
        Secret("ory/oathkeeper/mutator-id-token-jwks", jwks.jwks_json, "Oathkeeper JWKS for ID token signing")

        # Hydra OAuth2 clients (requires running Hydra — set ory:hydra-admin-url after deploy)
        hydra_admin_url = pulumi.Config("ory").get("hydra-admin-url") or ""

        argocd_client = millionaire.HydraOAuth2Client(
            "ory_argocd_client",
            admin_url=hydra_admin_url,
            client_name="ArgoCD",
            grant_types=["authorization_code", "refresh_token"],
            redirect_uris=[f"https://argocd.{domain}/auth/callback"],
            response_types=["code"],
            scope="openid profile email",
        )
        Secret("ory/argocd/client-id", argocd_client.client_id, "ArgoCD Hydra OAuth2 client ID")
        Secret("ory/argocd/client-secret", argocd_client.client_secret, "ArgoCD Hydra OAuth2 client secret")

        sure_secret_key_base = rand.RandomPassword("sure_secret_key_base", length=128, special=False)
        Secret("sure/secret_key_base", sure_secret_key_base.result, "Sure Finance Rails SECRET_KEY_BASE")

        sure_client = millionaire.HydraOAuth2Client(
            "ory_sure_client",
            admin_url=hydra_admin_url,
            client_name="Sure Finance",
            grant_types=["authorization_code", "refresh_token"],
            redirect_uris=[f"https://sure.{domain}/auth/oidc/callback"],
            response_types=["code"],
            scope="openid profile email",
        )
        Secret("ory/sure/client-id", sure_client.client_id, "Sure Finance Hydra OAuth2 client ID")
        Secret("ory/sure/client-secret", sure_client.client_secret, "Sure Finance Hydra OAuth2 client secret")

if __name__ == "__main__":
    Millionaire()
