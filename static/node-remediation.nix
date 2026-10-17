# Node prerequisites for medik8s Self Node Remediation (SNR) and Node Health Check (NHC). Eligibility is a per-node
# fact, not derived from the node's rke2 role: `nodeRemediation.eligible` (bonobo and chinchilla, which NHC may reboot
# whether or not they are etcd members) labels the node `node.trdos.me/remediation=eligible`, the label the NHC and SNR
# selectors in nixidy/system/cluster/medik8s.nix require. Every other node (sirver and octopus hold the Ceph OSDs,
# dingo is the stable server, falcon and axolotl are desktops that sleep and reboot at will) gets
# `remediation.medik8s.io/exclude-from-remediation=true`, which the SNR operator honours on its own.
# Eligible nodes also get what the agent needs to reboot them (docs/node-standard.md, "Node remediation").
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.nodeRemediation;
in {
  options.nodeRemediation.eligible = lib.mkEnableOption "SNR rebooting this node (the agent arms /dev/watchdog1 and may run `/bin/bash`)";
  config = lib.mkMerge [
    (lib.mkIf (!cfg.eligible) {
      canivete.kubernetes.yaml.node-label = ["remediation.medik8s.io/exclude-from-remediation=true"];
    })
    (lib.mkIf cfg.eligible {
      canivete.kubernetes.yaml.node-label = ["node.trdos.me/remediation=eligible"];
      # systemd holds the first hardware watchdog open (srvos RuntimeWatchdogSec=15s: hang detection),
      # so the agent gets the second one (SelfNodeRemediationConfig `watchdogFilePath: /dev/watchdog1`).
      # Both paths are fixed, so they never collide whichever driver registers first. On bonobo and
      # chinchilla watchdog0 is intel_oc_wdt and watchdog1 iTCO_wdt (read 2026-10-16).
      systemd.settings.Manager.WatchdogDevice = "/dev/watchdog0";
      boot.kernelModules = ["iTCO_wdt"];
      # SNR's software-reboot fallback runs `nsenter -m/proc/1/ns/mnt /bin/bash -c 'echo b > /proc/sysrq-trigger'`;
      # NixOS only has /bin/sh.
      systemd.tmpfiles.rules = ["L+ /bin/bash - - - - ${pkgs.bashInteractive}/bin/bash"];
    })
  ];
}
