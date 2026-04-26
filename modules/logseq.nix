{
  home = {
    config,
    lib,
    pkgs,
    ...
  }: let
    lsq = pkgs.buildGoModule {
      pname = "lsq";
      version = "1.5.0";
      src = pkgs.fetchFromGitHub {
        owner = "jrswab";
        repo = "lsq";
        rev = "v1.5.0";
        hash = "sha256-sgCYjkV39dG40v4KuX1BOCr5FIrB66l2oueBzHeoNwI=";
      };
      vendorHash = "sha256-ZSyfmwhc0FhQ+lLNBVNvJZB/OfR2zwGR6j1ddpY3QxQ=";
      meta.description = "Ultra-fast CLI companion for Logseq";
    };
    c = config.lib.stylix.colors.withHashtag;
    logseqThemeCSS = ''
      .dark-theme,
      html[data-theme="dark"] {
        /* ── Base palette from stylix ── */
        --background: ${c.base00};
        --light-background: ${c.base01};
        --lighter-background: ${c.base02};
        --dark-background: ${c.base00};
        --darker-background: ${c.base00};
        --current-line: ${c.base02};
        --comment: ${c.base03};
        --white: ${c.base05};
        --white-hover: ${c.base05}80;
        --red: ${c.base08};
        --orange: ${c.base09};
        --yellow: ${c.base0A};
        --green: ${c.base0B};
        --purple: ${c.base0F};
        --purple-hover: ${c.base0F}80;
        --cyan: ${c.base0C};
        --cyan-hover: ${c.base0C}80;
        --pink: ${c.base0E};
        --pink-hover: ${c.base0E}80;

        /* ── Typography ── */
        --ls-page-text-size: 16px;
        --ls-page-title-size: 36px;
        --ls-font-weight-light: 300;
        --ls-font-weight-regular: 400;
        --ls-font-weight-medium: 500;
        --ls-font-line-height: 1.5;
        --ls-border-radius-low: 3px;
        --ls-border-radius-medium: 6px;

        /* ── Primary background colors ── */
        --ls-primary-background-color: ${c.base00};
        --ls-secondary-background-color: ${c.base01};
        --ls-tertiary-background-color: ${c.base02};
        --ls-quaternary-background-color: ${c.base02};
        --ls-quinary-background-color: ${c.base00};

        /* ── Text colors ── */
        --ls-primary-text-color: ${c.base05};
        --ls-secondary-text-color: ${c.base04};
        --ls-title-text-color: ${c.base05};
        --ls-head-text-color: ${c.base05};

        /* ── Links and tags ── */
        --ls-link-text-color: ${c.base0D};
        --ls-link-text-hover-color: ${c.base0D};
        --ls-link-ref-text-color: ${c.base0D};
        --ls-link-ref-text-hover-color: ${c.base0D};
        --ls-tag-text-color: ${c.base0F};
        --ls-tag-text-hover-color: ${c.base0F}80;
        --ls-tag-text-opacity: 0.8;
        --ls-tag-text-hover-opacity: 0.8;

        /* ── Active / accent colors ── */
        --ls-active-primary-color: ${c.base0E};
        --ls-active-secondary-color: ${c.base0E};

        /* ── Borders and UI ── */
        --ls-border-color: ${c.base03};
        --ls-icon-color: ${c.base03};
        --ls-guideline-color: ${c.base02};
        --ls-menu-color: ${c.base00};
        --ls-menu-hover-color: ${c.base01};

        /* ── Sidebar ── */
        --ls-left-sidebar-bg-color: ${c.base00};
        --ls-right-sidebar-bg-color: ${c.base00};

        /* ── Search ── */
        --ls-search-background-color: ${c.base00};

        /* ── Scrollbar ── */
        --ls-scrollbar-background-color: ${c.base00};
        --ls-scrollbar-foreground-color: ${c.base03};
        --ls-scrollbar-thumb-hover-color: ${c.base02};

        /* ── Block highlights and selection ── */
        --ls-block-highlight-color: ${c.base02};
        --ls-selection-background-color: ${c.base02};
        --ls-selection-text-color: ${c.base05};
        --ls-block-properties-background-color: ${c.base00};

        /* ── Code blocks ── */
        --ls-page-inline-code-color: ${c.base0B};
        --ls-page-inline-code-bg-color: ${c.base00};

        /* ── Blockquotes ── */
        --ls-page-blockquote-bg-color: ${c.base01};
        --ls-page-blockquote-color: ${c.base05};
        --ls-page-blockquote-border-color: ${c.base0A};

        /* ── Header colors ── */
        --ls-header-1-color: ${c.base0F};
        --ls-header-2-color: ${c.base0E};
        --ls-header-3-color: ${c.base0B};
        --ls-header-4-color: ${c.base0A};
        --ls-header-5-color: ${c.base0C};
        --ls-header-6-color: ${c.base09};

        /* ── Nested block color levels ── */
        --color-level-1: ${c.base01};
        --color-level-2: ${c.base00};
        --color-level-3: ${c.base02};
        --color-level-4: ${c.base02};
        --color-level-5: ${c.base00};

        /* ── Logseq color palette ── */
        --rx-logseq-red: ${c.base08};
        --rx-logseq-orange: ${c.base09};
        --rx-logseq-yellow: ${c.base0A};
        --rx-logseq-green: ${c.base0B};
        --rx-logseq-blue: ${c.base0D};
        --rx-logseq-blue-deep: ${c.base0C};
        --rx-logseq-purple: ${c.base0F};
        --rx-logseq-pink: ${c.base0E};
      }
    '';
  in {
    config = lib.mkIf config.profiles.workstation.enable {
      home.packages = [
        pkgs.logseq
        lsq
      ];
      # Generated theme CSS available at ~/.config/logseq/custom.css
      # Copy or symlink into any graph's logseq/custom.css directory
      home.file.".config/logseq/custom.css".text = logseqThemeCSS;
    };
  };
}
