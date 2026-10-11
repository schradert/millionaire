# Security CLIs + YubiKey on NixOS clients (enrolment: docs/yubikey.md).
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (config.profiles.yubikey) keys;
    # pam_u2f wants one line per user: user:cred1:cred2 (pamu2fcfg prints user:cred)
    byUser = lib.zipAttrsWith (_: lib.concatLists) (map (line: let
      p = lib.splitString ":" line;
    in {${lib.head p} = lib.tail p;})
    keys);
    authfile = lib.concatLines (lib.mapAttrsToList (user: creds: lib.concatStringsSep ":" ([user] ++ creds)) byUser);
  in {
    config = lib.mkIf config.profiles.yubikey.enable {
      environment.systemPackages = with pkgs; [pam_u2f yubikey-manager yubioath-flutter];
      programs.yubikey-touch-detector.enable = true;
      # One origin for every host so a single enrolment works fleet-wide
      security.pam.u2f = {
        enable = true;
        settings.cue = true;
        settings.origin = "pam://trdos";
        settings.appid = "pam://trdos";
        settings.authfile = lib.mkIf (keys != []) (pkgs.writeText "u2f_keys" authfile);
      };
      services.pcscd.enable = true;
      services.udev.packages = with pkgs; [libfido2 yubikey-personalization];
      # Lock every session when the YubiKey is unplugged
      services.udev.extraRules = ''
        ACTION=="remove", ENV{ID_BUS}=="usb", ENV{ID_VENDOR_ID}=="1050", ENV{ID_MODEL_ID}=="0407", RUN+="${pkgs.systemd}/bin/loginctl lock-sessions"
      '';
    };
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs; [cotp flawz];
    };
  };
}
