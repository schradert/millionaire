# Node standard

What every host that runs RKE2 has in common, and how a host is reinstalled onto it. Written 2026-10-11 from the repo; the
reinstall path has not been run end to end (see "Not verified").

## Layers

A node is built from independent layers; a host file (`static/<host>.nix`) picks one of each and adds only its own facts
(disk device, hostId, NICs, hardware quirks).

| Layer | Module | What it gives | Choose |
| --- | --- | --- | --- |
| Disk | `modules/disko.nix` | ZFS pool `root`: `system/{root,var}`, `local/nix`, `safe/{home,var/lib}` (copies=2), `temp/tmp` (sync=disabled), ESP on `/boot` | every node and hyena |
| Disk (legacy) | `static/zfs-legacy.nix`, `disko.legacyLayout = true` | flat `root/{root,home,tmp}` as installed by the old dotfiles; mounts only | falcon, axolotl until their reinstall |
| Node | `static/k8s-node.nix` | RKE2 via `canivete.kubernetes` (agent unless `services.rke2.role` is set), cluster tailnet (`tailnet.nix`: cluster-node key, pod routes, `accept-dns=false`), build-pool membership and name resolution (`builder.nix`), attic substituter and push hook, chrony, kubelet resolv.conf, etcd watchdog/snapshot, opt-in `externalContainerd` (`static/containerd-external.nix`) | every RKE2 host |
| Role | `static/server.nix` | srvos server profile (headless) | sirver, octopus, dingo, bonobo, chinchilla |
| Role | `static/desktop-node.nix` | no sleep, NetworkManager leaves cilium alone, LAN NIC renamed `eno1` (cilium's device list), NVIDIA container toolkit + `nvidia` containerd runtime when `profiles.nvidia` is on | falcon, axolotl |
| Host | `static/<host>.nix` | disk device, hostId, hardware | one per host |

Import `k8s-node.nix` and the role as siblings in the host's `imports` (flake nodes for the headless five; `falcon-system.nix` and
`axolotl.nix` for the desktops). Nesting one under the other changes NixOS module-merge order, and with it every host's toplevel.

Outside the layers, on purpose:

- **Data pools never go through disko.** disko rewrites the GPT of every disk it declares, even when a pool already lives there.
  Extra disks are plain `fileSystems` plus `boot.zfs.extraPools` (falcon's `data` pool). `nofail`, so a dead data disk cannot keep
  a node from booting.
- **Clients are not nodes.** The Steam Deck keeps its ext4 layout (`static/systeamadeck.nix`) and has no `k8s-node.nix`.
- **Tailnet identity follows node-ness.** `tailnet-personal.nix` (user `tristan`, `secrets/sops/personal.yaml`) steps aside when
  `tailnet.enable` is set, so a personal device that becomes a node joins with the shared cluster-node key instead.
- **Build pool.** `static/builders.nix` lists the members. The headless nodes are capped (`nodes`); falcon is a member without caps
  (`falcon`); any other host (axolotl) gets only name resolution (`sirver`, `<node>.tailnet`) and no builder access.
- **Native aarch64-linux builds** come from the Mac's `nix.linux-builder` VM (`morgenmuffelVm` in `static/builders.nix`), not from
  falcon's binfmt emulation (`falcon.emulated`, speedFactor 2, 6h+ for voron, and cache misses since the fleet's overlays differ from
  cachix). The VM's sshd is QEMU's hostfwd on the Mac's LAN address, port 31022; its host key is fixed in nixpkgs' builder image
  (pinned in `builders.nix`); `static/morgenmuffel.nix` authorizes every pool host key for the VM's `builder` user, so the pool hosts
  reach it with their ssh host keys and it appears in their `/etc/nix/machines` (`static/builder.nix`) and in `build-all`'s pool
  string (`devenv.nix`). It exists only while the Mac is awake and on the LAN; builds then fall back to falcon's emulation.
  After the Mac's `darwin-rebuild` (the VM restarts with the new key list) and falcon's switch, verify on falcon:
  `nix build --system aarch64-linux --no-link nixpkgs#hello -L` (the log shows `building ... on 'ssh-ng://builder@192.168.50.249:31022'`;
  `nix store ping --store ssh-ng://builder@192.168.50.249:31022 --option ssh-key /etc/ssh/ssh_host_ed25519_key` as root answers),
  or `build-all --system aarch64-linux`. The post-build hook that pushes to attic does not cover these builds (they run in the VM's
  daemon, which has no hook): pushing aarch64 results to attic (now on chinchilla) is a manual step.

## Secrets

