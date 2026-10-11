# RSS readers synced with miniflux (nixidy/apps/home/miniflux.nix) as tristan:
# newsboat over the miniflux API, Doom elfeed over Fever (elfeed-protocol).
# The password is Bitwarden Secrets Manager `miniflux/tristan-password`, read
# with bws-get (modules/git.nix). Dropped from the old feeds.nix: russ, so, tut.
{config, ...}: let
  inherit (config.canivete.meta) domain people;
  host = "rss.${domain}";
  url = "https://${host}";
  bwsKey = "miniflux/tristan-password";
in {
  home = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.profiles.workstation.enable (lib.mkMerge [
      {
        programs.newsboat = {
          enable = true;
          extraConfig = ''
            urls-source "miniflux"
            miniflux-url "${url}/"
            miniflux-login "${people.me}"
            miniflux-passwordeval "bws-get ${bwsKey}"
          '';
        };
      }
      (lib.mkIf config.programs.doom-emacs.enable {
        programs.doom-emacs = {
          extraPackages = e: [e.elfeed-protocol];
          tangle.init.app.rss = true;
          tangle.config = ''
            (use-package! elfeed-protocol
              :after elfeed
              :config
              (setq! elfeed-use-curl t
                     elfeed-protocol-enabled-protocols '(fever)
                     elfeed-protocol-fever-update-unread-only nil
                     elfeed-protocol-fever-fetch-category-as-tag t
                     elfeed-feeds
                     `(("fever+https://${people.me}@${host}" :api-url "${url}/fever/"
                        :password ,(lambda () (car (process-lines "bws-get" "${bwsKey}"))))))
              (elfeed-protocol-enable))
          '';
        };
      })
    ]);
  };
}
