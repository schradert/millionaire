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
| Node | `static/k8s-node.nix` | RKE2 via `canivete.kubernetes` (agent unless `services.rke2.role` is set), cluster tailnet (`tailnet.nix`: cluster-node key, pod routes, `accept-dns=false`), build-pool membership and name resolution (`builder.nix`), attic substituter and push hook, chrony, kubelet resolv.conf, etcd watchdog/snapshot | every RKE2 host |
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

## Migrating a live node to the containerd dataset

`root/local/containerd` (`sync=disabled`, `copies=1`, legacy mount at `/var/lib/rancher/rke2/agent/containerd`) is declared in
`static/k8s-node.nix`, so reinstalls get it from disko. disko does not run on live nodes, and the switch that adds the fileSystems
entry is `nofail` (an unmigrated node keeps running on the old directory, silently), so run `static/containerd-zfs-migrate.sh` as root
on each node BEFORE its switch. One node at a time, never while another server is down (sirver stays out until its disk is replaced):

1. etcd 3/3, all nodes Ready, ceph known state. `seed` (rke2 running; copies the layers into the new dataset, about the size of
   `du -sh /var/lib/rancher/rke2/agent/containerd`, 50-80 GB; the script refuses if the pool lacks 120% of that).
2. `cutover` (stops rke2, `rke2-killall.sh`, final rsync, old dir moved to `containerd.premigration`, dataset mounted).
3. Switch the node (runbook), then `systemctl is-active rke2-server rke2-agent`, starting the unit if the switch left it stopped.
4. Verify: `findmnt /var/lib/rancher/rke2/agent/containerd`, `zfs get sync,copies root/local/containerd`, node Ready, pods Running.
5. `cleanup` once satisfied (deletes `containerd.premigration`, freeing its `copies=2` space). `rollback` undoes step 2 before it.

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