`secrets/sops/default.yaml` (RKE2 token, cluster tailnet key, attic token) is decrypted on a node by the shared `server` age identity
that nixos-anywhere places at `/root/.config/sops/age/keys.txt`, and, for desktop nodes, by the host's own ssh host key. So each
desktop node is also a recipient in `.sops.yaml` (`&falcon`, `&axolotl`, from `ssh-keyscan <host> | ssh-to-age`) and needs
`sops updatekeys secrets/sops/default.yaml` after any change to that list. The ssh host key therefore has to survive a reinstall;
if it does not, redo the anchor, `updatekeys` both sops files, and `hostKey` in `static/builders.nix`.

## Adding a host

1. Host file with the layers above; `networking.hostName`, `networking.hostId` (8 hex digits, kept for the life of the pool), the
   root disk by `/dev/disk/by-id`, `static/facter/<host>.json` (nixos-facter).
2. Desktop on the home LAN: `desktopNode.lanLink` matching the wired NIC by driver or MAC. A Wi-Fi-only box cannot be a node
   (cilium's `devices` lists `br0 eno1 eth0`).
3. A host that should build for the fleet: a record in `static/builders.nix`. Its `hostKey` is also its client identity towards peers.
4. If it needs `default.yaml`: its age anchor in `.sops.yaml`, then `sops updatekeys` (needs an existing recipient's key).
5. Headless Linux VM on a Mac (`muffin` on morgenmuffel, `static/muffin.nix` + `static/muffin-vm.nix`): not installed, run. The
   NixOS side is `k8s-node.nix` + `server.nix` + `foreign-boot.nix` + nixpkgs' `qemu-vm.nix` (kernel and initrd straight from the
   toplevel, an erofs `/nix/store` image built at start, one sparse qcow2 root disk), the Mac side a root launchd daemon, so
   `darwin-rebuild switch` on the Mac deploys it (the daemon restarts on a new closure). The guest's ssh host key is generated on
   the Mac (`/var/lib/muffin-vm/identity`), shared in over 9p, and is both sshd's key and its sops identity (`&muffin`). The NIC is
   `vmnet-bridged` on the Mac's `en0` (works over Wi-Fi) with a fixed MAC, so it is an ordinary LAN node (`eth0`, in cilium's
   device list); reserve that MAC on the router. See "Muffin" below.

## Reinstalling a desktop node onto the standard layout

Applies to falcon first (axolotl identically). It wipes the host's root disk. Only the root disk is in disko, so a second disk (falcon's
`data` pool) is never touched. Run by hand; pulumi never does this on its own.

**Do not kexec these two.** Both have an onboard Intel I219 (`e1000e`) that does not come back after a kexec: the installer boots
with no link and the host needs a power-button reset (axolotl, twice). What worked (both installed this way, 2026-10-14):

1. Build on a native x86 host (falcon, with the nodes as `--builders`): `system.build.toplevel` and `system.build.diskoScript`
   of the host, plus `inputs.nixos-anywhere`. axolotl's build needs the DisplayLink zip in that store (docs/displaylink.md).
2. Copy the nixos-images kexec tarball's `kexec/` directory (bzImage, initrd, run) to `/root/installer/kexec` on the host and run
   `static/installer-oneshot.sh` as root: it puts the installer on the ESP as a systemd-boot entry with the same payload kexec
   would add (authorized keys, host keys, network state) and arms it with `bootctl set-oneshot`. Reboot: the NIC gets a cold
   start and the installer comes up on the host's usual address. The ESP needs ~350M free (prune old generation entries).
3. From another LAN host holding the closures: `nixos-anywhere --store-paths <diskoScript> <toplevel> --extra-files <dir>
   --phases disko,install,reboot root@<host>`, where `<dir>` holds `root/.config/sops/age/keys.txt` (the `server` identity)
   and the host's `etc/ssh/ssh_host_ed25519_key{,.pub}` (dirs 755 except `root/`, keys 600).
4. After the first boot, set the login password (`passwd`): users are mutable and none is declared.

The pulumi path below still kexecs and builds on the target (`--build-on remote`); it fits headless nodes, not these two.

Before:

1. Everything wanted from the root pool is somewhere else (falcon: `/home` 242G and `/` 641G on a 90%-full pool; axolotl: little).
   `data` is untouched but is the only copy of the rips until they are in the cluster: check `zpool status data`.
