from __future__ import annotations

import pathlib
import shlex
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
        deploy_hostname: str | pulumi.Output[str] | None = None,
        depends_on: list[pulumi.Resource] | None = None,
        identity: str | None = None,
        preserve_host_key: bool = False,
    ):
        """`target` is the ssh target of the install (a live host that is not
        root-reachable: `user@host` with passwordless sudo; nixos-anywhere
        switches to root@host after kexec). `identity` is an ssh key path, passed
        as given to the shell (e.g. "$HOME/.ssh/personal"). `preserve_host_key`
        copies the live host's ed25519 ssh host key into the new install, for
        hosts whose key is a sops recipient and is pinned elsewhere (falcon)."""
        nixos_anywhere = Nix.bin(
            f"canivete.inputs.nixos-anywhere.packages.{Nix.system()}.default"
        )
        sops_dir = Nix.attr("canivete.sops.directory").value().strip()

        ssh_id = f"-o IdentitiesOnly=yes -i {identity}" if identity else ""
        na_id = f"-i {identity} --ssh-option IdentitiesOnly=yes" if identity else ""
        host_key = (
            f"""
                # Keep the host's ssh identity across the reinstall: it is a sops
                # recipient (.sops.yaml) and its public half is pinned in static/builders.nix.
                mkdir -p "$EXTRA_DIR/etc/ssh"
                for k in ssh_host_ed25519_key ssh_host_ed25519_key.pub; do
                    ssh {ssh_id} -o StrictHostKeyChecking=accept-new "$TARGET" "sudo cat /etc/ssh/$k" > "$EXTRA_DIR/etc/ssh/$k"
                done
                chmod 600 "$EXTRA_DIR/etc/ssh/ssh_host_ed25519_key"
                [ -s "$EXTRA_DIR/etc/ssh/ssh_host_ed25519_key" ] || {{ echo "could not read the host key from $TARGET" >&2; exit 1; }}
"""
            if preserve_host_key
            else ""
        )

        def _make_install_cmd(resolved_target: str) -> str:
            return f"""
                set -euo pipefail
                # Wipes the target's disks. Only ever runs on an explicit,
                # per-node request — never because state or a URN drifted.
                if [ "${{NIXOS_ANYWHERE_INSTALL:-}}" != "{name}" ]; then
                    echo "refusing to install {name}: set NIXOS_ANYWHERE_INSTALL={name}" >&2
                    exit 1
                fi
                ulimit -n 1048576

                # nixos-anywhere reconnects as root@<host> once kexec has booted the installer
                TARGET={shlex.quote(resolved_target)}
                POST_KEXEC="root@${{TARGET##*@}}"

                EXTRA_DIR=$(mktemp -d)
                ENCRYPTED="{Nix.root}/{sops_dir}/default.yaml"
                DECRYPTED="$EXTRA_DIR/root/.config/sops/age/keys.txt"

                trap 'rm -rf "$EXTRA_DIR"' EXIT
                mkdir -p "$(dirname "$DECRYPTED")"
                sops --decrypt --extract '["passwords"]["age"]' "$ENCRYPTED" > "$DECRYPTED"
                chmod 600 "$DECRYPTED"
                {host_key}
                NA="{nixos_anywhere}"
                # --build-on remote: have the target machine build its own closure.
                # The local linux-builder VM only has 3GB and was OOMing on big closures;
                # remote-build avoids the VM bottleneck entirely.
                NA_ARGS=(--extra-files "$EXTRA_DIR" --build-on remote --flake "{Nix.root}#{name}" {na_id} {" ".join(flags)})

                # Phase 1: kexec into the NixOS installer
                "$NA" "${{NA_ARGS[@]}}" --phases kexec "$TARGET"

                # Raise file descriptor limits on the remote NixOS installer.
                # After kexec the default ulimit is 1024 which is too low for
                # large NixOS builds (2000+ derivations).
                ssh {ssh_id} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$POST_KEXEC" \
                    'for pid in 1 $(pgrep -x sshd) $(pgrep -x nix-daemon); do prlimit --nofile=1048576:1048576 --pid "$pid" 2>/dev/null; done'

                # Phase 2: partition, install, and reboot
                "$NA" "${{NA_ARGS[@]}}" --phases disko,install,reboot "$POST_KEXEC"
            """

        create_cmd = (
            pulumi.Output.from_input(target).apply(_make_install_cmd)
            if isinstance(target, pulumi.Output)
            else _make_install_cmd(target)
        )

        # Install runs once. Re-running on a live NixOS box would kexec it
        # back to the installer and wipe its disks. Three guards:
        # ignore_changes makes drift a no-op, protect blocks replace/delete,
        # and the script itself refuses unless NIXOS_ANYWHERE_INSTALL=<name>
        # (covers a fresh create after a rename or lost state entry).
        # Reinstall (dead disk): `pulumi state unprotect <urn>`, then
        # `pulumi state delete <urn>`, then
        # `NIXOS_ANYWHERE_INSTALL=<name> pulumi up --target <urn>`. Deleting
        # from state matters: ignore_changes also applies to forced
        # replacements, so a --target-replace would re-run the OLD command
        # string frozen in state.
        self.command = command.local.Command(
            f"nixos-{name}-install",
            create=create_cmd,
            opts=pulumi.ResourceOptions(
                depends_on=depends_on or [],
                ignore_changes=["create"],
                protect=True,
            ),
        )

        # Deploy re-runs when the rendered system toplevel changes (triggers)
        # OR when the command itself changes (new flags, new deploy-rs store
        # path). Deliberately NOT ignore_changes=["create"]: pulumi would
        # freeze the command string in state and even replacements re-run the
        # old one — new flags would never reach existing nodes, and a GC'd
        # deploy-rs path would dangle. Drift-driven re-deploys are idempotent
        # (deploy-rs re-activates the same toplevel) and cheap.
        toplevel = (
            Nix.attr(f"nixosConfigurations.{name}.config.system.build.toplevel.outPath")
            .impure()
            .value()
            .strip()
        )
        # TODO re-enable rollback once RKE2 restart handling is fixed
        # RKE2 transiently fails on config switch (port conflicts), triggering rollback loops
        deploy_bin = Nix.bin(
            f"canivete.inputs.deploy-rs.packages.{Nix.system()}.default"
        )
        deploy_base = f"{deploy_bin} .#{name}.system --remote-build --skip-checks --auto-rollback false --magic-rollback false"
        deploy_cmd = (
            pulumi.Output.from_input(deploy_hostname).apply(
                lambda h: f"{deploy_base} --hostname {shlex.quote(h)}"
            )
            if deploy_hostname is not None
            else deploy_base
        )
        self.refresh = command.local.Command(
            f"nixos-{name}-deploy",
            triggers=[toplevel],
            create=deploy_cmd,
            opts=pulumi.ResourceOptions(depends_on=[self.command]),
        )
