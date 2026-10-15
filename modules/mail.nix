# Proton mail on the workstation: protonmail-bridge (headless; systemd user
# unit on Linux, launchd agent on darwin) serves IMAP 127.0.0.1:1143 and SMTP
# 127.0.0.1:1025 (STARTTLS, its own certificate). mbsync pulls to ~/Maildir,
# mu indexes, msmtp sends, Doom mu4e reads.
#
# One-time setup (the bridge's Proton login cannot be declarative):
#   1. Stop the service: `systemctl --user stop protonmail-bridge` or
#      `launchctl bootout gui/$UID/org.nix-community.home.protonmail-bridge`.
#   2. `protonmail-bridge --cli`: `login` (Proton credentials + 2FA), `info`
#      (shows the bridge's IMAP/SMTP password), `cert export` into
#      ~/.local/share/protonmail-bridge (writes cert.pem), `exit`.
#   3. Store that password in Bitwarden Secrets Manager under the key
#      `proton/bridge/password` (bws-get reads it; modules/git.nix).
#   4. Start the service again (home-manager switch or `systemctl --user start`
#      / `launchctl bootstrap`).
{config, ...}: let
  inherit (config.canivete.meta) people;
in {
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
    inherit (people.my.profiles.personal) email;
    account = "proton";
    host = "127.0.0.1";
    cert = "${config.xdg.dataHome}/protonmail-bridge/cert.pem";
    # The bridge's macOS self-updater syncs Dir(Dir(Dir(os.Executable()))) (it
    # assumes <X>.app/Contents/MacOS/bridge). From a nix store path that is
    # /nix/store itself: it copied the whole store (.links, ~100+ MB/s, 7-9k IOPS)
    # into $TMPDIR on every start, starving tccd -> WindowServer watchdog ->
    # forced logout. Run a copy inside a tiny fake bundle so the bundle root is
    # just the binary.
    bridgeApp = pkgs.runCommand "protonmail-bridge-app" {} ''
      d="$out/Proton Mail Bridge.app/Contents/MacOS"
      mkdir -p "$d"
      cp ${pkgs.protonmail-bridge}/bin/protonmail-bridge "$d/protonmail-bridge"
    '';
    bridgeExe = "${bridgeApp}/Proton Mail Bridge.app/Contents/MacOS/protonmail-bridge";
    sync = pkgs.writeShellScript "mail-sync" ''
      ${lib.getExe pkgs.isync} --all && ${lib.getExe pkgs.mu} index
    '';
  in {
    config = lib.mkIf (config.profiles.workstation.enable && config.profiles.mail.enable) (lib.mkMerge [
      {
        accounts.email.accounts.${account} = {
          primary = true;
          address = email;
          userName = email;
          realName = people.my.name;
          # Services run with a minimal PATH, hence the profile path.
          passwordCommand = "${config.home.profileDirectory}/bin/bws-get proton/bridge/password";
          folders = {
            inbox = "INBOX";
            sent = "Sent";
            drafts = "Drafts";
            trash = "Trash";
          };
          imap = {
            inherit host;
            port = 1143;
            tls.useStartTls = true;
            tls.certificatesFile = cert;
          };
          smtp = {
            inherit host;
            port = 1025;
            tls.useStartTls = true;
            tls.certificatesFile = cert;
          };
          mbsync = {
            enable = true;
            create = "both";
            expunge = "both";
            remove = "both";
          };
          msmtp.enable = true;
          mu.enable = true;
        };
        programs.mbsync.enable = true;
        programs.msmtp.enable = true;
        programs.mu.enable = true;
      }
      (lib.mkIf isLinux {
        services.protonmail-bridge.enable = true;
        services.mbsync = {
          enable = true;
          postExec = "${lib.getExe pkgs.mu} index";
        };
      })
      (lib.mkIf isDarwin {
        home.packages = [pkgs.protonmail-bridge];
        launchd.agents.protonmail-bridge = {
          enable = true;
          config = {
            ProgramArguments = [bridgeExe "--noninteractive"];
            RunAtLoad = true;
            KeepAlive = true;
          };
        };
        launchd.agents.mail-sync = {
          enable = true;
          config = {
            ProgramArguments = ["${sync}"];
            StartInterval = 900;
          };
        };
      })
      (lib.mkIf config.programs.doom-emacs.enable {
        programs.doom-emacs = {
          extraPackages = e: [e.mu4e];
          extraBinPackages = with pkgs; [isync msmtp mu];
          tangle.init.email.mu4e = ["+mbsync" "+org"];
          tangle.config = ''
            (after! mu4e
              (set-email-account! "${account}"
                '((mu4e-sent-folder . "/${account}/Sent")
                  (mu4e-drafts-folder . "/${account}/Drafts")
                  (mu4e-trash-folder . "/${account}/Trash")
                  (mu4e-refile-folder . "/${account}/Archive")
                  (user-mail-address . "${email}"))
                t)
              ;; The bridge files sent mail itself.
              (setq! mu4e-sent-messages-behavior 'delete
                     sendmail-program "msmtp"
                     send-mail-function #'message-send-mail-with-sendmail
                     message-send-mail-function #'message-send-mail-with-sendmail
                     message-sendmail-f-is-evil t
                     message-sendmail-extra-arguments '("--read-envelope-from"))
              (defun my/org-capture-mail ()
                (interactive)
                (call-interactively 'org-store-link)
                (org-capture nil "@"))
              (map! :map mu4e-headers-mode-map "X" #'my/org-capture-mail)
              (map! :map mu4e-view-mode-map "X" #'my/org-capture-mail))
            (after! org
              (add-to-list 'org-capture-templates
                           '("@" "inbox [mu4e]" entry (file "inbox.org")
                             "* DRAFTING Process \"%a\" %?\nEntered on %U"
                             :clock-in t :clock-resume t)))
          '';
        };
      })
    ]);
  };
}
