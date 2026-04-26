from __future__ import annotations

import pathlib
import shlex
import time
import typing

import pulumi
import pulumi_command as command


class Nix:
    """Evaluate Nix flake and system expressions and attributes."""

    root = pathlib.Path(__file__).parents[2]

    class Eval:
        def __init__(
            self,
            args: list[str],
            *,
            impure: bool = False,
            format: typing.Literal["raw", "json"] = "raw",
        ):
            self._args = args
            self._impure = impure
            self._format = format

        def _clone(
            self,
            *,
            args: list[str] | None = None,
            impure: bool | None = None,
            format: typing.Literal["raw", "json"] | None = None,
        ) -> Nix.Eval:
            return Nix.Eval(
                args=args if args is not None else list(self._args),
                impure=self._impure if impure is None else impure,
                format=self._format if format is None else format,
            )

        def args(self, *extra: str) -> Nix.Eval:
            return self._clone(args=list(self._args) + list(extra))

        def impure(self, enabled: bool = True) -> Nix.Eval:
            return self._clone(impure=enabled)

        def json(self) -> Nix.Eval:
            return self._clone(format="json")

        def raw(self) -> Nix.Eval:
            return self._clone(format="raw")

        def apply(self, fn: str) -> Nix.Eval:
            # Transform the attribute in one evaluation via nix --apply.
            return self._clone(args=["--apply", fn, *self._args])

        def value(self) -> str:
            cmd_parts = ["nix", "eval", f"--{self._format}"]
            if self._impure:
                cmd_parts.append("--impure")
            cmd_parts.extend(self._args)
            cmd = shlex.join(cmd_parts)
            result = command.local.run(command=cmd)
            return result.stdout

        def __str__(self) -> str:
            return self.value()

    @staticmethod
    def eval(*args: str) -> Nix.Eval:
        return Nix.Eval(list(args))

    @staticmethod
    def expr(_expr: str) -> Nix.Eval:
        return Nix.eval("--expr", _expr)

    @staticmethod
    def attr(_attr: str) -> Nix.Eval:
        return Nix.eval(f"{Nix.root}#{_attr}")

    @staticmethod
    def build(_attr: str) -> str:
        """Build a flake attribute and return its out path without linking."""
        cmd = shlex.join(
            ["nix", "build", "--no-link", "--print-out-paths", f"{Nix.root}#{_attr}"]
        )
        result = command.local.run(command=cmd)
        return result.stdout.strip()

    @staticmethod
    def bin(_attr: str) -> str:
        # Ensure the package is realized, then compute the executable path in one eval.
        package = Nix.build(_attr)
        exe = (
            Nix.attr(_attr)
            .apply("pkg: pkg.meta.mainProgram or pkg.pname")
            .value()
            .strip()
        )
        return f"{package}/bin/{exe}"

    @staticmethod
    def system() -> str:
        return Nix.expr("builtins.currentSystem").impure().value()


class NixOS:
    """Deploy NixOS using nixos-anywhere."""

    def __init__(
        self,
        name: str,
        target: str | pulumi.Output[str],
        *flags: str,
        depends_on: list[pulumi.Resource] | None = None,
    ):
        nixos_anywhere = Nix.bin(
            f"canivete.inputs.nixos-anywhere.packages.{Nix.system()}.default"
        )
        sops_dir = Nix.attr("canivete.sops.directory").value().strip()

        def _make_install_cmd(resolved_target: str) -> str:
            return f"""
                set -euo pipefail
                ulimit -n 1048576

                EXTRA_DIR=$(mktemp -d)
                ENCRYPTED="{Nix.root}/{sops_dir}/default.yaml"
                DECRYPTED="$EXTRA_DIR/root/.config/sops/age/keys.txt"

                trap 'rm -rf "$EXTRA_DIR"' EXIT
                mkdir -p "$(dirname "$DECRYPTED")"
                sops --decrypt --extract '["passwords"]["age"]' "$ENCRYPTED" > "$DECRYPTED"
                chmod 600 "$DECRYPTED"

                NA="{nixos_anywhere}"
                NA_ARGS=(--extra-files "$EXTRA_DIR" --flake "{Nix.root}#{name}" {" ".join(flags)})

                # Phase 1: kexec into the NixOS installer
                "$NA" "${{NA_ARGS[@]}}" --phases kexec {resolved_target}

                # Raise file descriptor limits on the remote NixOS installer.
                # After kexec the default ulimit is 1024 which is too low for
                # large NixOS builds (2000+ derivations).
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null {resolved_target} \
                    'for pid in 1 $(pgrep -x sshd) $(pgrep -x nix-daemon); do prlimit --nofile=1048576:1048576 --pid "$pid" 2>/dev/null; done'

                # Phase 2: partition, install, and reboot
                "$NA" "${{NA_ARGS[@]}}" --phases disko,install,reboot {resolved_target}
            """

        create_cmd = (
            pulumi.Output.from_input(target).apply(_make_install_cmd)
            if isinstance(target, pulumi.Output)
            else _make_install_cmd(target)
        )

        self.command = command.local.Command(
            f"nixos-{name}-install",
            # FIXME prevent retriggering!
            create=create_cmd,
            opts=pulumi.ResourceOptions(depends_on=depends_on or []),
        )

        self.refresh = command.local.Command(
            f"nixos-{name}-deploy",
            triggers=[Nix.attr(f"nixosConfigurations.{name}.config.system.build.toplevel.outPath").impure().value()],
            # TODO re-enable rollback once RKE2 restart handling is fixed
            # RKE2 transiently fails on config switch (port conflicts), triggering rollback loops
            create=f"{Nix.bin(f'canivete.inputs.deploy-rs.packages.{Nix.system()}.default')} .#{name}.system --skip-checks --auto-rollback false --magic-rollback false",
            opts=pulumi.ResourceOptions(depends_on=[self.command]),
        )
