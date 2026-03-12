import millionaire

import pulumi_cloudflare as cf
import pulumi_bitwarden as bw
import pulumi_random as rand


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
        key = "cloudflare/tunnel/token"
        bw.Secret(
            key,
            key=key,
            value=tunnel_token.token,
            note="Cloudflared Tunnel token",
            organization_id="ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf",
            project_id="baf88382-abda-41b2-8d0f-b30e014c2db9",
        )

        ceph_dashboard_password = rand.RandomPassword("ceph_dashboard_password", length=24, special=False)
        key = "ceph/dashboard/password"
        bw.Secret(
            key,
            key=key,
            value=ceph_dashboard_password.result,
            note="Rook Ceph builtin dashboard password",
            organization_id="ce96e43f-f2ce-4cd7-a36f-b30e0149eeaf",
            project_id="baf88382-abda-41b2-8d0f-b30e014c2db9",
        )


if __name__ == "__main__":
    Millionaire()
