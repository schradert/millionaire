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
  After the Mac's `darwin-rebuild` (the VM restarts with the new key list, done 2026-10-16) and falcon's switch, verify on falcon:
  `nix build --system aarch64-linux --no-link <a derivation cache.nixos.org does not have> -L` (the log shows `building ... on 'ssh-ng://builder@192.168.50.52:31022'`;
  `nix store info --store 'ssh-ng://builder@192.168.50.52:31022?ssh-key=/etc/ssh/ssh_host_ed25519_key'` as root answers: the key is a store parameter, `--option ssh-key` is ignored),
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
sirver stays on 26.05 / rke2 1.34.7 until its root disk is replaced (README 24, 33). That roll rebooted nothing; the second roll the same
day ("Next node roll", below) rebooted chinchilla and bonobo onto kernel 7.2.9. dingo, octopus and sirver still run 7.0.10 (a server reboot
is an etcd event, and the OSD hosts octopus and sirver a Ceph one: not done).

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

Done 2026-10-16 (10:26 to 15:30 PDT), by hand with the steps below (build on falcon, `nix copy`, detached switch), not through pulumi: its
state still records the older toplevels, so the next `pulumi up` redeploys each node once (a no-op activation, README 43). Built from main at
96529bf plus #1063 (the DHCP request address, "What the roll found"); hyena from #1064. What is live per node (all read on the nodes afterwards):

