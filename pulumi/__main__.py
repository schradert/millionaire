import millionaire

import pulumi_cloudflare as cf


class Millionaire:
    def __init__(self) -> None:
        millionaire.NixOS("sirver", "root@nixos")
        # RPI doesn't support kexec
        # millionaire.NixOS("piper", "piper", "--phases disko,install,reboot")

        cf.ZeroTrustTunnelCloudflared(
            "main",
            account_id="73c86a33c82d5c90d0feb68269932302",
            name="main",
            config_src="local",
        )


if __name__ == "__main__":
    Millionaire()
