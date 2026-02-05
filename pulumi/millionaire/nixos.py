from __future__ import annotations

import pathlib
import shlex
import subprocess
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
            return subprocess.run(cmd, shell=True, capture_output=True).stdout.decode()

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
        return (
            subprocess.run(cmd, shell=True, capture_output=True).stdout.decode().strip()
        )

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
        target: str,
        *flags: str,
        depends_on: list[pulumi.Resource] | None = None,
    ):
        nixos_anywhere = Nix.bin(
            f"canivete.inputs.nixos-anywhere.packages.{Nix.system()}.default"
        )
        self.command = command.local.Command(
            f"nixos-{name}-install",
            create=f"{nixos_anywhere} --flake {Nix.root}#{name} {' '.join(flags)} {target}",
            opts=pulumi.ResourceOptions(depends_on=depends_on or []),
        )
