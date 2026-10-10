# Chat clients: TUIs, desktop apps (linux clients / darwin casks), IRC in Doom.
# beeper/discord/legcord live in modules/{default,client}.nix, slack in
# modules/work. Dropped: quiet, webcord.
{
  darwin = {
    config,
    lib,
    ...
  }: {
    homebrew.casks = lib.mkIf config.profiles.workstation.enable ["element" "legcord" "session" "signal"];
  };
  home = {
    config,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = with pkgs;
        [nchat profanity scli signal-cli toot tuisky twitch-tui zulip-term]
        ++ lib.optionals (stdenv.hostPlatform.isLinux && config.profiles.client.enable) [discordo element-desktop session-desktop signal-desktop simplex-chat-desktop];
      programs.doom-emacs = {
        extraBinPackages = [pkgs.gnutls];
        tangle.init.app.irc = true;
        # SASL password comes from auth-source (~/.authinfo.gpg).
        tangle.config = ''
          (after! circe
            (set-irc-server! "irc.libera.chat"
                             '(:tls t
                               :port 6697
                               :nick "gobbledigook"
                               :sasl-password
                               (lambda (server)
                                 (+irc-fetch-password :user "tristan" :host "irc.libera.chat"))
                               :channels ("#emacs"))))
          (defun +irc-fetch-password (&rest params)
            (require 'auth-source)
            (if-let* ((match (car (apply #'auth-source-search params)))
                      (secret (plist-get match :secret)))
                (if (functionp secret) (funcall secret) secret)
              (user-error "Password not found for %S" params)))
        '';
      };
    };
  };
}
