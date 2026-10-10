# Disk layout of hosts installed by the old dotfiles `diskoZfs` helper: ESP +
# pool `root` with flat root/home/tmp datasets. Overrides modules/disko.nix's
# dataset tree so the generated fileSystems match what is already on disk.
# Never reinstall/reformat through this; it exists to mount, not to create.
{lib, ...}: {
  disko.devices.disk.root.content.partitions.ESP.size = "1G";
  disko.devices.zpool.root.datasets = lib.mkForce {
    root = {
      type = "zfs_fs";
      mountpoint = "/";
    };
    home = {
      type = "zfs_fs";
      mountpoint = "/home";
    };
    tmp = {
      type = "zfs_fs";
      mountpoint = "/tmp";
      options.sync = "disabled";
    };
  };
}
