# Which folders of `syncthing.folders` (options/syncthing.nix) a device carries; shared by the hub
# (nixidy/apps/home/syncthing.nix) and the clients (modules/syncthing.nix) so both sides agree.
{lib}: rec {
  port = 22000;

  # What a client dials for a device: its fixed LAN address over TCP and QUIC (the hub's LoadBalancer
  # exposes both), then discovery and relays.
  addresses = device:
    lib.optionals (device.lan != null) ["tcp://${device.lan}:${toString port}" "quic://${device.lan}:${toString port}"] ++ ["dynamic"];

  # `device`: {name, os, profiles}. A folder applies when its path exists on that OS, it is limited
  # to no hosts or to this one, and the device has one of its profiles.
  applies = device: folder:
    (folder.path.${device.os} or null)
    != null
    && (folder.hosts == null || lib.elem device.name folder.hosts)
    && lib.any (p: lib.elem p device.profiles) folder.profiles;

  # A device with a folder list takes exactly those folders (a phone gets `org` only).
  shares = device: id: folder:
    if device.folders != null
    then lib.elem id device.folders
    else applies device folder;

  # Every device but the hub that has a recorded ID, with the folders it gets.
  clients = syncthing:
    lib.filterAttrs (n: d: n != "hub" && d.id != null) syncthing.devices;
  sharedWith = syncthing: id:
    lib.filterAttrs (n: d: shares (d // {name = n;}) id syncthing.folders.${id}) (clients syncthing);
}
