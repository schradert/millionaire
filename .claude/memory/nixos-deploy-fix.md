# NixOS Deploy "Too many open files" Fix

## Problem
`pulumi up --yes` deploying NixOS via nixos-anywhere fails with:
- `error: creating pipe: Too many open files`
- `error: opening directory "/mnt/nix/store": Too many open files`

## Root Cause
Remote NixOS kexec installer SSH sessions have default ulimit of 1024 file descriptors.
Large NixOS builds (2000+ derivations) need much higher limits.

## Why other approaches failed
- Local macOS ulimit fixes don't help (error is remote)
- Remote `/etc/systemd/system.conf` is read-only on kexec installer
- `.bashrc`/`.profile` don't work because nixos-anywhere uses `runSsh sh <<SSH` heredoc (doesn't source profiles)
- `systemctl restart sshd` would kill the SSH connection

## Solution
Split nixos-anywhere into two phase groups:
1. `--phases kexec` - boot into NixOS installer
2. SSH in and `prlimit --nofile=1048576:1048576` on PID 1, sshd, nix-daemon
3. `--phases disko,install,reboot` - partition, install, reboot

This works because:
- `uploadSshKey()` is called on every nixos-anywhere invocation (phase splitting safe)
- `prlimit` on PID 1 means all new child processes inherit higher limits
- No service restart needed (prlimit modifies running processes)
