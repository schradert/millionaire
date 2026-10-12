# Syncthing: the devices that may connect and the folders that sync (data in modules/syncthing.nix).
# The hub (nixidy/apps/home/syncthing.nix) and every client (modules/syncthing.nix) read this table.
{
  can,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  profiles = ["workstation" "gaming"];
  deviceID = types.strMatching "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}";
in {
  options.syncthing = {
    devices = can.attrs.submodule "devices by name; one is accepted only through the ID recorded here. `hub` is the cluster hub" ({name, ...}: {
      options = {
        id = mkOption {
          type = types.nullOr deviceID;
          default = null;
          description = "device ID (`syncthing --device-id` on the device); null until recorded, and a device without one is not accepted";
        };
        os = can.enum ["linux" "darwin" "android"] "picks each folder's path" {default = "linux";};
        profiles = mkOption {
          type = types.listOf (types.enum profiles);
          default = [];
          description = "profiles enabled on the device (keep in step with its static/<host>.nix); a folder applies to it through these";
        };
        folders = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "folder ids shared with the device, whatever its profiles; null picks them by profile";
        };
      };
    });
    folders = can.attrs.submodule "folders by id" ({name, ...}: {
      options = {
        label = can.str "label shown in the GUIs" {default = name;};
        hub = {
          volume = can.enum ["docs" "saves" "org"] "hub volume, mounted at /var/syncthing/<volume> (docs: sync-docs, saves: sync-saves, org: org-files)" {};
          dir = can.str "single directory under the volume; empty is the volume root" {default = "";};
        };
        path = {
          linux = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "path relative to $HOME on Linux; null keeps the folder off Linux";
          };
          darwin = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "path relative to $HOME on macOS; null keeps the folder off macOS";
          };
        };
        type = can.enum ["sendreceive" "sendonly"] "sendonly: clients only send and the hub only receives, so the hub never overwrites a client's declarative state" {default = "sendreceive";};
        versioning = mkOption {
          type = types.nullOr (types.submodule {
            options = {
              type = can.enum ["simple" "staggered" "trashcan"] "Syncthing versioning type" {};
              params = can.attrs.str "its parameters (https://docs.syncthing.net/users/versioning.html)" {};
            };
          });
          default = null;
          description = "versions kept on the hub, which receives every change";
        };
        ignore = can.list.str "Syncthing ignore patterns on the clients" {default = [];};
        profiles = mkOption {
          type = types.listOf (types.enum profiles);
          default = [];
          description = "devices with one of these profiles carry the folder";
        };
        hosts = mkOption {
          type = types.nullOr (types.listOf types.str);
          default = null;
          description = "only these hosts (networking.hostName) carry the folder; null is every host with a matching profile";
        };
      };
    });
  };
}
