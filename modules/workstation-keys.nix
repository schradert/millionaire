# The primary user's personal ssh key (~/.ssh/personal, authorized on every host: modules/users.nix)
# and sops age identity (~/.config/sops/age/keys.txt), decrypted from secrets/sops/personal.yaml
# (`ssh/personal`, `age/tristan`) with the host's ssh key, so deploy/pulumi/sops/bws work on every
# NixOS workstation with no key copying. Opt-in per workstation (it must be a
# personal.yaml recipient). NixOS only: the Macs decrypt personal.yaml with that age
# key itself, so it stays hand-placed there (docs/manual-steps.md). Never on cluster-only nodes.
{
  nixos = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: let
    inherit (flake.config.canivete.meta) people;
    inherit (people) me;
    user = config.users.users.${me};
    sopsFile = builtins.path {
      path = ../secrets/sops/personal.yaml;
      name = "sops-personal.yaml";
    };
    sshDir = "${user.home}/.ssh";
    ageDir = "${user.home}/.config/sops/age";
  in {
    options.workstationKeys.enable = lib.mkEnableOption "the personal ssh key and sops age identity (hosts that are recipients of personal.yaml, .sops.yaml)";
    config = lib.mkIf config.workstationKeys.enable {
      sops.secrets = {
        personal-ssh-key = {
          inherit sopsFile;
          key = "ssh/personal";
          path = "${sshDir}/personal";
          owner = me;
          mode = "0600";
        };
        sops-age-key = {
          inherit sopsFile;
          key = "age/tristan";
          path = "${ageDir}/keys.txt";
          owner = me;
          mode = "0600";
        };
      };
      # sops-install-secrets creates missing parents as root; make them the user's first
      system.activationScripts.workstationKeyDirs = {
        deps = ["users" "groups"];
        text = ''
          if [ -d ${user.home} ]; then
            install -d -o ${me} -g ${user.group} -m 0700 ${sshDir} ${user.home}/.config/sops
            install -d -o ${me} -g ${user.group} -m 0700 ${ageDir}
          fi
        '';
      };
      system.activationScripts.setupSecrets.deps = ["workstationKeyDirs"];
      systemd.tmpfiles.rules = [
        "L+ ${sshDir}/personal.pub - - - - ${pkgs.writeText "personal.pub" "${people.users.${me}.profiles.personal.sshPubKey}\n"}"
      ];
    };
  };
}
