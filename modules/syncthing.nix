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
    # Placeholders: record each ID from `syncthing --device-id` on the host (docs/manual-steps.md).
    morgenmuffel = {
      os = "darwin";
      profiles = ["workstation"];
    };
    axolotl.profiles = ["workstation"];
    falcon.profiles = ["workstation" "gaming"];
    systeamadeck.profiles = ["gaming"];
    # The phone's Syncthing-Fork carries only the notes.
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
}
