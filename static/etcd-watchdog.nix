# rke2-server is containerd's parent: when rke2 dies, containerd dies with it and
# nothing reads the static pods' stderr pipes. etcd then blocks on a log write,
# raft stalls, and rke2 can't restart without a local etcd. Detect that state
# and drain the pipe from whichever process still holds its read end.
{pkgs, ...}: let
  watchdog = pkgs.writeShellApplication {
    name = "etcd-pipe-watchdog";
    runtimeInputs = with pkgs; [coreutils gnugrep procps systemd];
    text = ''
      target=''${TARGET_COMM:-etcd}
      reader=''${READER_COMM:-containerd-shim}
      blocked() { grep -qs anon_pipe_write /proc/"$1"/task/*/stack; }

      pid=$(pgrep -x "$target" | head -1) || exit 0
      blocked "$pid" || exit 0
      sleep 5
      blocked "$pid" || exit 0
      systemctl is-active --quiet etcd-pipe-drain && exit 0

      pipe=$(readlink /proc/"$pid"/fd/2)
      src=""
      for p in $(pgrep -f "$reader"); do
        for fd in /proc/"$p"/fd/*; do
          [ "$(readlink "$fd" 2>/dev/null)" = "$pipe" ] && src=$fd
        done
      done
      if [ -z "$src" ]; then
        echo "$target ($pid) blocked on $pipe; no $reader holds its read end"
        exit 1
      fi
      echo "$target ($pid) blocked on $pipe; draining $src"
      systemctl reset-failed etcd-pipe-drain 2>/dev/null || true
      systemd-run --unit=etcd-pipe-drain --collect \
        ${pkgs.bash}/bin/bash -c "exec ${pkgs.coreutils}/bin/cat $src >/dev/null"
    '';
  };
in {
  environment.systemPackages = [watchdog];
  systemd.services.etcd-pipe-watchdog = {
    serviceConfig.Type = "oneshot";
    script = "${watchdog}/bin/etcd-pipe-watchdog";
  };
  systemd.timers.etcd-pipe-watchdog = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30s";
    };
  };
}
