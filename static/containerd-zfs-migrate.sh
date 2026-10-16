#!/usr/bin/env bash
# One-shot, per-node migration of the containerd dir onto its own ZFS dataset
# (<pool>/local/containerd: sync=disabled, copies=1, legacy mountpoint), matching
# the dataset static/k8s-node.nix declares for disko. disko only runs on install,
# so live nodes need this BEFORE the switch that adds the fileSystems entry.
# Run as root on the node. See docs/node-standard.md for the order and etcd gates.
#
#   seed      rke2 running: create the dataset, mount it at /mnt/containerd-new, rsync
#   cutover   rke2 down: stop + killall, final rsync, move the old dir aside, mount the dataset
#   rollback  undo cutover: unmount, put the old dir back
#   cleanup   after verifying: delete the old dir (frees its copies=2 space)
set -euo pipefail

DIR=/var/lib/rancher/rke2/agent/containerd
OLD=${DIR}.premigration
TMP=/mnt/containerd-new
POOL=$(findmnt -no SOURCE /var/lib)
POOL=${POOL%%/*}
DS=$POOL/local/containerd
# NixOS ships a stub rke2-server on agents too, so pick the unit that is running (override: UNIT=...).
UNIT=${UNIT:-$(systemctl is-active --quiet rke2-agent && echo rke2-agent || echo rke2-server)}
RSYNC=(rsync -aHAX --numeric-ids --info=stats1 --exclude='/lost+found')

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root"
# rke2-killall.sh would unmount /run/k3s under a live containerd of its own unit (docs/node-standard.md)
case "${1:-}" in cutover | rollback) ! grep -qs container-runtime-endpoint /etc/rancher/rke2/config.yaml || die "externalContainerd is on";; esac

case "${1:-}" in
seed)
  zfs list -H "$DS" >/dev/null 2>&1 || {
    # live snapshots vanish mid-walk; du still prints the total
    used=$({ du -sx --block-size=1 "$DIR" 2>/dev/null || true; } | tail -1 | cut -f1)
    avail=$(zfs list -Hpo avail "$POOL")
    [ "$avail" -gt $((used * 12 / 10)) ] || die "pool $POOL has $avail free, $DIR is $used"
    zfs create -o mountpoint=legacy -o sync=disabled -o copies=1 -o com.sun:auto-snapshot=false "$DS"
  }
  mkdir -p "$TMP"
  mountpoint -q "$TMP" || mount -t zfs "$DS" "$TMP"
  # 24 = source files vanished (containerd is live); cutover's rsync catches them up
  "${RSYNC[@]}" "$DIR"/ "$TMP"/ || [ $? = 24 ]
  ;;
cutover)
  mountpoint -q "$DIR" && die "$DIR is already a mountpoint"
  [ -e "$OLD" ] && die "$OLD exists; run rollback or cleanup first"
  mountpoint -q "$TMP" || die "run seed first"
  systemctl stop "$UNIT"
  rke2-killall.sh
  findmnt -R "$DIR" >/dev/null 2>&1 && die "mounts still under $DIR"
  "${RSYNC[@]}" --delete "$DIR"/ "$TMP"/
  umount "$TMP"
  mv "$DIR" "$OLD"
  mkdir "$DIR"
  mount -t zfs "$DS" "$DIR"
  zfs get -H -o property,value sync,copies,mountpoint "$DS"
  echo "cutover done; $UNIT is stopped. Switch next, then: systemctl is-active $UNIT || systemctl start $UNIT"
  ;;
rollback)
  systemctl stop "$UNIT"
  rke2-killall.sh
  umount "$DIR"
  rmdir "$DIR"
  mv "$OLD" "$DIR"
  echo "rolled back; $DIR is back on the old dataset. systemctl start $UNIT. Dataset $DS kept (zfs destroy it to retry from scratch)."
  ;;
cleanup)
  mountpoint -q "$DIR" || die "$DIR is not on $DS"
  [ -d "$OLD" ] || die "nothing at $OLD"
  rm -rf "$OLD"
  ;;
*)
  die "usage: $0 seed|cutover|rollback|cleanup"
  ;;
esac