2. `nix eval --json .#nixosConfigurations.<host>.config.disko.devices.disk` lists only `root` (never the data disk).
3. The cluster is reachable (sirver, hyena for headscale, attic), and the host is a recipient of `default.yaml`
   (its `age1...` is in the file's `sops:` block).
4. In the host file, remove `disko.legacyLayout = true;` and merge that change.

Install:

```sh
cd pulumi
pulumi config set falconNode true        # axolotl: axolotlNode
NIXOS_ANYWHERE_INSTALL=falcon pulumi up --target <urn of nixos-falcon-install>
```

The install step runs nixos-anywhere against `tristan@192.168.50.215` (sudo kexec; it reconnects as root once the installer is up).
It copies the `server` age identity and the host's existing ssh host key into the new system (`--extra-files`), partitions the
root disk with `modules/disko.nix`, installs, and reboots. `NIXOS_ANYWHERE_INSTALL` must name the host or the step refuses to
run; leave the config flag set afterwards so the protected resource stays in the program.

After:

- `data` is imported by `boot.zfs.extraPools` (same hostId, no `-f`) and mounted; missing datasets (`data/media`, `data/scratch`,
  `data/backup`) are created by the import service, before any `/data` mount. `zfs list -r data`, `findmnt /data`.
- `kubectl get node falcon` (NotReady until Cilium schedules on it), `systemctl --failed`, `tailscale status` (now as a cluster node).
- falcon only: `nvidia.com/gpu` appears on the node once the gpu-operator pods run (README todo 27).

## Rolling the fleet to a new nixpkgs

Done 2026-10-16 (00:30 to 03:00 PDT): chinchilla, bonobo, dingo and octopus moved to nixos 26.11.20261008.e7439b6 with rke2 v1.34.11.
sirver stays on 26.05 / rke2 1.34.7 until its root disk is replaced (README 24, 33). No node was rebooted, so kernel 7.2.9 loads at each
node's next boot (the OSD hosts need a forced reboot).

Order: agents first, then servers (chinchilla, bonobo, dingo, octopus), one node at a time. Per node:

1. On falcon build the toplevel `T` (`nix build .#nixosConfigurations.<n>.config.system.build.toplevel`).
2. Check the cluster: etcd 3/3, all nodes Ready, ceph state. Point your kubeconfig at a server that is NOT the one being switched.
3. For a server, move the etcd leader off it first (`etcdctl --endpoints https://<leader>:2379 move-leader <id>` from the etcd-dingo
   pod); the member rejoins within seconds after the switch.
4. Containerd dataset (agents and dingo; see the next section): `seed` with rke2 running, then `cutover`.
5. As root on falcon: `nix copy --no-check-sigs --to 'ssh-ng://nix-remote-builder@<lan ip>?ssh-key=/etc/ssh/ssh_host_ed25519_key' T`.
   Do this right before step 6 (gotcha 1).
6. On the node: `nix store diff-closures` and `T/bin/switch-to-configuration dry-activate`, then `nix-env -p /nix/var/nix/profiles/system --set T`
   and `systemd-run --unit=nixos-switch --collect T/bin/switch-to-configuration switch`. Detached, because sshd restarts mid-switch.
7. Verify: `systemctl --failed`, node Ready, etcd 3/3 (`etcdctl endpoint status --cluster` in the `etcd-NODE` pod), pods back.
   Then `containerd-zfs-migrate.sh cleanup`.

Gotchas:

1. The node's `nix-collect-garbage` deletes a pre-copied toplevel that is not in a profile. Copy right before `nix-env --set`: it
   bit bonobo (cutover done, rke2 stopped, then the path was gone).
2. `seed` refuses when the pool has less than 120% of the containerd dir free (`du` counts `copies=2` double). `crictl rmi --prune` and a
   nix GC on the node made room on bonobo and dingo.
3. After the restart the pods on the node take 5 to 15 minutes to come back: cilium-agent rate-limits endpoint creation
   (`putEndpointIdTooManyRequests`, 429) and the kubelet backs off exponentially. The node is Ready long before its pods are.
4. octopus is an OSD host: its 7 OSDs were down for about 90 s, Ceph showed 50% degraded then recovered without backfill, well inside
   `mon_osd_down_out_interval`.
5. octopus's containerd migration was deferred: an HDD rsync of an unmeasured directory while it hosts etcd is the known flap trigger.
   Do it with the leader moved off it and `ionice -c3`, measured first (README 55).
6. `home-manager-tristan.service` failed on dingo after the switch: `~/.config/Kvantum/Base16Kvantum` exists as a directory from an
   older generation, so `ln` fails. Cosmetic.
7. `users.users.<person>.shell = pkgs.zsh` (with `programs.zsh.enable`, `modules/users.nix`) matches the zsh that home-manager configures.
   It was added after the roll, so it takes effect at each node's next deploy.
8. attic moved to chinchilla (#978) with the original cache keypair: the sirver storage copy stalled on the failing disk, so only
   `server.db` was taken, its nar/chunk/object index tables emptied (`DELETE FROM chunkref, nar, object, chunk; VACUUM`) and the file
   installed under `/var/lib/private/atticd` (owner 65534:65534, the DynamicUser). The cache starts empty but `trusted-public-keys`
   stays valid (`nix store verify --trusted-public-keys` on bonobo). The Macs and nodes still pointing at `sirver:8199` switch over
   with their next deploy or darwin-rebuild.

## Migrating a live node to the containerd dataset

`root/local/containerd` (`sync=disabled`, `copies=1`, legacy mount at `/var/lib/rancher/rke2/agent/containerd`) is declared in
`static/k8s-node.nix`, so reinstalls get it from disko. disko does not run on live nodes, and the switch that adds the fileSystems
entry is `nofail` (an unmigrated node keeps running on the old directory, silently), so run `static/containerd-zfs-migrate.sh` as root
on each node BEFORE its switch. One node at a time, never while another server is down (sirver stays out until its disk is replaced). Migrated 2026-10-16: chinchilla, bonobo, dingo. Pending: octopus (README 55) and sirver (at its reinstall):

1. etcd 3/3, all nodes Ready, ceph known state. `seed` (rke2 running; copies the layers into the new dataset, about the size of
   `du -sh /var/lib/rancher/rke2/agent/containerd`, 50-80 GB; the script refuses if the pool lacks 120% of that).
2. `cutover` (stops rke2, `rke2-killall.sh`, final rsync, old dir moved to `containerd.premigration`, dataset mounted).
3. Switch the node (runbook), then `systemctl is-active rke2-server rke2-agent`, starting the unit if the switch left it stopped.
4. Verify: `findmnt /var/lib/rancher/rke2/agent/containerd`, `zfs get sync,copies root/local/containerd`, node Ready, pods Running.
5. `cleanup` once satisfied (deletes `containerd.premigration`, freeing its `copies=2` space). `rollback` undoes step 2 before it.

## Running containerd as its own unit (`externalContainerd`)

By default rke2 runs its embedded containerd as its own child: an rke2 crash kills containerd and orphans every shim, and static pods
(etcd) block on log pipes nobody reads (`static/etcd-watchdog.nix` drains only etcd's). `externalContainerd.enable = true` on a node
(set it in that node's block in `flake.nix`; default off everywhere, so merging the module changes no node) runs the NixOS
`containerd.service` instead, configured like rke2's, and points rke2 at it. Shims and containers then survive rke2 restarts and crashes.

What the flag sets (`static/containerd-external.nix`, ported from the config.toml rke2 1.34.11 generates on chinchilla and falcon):

- rke2 `container-runtime-endpoint: unix:///run/k3s/containerd/containerd.sock` in `/etc/rancher/rke2/config.yaml`. rke2 then does not
  start its own containerd. The socket path is the old embedded one, so `crictl` (`/var/lib/rancher/rke2/agent/etc/crictl.yaml`) and
  anything that mounts the socket keep working; the alternative (a new socket plus `container-runtime-endpoint`) would have worked
  the same and changed every consumer.
- containerd config version 3, root `/var/lib/rancher/rke2/agent/containerd` (the ZFS dataset: images and snapshots are reused),
  state `/run/k3s/containerd`, overlayfs snapshotter, runc with `SystemdCgroup`, `use_local_image_pull`, stream server on
  `127.0.0.1:10010`, pause image `index.docker.io/rancher/mirrored-pause:3.10.2` (what rke2 1.34.11 uses; the task text said 3.6, the
  live config says 3.10.2). CNI is containerd's default: binaries in `/opt/cni/bin` (multus installs them), config in `/etc/cni/net.d`.
- `nvidia` and `nvidia-cdi` runtimes (`BinaryName` in the toolkit's `tools` output) on hosts with `hardware.nvidia-container-toolkit`
  (falcon): the same handlers rke2 generates today when it finds `nvidia-container-runtime` on its PATH.
- Registry mirrors: none are configured live (no `registries.yaml`), Harbor resolves through `networking.hosts`, which containerd shares.
  Mirrors, when needed, go in `virtualisation.containerd.settings` (`registry.config_path` plus `hosts.toml` files).
- Not carried over: the Windows `runhcs-wcow-process` runtime, and rke2's `certs.d` registry path (nothing is in it).
- `LimitNOFILE=1048576` on the unit, rke2's value: containers inherit the runtime's limit.
- `containerd.service` is ordered before rke2 and wanted by it, and has `restartIfChanged = false`: a switch never restarts it
  (containerd restarts keep running pods: shims reconnect), you restart it on purpose. Ordering is declared on the containerd side so
  that enabling the flag does not change rke2's unit.
- Two build-time assertions pin what the port was done for: rke2 1.34 and containerd 2.x. A bump fails the toplevel of a flagged node
  until the port is re-read. On every rke2 bump: re-read the config rke2 generates (pause image, runtime options, new defaults;
  `containerd -c <live> config dump` against the unit's dump should differ only in `imports`, `registry.config_path` and the Windows
  runtime) and check that nixpkgs' containerd still meets the new kubelet's CRI requirement (each Kubernetes release lists the minimum
  containerd version; embedded rke2 1.34.11 ships 2.2.7-k3s1, nixpkgs has 2.4.1).

Migrating a node (untested on a live node; agents first, then dingo and octopus one at a time with etcd 3/3 between, sirver at its
reinstall). Drain is not needed: the pods restart in place, which is what any rke2 restart after `rke2-killall.sh` already does.

1. Gates as in the roll: etcd 3/3, all nodes Ready, ceph known state, kubeconfig on a server that is not this one. For dingo/octopus
   move the etcd leader off first. Do the containerd dataset migration first if the node is not on it yet (octopus).
2. Set `externalContainerd.enable = true` for the node, build the toplevel on falcon, copy it right before the switch (roll gotcha 1).
3. Switch with rke2 running. The flag is inert for running processes: `config.yaml` is read at rke2's start and `containerd.service`
   is not restarted. `dry-activate` must not list `rke2-*` among the units to restart; abort if it does. Afterwards
   `grep container-runtime-endpoint /etc/rancher/rke2/config.yaml` shows the endpoint and `systemctl is-active containerd` is still the
   old unused instance.
4. Cut over (this node's pods go down for 5 to 15 minutes, roll gotcha 3):
   `systemctl stop rke2-<role>` (the embedded containerd dies with it, its shims stay), then `rke2-killall.sh` (kills those shims and
   unmounts `/run/k3s`; this is the last time it is valid on this node), `pgrep -a containerd-shim` empty, then
   `systemctl restart containerd` (new config, same root dir) and `crictl images | wc -l` (the old image count), then
   `systemctl start rke2-<role>`.
5. Verify: `ps -o ppid= -p $(pgrep -x containerd)` is 1, not rke2; `journalctl -u rke2-<role>` shows no embedded containerd start;
   node Ready; static pods on a server Running; etcd 3/3; a pod on falcon with `runtimeClassName: nvidia` runs. Then
   `systemctl restart rke2-<role>` once and check pods and shims stay up (`pgrep -a containerd-shim | wc -l` unchanged): that is the
   point of the change.
6. Logs move: `journalctl -u containerd` replaces `/var/lib/rancher/rke2/agent/containerd/containerd.log`.

On a flagged node never run `rke2-killall.sh` or `containerd-zfs-migrate.sh cutover` (the script refuses): killall finds shims by rke2's
data dir path, misses nixpkgs' shims, and unmounts `/run/k3s` under a running containerd. To wipe a node's pods reboot it.

Rollback per node: flag off, then `systemctl stop rke2-<role> containerd`, `pkill -9 -f containerd-shim-runc-v2`, `rke2-killall.sh`
(nothing is running now, so it is safe), switch to the flag-off toplevel (containerd.service goes back to the unused defaults,
`config.yaml` loses the endpoint), `systemctl start rke2-<role>` (rke2 starts its embedded containerd on the same root dir).

Not verified: all of the above on a live node. In particular that rke2 1.34.11 starts cleanly against the external endpoint (its
`--container-runtime-endpoint` help text: "Disable embedded containerd and use the CRI socket at the given path"), that kubelet picks the
systemd cgroup driver from the CRI as it does today, that the GPU operator validator passes with `nvidia` served by this unit,
and that a switch does not restart rke2 (step 3).

## Next node roll: externalContainerd, pod routes, remediation prep

Repo side is merged and inert until a node is deployed; this is what the coordinator runs, one node at a time (README 6, 7, 9, 47, 55).
What a deploy of each node now carries (all verified by building the toplevels on falcon, 2026-10-16):

| Change | Nodes | Takes effect |
| --- | --- | --- |
| `tailnet.podRoutes = false` (`static/k8s-node.nix`) | every node | at the switch: `tailnet-pod-routes` is a oneshot whose script changed, so the switch reruns it and it withdraws the advertisement and the `10.0.0.0/8` route |
| `externalContainerd.enable` (`flake.nix`) | chinchilla, bonobo | only at the cutover below; the switch writes `container-runtime-endpoint` into `config.yaml`, which rke2 reads at its next start |
| `static/node-remediation.nix`: `/bin/bash`, `iTCO_wdt` loaded, systemd pinned to `/dev/watchdog0` | chinchilla, bonobo (`nodeRemediation.eligible`) | at the switch (`systemd-tmpfiles-resetup`); the pin equals what systemd already uses |
| node label `remediation.medik8s.io/exclude-from-remediation=true` | every other node: sirver, octopus, dingo, falcon, axolotl, muffin | at the next **rke2 restart** (kubelet reads `node-label` at start) |
| `node-monitor-grace-period=2m` and the 600 s not-ready/unreachable tolerations (README 47) | servers: dingo, octopus (sirver at its reinstall) | at the next rke2-server restart |

**A switch alone does not restart rke2.** The `rke2-server`/`rke2-agent` unit files in the new toplevels are byte-identical to the ones running on
octopus and bonobo (diffed 2026-10-16), and NixOS only restarts a unit whose file changed. So config.yaml changes (labels, grace period,
container-runtime-endpoint) wait for a restart, which each node below does on purpose. Check `dry-activate` anyway: abort the node if it
lists `rke2-*` among the units to restart.

### Gates, before and after every node

```sh
export KUBECONFIG=...   # fetched from a server that is NOT the one being switched
kubectl get nodes -o wide                                      # all Ready
kubectl get cephcluster -A                                     # HEALTH_OK
etcdctl() { local t=/var/lib/rancher/rke2/server/tls/etcd; kubectl -n kube-system exec etcd-$POD -- etcdctl \
  --endpoints=https://127.0.0.1:2379 --cacert=$t/server-ca.crt --cert=$t/server-client.crt --key=$t/server-client.key "$@"; }
POD=dingo etcdctl endpoint status --cluster -w table           # 3 rows, one leader, ERRORS empty
```

(The etcd image has no shell: the flags go on `etcdctl` itself. Run it from a pod of a server that is not being switched. Verified read-only on
2026-10-16: leader dingo `aa1b465deb84b6ad`, octopus `f4e927b319bde64`, sirver `2f50e46c20143168`.) sirver's disk is failing: a server switch is
only safe while all three members answer, so re-read the table immediately before each server step.

### Order

Per node: steps 1, 2, 5, 6 and 7 of "Rolling the fleet to a new nixpkgs" (build, gates, copy, detached switch, verify) plus the node-specific steps here.

1. **axolotl**, then **falcon** (desktop agents; first nodes to lose their pod routes). After the switch: `ip route show 10.0.0.0/8` empty,
   `tailscale debug prefs | jq .AdvertiseRoutes` null, `headscale nodes list-routes` on hyena no longer lists the node. Then `systemctl restart rke2-agent` for the label (its pods restart, 5 to 15 minutes; falcon: no dvdrip Job
   running first, `kubectl get jobs -A`), and `kubectl get node <n> --show-labels | grep exclude-from-remediation`. Rollback: `podRoutes = true` and redeploy.
2. **chinchilla**, then **bonobo** (agents, flagged; one at a time so one gateway relay stays up). Containerd dataset first, already done:
   `findmnt /var/lib/rancher/rke2/agent/containerd` shows `root/local/containerd` (read 2026-10-16 on both). Then:
   - switch; verify `ls -l /bin/bash`, `cat /sys/class/watchdog/watchdog1/{identity,state}` (`iTCO_wdt`, inactive), `ip route show 10.0.0.0/8` empty,
     `grep container-runtime-endpoint /etc/rancher/rke2/config.yaml`. **Do not restart rke2 between this switch and the cutover**: rke2 would find
     no CRI at the configured socket until `containerd.service` is restarted;
   - the cutover and verification of "Running containerd as its own unit", steps 4 to 6 (stop rke2, `rke2-killall.sh`, restart `containerd`,
     start rke2; then check the parent of containerd is PID 1 and one more `systemctl restart rke2-agent` leaves the shims up);
   - gates, then the next node. Rollback: the "Rollback per node" paragraph above.
3. **dingo** (etcd server, no flag yet: set `externalContainerd.enable` for it in a later roll, after chinchilla and bonobo have run clean).
   Gates; if dingo is the etcd leader, move it first (below); switch; then `systemctl restart rke2-server` (grace period, tolerations, label);
   wait for etcd 3/3 and the node Ready, 5 to 15 minutes for the pods.
4. **octopus**, last: containerd dataset migration and the same server steps (next subsection).
5. **sirver**: not rolled (26.05, failing disk). It has no SNR agent as long as the SNR config excludes control-plane nodes; if a DaemonSet pod
   still lands there once medik8s is re-landed, label it once by hand (`kubectl label node sirver remediation.medik8s.io/exclude-from-remediation=true`);
   its reinstall carries the label from config.
6. **hyena**, after every node above: `tailnet.podRoutes = false` in its profile (`flake.nix`) so headscale stops auto-approving `10.0.0.0/8`
   (`static/hyena.nix` keys the approver off the same option). Rollback order is the reverse (docs/tailscale-integration.md, "Pod routes").

### Moving the etcd leader off a node

Only the leader accepts `move-leader`, so run it in the leader's own pod against its own endpoint, and name a healthy member as target, never sirver:

```sh
POD=octopus etcdctl endpoint status -w table                  # IS LEADER true on this node?
POD=octopus etcdctl move-leader aa1b465deb84b6ad              # target: dingo's member ID (re-read `member list` first)
POD=dingo etcdctl endpoint status --cluster -w table          # leader is now the target; RAFT TERM went up by one
```

`move-leader` itself was not run while preparing this (only `endpoint status` and `member list` were, read-only, through this exact pod invocation).
It changes the leader without a restart; if it errors with "not leader", the leadership already moved: re-read the table.

### octopus: containerd dataset (README 55)

octopus is on `root/safe/var/lib` (no `root/local/containerd`), an HDD pool that also hosts etcd, so the rsync is the known flap trigger.
Nothing below has been run on octopus (a stray `du -sh` over its containerd dir during preparation already showed how slow the tree walk is; it was killed).

1. Gates, and the etcd leader is NOT octopus (move it, previous subsection). Keep `POD=dingo etcdctl endpoint status --cluster` and
   `kubectl -n kube-system logs etcd-octopus --since=2m | grep -c "took too long"` open in a second terminal for the whole copy.
2. Measure without walking the tree on the HDD: `crictl imagefsinfo` (usedBytes of the image filesystem; not tried here) and `zfs list -Hpo avail root`;
   the script needs 120% of the directory free (its `du` counts `copies=2` double, so expect about twice `usedBytes`). If it is short:
   `crictl rmi --prune` and a nix GC (roll gotcha 2).
3. Copy the script over and seed with the lowest IO class, rke2 still running:
   `ionice -c3 nice -n 19 ./containerd-zfs-migrate.sh seed` (the script's own `du` inherits the class). If `took too long` counts climb or etcd
   latency alarms, `Ctrl-C` the rsync: a partial copy stays in the new dataset and `seed` resumes it later.
4. Switch octopus (the standard server steps above), then `ionice -c3 ./containerd-zfs-migrate.sh cutover` (stops rke2-server; 2 of 3 etcd
   members stay up, so the leader must already be elsewhere), `systemctl start rke2-server`, verify as in "Migrating a live node to the containerd
   dataset", then `cleanup` once satisfied. `rollback` undoes the cutover before cleanup.
5. After it: README 48 (siyuan/shoko workarounds) can be removed.

## Node remediation

`nixidy/system/cluster/medik8s.nix` runs medik8s Node Health Check (NHC) and Self Node Remediation (SNR) in the `medik8s` namespace
(apps `node-healthcheck-operator`, `self-node-remediation`, CRDs in `medik8s-crds`). When a selected node's `Ready` condition stays
`False` or `Unknown` for 15 minutes, NHC creates a `SelfNodeRemediation` from the `out-of-service` template: the node's SNR agent
reboots it through the hardware watchdog, and the operator then sets the `node.kubernetes.io/out-of-service` taint so its pods are
force-deleted and their RBD volumes detach and move.

- **Selected**: the agents only (bonobo, chinchilla): no `node-role.kubernetes.io/control-plane` label and `node.trdos.me/class` not
  `desktop`. The SNR agent DaemonSet gets the same requirements, AND-ed with the operator's own `remediation.medik8s.io/exclude-from-remediation NotIn true`
  (read in the operator source, v0.13.0, `updateDsNodeSelectors`). The first landing (#958) still saw agent pods on every node, so the node label is the
  second guard: `static/node-remediation.nix` sets it on every node that is not `nodeRemediation.eligible`.
- **Never touched**: sirver, octopus, dingo (a reboot there is an etcd and OSD event to plan: sirver's disk is failing, octopus hangs on
  a graceful reboot) and the desktops falcon and axolotl (they sleep and reboot at will, which would read as unhealthy).
- **One at a time**: `minHealthy: 1` of the two selected nodes; with one already remediating, the other is never started.
- **15 minutes**: well above the 4-minute `Unknown` that octopus' etcd flaps caused on 2026-10-11.
- **Signals**: Alertmanager `NodeRemediationInProgress` (warning, via ntfy) and `NodeRemediationStuck`; `kubectl get nodehealthcheck,selfnoderemediation -A`.
- **Pause** (running remediations continue): add an entry to `spec.pauseRequests` of NodeHealthCheck `agents` in `medik8s.nix` and merge. The
  apps self-heal, so a `kubectl edit` of the CR is reverted.
- **Remove**: delete the app files; ArgoCD prunes the three apps. The webhooks fail open, so a CR delete never waits on them.

### Node config the agent needs (`static/node-remediation.nix`)

- **Watchdog**: systemd holds `/dev/watchdog0` (`intel_oc_wdt` on bonobo and chinchilla; `WatchdogDevice=/dev/watchdog0`, `RuntimeWatchdogSec=15s`
  as before), and the SNR config's `watchdogFilePath` is `/dev/watchdog1` (`iTCO_wdt`, 30 s). The two paths are fixed, so they never collide
  whichever driver registers first. Opening `/dev/watchdog` itself would fail with EBUSY.
- **Software fallback**: the agent runs `nsenter -m/proc/1/ns/mnt /bin/bash -c 'echo b > /proc/sysrq-trigger'`; a tmpfiles rule links `/bin/bash`.
- **Excluded nodes** carry `remediation.medik8s.io/exclude-from-remediation=true` through rke2's `node-label`, applied at the node's next rke2 restart.
  sirver (not rolled) is kept out by the control-plane requirement; if an agent pod still lands there, `kubectl label node sirver remediation.medik8s.io/exclude-from-remediation=true` once.

### Staged: NHC is paused

The NodeHealthCheck ships with a `pauseRequests` entry, so nothing is remediated. This change was held (#962) until every node had the config above, deployed
and rke2 restarted (docs/node-standard.md "Next node roll"). Before merging it, check:

```sh
kubectl get nodes -L remediation.medik8s.io/exclude-from-remediation   # true on octopus, dingo, falcon, axolotl; empty on bonobo, chinchilla
ssh bonobo 'ls -l /bin/bash; cat /sys/class/watchdog/watchdog1/identity; systemctl show -p WatchdogDevice'   # same on chinchilla
```

After the merge: `kubectl -n medik8s get ds,pods -o wide` shows agent pods only on bonobo and chinchilla and `kubectl get nhc` shows `Paused`. Then the drill,
one node, with etcd 3/3 and Ceph HEALTH_OK:

1. Unpause (delete the `pauseRequests` entry) and merge.
2. On bonobo (or chinchilla): `systemctl stop rke2-agent` plus a network cut for over 15 minutes. An armed watchdog resets a node whose agent stalls for 30 s: that is the design.
3. Expect `NodeRemediationInProgress`, a reboot, the out-of-service taint, pods rescheduled, and the taint removed when the node is Ready again.
4. If it does not behave, re-add the `pauseRequests` entry.

## Not verified

- No node has been installed through this path; the pulumi step was only rendered and syntax-checked, never run.
- Whether rke2 picks up `nvidia-container-runtime` from the service PATH on NixOS, and whether the gpu-operator validator passes
  with the driver and toolkit disabled.
- Boot ordering of the `data` pool import, dataset creation and the `/data/*` mounts on real hardware.
- Cilium devices on the renamed `eno1`, and L2 announcements from a desktop.

## Muffin (aarch64 VM on morgenmuffel)

An RKE2 agent labelled `node.trdos.me/class=vm` with a `PreferNoSchedule` taint (like the desktops), 8 GB RAM and 4 vCPUs, sized for a
16 GB Mac (qemu does not return guest page cache, so expect it to hold all 8 GB). Its logs: `/var/lib/muffin-vm/console.log` on the Mac.

- Deploy: `darwin-rebuild switch --flake .#morgenmuffel` on morgenmuffel (the VM hard-stops and restarts; drain first if it matters).
  A system daemon, not a home-manager agent, so it works from an ssh session.
- Reset the node: stop the daemon, delete `/var/lib/muffin-vm/muffin.qcow2`, start it (`kubectl delete node muffin` first).
- First run on a Mac without `/var/lib/muffin-vm/identity`: the daemon generates the key, the guest cannot decrypt anything yet.
  Add `ssh-to-age < identity/ssh_host_ed25519_key.pub` to `.sops.yaml` (`&muffin`, `default.yaml`), `sops updatekeys`, rebuild.
- arm64 images: the node ran the existing DaemonSets with two exceptions. `ghcr.io/angelnu/cni-plugins` (multus's installer) ships
  x86-64 plugin binaries in its arm64 image, worked around on the node (containerd `bin_dirs`, `static/muffin.nix`); smartctl-exporter
  v0.14.0 is amd64-only and is excluded from VMs (`nixidy/system/observability/smartctl-exporter.nix`).
- GPU: none. The only documented path to the Apple GPU from a Linux guest is krunkit/libkrun's Venus virtio-gpu (Vulkan over
  MoltenVK, per Lima's krunkit docs); Apple documents Virtualization.framework's Linux graphics device only as a display scanout
  (no 3D found), and qemu's hvf path has no 3D here. Vulkan is not CUDA and nothing in the cluster (NVIDIA operator, device
  plugins) schedules it, so the VM is CPU-only. Not tried.

## Provisioned host keys (piper, echidna, gargoyle)

Hosts that are off or not built yet cannot be asked for their ssh host key, so theirs were generated in advance. The public halves
are the `&piper`, `&echidna` and `&gargoyle` age anchors in `.sops.yaml` (`personal.yaml`: echidna and gargoyle, the tailnet key;
`default.yaml`: piper, the cluster secrets), the private halves are in `secrets/sops/hostkeys.yaml` (tristan only). Install the key
on the host and the host decrypts its secrets from the first boot, no `updatekeys` round trip:

- running host: `static/host-key.sh ssh <host> <user@address>` (then deploy: `deploy '.#<host>'`);
- piper's SD image: `static/host-key.sh image piper <raw image>` before flashing (below).

A host that already has its own key (gargoyle, echidna) can keep it instead: `ssh-keyscan -t ed25519 <host> | ssh-to-age`, replace
the anchor, `sops updatekeys` both files.
