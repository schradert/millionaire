# Security CLIs + YubiKey on NixOS clients. Unported: metasploit (old/old/security/default.nix).
# YubiKey enrolment is per key, on the device:
#   pamu2fcfg -o pam://trdos -i pam://trdos >> ~/.config/Yubico/u2f_keys
#   ssh-keygen -t ed25519-sk -O resident -O verify-required
{
  nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.yubikey.enable {
      environment.systemPackages = with pkgs; [pam_u2f yubikey-manager yubioath-flutter];
      programs.yubikey-touch-detector.enable = true;
      # One origin for every host so a single enrolment works fleet-wide
      security.pam.u2f = {
        enable = true;
        settings.cue = true;
        settings.origin = "pam://trdos";
        settings.appid = "pam://trdos";
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