| Node | nixpkgs / rke2 | Kernel running | `externalContainerd` | `podRoutes` | Remediation | Rebooted | Switch |
| --- | --- | --- | --- | --- | --- | --- | --- |
| sirver | 26.05 / 1.34.7 | 7.0.10 | off | still advertises 10.0.0.0/24 (headscale approval cleared) | no label: the SNR DaemonSet's control-plane requirement keeps its agent off (none landed) | no | not rolled |
| octopus | 26.11 / 1.34.11 | 7.0.10 | off | false | label `exclude-from-remediation=true` | no | 39 s |
| dingo | 26.11 / 1.34.11 | 7.0.10 | off | false | label | no | 18 s |
| chinchilla | 26.11 / 1.34.11 | 7.2.9 | on | false | eligible: `/bin/bash`, watchdog1 (`iTCO_wdt`) armed by the agent, no label | 11:04 | 5 s |
| bonobo | 26.11 / 1.34.11 | 7.2.9 | on | false | eligible, same | 11:44 | 6 s |
| falcon | 26.11 / 1.34.11 | 7.2.9 (installed on it) | off | false | label | no (kernel already current) | 101 s |
| axolotl | 26.11 / 1.34.11 | 7.2.9 (installed on it) | off | false | label | no (same) | 2 min |
| hyena | 26.11 | n/a | n/a | approver off (#1064) | n/a | no | 9 s |

muffin is not rolled (a Mac VM, restarted by `darwin-rebuild`): it still advertises 10.0.7.0/24 (approval cleared). headscale: no approved
10.0.x.0/24 route remains, `autoApprovers.routes` is empty; `trdos-check` and a `curl` through both relays (`100.64.0.4`, `.5`) pass.
The nodes' `config.yaml` carries the exclude label (dingo, octopus, falcon, axolotl), `node-monitor-grace-period=2m` and the 600 s tolerations
(dingo, octopus); `container-runtime-endpoint` (chinchilla, bonobo). `systemd-networkd` requests the pool address (#1063).

Measured:

- Agent reboot, drained: chinchilla 11:04:27, answering ssh about 35 s later, kubelet heartbeating at about +75 s; bonobo ssh at +45 s, kubelet at about +90 s.
- `rke2-agent` restart with the embedded containerd (axolotl, falcon): the label was on the node 27 s later; falcon's pods were all Running when checked 6 minutes later
  (whether they ever stopped was not measured: see the `rke2-server` line).
- Cutover to the external containerd: 8 s (chinchilla), 9 s (bonobo) from `systemctl stop` to `start`; the node's daemonset pods were back in about 2 minutes; then
  `systemctl restart rke2-agent` left the same 12 shim PIDs running (hash of the `pgrep containerd-shim` list unchanged) on both, node Ready within 25 s.
- `rke2-server` restart with the embedded containerd (dingo, octopus): Ready and etcd 3/3 in about a minute, and the pods did not restart: dingo showed 73 Running pods
  and 74 shims a minute later, octopus 110 Running and 112 shims, and octopus' 13 OSDs read `up (since 11h)` (a restarted OSD resets that). Presumably rke2's
  `KillMode=process` leaves the shims running and the new containerd re-attaches (the unit was not read). The 5 to 15 minutes of the old roll came after
  `rke2-killall.sh` (the cutover), where everything is recreated.
- Drain: chinchilla 96 s (11 CNPG primaries had moved by themselves, below); bonobo 3 minutes, then 3 more for five single-instance Postgres pods.
- Etcd leader moves (`move-leader`, first real run): dingo to octopus, later octopus to dingo; each took effect at once and the table read 3 healthy members.

What the roll found:

1. **A cold boot does not keep the DHCP address.** chinchilla came back as 192.168.50.161 instead of .85. Observed: a plain discover got .161 whether the client id was the
   DUID or the MAC, one asking for .85 (`RequestAddress`) got it; why the router lost the binding is not known. Everything keyed to `lan` in `static/builders.nix` (peer
   names in `/etc/hosts`, rke2 join, attic, etcd peer URLs) pointed at nothing, and Ceph mon-c could not rejoin: Rook failed it over onto falcon (`mon: a,d,e`). #1074 keeps mon, mgr, mds and rgw off nodes with a `node.trdos.me/class` label (`placement` in `rook-ceph.nix`); the operator left mon-e Pending, waited its 10 min failover timeout twice (the second because the pod was unscheduled), then created mon-f on sirver (`mon: a,d,f`, HEALTH_OK). Nothing needed doing by hand. A mon on sirver is unwanted (the mon store is hostPath `/var/lib/rook` on its failing root disk), so the mon placement also excludes `kubernetes.io/hostname=sirver` until the disk is replaced (README todo 33; delete the expression then). #1082 rolled it out: Rook restarted mon-a and mon-d one at a time, left the new mon-f pod Pending, waited its 10 min timeout twice (17:25 and 17:36 PDT) and created mon-g on bonobo at 17:48 (`mon: a,d,g`, 13/13 OSDs up, HEALTH_OK); nothing was restarted or deleted by hand.
   Fixed in #1063: `RequestAddress=<lan>` on `40-eno1` (chinchilla, bonobo, dingo, octopus; sirver has a bridge). bonobo rebooted with it and kept .142; `networkctl reconfigure eno1`
   on chinchilla (a fresh discover) re-acquired .85 from the declared config. dingo and octopus carry it but were not rebooted. A server reboot without it would move an etcd peer URL.
2. **After an address change restart rke2 and the cilium pods.** rke2's node address and the `CiliumNode` keep the old one: pods started on chinchilla had no DNS or apiserver
   access and peers routed its pod /24 to the dead address, until `kubectl -n kube-system delete pod cilium-<node> cilium-envoy-<node>`.
3. **`kubectl cordon` makes CNPG switch the primaries off the node by itself** (`status.phase: Switchover`; 11 on chinchilla, 4 on bonobo). A drain then blocks only on the
   single-instance clusters (their `-primary` PDB allows no disruption): delete those pods (a graceful Postgres stop, recreated elsewhere; 3 minutes) rather than waiting.
4. **Rook fails a mon over after 10 minutes out of quorum**, drained or not. A node with a mon (now octopus, dingo, bonobo; none is allowed on sirver, falcon or axolotl) has to be back within that or the mon moves.
5. sirver was found schedulable (the 02:45 cordon had been lifted) with 120 pods on the failing disk, so it was cordoned for the roll and uncordoned at the end.
6. The first start of the external containerd (2.4.1) logs `failed to unmarshal sandbox spec` for every sandbox rke2's 2.2.7 had created; all of them had been killed by the
   cutover and nothing referred to them afterwards.
7. The switch on falcon and axolotl restarts `nix-daemon.service` (dry-activate lists it), which ends builds running there; on axolotl home-manager then waited on the attic
   post-build hook's 120 s timeout (the cache is not reachable at `sirver:8199`).
8. axolotl: its toplevel needs the DisplayLink zip in falcon's store: `ssh axolotl nix-store --export <zip> | ssh falcon sudo nix-store --import`. Its closure was copied
   as `tristan` (`nix copy --to ssh-ng://tristan@192.168.50.250`; the builder user has no key on it).
9. Substituters, checked on every node 2026-10-16 (`nix config show`): all list `http://chinchilla:8199/main` except sirver, which still runs its pre-roll generation and lists `sirver:8199` (refuses connections; its next deploy fixes it). falcon already lists chinchilla in `/etc/nix/nix.conf` and its daemon (started after the 10:49 switch); no user or root override exists. Macs and the Deck take only cache.nixos.org by design (`flake.nix`); the devshell adds the attic URL through `NIX_CONFIG`.

Everything below was written for this roll and still describes how to do a node.

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
2026-10-16, before the control plane moved: leader dingo `aa1b465deb84b6ad`, octopus `f4e927b319bde64`, sirver `2f50e46c20143168`; since "Control plane topology"
the members are bonobo `3a437683a172854d`, chinchilla and dingo.) A server switch is only safe while all three members answer, so re-read the table immediately before each server step.

### Order (as run; nothing here is pending except the octopus dataset and sirver)

Per node: steps 1, 2, 5, 6 and 7 of "Rolling the fleet to a new nixpkgs" (build, gates, copy, detached switch, verify) plus the node-specific steps here.

1. **axolotl**, then **falcon** (desktop agents; first nodes to lose their pod routes). Done. After the switch: `ip route show 10.0.0.0/8` empty,
   `tailscale debug prefs | jq .AdvertiseRoutes` null, `headscale nodes list-routes` on hyena no longer lists the node. Then `systemctl restart rke2-agent` for the label (its pods restart, 5 to 15 minutes; falcon: no dvdrip Job
   running first, `kubectl get jobs -A`), and `kubectl get node <n> --show-labels | grep exclude-from-remediation`. Rollback: `podRoutes = true` and redeploy.
2. **chinchilla**, then **bonobo** (agents, flagged; one at a time so one gateway relay stays up). Done, drained, with a reboot at the end of each (kernel 7.0.10 to 7.2.9). Containerd dataset first, already done:
   `findmnt /var/lib/rancher/rke2/agent/containerd` shows `root/local/containerd` (read 2026-10-16 on both). Then:
   - switch; verify `ls -l /bin/bash`, `cat /sys/class/watchdog/watchdog1/{identity,state}` (`iTCO_wdt`, inactive), `ip route show 10.0.0.0/8` empty,
     `grep container-runtime-endpoint /etc/rancher/rke2/config.yaml`. **Do not restart rke2 between this switch and the cutover**: rke2 would find
     no CRI at the configured socket until `containerd.service` is restarted;
   - the cutover and verification of "Running containerd as its own unit", steps 4 to 6 (stop rke2, `rke2-killall.sh`, restart `containerd`,
     start rke2; then check the parent of containerd is PID 1 and one more `systemctl restart rke2-agent` leaves the shims up);
   - gates, then the next node. Rollback: the "Rollback per node" paragraph above.
3. **dingo** (done; etcd server, no flag yet: set `externalContainerd.enable` for it in a later roll, after chinchilla and bonobo have run clean).
   Gates; if dingo is the etcd leader, move it first (below); switch; then `systemctl restart rke2-server` (grace period, tolerations, label);
   wait for etcd 3/3 and the node Ready, 5 to 15 minutes for the pods.
4. **octopus**, last: the same server steps, done; the containerd dataset migration was started and aborted ("octopus: containerd dataset", below).
5. **sirver**: not rolled (26.05, failing disk). It has no SNR agent as long as the SNR config excludes control-plane nodes; if a DaemonSet pod
   still lands there once medik8s is re-landed, label it once by hand (`kubectl label node sirver remediation.medik8s.io/exclude-from-remediation=true`);
   its reinstall carries the label from config.
6. **hyena**, after every node above (done, #1064): `tailnet.podRoutes = false` in its profile (`flake.nix`) so headscale stops auto-approving `10.0.0.0/8`
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

Tried 2026-10-16 and **aborted, nothing was cut over**; octopus is on `root/safe/var/lib` as before (the dataset was destroyed, `findmnt` shows no mount, the fstab mount unit
is still `failed` by design). Why, with the numbers:

- octopus' root pool is one spinning disk that also holds etcd. A `seed` is bound by random reads on it, not by bandwidth: about 120 files/s whatever `--bwlimit` says (30 MB/s
  was set; it ran at 5 to 25 MB/s), and four rsyncs in parallel gave 9K inodes/min instead of 7K. While it ran the octopus etcd member logged 150 to 300 `took too long`
  warnings a minute (baseline about 25; dingo stayed at 1 to 15), IO pressure sat near 30 to 45 %, and nothing failed: no etcd error, no leader change, no NotReady node,
  `/readyz` through dingo 60 to 95 ms. `ionice -c3` is unlikely to help: the device's scheduler is `none` and ZFS issues the IO from its own threads.
- The tree is bigger than it looks: `du` was never run (it walks the HDD), `crictl imagefsinfo` said 107 GB and 5.0 M inodes, and the first 54 minutes copied 60 GB and
  only 230 K inodes. **`crictl rmi --prune` first**: 354 of 456 images (62 GB) were unused, the prune returned in seconds, containerd's garbage collection then took about
  8 minutes of 4 to 10 MB/s of writes, and the directory went from 107 GB to 18 GB by `imagefsinfo`. After that the second seed copied 950 K inodes in 116 minutes, was at
  snapshot 61585 of 1177 directories (355 done, so about 3 M inodes in all: imagefsinfo's inode figure is cached and wrong) and was stopped, at an estimated 5 hours to go.
- Not done and worth it: move the etcd member off octopus first (README 47: falcon as the third server), after which a long seed does not matter; or give
  `/var/lib/rancher/rke2/agent/containerd` an SSD; or start from an empty dataset and have the node pull what it runs (untested: the control plane's own images would
  be pulled from the internet at that start, with etcd on two members, one of them sirver).

If it is retried: `zfs create -o mountpoint=legacy -o sync=disabled -o copies=1 -o com.sun:auto-snapshot=false root/local/containerd` by hand first (the script's `du` check
is skipped when the dataset exists; `zfs list -Hpo avail root` was 2.3 TB), run `seed` as a transient unit (`systemd-run`) so a dropped ssh does not end it, watch
`kubectl -n kube-system logs etcd-octopus --since=60s | grep -c 'took too long'` and `/readyz` through another server, and order the rest as **seed, cutover, switch with rke2
stopped, start**: the new toplevel's fstab entry mounts the dataset as soon as it exists and the unit is started, which would put a partial copy over the live directory.
`ceph osd set noout` around the cutover; the OSDs are hostNetwork pods and came back fast in every earlier restart. After it: README 48.

## Control plane topology

Since 2026-10-16 (evening PDT) the RKE2 servers and etcd members are **bonobo, chinchilla and dingo**. sirver and octopus are agents (and the two Ceph OSD hosts); falcon and
axolotl are agents as before. Why: octopus's etcd sat on one spinning disk (README 47) and sirver's member on the failing root disk (read 2026-10-16 18:15: 1484 `took too long`
warnings in 10 minutes on sirver's member against 38 on dingo's and octopus's). bonobo (Micron 1100 SATA SSD, `rotational` read as 0) and chinchilla
(Micron MTFDDAK SSD, `rotational` 0) have SSDs like dingo.

What declares it (all in the repo; nothing is set by hand except the one-off steps under "Gotchas"):

- `services.rke2.role = "server"` for bonobo, chinchilla and dingo in `flake.nix`. canivete forces the role of `canivete.meta.root` to server, so `root` moved from sirver to dingo
  (sirver would otherwise stay a server whatever its entry says); `nixidy kubeconfig` and the Mac's `kubeconfig` fetch from dingo.
- Every node joins through `https://dingo:9345` (`static/k8s-node.nix`, was `sirver`). There is no DNS name for all three servers; an agent also keeps the server list in
  `agent/etc/rke2-agent-load-balancer.json` (read 2026-10-16 on sirver, octopus and falcon: it listed bonobo, chinchilla and dingo within seconds of the change, octopus dropped).
  Whether an agent restart with dingo down uses it was not tested.
- Remediation eligibility is the node label `node.trdos.me/remediation=eligible` (`nodeRemediation.eligible`), not the absence of `control-plane` ("Node remediation").
- `static/builders.nix`: bonobo and chinchilla got dingo's build caps (1 core, 3G/4G); sirver and octopus kept theirs.
- Argo Workflows' build templates ask for a node without the `node-role.kubernetes.io/etcd` label (and not sirver) instead of the hostnames bonobo and chinchilla
  (`nixidy/system/cicd/argo-workflows.nix`); an `image-publish` run scheduled after the change succeeded.
- Prometheus scrapes etcd on the three servers (`prometheus.nix`), gatus probes their apiservers from hyena (`static/hyena.nix`); the `etcd-snapshot-offsite` timer follows the role.

How it was done (add before remove, one change at a time, `etcdctl endpoint status --cluster` and Ceph read between steps; times are PDT on 2026-10-16, from the node journals):

| Step | What | Result |
| --- | --- | --- |
| 1. #1092, #1098, #1101 | PRs merged ahead of each step; toplevels built on falcon from main, `nix copy` right before each switch (the roll's recipe) | bonobo, chinchilla, octopus and sirver run exactly main's toplevel (store paths compared); dingo too after its config-only switch |
| 2. bonobo joins | pre-pull `hardened-etcd` and `hardened-kubernetes` for 1.34.11, `exclude-from-remediation` label, detached switch at 18:19:20 | the switch stopped `rke2-agent` and started `rke2-server` by itself; member added 18:19:27, voting 18:19:46, node `control-plane,etcd` and Ready 18:19:59 (40 s); `/readyz` through bonobo ok; the node was never NotReady, 17 shims before, 19 after (the two new static pods), the node's mon stayed |
| 3. sirver leaves | `ceph osd set noout`, `member remove` 18:37:44, `systemctl stop rke2-server` 18:37:50, detached switch to the agent toplevel | `rke2-agent` active 18:38:13 and Ready within a minute without ever going NotReady; the OSDs did not restart (`up since 15h` before and after); `unset noout`, HEALTH_OK |
| 4. chinchilla joins | as bonobo, switch at 18:49:11 | member 18:49:31, Ready with the labels 18:49:42 (31 s), 62 shims before, 66 after |
| 5. octopus leaves | as sirver: `member remove` 19:06:27, stop 19:06:31, switch 19:06:32 | `rke2-agent` started about 19:06:50, Ready throughout, 107 shims after, no OSD restart, HEALTH_OK |

Etcd `took too long` per member (counted with `kubectl logs --since`): before, 5 minutes: dingo 59, octopus 18, sirver 689. After sirver left, 4 minutes: dingo 11, bonobo 11, octopus 35 (octopus's own
disk). After chinchilla joined, 10 minutes: bonobo 26, chinchilla 14, dingo 57, octopus 125. After octopus left (19:06 to 19:16, 10 minutes): bonobo 15, chinchilla 9, dingo 70.
The order is the rollback: a join that fails leaves the old members in place (`systemctl stop rke2-server` on the new node and `etcdctl member remove` for it would undo it; not exercised, nothing failed),
and after step 3 the cluster was already on bonobo, dingo and octopus, so a failed chinchilla would have left three healthy members.

Gotchas, all observed:

1. **A demoted server keeps its Node labels and annotations.** `kubectl label node <n> node-role.kubernetes.io/control-plane- node-role.kubernetes.io/etcd-` and
   `kubectl annotate node <n> etcd.rke2.cattle.io/local-snapshots-timestamp- etcd.rke2.cattle.io/node-address- etcd.rke2.cattle.io/node-name- etcd.rke2.cattle.io/s3-snapshots-timestamp- rke2.io/encryption-config-hash-`
   (done on both). Delete `/var/lib/rancher/rke2/server` and `/etc/rancher/rke2/rke2.yaml` on the node afterwards (done: only those). Nothing else on the node needed cleaning:
   the agent's start logged "Static pod cleanup in progress" and removed the old etcd, kube-apiserver, kube-controller-manager and kube-scheduler pods itself, so the leftover processes
   did not hold port 6443 (sirver's first attempt to kill and delete them by hand ran in a `systemd-run` unit whose PATH has no coreutils; only `systemctl` worked, and rke2 did the cleanup).
2. **An agent's `rke2-server.service` is a stub.** `k8s-node.nix` always sets `rke2-server.serviceConfig.TimeoutStartSec`, so sirver's agent toplevel contains a `rke2-server.service` with only
   environment and that timeout (read in the built toplevel), no ExecStart. The dry run on a node still running the real one lists it under "would stop/start"; stop the real `rke2-server` first and the stub is never started.
3. **`member remove` before the stop, from a member that stays.** The removed member's etcd exits at once; the node's own apiserver then has no datastore, so stop `rke2-server` straight away
   (about 6 seconds apart on both). Read the member id from `member list` first; never remove the leader (`move-leader` first, "Moving the etcd leader off a node").
4. **A node labelled `exclude-from-remediation` loses its SNR agent pod and gets it back when the label goes** (bonobo: `Init` for a few seconds, then `Running`). The label is only needed
   because a joining server is NotReady for as long as its local apiserver is down; neither join took more than a minute.
5. **The snapshot timer fires at once on a new server** (`Persistent=true`, no earlier run) while its apiserver is still starting: bonobo's first run failed at 18:19:24 and its retry 15 minutes
   later (18:34:35) succeeded; chinchilla's succeeded at 19:04:32. Both objects are in the bucket (`etcd/offsite-bonobo-bonobo-1792200866`, `etcd/offsite-chinchilla-chinchilla-1792202662`, read with `b2 ls`).
   The 26 `offsite-sirver-*` and 25 `offsite-octopus-*` objects (and dingo's) stay: S3 retention prunes by name prefix when that node saves, and neither does any more. Delete them by hand
   when no restore needs them.
6. **A sirver agent does not serve 9345 or 6443 any more.** Everything that pointed at it moved (join URL, kubeconfig recipes, `ssh -J 192.184.168.248 dingo ...` for the off-LAN `kubectl`, the
   apiserver probes). Not moved, because nothing is deployed that uses it: the cloud-burst supervisor address (`static/cloud-worker.nix`, `nixidy/system/cicd/capi-cluster.nix`,
   pulumi's `sirver_tailnet_ip`) still names sirver's tailnet IP: point it at dingo's (`100.64.0.6`) before CAPI is enabled (`docs/cloud-burst.md`).
7. **falcon and axolotl still have `server: https://sirver:9345` in their running config** (read on falcon): their agent keeps working from the saved server list, and the next switch of
   each (config only, `static/k8s-node.nix`) fixes the file.

## Taking a node down for hardware work

Short answer: cordon, then drain, then stop rke2, then power off; the reverse afterwards. `node-maintenance <host> down|up [--dry-run]` (devshell, `devenv.nix`) does
it with every check below; `down` stops at "ready to power off" unless `--poweroff` is given, and `--dry-run` runs the read-only checks and prints what it
would change. What is below was read on the live cluster on 2026-10-16/17 unless it says otherwise.

### What happens, per node

All 229 PersistentVolumes are `ceph-block` or `ceph-filesystem` and none has node affinity, so a pod evicted from any node comes back elsewhere with its data.
A node-bound pod is one whose `nodeSelector` no other node satisfies; `node-maintenance` lists them before it does anything.

| Node | Goes Pending until it is back | Also |
| --- | --- | --- |
| falcon | `jellyfin` and `tdarr-node` (`nvidia.com/gpu.present=true`, only falcon has the card; runtimeClass `nvidia`), the dvdrip agent DaemonSet (`dvd.trdos.me/drive=true`, the disc drive) and the GPU encode/publish Jobs, the `dvdrip-import` CronJob (`kubernetes.io/hostname=falcon`, suspended). `ollama`, `vllm`, `heretic` carry the same GPU selector but none is deployed. | 31 non-DaemonSet pods are evicted (dry run), 2 of them cannot be placed (left column). A disc being read when it goes down is `Failed: interrupted` and is retried when the agent is back (`docs/dvd-rip.md`). falcon holds no etcd, mon or OSD. |
| axolotl | Nothing: no pod on it has a `nodeSelector`. | 17 pods move. It held three L2 VIP leases when read (the external gateway `192.168.50.240`, forgejo-ssh, owncast-rtmp): another node takes each over when its 15 s lease expires (duration read from the Lease; the gap itself was not measured). |
| bonobo, chinchilla | Only the per-node Rook crashcollector and exporter (and mon-g on bonobo). | Servers: etcd. Their tailnet relays (`100.64.0.4`, `.5`) are the internal gateway's entry points and AdGuard returns both: take one down at a time. medik8s may reboot them (below), which is also an etcd event. |
| dingo | Rook mon-d, crashcollector, exporter. | A server: etcd. |
| octopus | Rook mon-a, the 7 OSDs, crashcollector, exporter. | An agent and an OSD host. |
| sirver | Rook's 6 OSDs, `zigbee2mqtt` (the USB Zigbee stick) and `music-assistant` (the `br0` L2 segment for mDNS), both pinned by hostname. | An agent and an OSD host. Its root disk is failing (README 33). |

**etcd.** Agents (falcon, axolotl, sirver, octopus) are not members. Servers are bonobo, chinchilla, dingo: 3 members to 2 keeps quorum, and a second server down
(or one failing while the first is out) is a cluster outage. Never two servers; the kubeconfig you use must not point at the one going down (the script refuses).
Check `etcdctl endpoint status --cluster` shows 3 healthy ("Gates" above) and move the leader off first.

**Ceph.** Pools are size 2 / min_size 1 (read with `ceph osd pool ls detail`): with one OSD host out Ceph stays writable and every PG is degraded, with one copy of the
data on the other host. Never both OSD hosts (the script refuses). `ceph osd set noout` before and `unset` after, so the OSDs the node takes with it are not marked
out after `mon_osd_down_out_interval` (600 s, read). Rook also manages disruption (`managePodBudgets`, `osdMaintenanceTimeout: 30` in the CephCluster, a `rook-ceph-osd`
PDB); whether Rook's own noout survives a drain was not tested, so the script sets the cluster-wide flag itself and re-reads it after the drain.
Mons are on octopus, dingo and bonobo (`mon: a,d,g`, read 2026-10-16 after #1089): none on desktops or sirver (#1074, #1082). A mon host going down needs the other two mons in quorum: the
`rook-ceph-mon-pdb` blocks the drain otherwise, and the script refuses.
Rook fails a mon over after 10 min out of quorum: within that the mon returns, after it Rook starts a new one on bonobo or chinchilla.

**Builds.** falcon is the Macs' and the nodes' main builder (`static/builders.nix`); the attic cache runs on chinchilla, not falcon. Probed on falcon (nix 2.35.2) with a LAN address
that does not answer, which is what a powered-off host looks like: nix prints `cannot build on 'ssh-ng://...': failed to start SSH connection` after about 2 s and builds locally if `max-jobs`
allows it (`max-jobs = 0` fails with "Failed to find a machine for remote build"). The nodes name falcon through `/etc/hosts` (its LAN address), so with falcon off they use the other pool nodes
(CPU-capped, `static/builders.nix`) and local builds. The Macs have no local Linux fallback: x86_64-linux builds go to the four nodes, and aarch64-linux has nowhere to go (falcon's emulation is the only
aarch64 entry in `modules/builders.nix`; the nodes also list morgenmuffel's VM). Do nixidy renders and `build-all --remote` (they run on falcon) before. An address that silently drops packets
hung for the full 60 s cap (a blackhole address) and for 40 s (an unregistered tailnet IP); a registered tailnet peer that is powered off was not tested, and the nodes list their peers by tailnet name.

**Alerts.** `NodeNotReady`, `KubeNodeNotReady`, `KubeNodeUnreachable` rules exist (read from the PrometheusRules); silence them in Alertmanager first if the noise matters.
Not checked: delivery to ntfy.

### Procedure

1. Pre-checks: node Ready, every other node Ready, Ceph HEALTH_OK, etcd 3/3 (servers), mon quorum survives (mon hosts), no `Pending` surprises, kubeconfig on another server, ssh and
   sudo work, and for falcon no disc being read and no running dvdrip Job (`kubectl get drives; kubectl -n media get pods -l dvd.trdos.me/disc`). `node-maintenance <host> down --dry-run`.
2. `kubectl cordon <node>`: CNPG moves the replicated Postgres primaries off the node on its own (`status.phase: Switchover`, observed in the roll).
3. OSD hosts only: `ceph osd set noout` (the script runs it in the `rook-ceph-operator` pod: there is no toolbox).
4. Single-instance Postgres (`instances: 1`; their `-primary` PDB allows no eviction, so the drain would block): delete the primary pod, it is stopped gracefully and recreated elsewhere (3 minutes on bonobo).
5. Servers: if the node is the etcd leader, `etcdctl move-leader <member id of another healthy server>` from the leader's own pod ("Moving the etcd leader off a node").
6. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. It retries PDB-blocked pods; a replicated primary clears once its switchover has finished.
7. `systemctl stop rke2-agent` (`rke2-server` on a server); a server's etcd then shows 2 of 3 healthy. Then `systemctl poweroff`.
8. After the hardware work: boot. Check the address is the same: chinchilla, bonobo, dingo, octopus carry `RequestAddress` (#1063); falcon, axolotl and sirver do not (grep of the repo), so they depend on the
   router's lease, and a different address breaks the builder lists, `/etc/hosts` entries and rke2 joins (then restart rke2 and delete the node's cilium pods, "What the roll found" 2).
9. Node Ready, servers: etcd 3/3. `kubectl uncordon <node>`. OSD hosts: wait for every OSD up, `ceph osd unset noout`, wait for HEALTH_OK. Re-enable the DVD drive.
10. Node-bound pods Running (jellyfin and tdarr-node for falcon). The node's DaemonSet pods take 5 to 15 minutes (cilium rate-limits endpoint creation); the node is Ready long before.

`node-maintenance` also pauses falcon's DVD drive (`Drive.spec.enabled=false`) so a disc inserted mid-work is not started, labels an agent `exclude-from-remediation` for the duration, and
records what it changed as `node-maintenance.trdos.me/*` annotations on the node, so `up` restores only what `down` changed. Not exercised: a real `down`/`up` (this was written with dry runs only).

### How long can it stay down

- **falcon, axolotl:** as long as you like. medik8s does not touch them (label `exclude-from-remediation=true`, read with `kubectl get nodes -L`), no Rook mon is placed on them (#1074), VolSync and CNPG
  backups have no node binding in their config. The node-bound pods stay Pending and nothing times out. After an unplanned loss (not drained) their RBD-backed pods stay `Terminating` on the dead node
  until you apply the `node.kubernetes.io/out-of-service` taint, which medik8s would set for an eligible node (the 2026-10-16 drill: the replacement waited for it); do that by hand only once the machine is off.
- **bonobo, chinchilla:** medik8s remediates an eligible node that stays NotReady for 15 minutes (about 17 minutes to detect, drill); `node-maintenance` sets the exclude label for the outage, and the NHC
  selector now also requires `exclude-from-remediation` not `true` (`nixidy/system/cluster/medik8s.nix`), so a labelled node is out of NHC's selection as well as of the SNR agent's. They are etcd members now: a
  remediation reboots a server, so it is an etcd event (3 members to 2) and must not coincide with dingo being down.
- **servers:** etcd has no spare member while one is out, so keep it to the job. A mon is replaced after 10 minutes.
- **OSD hosts:** keep `noout` only for the job. With two OSD hosts and `failureDomain: host` there is no third host for the second copy: lifting `noout` lets Ceph mark the OSDs out after 10 minutes but
  it cannot rebuild size 2 until the host returns (inferred from the pool config, not tested). A long OSD outage is therefore one copy on the other host: hurry, and check its SMART state first (sirver's disk is failing).
  sirver and octopus are agents since the control plane moved: stopping them no longer touches etcd.

## Node remediation

`nixidy/system/cluster/medik8s.nix` runs medik8s Node Health Check (NHC) and Self Node Remediation (SNR) in the `medik8s` namespace
(apps `node-healthcheck-operator`, `self-node-remediation`, CRDs in `medik8s-crds`). When a selected node's `Ready` condition stays
`False` or `Unknown` for 15 minutes, NHC creates a `SelfNodeRemediation` from the `out-of-service` template: the node's SNR agent
reboots it through the hardware watchdog, and the operator then sets the `node.kubernetes.io/out-of-service` taint so its pods are
force-deleted and their RBD volumes detach and move.

- **Selected**: the nodes with the label `node.trdos.me/remediation=eligible` (bonobo, chinchilla) and without `exclude-from-remediation=true`. Eligibility is a per-node fact
  (`nodeRemediation.eligible` in `flake.nix`, applied as that label by `static/node-remediation.nix`), not derived from the rke2 role: until 2026-10-16 the selector was "no
  `control-plane` label", which stopped matching bonobo and chinchilla when they became etcd servers. The SNR agent DaemonSet gets the label requirement, AND-ed with the
  operator's own `remediation.medik8s.io/exclude-from-remediation NotIn true` (read in the operator source, v0.13.0, `updateDsNodeSelectors`). The first landing (#958) still saw agent
  pods on every node, so the exclude label is the second guard: `static/node-remediation.nix` sets it on every node that is not `nodeRemediation.eligible`.
- **Never touched**: sirver, octopus (the OSD hosts: sirver's disk is failing, octopus hangs on a graceful reboot), dingo (the server every node joins through) and the desktops
  falcon and axolotl (they sleep and reboot at will, which would read as unhealthy). A reboot of bonobo or chinchilla is an etcd event (above).
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
- **Excluded nodes** carry `remediation.medik8s.io/exclude-from-remediation=true` through rke2's `node-label`, applied at the node's next rke2 restart; **eligible** nodes carry
  `node.trdos.me/remediation=eligible` the same way (read on bonobo's rke2 command line 2026-10-16: `--node-labels=node.trdos.me/remediation=eligible`). sirver has had the exclude label from its
  agent start on 2026-10-16.

### Drill, 2026-10-16: passed, NHC is on

The remediation landed paused (#1055; the SNR agent DaemonSet ran on bonobo and chinchilla only, none on sirver or the desktops), the pause was removed in #1066 after
`kubectl get nodes -L remediation.medik8s.io/exclude-from-remediation` read `true` on octopus, dingo, falcon, axolotl and empty on bonobo and chinchilla, and
`/bin/bash`, `iTCO_wdt` (watchdog1, armed `active` with a 30 s timeout once the agent ran) and `WatchdogDevice=/dev/watchdog0` read right on both agents.

Run on bonobo with etcd 3/3 and Ceph HEALTH_OK, sirver cordoned, a Deployment with an RBD volume (lidarr) on the node as the workload to follow. Fault: `systemctl stop rke2-agent`
**without a network cut**. A cut makes the agent lose the apiserver and its peers, so it fences its own node within a minute; the cut is gone after that reboot and NHC's
15 minutes would never run. Stopping the kubelet keeps the agent healthy and exercises the whole chain. What happened (15:36:11 is t0):

| t0 + | What |
| --- | --- |
| 2 min 4 s | node `Ready=Unknown` (the 2 minute grace period; the NoExecute `unreachable` taint starts the 600 s toleration) |
| 6 min 56 s | the lidarr pod is evicted by its NoExecute toleration (this one carried the old 300 s default; pods admitted now get 600 s); the replacement waits on chinchilla (RBD still mapped on the dead node) |
| 17 min | NHC creates the `SelfNodeRemediation` (15 minutes after `Unknown`; `NodeRemediationInProgress` went pending, then firing in Prometheus; delivery to ntfy not checked) |
| 17 min to 17 min 40 s | bonobo hard-reset by the agent (watchdog or the `echo b` fallback, not told apart; its journal ends mid-run with no shutdown, last entry 15:53:20, kernel started 15:53:51), kubelet Ready at 18 min 1 s |
| by 18 min 59 s | out-of-service taint applied by the SNR manager |
| by 20 min 3 s | taints and the `SelfNodeRemediation` gone, NHC `Enabled` with 2 healthy, lidarr Running on chinchilla |

So a dead agent costs about 17 minutes to detect and 3 more to move its volumes. After it: etcd 3/3, Ceph HEALTH_OK, no pod left on bonobo from before, the SNR agent back
on it (watchdog started), `rke2-agent` active with `containerd` the child of PID 1. If it misbehaves, re-add a `pauseRequests` entry in `nixidy/system/cluster/medik8s.nix`.
Not exercised: the isolated-agent self-fence (a real network cut), NHC with the other agent unhealthy (`minHealthy: 1`), and a remediation of chinchilla.

## sirver reinstall plan

Written 2026-10-16 (evening PDT) from read-only surveys of sirver, octopus, falcon, Ceph and the repo. **Nothing in the procedure has been run.** What was read live is
marked "read"; what is inferred from configuration or from how the tools behave is marked "inferred" or "assumed". It starts once sirver is an RKE2 agent (the etcd
move to bonobo, chinchilla and dingo is separate work: "Gate A" below).

Goals: (1) get sirver off its failing root disk by installing onto one of its better disks; (2) keep the two bad disks (the old root, bay 6, and the old osd.7, bay 7)
in Ceph "only for redundancy"; (3) make falcon, octopus and sirver the three OSD hosts at replication `size 2`, with no capacity loss.

### Survey (read 2026-10-16 17:50 to 18:10 PDT)

sirver is a Dell PowerEdge R630 (read: `/sys/class/dmi/id`), UEFI, systemd-boot, eight 2.5" SAS bays behind a `megaraid_sas` controller that shows the disks as plain
SCSI disks (`scsi-35000c500...` by-id). Every bay is occupied: there is no empty one. All eight are Seagate ST9900805SS (900 GB 10K SAS), manufactured week 18 of 2013, so
all of them are 8.6 years old. **Kernel names (`sda`...) are not stable across boots** (osd.9's Deployment says `ROOK_BLOCK_PATH=/dev/sda`, today's root, while osd.9 is up
on `sdh`): everything below goes by serial, by-id and bay (`by-path pci-0000:02:00.0-scsi-0:0:<bay>:0` = the controller's slot, which is also smartctl's `megaraid,<bay>`).

| Bay | Serial | by-id (`scsi-3...`) | Role today | Grown defects | Uncorrected R / W / V | Corrected write | Non-medium errs | Power-on h | Health |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 6XS42DVQ | `5000c50067fcc2fb` | osd.9, 268 GiB (114 PGs) | 3 | 0 / 0 / 1 | 30 | 17244 | 75853 | OK |
| 1 | 6XS42EQA | `5000c50067fc640b` | osd.10, 337 GiB (129 PGs) | 16 | 0 / 0 / 0 | 4 | 813 | 75360 | OK |
| **2** | **6XS42DQ9** | **`5000c50067fcd9af`** | **osd.0, 329 GiB (140 PGs)** | **4** | **0 / 0 / 0** | 16 | 24392 | 75552 | OK |
| 3 | 6XS42A75 | `5000c50067fe560f` | osd.2, 422 GiB (114 PGs) | 9 | 0 / 0 / 0 | 77 | 35393 | 75437 | OK |
| 4 | 6XS42DX1 | `5000c50067fcc0d3` | osd.4, 403 GiB (122 PGs) | 34 | 0 / 0 / 0 | 25 | 8284 | 75399 | OK |
| 5 | 6XS42ESH | `5000c50067fc5df3` | osd.5, 345 GiB (126 PGs) | 46 | 0 / 0 / 9 | 6 | 2730 | 75854 | OK |
| 6 | 6XS4209D | `5000c50067faa64b` | **root** (ZFS `root`, 361 G allocated of 832 G) | 8 | 0 / **79** / 0 | 1410 | 28074 | 141 (the counter looks reset; the others read 75k) | **impending failure** `asc=5d/ascq=10` |
| 7 | 6XS41YTD | `5000c50067fb404b` | empty, zapped 2026-10-13 (was osd.7) | 17 | 0 / 0 / **81** | 10 | 27515 | 75574 | **impending failure** |

(smartctl through the `smartctl-exporter` pod on sirver: the host has no smartctl. "R / W / V" = total uncorrected errors for read / write / verify. The root pool: `zpool status`
read DEGRADED, 176 write errors on its one vdev, last scrub 2026-10-01 repaired 0 B. The exporter's `smartctl_scsi_grown_defect_list` history reaches back about 6.8 days and no disk's
count moved in the last four days.)

OSD to device map (read with `ceph osd metadata`, so by serial rather than by kernel name): osd.0 6XS42DQ9, osd.2 6XS42A75, osd.4 6XS42DX1, osd.5 6XS42ESH, osd.9 6XS42DVQ,
osd.10 6XS42EQA. Utilisation of sirver's OSDs is 32 to 50 % (host 41.8 %, 2.1 TiB of 4.9 TiB), octopus's is 9.6 to 12.6 % (host 10.8 %, 2.1 TiB of 19 TiB). Pools are all `size 2 / min_size 1`,
`failureDomain: host`; `nearfull 0.85`, `backfillfull 0.90`, `full 0.95`.

**New root: bay 2, serial 6XS42DQ9, `/dev/disk/by-id/scsi-35000c50067fcd9af`, osd.0.** The criteria were zero uncorrected errors in all three counters (that removes bays 0, 5, 6, 7), then
the fewest grown defects (bay 2 has 4; bay 3 has 9, bay 1 has 16, bay 4 has 34). Runner-up: bay 1 (osd.10, `scsi-35000c50067fc640b`): 16 defects but the fewest corrected write errors (4)
and the fewest non-medium errors (813). The differences between the good five are small and every disk is the same age: "healthiest" here means "least bad", not "good". The root pool is a
single vdev again; the mitigation is that the node holds nothing that is not reproducible once etcd has left it (below), and that a reinstall is a procedure with a script.

**What purging osd.0 moves.** osd.0 holds 329 GiB in 140 PGs. With `failureDomain: host` its PGs keep their sirver copy on sirver, so the 329 GiB re-replicates onto osd.2, 4, 5, 9, 10 (free
416, 436, 493, 571, 501 GiB, 2.4 TiB in all). Afterwards each of the five holds about 421 GiB of 838 (50 %; the fullest, osd.2, rises from 50 to about 55 %), far from the 85 % nearfull
line. Source: osd.0 itself (a healthy disk), so the drain does not read from octopus or from a bad disk. Estimate, not measured: 1 to 3 hours with the declared `high_client_ops` profile
(about 105 k object copies at the ~12 objects/s the last purge saw), minutes to an hour with `high_recovery_ops`.

**octopus (read).** 8 PERC H710P virtual disks, each one physical disk, none with a defect: slots 0,1,2,3,5,7 HGST "HUS7230..." (3 TB, 7200 rpm, 27 to 40k h, 0 grown defects, 0 uncorrected),
slots 4,6 Seagate "ST3300..." (3 TB, 21.6k h, 0 defects, 0 uncorrected). The root is one virtual disk (`scsi-36b82a720cf60ce002fd94d2e2991b17e`, ZFS `root` 2.72 T, 358 G used, ONLINE), the OSDs are the other
seven (osd.1,3,6,8,11,12,13 at `scsi-36b82a720cf60ce002fd94d462aff700b` ... `...d962fc2bcad`, 268 to 351 GiB each). Which physical slot is the root was not read (no `perccli` here). No change is needed.

**falcon (read).** NVMe PC801 1 TB (root pool, 346 G used, standard layout) and `sda`, a Toshiba MG08ADA400NY, 4 TB 7200 rpm, `wwn-0x5000039b38dbee27`
(`ata-TOSHIBA_MG08ADA400NY_X1Q0A2MPFYXG`): SMART PASSED, 15 884 h, 0 reallocated, 0 pending, 0 offline-uncorrectable, 0 CRC errors, no self-test ever run. It holds the ZFS pool `data`
(3.62 T, 1.62 T used, all of it `data/dvd-rips`; `data/media`, `data/backup`, `data/scratch` are empty). It is the only spare spinning disk in the fleet and the only candidate for falcon's OSD.
Its contents are NOT yet confirmed to be in the cluster (the 2026-10-16 library check in `docs/dvd-rip.md` covers published ISOs and movies, not the leftovers, rescue images and
`.discid` files the importer and the `rerip` seed read from `/data/dvd-rips`): that is a gate, see "falcon" below.

### Ceph layout: falcon, octopus, sirver at `size 2`

What three OSD hosts buy (arithmetic from the CRUSH weights, approximate: the pool has 745 PGs, not a continuum):

| | host weights (TiB) | share of all copies (octopus / sirver / falcon) | at today's 2.1 TiB of data, held (TiB) | most data the layout holds below nearfull |
| --- | --- | --- | --- | --- |
| today, 2 hosts | 19.1 / 4.9 | 1.00 / 1.00 | 2.1 / 2.1 | about 4.2 TiB (sirver is full first: it holds a whole copy) |
| 3 hosts, bad disks at full weight | 19.1 / 5.7 / 3.6 | 0.94 / 0.64 / 0.42 | 1.97 / 1.35 / 0.88 | about 7.3 TiB (falcon fills first) |
| 3 hosts, bad disks at 25 % weight | 19.1 / 4.5 / 3.6 | 0.95 / 0.58 / 0.47 | 1.99 / 1.21 / 0.99 | about 6.5 TiB |

So the capacity goes up, not down, even though sirver gives one disk to its root: it gains the two bad disks and the cluster gains falcon's 4 TB. And the failure mode changes. Today a host
outage leaves single copies for as long as it lasts, and Ceph cannot re-replicate because there is no third host. With three, an out host's PGs rebuild onto the other two (octopus out: its 1.97 TiB
fits on sirver and falcon, which hold 2.2 TiB of their 9.3 TiB; sirver out: its 1.35 TiB fits on falcon, which would hold 2.2 of 3.6 TiB, 61 %). The cost: (1) any planned outage still wants `noout` (otherwise a 10-minute
outage starts a 1 to 2 TiB rebuild on single 7200 rpm and 10K disks); `node-maintenance` does that. falcon is a desktop that is switched off or rebooted for hardware work: with it as an OSD host a
falcon outage becomes a Ceph maintenance (`node-maintenance falcon down` sets `noout` for OSD hosts); (2) falcon's one disk would carry about 0.42 of a copy where each of octopus's seven carries about 0.13 and
each of sirver's about 0.09: it will be the busiest disk in the cluster. If it shows slow ops, give it `config.initialWeight` below its capacity (half, 1.8 TiB, costs about a third of the headroom row above); (3) `pg_autoscaler` will
re-split pools for the extra OSDs (a one-time backfill).

**The two bad disks "only for redundancy".** What Ceph offers, and what it cannot:

- `ceph osd primary-affinity osd.N 0`: the OSD never becomes the primary of a PG unless it is the only one left, so client reads and the PG's coordination go to the healthy partner and the bad disk only holds a
  replica. Writes still go to both copies, so every client write waits for the slower of the two: a dying disk that retries for seconds stalls writes cluster-wide, and affinity does nothing about that. Read-side caveat:
  the CephCluster has `csi.readAffinity.enabled = true` (`rook-ceph.nix`), which makes kernel RBD/CephFS clients read from the nearest replica; a pod running on sirver would read from the replica on sirver's bad disk
  even with affinity 0 (inferred from what the option does; not tested). Keep sirver light in compute, or leave it cordoned for general pods once the zwave and music-assistant pins are the only reasons to run there.
- A low CRUSH weight (`config.initialWeight` per device in the CephCluster node list, TiB; 0.2 against the default 0.82) holds less data on the disk, shortens any rebuild after it dies and shrinks the data at risk. Weight does not
  change the write-stall problem; it only reduces how many PGs have a copy there.
- The honest risk: a replica on a failing disk is only as good as its partner. For every PG whose copies are one on a bad disk and one elsewhere, redundancy is real only while the elsewhere copy is intact; if that one
  is lost or corrupted at the wrong time, the bad disk is the only source and it may not read. BlueStore checksums turn silent corruption into a read error, and a deep scrub repairs it from the other copy: the
  protection is the scrub schedule, not the disk. sda (bay 6) has 79 uncorrected **write** errors (it has already failed to store data); bay 7 has 81 uncorrected verify errors. Use them as extra redundancy, not as
  capacity: do not count their space in any "how much can we store" figure, add bay 7 first and bay 6 a day later, watch `ceph osd perf` (commit latency), `dmesg | grep -i 'medium error'` and the scrub results for a week, and
  `ceph osd out` a disk the moment it stalls writes. (Rook crash-loops an OSD whose disk errors out; Ceph marks it down and rebuilds elsewhere: that part is safe.)

**Doing it declaratively.** `primary-affinity` is an osdmap setting set with `ceph osd primary-affinity`, not a Ceph config option (`ceph config help osd_primary_affinity` answers ENOENT, read) and not a CephCluster field. The CephCluster
schema does have a per-device `config` map (`initialWeight`, `osdsPerDevice`, `deviceClass`, `metadataDevice`, `databaseSizeMB`, `walSizeMB`, `encryptedDevice`; the prepare job's desired-device dump shows `InitialWeight`), so the weight is
declarative and the affinity needs a Job in `nixidy/system/storage/rook-ceph.nix`, in the style of `rook-ceph-remove-osds`: a **CronJob** (every 10 minutes, `concurrencyPolicy: Forbid`) in the ceph image with the admin keyring, not a PostSync
hook, because the OSD is created by the operator after the sync, and because purging and recreating an OSD resets its affinity to 1 (a new id is a new entry in the osdmap). The script walks `ceph osd ls`, matches each id's
`ceph osd metadata` `device_ids` against a list of serials (`6XS4209D`, `6XS41YTD`) and runs `ceph osd primary-affinity osd.$id 0` (idempotent), skipping serials that have no OSD yet. Drafted as PR #1096 (not merged).

**falcon as an OSD host (gated).** Adding the host is one `nodes` entry in `rook-ceph.nix` (`name = "falcon"; devices = [{name = "/dev/disk/by-id/wwn-0x5000039b38dbee27";}]`; falcon carries only the `PreferNoSchedule`
`node.trdos.me/class=desktop` taint, and OSD pods are pinned by hostname, so nothing else is needed). What Rook does with a disk that still holds a ZFS pool: it does not format it. The prepare job's inventory skips a disk that has partitions
("skipping device sda because it has child, considering the child instead", read in sirver's prepare log for its root), so a listed whole disk with `sda1` carrying a `zfs_member` is not available and no OSD is created; `cleanupPolicy.wipeDevicesFromOtherClusters` only
concerns other clusters' bluestore labels. (Inferred from that log line and ceph-volume's rule; not exercised on falcon.) So the wipe is a deliberate manual step, after the gates:

1. `/data/dvd-rips` is fully in the cluster. Check against `kubectl -n media get discs` and the importer (`kubectl -n media create job --from=cronjob/dvdrip-import ...`, `docs/dvd-rip.md`); nothing in it is needed as a rescue seed (`raw.iso` + `raw.map` for held discs: "Nightmare"); coordinate with whoever is running the DVD work. If anything is not in the cluster, copy it first. The 2026-10-11 restic safety net of falcon is 22.8 GiB of `/home` plus the root snapshot, far too small to hold the 1.6 TiB, so this pool is the only copy of anything not yet in the cluster.
2. Remove `boot.zfs.extraPools = ["data"]`, the `/data*` `fileSystems`, `systemd.services.zfs-import-data.postStart` and `dataDatasets` from `static/falcon-system.nix` (and point `services.dvd-rip` at a path that exists: its default is `/data/dvd-rips`), switch falcon.
3. On falcon: `sudo zpool export data` (not `destroy` until step 1 is signed off), then after sign-off `sudo zpool destroy data && sudo wipefs -a /dev/disk/by-id/wwn-0x5000039b38dbee27-part1 && sudo sgdisk --zap-all /dev/disk/by-id/wwn-0x5000039b38dbee27 && sudo wipefs -a /dev/disk/by-id/wwn-0x5000039b38dbee27`.
4. Merge the node entry; `kubectl -n storage logs job/rook-ceph-osd-prepare-falcon` shows the OSD; `ceph osd tree` shows host `falcon`. The balancer and `pg_autoscaler` then move about 0.9 TiB onto it.

### Procedure

**Gate A: before anything.** All of these must hold; a failed one stops the plan.

1. sirver is an agent and the cluster no longer depends on it: `etcdctl member list` shows bonobo, chinchilla and dingo and not sirver; `ssh sirver systemctl is-active rke2-agent` is `active` (and `rke2-server` is not);
   **no node's `/etc/rancher/rke2/config.yaml` has `server: https://sirver:9345`**. Today `static/k8s-node.nix` forces that URL on every node (read, and it is what sirver's own config says), so after the conversion every node's join address is a
   node that is about to be reinstalled and sirver itself would point at itself. The etcd move has to repoint it (to a server) before this plan runs.
2. Backups, the "checks" in docs/etcd-restore.md and docs/pvc-and-postgres-restore.md, plus what sirver carries that is not in them:
   - VolSync: `kubectl get replicationsources -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name,.status.lastSyncTime,(.spec.trigger.manual//"-")] | @tsv' | sort -k3 | head` (read at 18:00 PDT: 81 sources, none unsynced, the oldest synced 2026-10-16 10:30 UTC, none with a manual trigger).
   - CNPG: newest completed `backups.postgresql.cnpg.io` per cluster is under a day (the known gaps are in docs/pvc-and-postgres-restore.md, "Backup coverage gaps").
   - etcd: `etcd-restore-test` (devshell) passes against the newest `offsite-*` snapshot of the NEW servers, and `EtcdOffsiteSnapshotStale` is not firing for them. sirver's old `s3-offsite-sirver-*` records and objects remain after it leaves etcd.
   - Bitwarden: `kubectl -n security get cronjob bws-backup -o jsonpath='{.status.lastSuccessfulTime}'` (read: 2026-10-16T07:30:19Z, weekly), and `bws-backup-restore-test` if it has not been run since the last secret change.
   - sirver's identity files, copied off in step C2 (they are in no backup).
3. Ceph: `HEALTH_OK`, every PG `active+clean`, the balancer idle, no `noout`, `ceph osd df tree` as in the survey. `HEALTH_WARN` for anything is a stop: the plan lowers redundancy for hours.
4. The pods that cannot leave sirver (below) are acceptable to stop for the window.

Helper used below (the rook operator pod carries the CLI and the admin keyring; there is no toolbox):

```sh
ceph() { kubectl -n storage exec deploy/rook-ceph-operator -c rook-ceph-operator -- ceph -c /var/lib/rook/storage/storage.config --keyring /var/lib/rook/storage/client.admin.keyring "$@"; }
```

**Phase B: free bay 2 (online, hours; reversible until the zap).** Declarative, through the existing `removedOsds` machinery (`rook-ceph-remove-osds` then `rook-ceph-zap-devices-sirver`):

1. One PR to `nixidy/system/storage/rook-ceph.nix` (render on falcon): delete `{name = "/dev/disk/by-id/scsi-35000c50067fcd9af";}` from sirver's `devices`, append `{id = 0; node = "sirver"; device = "/dev/disk/by-id/scsi-35000c50067fcd9af";}` to `retiredOsds`, bump the ConfigMap `revision`.
   Optional, to finish in under an hour: set `cephConfig.osd.osd_mclock_profile = "high_recovery_ops"` in the same PR and revert it after (the last purge ran at about 12 objects/s under `high_client_ops` and about 200 under `high_recovery_ops`).
   Merging it starts the drain, so merge it when the plan starts.
2. Watch: `kubectl -n storage logs -f job/rook-ceph-remove-osds` (`osd.0: waiting for its data to migrate (n/745 PGs clean)`), `ceph -s` (judge by the `remapped` PG count, not by misplaced objects), `ceph osd df tree`.
   Expected: osd.0 goes out, its 140 PGs backfill, `safe-to-destroy` succeeds, the hook removes osd.0 and `rook-ceph-osd-0` is deleted, then the zap Job wipes the label.
   The failure modes seen on 2026-10-12/13 when osd.7 was retired: Rook re-adopts an OSD whose bluestore label is still on a disk (the zap Job is what ends that), and a re-adopted OSD keeps `noup` (the hook now forces the removal once every PG is clean).
3. Verify: `ceph osd ls` has no 0; `ssh sirver lsblk -o NAME,FSTYPE,SERIAL /dev/disk/by-id/scsi-35000c50067fcd9af` shows no filesystem (bluestore label gone); `ceph health` OK; the five OSDs (2, 4, 5, 9, 10) hold about 421 GiB each.
4. Test the disk before trusting it: in the sirver exporter pod `smartctl -t long /dev/<its kernel name today>` (`readlink -f /dev/disk/by-id/scsi-35000c50067fcd9af`), several hours (not measured). Pass = `smartctl -l selftest` "Completed without error", grown defects still 4, no new `Medium error` in `dmesg`. If it fails, repeat Phase B for the runner-up (osd.10, `scsi-35000c50067fc640b`) and change the disko device to it.

**Phase C: prepare the window (no outage yet).**

1. Merge the disko-device PR (#1094, draft; `flake.nix`, sirver: `disko.devices.disk.root.device = "/dev/disk/by-id/scsi-35000c50067fcd9af"`). Verified on falcon: it changes `system.build.diskoScript` (`...jzpsks1j-disko` to `...xhxxiinz-disko`) and leaves the sirver toplevel
   (`...m4fgyygvskrp19f4lglzycwww514ar89-nixos-system-sirver-26.11.20261008.e7439b6`) byte-identical, so no deploy and no `nixos-sirver-deploy` trigger changes. Nothing installs without `NIXOS_ANYWHERE_INSTALL=sirver` (`pulumi/millionaire/nixos.py`, read: the guard exits 1 otherwise, and the install resource has `protect=True`, `ignore_changes=["create"]`).
   The built disko script names exactly one disk, `scsi-35000c50067fcd9af` (34 references, read in the built script), plus the partlabels `disk-root-ESP` and `disk-root-zfs`. There is no OSD device in it and the only zpool is `root` (`nix eval` of `disko.devices.disk` / `zpool`: `["root"]`, `["root"]`).
   **Both of sirver's roots would then share partlabels and a pool name**: the old root's partitions are labelled `disk-root-ESP`/`disk-root-zfs` (read in the prepare job's udev dump) and its pool is `root`. disko's `zpool create` and `mkfs.vfat` address the partitions by those labels, so with both disks present
   udev's `by-partlabel` link can point at the OLD disk and disko would format it; and with both present at boot, `zpool import root` is ambiguous (ZFS refuses a name that matches two pools; inferred). So the old root must be physically out of the chassis for the install (C5).
2. Collect sirver's identity into a mode-700 directory on falcon (not in git, deleted at the end). The install keeps it exactly, so nothing re-registers:
   `etc/ssh/ssh_host_ed25519_key{,.pub}` (the public half is pinned as `hostKey` in `static/builders.nix`, read: they match; sirver is not a sops recipient, it decrypts with the `server` age identity; `ssh-keygen -lf` before and after), `etc/rancher/node/password` (rke2 refuses a re-registering node whose
   password differs from the `sirver.node-password.rke2` Secret; if lost, `kubectl -n kube-system delete secret sirver.node-password.rke2` once), `var/lib/tailscale/tailscaled.state` (keeps the node key and its tailnet address 100.64.0.2, which `static/hyena.nix`'s probe, `static/builders.nix` and the cloud-burst `headscale/node-ip/sirver` secret use),
   and `etc/machine-id` (see the address note in C4). Plus `root/.config/sops/age/keys.txt` (the `server` age identity: `sops --decrypt --extract '["passwords"]["age"]' secrets/sops/default.yaml`, as `pulumi/millionaire/nixos.py` does). Directories 755 except `root/`, keys 600 (as in the desktop procedure).
   `sudo cat` of each over ssh; the host is quiet but its disk is failing, so no `du`/`find` over `/var/lib`.
3. On falcon build `system.build.toplevel` and `system.build.diskoScript` of sirver (the flake is 26.11 / rke2 1.34.11; sirver is still on 26.05 / 1.34.7, so this install is also its roll) and `inputs.nixos-anywhere`, with the nodes as `--builders`.
   `grep -o '/dev/disk/by-id/[^ "]*'` over the disko script's closure must print only `scsi-35000c50067fcd9af`.
4. The installer and the address. sirver's uplink is `eno4` (`18:66:da:55:01:17`, Broadcom `bnx2x`), enslaved to `br0`, which carries the DHCP lease `192.168.50.204`; `br0`'s MAC is `b6:53:68:1e:eb:81` (not a port's: `addr_assign_type 3`, systemd-networkd's persistent
   policy, inferred to be derived from `/etc/machine-id`, which is why that file is preserved). The kexec installer and `static/installer-oneshot.sh` both copy `ip addr` into the installer's network setup, matched by MAC: the entry that has the address belongs to
   `br0`, which does not exist in the installer, so **the installer will probably come up on `eno4` via DHCP under eno4's own MAC, possibly at a different address** (inferred from how the nixos-images network step matches interfaces; not observed). Find it by MAC
   (`18:66:da:55:01:17` in the router's client list, or an ARP scan from falcon) or from the iDRAC console (the BMC exists: `/dev/ipmi0` read; its address and credentials were not found anywhere in the repo or memory: confirm them first; without it a failed boot is a keyboard-and-monitor job).
   The e1000e kexec problem of falcon and axolotl does not apply (sirver's NICs are `bnx2x`, octopus's `igb`, both read), but `bnx2x` after a kexec is untested: use `installer-oneshot.sh` (cold NIC start), the same as the desktops. The ESP has 457M free (read), the script wants about 350M.
   The pulumi install path is not the one to use here: `pulumi/__main__.py` targets `root@nixos`, builds on the target (`--build-on remote`) and would need `pulumi state unprotect`/`state delete` first (the instructions are in `nixos.py`). Use the manual `--store-paths` flow of "Reinstalling a desktop node onto the standard layout", with one
   addition: run its `prlimit --nofile=1048576:1048576` loop on the installer's PID 1, sshd and nix-daemon before the `disko,install` phases (the "Too many open files" fix, `nixos-deploy-fix.md`), because `nixos-install` copies thousands of paths.
5. Ask whoever is at the machine to be there for the window: the old root (bay 6, serial 6XS4209D) is pulled during it.

**Phase D: the window (sirver is out for about 1.5 to 3 hours; estimate, not measured).**

1. `ceph osd set noout` is done by `node-maintenance`; the OSDs go down with the node and Ceph stays writable on one copy of every PG. Pause the heavy writers first (qBittorrent and the media downloaders, anything with a large rolling write) so the single-copy period is quiet, and move the ZWA-2 stick if Z-Wave matters (below).
   `node-maintenance sirver down --dry-run`, then `node-maintenance sirver down` (cordons, sets `noout`, drains, stops rke2, stops at "ready to power off"; the dry run on 2026-10-16 listed the pods that cannot move: `music-assistant`, `zigbee2mqtt`, the Rook crashcollector/exporter/OSD pods). The kubeconfig must point at another server.
2. Arm the installer: `installer-oneshot.sh` as root on sirver, reboot, find the installer's address (C4). In the installer, with the old root still present, check `lsblk -o NAME,SERIAL,SIZE,PARTLABEL` and that `by-id/scsi-35000c50067fcd9af` is a blank 838 G disk (the label was zapped in Phase B).
3. **Pull bay 6 (6XS4209D) now**, while the installer runs from RAM. It is the rollback: with it back in its bay the old system boots as it was.
4. `nixos-anywhere --store-paths <diskoScript> <toplevel> --extra-files <dir> --phases disko,install root@<installer address>` (no `reboot` phase: reboot by hand after the checks). The `--extra-files` directory is the one from C2.
   Then in the installer: `zpool list` shows `root` on `scsi-35000c50067fcd9af-part2` only, `/mnt/etc/ssh/ssh_host_ed25519_key.pub` equals the old one, `efibootmgr` (or `ls /mnt/boot/EFI/BOOT/BOOTX64.EFI`) shows a boot entry or the fallback file on the new ESP.
5. `reboot`. Expect the node at 192.168.50.204 (check; else follow step 8 of "Taking a node down", restart rke2 and delete the node's cilium pod, and fix `static/builders.nix`'s `lan` and the pinned `/etc/hosts`; or add `RequestAddress` for `br0` and redeploy). First boot checks: `systemctl --failed`, sops secrets decrypted (`/run/secrets`), `tailscale status` (same 100.64.0.2), `findmnt /var/lib/rancher/rke2/agent/containerd` (the `root/local/containerd` dataset comes from disko: this install ends the sirver containerd migration), `zpool status`.
6. rke2 joins as an agent (`journalctl -u rke2-agent`): the node-password check passes (preserved); `kubectl get node sirver` goes Ready (the cordon and the node's labels are on the Node object, which persists); the SNR exclusion label comes from `static/node-remediation.nix`.
7. Rook re-adopts the five OSDs. Nothing touched their disks: the disko script names no OSD device, and the bluestore labels (osd id, osd uuid, cluster fsid, key) are on the disks. The OSD Deployments still exist in the API, pinned by hostname; the operator reconciles when the node returns and runs `rook-ceph-osd-prepare-sirver`, whose `ceph-volume raw list` finds the six labels
   and maps each id to whatever kernel name it has now (its log today reads `6 ceph-volume raw osd devices configured on this node`, with osd.0 on `/dev/sdf`, while the Deployment still says `/dev/sdc`: names are not load-bearing). `/var/lib/rook` comes back empty and is rebuilt (inferred: the OSD data and keys are in the labels). Watch `kubectl -n storage get pods -l app=rook-ceph-osd -w` until the five are `Running` and `ceph osd tree` shows them up; if the prepare job does not run,
   `kubectl -n storage rollout restart deploy/rook-ceph-operator`.
8. `node-maintenance sirver up` (it restores only what `down` recorded, waits for every OSD to be up, then runs `ceph osd unset noout` and waits for `HEALTH_OK`; if it balks at the reinstalled node, `ceph osd unset noout` and `kubectl uncordon sirver` by hand once all five OSDs are up and `ceph -s` shows nothing unexpected). The writes made while sirver was away backfill (a small amount if the writers were paused). Resume the paused workloads.

**Phase E: the bad disks become OSDs (days later, one at a time).**

1. After a day clean on the new root: re-insert bay 6. The disk still has the old GPT and the old `root` pool. `udev` will re-point `by-partlabel/disk-root-*` at it, so wipe immediately by explicit path:
   `zpool labelclear -f /dev/disk/by-id/scsi-35000c50067faa64b-part2; sgdisk --zap-all /dev/disk/by-id/scsi-35000c50067faa64b; wipefs -a /dev/disk/by-id/scsi-35000c50067faa64b; udevadm settle; udevadm trigger -s block`, and check `ls -l /dev/disk/by-partlabel` points at the new disk.
   Whether this controller presents a hot-inserted disk to the OS without a reboot was not tested; if it does not, shut sirver down with the disk in and do the same wipe from the installer image (the old pool is never imported).
2. Bay 7 (6XS41YTD, blank today) first: add `{name = "/dev/disk/by-id/scsi-35000c50067fb404b"; config.initialWeight = "0.2";}` to sirver's devices in `rook-ceph.nix`, together with the primary-affinity CronJob (draft PR #1096). Bay 6 a day later, same form. Watch the first week as described under "The two bad disks". Rook picks up osd ids freely (osd.0 and osd.7 are free); the CronJob matches by serial, so the ids do not matter.
3. Falcon's OSD as above (the node entry is draft PR #1097), whenever its gates are met (independent of sirver, but easier after it: the rebalance is one at a time).
4. When both bad disks are in: `ceph osd tree` shows sirver with five healthy OSDs and two at low weight; update `docs/manual-steps.md` 5 (the "replace osd.7's drive" step is superseded: bay 7 returns as an OSD, not a replacement) and the README todos 24 and 33.

**The pods that stop (read 2026-10-16).** `music-assistant` (nodeSelector `kubernetes.io/hostname=sirver`; its macvlan attaches to `br0`, which exists only on sirver) has no alternative: it stays down for the window. `zigbee2mqtt` is also pinned to sirver but runs in onboarding mode against a placeholder path
(`/dev/serial/by-id/TBD-zigbee-stick`, an empty directory: there is no Zigbee stick), so nothing is lost. `zwave-js-ui` is not pinned: it takes whichever node advertises `devic.es/zwave`, today only sirver (the Nabu Casa ZWA-2 on its USB port; the generic-device-plugin DaemonSet runs on all seven nodes). Plugging the stick into another node
(any: the by-id path is the same everywhere) lets Z-Wave run through the window; otherwise it is Pending until sirver is back. The Postgres, Redis and application pods drain to other nodes (21 pods at the dry run), and the Ceph mgr, MDS (one hot standby) and RGW (one instance: S3 is unavailable for the minutes it takes to reschedule) move with them.

### Risks and rollbacks

| What goes wrong | Where it stands | What to do |
| --- | --- | --- |
| The install fails, or the new system will not boot | Until bay 6 is wiped (Phase E) the old root is intact on the shelf. Before the `disko` phase ran, bay 6 simply goes back and the old system boots. After it, bay 2 carries a new pool named `root` and partlabels `disk-root-*`, which collide with the old root's, so the old system will not boot until bay 2 is blank again (boot the installer and `sgdisk --zap-all` it, or iDRAC virtual media). Ceph is unaffected either way: osd.0 is already gone and the cluster is healthy without it. | Fix the cause (installer log, `efibootmgr`, the iDRAC console) and retry with bay 6 still out. Nothing on the old root is needed that is not reproducible, so there is no data at stake, only time. |
| The new root is already installed and later fails | A reinstall: this procedure again, 1 to 2 hours, no data loss (the node keeps nothing that is not in Ceph, git or the identity files kept from C2). Keep that directory until the node has run clean for a week. | Re-run Phase D from step 2. |
| Rook does not re-adopt an OSD | Its data is on the untouched disk. Causes seen before: the prepare job did not run, or a stale OSD Deployment or `noup` flag. | `kubectl -n storage logs job/rook-ceph-osd-prepare-sirver`; restart the operator; `ceph osd rm-noup osd.N`. If a bluestore label were gone the OSD is lost and Ceph rebuilds it from octopus (one copy until then). Never `ceph osd purge` an OSD that is merely down: that deletes its place. |
| An OSD fails during the window (size 2, `noout`, sirver down) | Every PG has one live copy, on octopus. An octopus disk dying (seven healthy ones, 0 defects, a 1.5 to 3 hour window) makes the PGs it holds (about 1/7 of them, 100 to 127 PGs, about 300 GiB) `down`: unavailable, not yet lost, because sirver's copies are intact on disk. They peer again when sirver returns; **writes made to those PGs during the window were only on the dead disk and are lost**. `ceph pg <pg> query` shows what is blocking; `ceph osd lost` / `mark_unfound_lost` are last resorts. | Keep the window short and quiet (pause writers), do Phase D only with a full set of passing gates, and do not combine it with any other octopus work. This is the same exposure every `node-maintenance` of an OSD host has today; falcon as a third host removes it only for outages long enough to un-set `noout`. |
| A bad disk (bay 6 or 7) stalls the whole cluster | Writes wait for both replicas. | `ceph osd out osd.N` (its data rebuilds from the partner), `ceph osd primary-affinity` does not help; remove it from the device list and add it to `retiredOsds`. |
| The disk picked as root dies later | The same single-vdev root as before, on a better disk. | Reinstall onto the runner-up (bay 1) by the same procedure; nothing else depends on it. |
| `br0`'s DHCP lease changes | Possible (see C4). Chinchilla came back on another address on 2026-10-16 and lost its Ceph mon. | Router reservation for `18:66:da:55:01:17` / the bridge MAC, or `RequestAddress` on `br0`; until fixed the builder lists, `/etc/hosts` entries and the rke2 join names (all `192.168.50.204`) are wrong. |
| Both OSD hosts' data at risk | Only one OSD host is ever taken down at a time (`node-maintenance` refuses otherwise). | Never run this during an octopus outage. |

Downtime (estimates): Phase B and the self-test run online in the background (hours, no outage, a drain load on sirver's disks). The window: drain 15 to 30 minutes, installer boot 5 to 10, install and first boot 30 to 60, rke2 join and OSD re-adoption 10 to 20, then 5 to 15 minutes before the node's DaemonSet pods are back (roll gotcha 3).
sirver's workloads are away for about 1.5 to 3 hours; `music-assistant` (and Z-Wave, unless the stick is moved) is down for that time; Ceph is on one copy of everything for the same time and degraded-then-backfilling afterwards.

### Execution checklist (ordered)

1. Gate A (etcd conversion done and the join URL moved off sirver; backups; Ceph HEALTH_OK).
2. PR: purge osd.0 (`rook-ceph.nix`: device out of sirver's list, `retiredOsds` += osd.0, optionally the `high_recovery_ops` profile). Merge, watch the drain, verify bay 2 is blank.
3. `smartctl -t long` on bay 2; pass or switch to bay 1 (repeat 2 with osd.10).
4. Merge the disko-device PR; build toplevel + disko script on falcon; check the disko script names only bay 2.
5. Copy off sirver's identity files; pick the installer address plan and confirm iDRAC or a person at the chassis.
6. Pause heavy writers; move the ZWA-2 if wanted; `node-maintenance sirver down`.
7. Oneshot installer, find its address, pull bay 6, `nixos-anywhere ... --phases disko,install`, verify, reboot.
8. First-boot checks, rke2 join, five OSDs re-adopted, `ceph osd unset noout`, HEALTH_OK, `node-maintenance sirver up`, resume writers.
9. A day later: wipe and re-insert bay 6, add bay 7 then bay 6 as low-weight OSDs with the primary-affinity CronJob (PRs).
10. falcon's OSD once its gates are met (DVD data confirmed, `static/falcon-system.nix` cleaned, `zpool destroy`, node entry PR).
11. Update `docs/manual-steps.md` 5, README todos 24, 33, the "sirver is not rolled" mentions in this file, and delete the identity directory.

## Not verified

- No node has been installed through this path; the pulumi step was only rendered and syntax-checked, never run.
- The sirver reinstall plan (above) is all unrun. Specifically unverified: that the installer comes up reachable (the `br0` MAC and DHCP matching, `bnx2x` after the oneshot boot, iDRAC access), that a purged-and-zapped sirver disk passes a long self-test,
  that this controller shows a hot-inserted disk without a reboot, what Rook does with a listed disk that still holds a ZFS pool (read from a log line only), the primary-affinity CronJob, and `readAffinity`'s effect on a bad-disk replica.
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
