# Syncthing devices and folders (options/syncthing.nix). The hub applies them to itself
# (nixidy/apps/home/syncthing.nix, app-bootstrap syncthing) and each client to its own
# Syncthing (the `home` module below), so a device is accepted only by an ID recorded here.
# Folder ids follow docs/games-inventory.md (saves map).
{...}: let
  everywhere = p: {
    linux = p;
    darwin = p;
  };
  # `~/.config/<app>` on Linux, Application Support on macOS
  app = linux: darwin: {
    inherit linux;
    darwin = "Library/Application Support/${darwin}";
  };
  staggered = days: {
    type = "staggered";
    params = {
      cleanInterval = "3600";
      maxAge = toString (days * 86400);
    };
  };
  # the Steam account shared by the Deck and falcon (docs/games-inventory.md)
  steamUser = "314551894";
  steam = ".local/share/Steam";
  # `_retail_` of World of Warcraft in the Deck's Battle.net prefix: the shortcut that created it
  # (compatdata 3175038736) is older than the current one, which has no prefix yet
  wow = "${steam}/steamapps/compatdata/3175038736/pfx/drive_c/Program Files (x86)/World of Warcraft/_retail_";
  both = ["workstation" "gaming"];
in {
  syncthing.devices = {
    # The hub's pinned identity (nixidy/apps/home/syncthing.nix). Redo only if its Secret is lost:
    #   kubectl -n home exec deploy/syncthing -c syncthing -- syncthing --device-id --home /var/syncthing/config
    hub.id = "WHD56GJ-S5XJMEV-PJNFHRL-7XZKKIE-IONK2R2-ZIQEN3P-JSQKR77-GLFEDQE";
    # Each client's identity is declared: `syncthing-identity <host>` (devshell) generates the key
    # pair once, sops-encrypts it to secrets/sops/syncthing-<host>.yaml and prints the ID, which
    # is public and recorded here. The `system` module below installs the pair for the host's Syncthing.
    morgenmuffel = {
      id = "C7KGE3I-GMHHEKH-BMN6GZP-2YGGOYC-6254ZOI-FRRFZG6-5IXYNJY-WQOCLAD";
      os = "darwin";
      profiles = ["workstation"];
    };
    axolotl = {
      id = "SLALODJ-OT6UR6E-TWGHZXV-3DK753M-VYS37AF-HOM6SGQ-MTALRCW-NFDDYQD";
      profiles = ["workstation"];
    };
    falcon = {
      id = "ILNWTY6-I2B6YWV-27IZOEN-JYWZSHN-OWAXB4N-2MDJGAT-KZNILKL-CJPPYAR";
      profiles = ["workstation" "gaming"];
    };
    systeamadeck = {
      id = "H7OCLG5-D3EMV3Z-PMVEMKT-VLL5YGJ-EPDO6HL-HK27L3L-QVBPY63-VST4UAN";
      profiles = ["gaming"];
    };
    # The phone's Syncthing-Fork carries only the notes. Its identity is made by the app: record
    # it from Syncthing-Fork -> menu -> Show device ID (docs/manual-steps.md).
    pixel = {
      os = "android";
      folders = ["org"];
    };
  };

  syncthing.folders = {
    # living files
    org = {
      label = "Org";
      hub.volume = "org";
      path = everywhere "Projects/sabedoria";
      versioning = staggered 30;
      profiles = both;
    };
    documents = {
      label = "Documents";
      hub = {
        volume = "docs";
        dir = "documents";
      };
      path = everywhere "Documents";
      versioning = staggered 30;
      profiles = both;
    };
    downloads-keep = {
      label = "Downloads to keep";
      hub = {
        volume = "docs";
        dir = "downloads-keep";
      };
      path = everywhere "Downloads/keep";
      versioning = staggered 30;
      profiles = both;
    };
    # ID scans, paystubs: also in Syncthing, not Bitwarden alone. Longest history.
    sensitive = {
      label = "Sensitive documents";
      hub = {
        volume = "docs";
        dir = "sensitive";
      };
      path = everywhere "Sensitive";
      versioning = staggered 365;
      profiles = both;
    };

    # game saves, both ways; the hub keeps history against a bad overwrite
    saves-retroarch = {
      label = "RetroArch saves";
      hub = {
        volume = "saves";
        dir = "retroarch";
      };
      path = app ".config/retroarch/saves" "RetroArch/saves";
      versioning = staggered 90;
      # reproducible
      ignore = ["/dolphin-emu/User/Cache"];
      profiles = both;
    };
    states-retroarch = {
      label = "RetroArch states";
      hub = {
        volume = "saves";
        dir = "retroarch-states";
      };
      path = app ".config/retroarch/states" "RetroArch/states";
      versioning = staggered 30;
      profiles = both;
    };
    saves-cemu = {
      label = "Cemu saves";
      hub = {
        volume = "saves";
        dir = "cemu";
      };
      path = app ".local/share/Cemu/mlc01/usr/save" "Cemu/mlc01/usr/save";
      versioning = staggered 90;
      profiles = both;
    };
    saves-duckstation = {
      label = "DuckStation memory cards";
      hub = {
        volume = "saves";
        dir = "duckstation";
      };
      path = app ".local/share/duckstation/memcards" "DuckStation/memcards";
      versioning = staggered 90;
      profiles = both;
    };
    # Battle.net's prefix exists only on the Deck. AddOns there is the Nix-managed ConsolePort
    # symlink (static/systeamadeck.nix), which must not travel.
    wow-wtf = {
      label = "WoW WTF";
      hub = {
        volume = "saves";
        dir = "wow-wtf";
      };
      path.linux = "${wow}/WTF";
      versioning = staggered 90;
      profiles = ["gaming"];
      hosts = ["systeamadeck"];
    };
    wow-interface = {
      label = "WoW Interface";
      hub = {
        volume = "saves";
        dir = "wow-interface";
      };
      path.linux = "${wow}/Interface";
      versioning = staggered 90;
      ignore = ["/AddOns"];
      profiles = ["gaming"];
      hosts = ["systeamadeck"];
    };
    # holds the PS5 registration keys; the hub is backed up encrypted (VolSync)
    chiaki = {
      label = "chiaki-ng";
      hub = {
        volume = "saves";
        dir = "chiaki";
      };
      path.linux = ".config/Chiaki";
      versioning = staggered 90;
      profiles = ["gaming"];
      hosts = ["systeamadeck"];
    };

    # One way, client to hub: the hub never writes into declarative state (the layouts the repo
    # generates, ludusavi's own directory), it only keeps what the clients send.
    steam-input = {
      label = "Steam Input layouts";
      hub = {
        volume = "saves";
        dir = "steam-input";
      };
      path.linux = "${steam}/userdata/${steamUser}/config/controller_configs";
      type = "sendonly";
      versioning = staggered 90;
      profiles = ["gaming"];
    };
    # per-title backups (services.ludusavi), one directory per host
    ludusavi = {
      label = "Ludusavi backups";
      hub = {
        volume = "saves";
        dir = "ludusavi";
      };
      path.linux = ".local/share/ludusavi-backup";
      type = "sendonly";
      versioning = staggered 90;
      profiles = ["gaming"];
    };
  };

  # The host's identity (secrets/sops/syncthing-<host>.yaml, made by `syncthing-identity`), decrypted
  # for the primary user, whose Syncthing installs it as cert.pem/key.pem (`home` below). The set is
  # an option because static/tailnet-personal.nix owns the whole `sops.secrets` of the Deck.
  system = {
    config,
    flake,
    lib,
    ...
  }: let
    inherit (flake.config.canivete.meta.people) me;
    host = toString (config.networking.hostName or "");
    file = ../secrets/sops + "/syncthing-${host}.yaml";
    mine = flake.config.syncthing.devices.${host} or null;
  in {
    options.syncthingIdentity.secrets = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      internal = true;
      description = "sops secrets holding this host's Syncthing certificate and key";
    };
    config = {
      syncthingIdentity.secrets = lib.optionalAttrs (mine != null && mine.id != null && builtins.pathExists file) (lib.listToAttrs (map (part:
        lib.nameValuePair "syncthing-${part}" {
          key = part;
          # by contents, not via the flake source (see modules/sops.nix)
          sopsFile = builtins.path {
            path = file;
            name = "sops-syncthing-${host}.yaml";
          };
          owner = me;
          mode = "0400";
        }) ["cert" "key"]));
      sops.secrets = config.syncthingIdentity.secrets;
    };
  };

  # Each client is a Syncthing of its own, peered with the hub only: no introducer and nothing
  # accepted automatically (overrideDevices/overrideFolders drop whatever is not declared here).
  # Personal workstations and gaming hosts (the Deck included); the work Mac stays out.
  home = {
    config,
    flake,
    lib,
    osConfig ? null,
    pkgs,
    ...
  }: let
    inherit (flake.config) syncthing;
    sync = import ../lib/syncthing.nix {inherit lib;};
    os =
      if pkgs.stdenv.hostPlatform.isDarwin
      then "darwin"
      else "linux";
    host = lib.optionalString (osConfig != null) (toString (osConfig.networking.hostName or ""));
    profiles = lib.filter (p: config.profiles.${p}.enable) ["workstation" "gaming"];
    mine = lib.filterAttrs (_:
      sync.applies {
        name = host;
        inherit os profiles;
      })
    syncthing.folders;
    pathOf = f: "${config.home.homeDirectory}/${f.path.${os}}";
    ignores = f: lib.optional (os == "darwin") "(?d).DS_Store" ++ f.ignore;
    inherit (syncthing.devices) hub;
    secretPath = name: let
      secrets =
        if osConfig == null
        then {}
        else osConfig.sops.secrets or {};
    in
      secrets.${name}.path or null;
  in {
    config = lib.mkIf (config.profile == "personal" && profiles != []) (lib.mkMerge [
      {
        assertions = lib.toList {
          assertion = hub.id != null;
          message = "syncthing.devices.hub.id is not recorded (modules/syncthing.nix)";
        };
        services.syncthing = {
          enable = true;
          # the declared identity (the `system` module above): its device ID is the one in the table
          cert = secretPath "syncthing-cert";
          key = secretPath "syncthing-key";
          overrideDevices = true;
          overrideFolders = true;
          settings = {
            devices.hub = {
              id = hub.id;
              name = "hub";
            };
            folders = lib.mapAttrs' (id: f:
              lib.nameValuePair (pathOf f) {
                inherit id;
                inherit (f) label type;
                devices = ["hub"];
                # macOS, Linux and the hub disagree about permissions
                ignorePerms = true;
                ignorePatterns = ignores f;
              })
            mine;
          };
        };
        # Syncthing refuses a folder without its marker, and an emulator that never ran has made no directory.
        home.activation.syncthing-folders = lib.hm.dag.entryAfter ["writeBoundary"] (lib.concatMapStringsSep "\n" (f: "run mkdir -p ${lib.escapeShellArg (pathOf f)}/.stfolder") (lib.attrValues mine));
      }
      # Per-title save backups from ludusavi's manifest, one directory per host in the synced
      # `ludusavi` folder (sendonly: the hub keeps them, no host restores from another's).
      (lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && config.profiles.gaming.enable) {
        services.ludusavi = {
          enable = true;
          settings = rec {
            manifest.url = "https://raw.githubusercontent.com/mtkennerly/ludusavi-manifest/master/data/manifest.yaml";
            roots = [
              {
                path = "${config.home.homeDirectory}/.local/share/Steam";
                store = "steam";
              }
              {
                path = "${config.home.homeDirectory}/.config/heroic";
                store = "heroic";
              }
            ];
            backup.path = "${pathOf syncthing.folders.ludusavi}/${
              if host == ""
              then "default"
              else host
            }";
            restore.path = backup.path;
          };
        };
      })
    ]);
  };
}
