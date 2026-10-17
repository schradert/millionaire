# Which folders of a person's table (`syncthing.users.<user>`, options/syncthing.nix) a device carries; shared by
# the hub (nixidy/apps/home/syncthing.nix) and the clients (modules/syncthing.nix) so both sides agree. The
# `syncthing` argument of `clients` and `sharedWith` is that table: {devices, folders}.
{lib}: rec {
  port = 22000;

  # The names of one person's hub and what hangs off it (nixidy/apps/home/{syncthing,org-bridge}.nix). The owner keeps
  # the names the single hub had (app `syncthing`, host `sync.<domain>`, PVCs `sync-docs`, `sync-saves`, `org-files`);
  # everyone else gets `-<user>` and a PVC of their own per volume. `slug`: DNS-safe form of the username.
  names = {
    owner,
    domain,
  }: user: let
    slug = lib.replaceStrings ["_" "."] ["-" "-"] (lib.toLower user);
    isOwner = user == owner;
  in {
    inherit user slug isOwner;
    # app, release, controller, Service and Secret name of the hub
    instance =
      if isOwner
      then "syncthing"
      else "syncthing-${slug}";
    host =
      if isOwner
      then "sync.${domain}"
      else "sync-${slug}.${domain}";
    # Bitwarden path segment of the identity copy: syncthing/<segment>/{cert,key}
    bitwarden =
      if isOwner
      then "hub"
      else slug;
    # the PVC behind a hub volume (`hub.volume` of a folder)
    claim = volume:
      if isOwner
      then
        {
          docs = "sync-docs";
          saves = "sync-saves";
          org = "org-files";
        }.${
          volume
        }
      else "syncthing-${slug}-${volume}";
    # the org-bridge of that hub and its Secret holding that person's Baïkal login
    bridge =
      if isOwner
      then "org-bridge"
      else "org-bridge-${slug}";
  };

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
