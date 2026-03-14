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

        bucket_name = "trdos-me--volsync"
        bucket = command.local.Command(
            "b2-bucket",
            create=f"b2 bucket create {bucket_name} allPrivate",
            delete=f"b2 bucket delete {bucket_name}",
        )
        b2_app_key = command.local.Command(
            "b2-app-key",
            create=f"b2 key create --bucket {bucket_name} {bucket_name} listFiles,readFiles,writeFiles,deleteFiles",
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


if __name__ == "__main__":
    Millionaire()
