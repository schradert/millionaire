# Coder workspace image (docs/dev-workspaces.md): user `coder` (1000) owns a
# single-user Nix store. The workspace mounts its own volume at /nix, so the
# template's init container runs `workspace-seed` to copy this image's store
# into it and register the paths (first start, and every new image tag).
# Project tools come from each repository's devenv; this is only the base.
{
  inputs,
  n2c,
  registry,
}: let
  pkgs = import inputs.nixpkgs {
    system = "x86_64-linux";
    config.allowUnfreePredicate = p: builtins.elem (pkgs.lib.getName p) ["claude-code"];
  };
  toolchain = pkgs.buildEnv {
    name = "workspace-toolchain";
    paths = with pkgs; [
      bashInteractive
      bat
      bzip2
      cacert
      claude-code
      coreutils
      curl
      devenv
      diffutils
      direnv
      eza
      fd
      file
      findutils
      fzf
      gawk
      gh
      git
      gnugrep
      gnused
      gnutar
      gzip
      helix
      htop
      jq
      less
      lazygit
      nix
      nix-direnv
      opencode
      openssh
      patch
      procps
      ripgrep
      tea
      tmux
      tree
      unzip
      util-linux
      which
      xz
      yq-go
      zellij
      zstd
    ];
    pathsToLink = ["/bin" "/share" "/etc"];
  };

  closure = pkgs.closureInfo {rootPaths = [toolchain];};

  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes
    # unprivileged container: no user namespaces, no build users
    sandbox = false
    build-users-group =
    max-jobs = auto
    substituters = https://cache.nixos.org https://nix-community.cachix.org https://devenv.cachix.org
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=
  '';

  profile = pkgs.writeText "profile" ''
    export PATH="$HOME/.nix-profile/bin:$HOME/.local/bin:${toolchain}/bin:$PATH"
    export SSL_CERT_FILE=${toolchain}/etc/ssl/certs/ca-bundle.crt
    export NIX_SSL_CERT_FILE=$SSL_CERT_FILE
    export EDITOR=hx
    case $- in *i*) [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc" ;; esac
  '';

  # Copies the image's store into the volume mounted at /mnt/nix (missing paths
  # only), registers them, and roots the toolchain so a GC in the workspace
  # never removes it. Idempotent.
  seed = pkgs.writeShellApplication {
    name = "workspace-seed";
    runtimeInputs = [pkgs.coreutils pkgs.nix];
    text = ''
      mkdir -p /mnt/nix/store /mnt/nix/var/nix/gcroots
      for path in /nix/store/*; do
        [ -e "/mnt/nix/store/''${path##*/}" ] || cp -a "$path" /mnt/nix/store/
      done
      nix-store --store 'local?root=/mnt' --load-db < ${closure}/registration
      ln -sfn ${toolchain} /mnt/nix/var/nix/gcroots/workspace-toolchain
      echo "seeded ${toolchain}"
    '';
  };

  root = pkgs.runCommand "workspace-root" {} ''
    mkdir -p $out/etc/nix $out/tmp $out/home/coder $out/bin $out/usr/bin $out/mnt/nix
    cat > $out/etc/passwd <<EOF
    root:x:0:0:root:/root:/bin/bash
    coder:x:1000:1000:coder:/home/coder:/bin/bash
    nobody:x:65534:65534:nobody:/nonexistent:/bin/false
    EOF
    cat > $out/etc/group <<EOF
    root:x:0:
    coder:x:1000:
    nobody:x:65534:
    EOF
    # copies, not store links: the workspace's store only keeps the toolchain
    cp ${nixConf} $out/etc/nix/nix.conf
    cp ${profile} $out/etc/profile
    ln -s ${toolchain}/bin/bash $out/bin/bash
    ln -s ${toolchain}/bin/bash $out/bin/sh
    ln -s ${toolchain}/bin/env $out/usr/bin/env
    ln -s ${seed}/bin/workspace-seed $out/bin/workspace-seed
  '';
in
  n2c.buildImage {
    name = "${registry}/library/workspace";
    tag = "0.1.0";
    arch = "amd64";
    # Also usable without a /nix volume (the store and its database as user coder).
    initializeNixDatabase = true;
    nixUid = 1000;
    nixGid = 1000;
    copyToRoot = [root];
    perms = [
      {
        path = root;
        regex = "/tmp";
        mode = "1777";
      }
      {
        path = root;
        regex = "/(home/coder|mnt/nix)";
        mode = "0755";
        uid = 1000;
        gid = 1000;
        uname = "coder";
        gname = "coder";
      }
    ];
    config = {
      User = "1000:1000";
      WorkingDir = "/home/coder";
      Env = [
        "PATH=${toolchain}/bin"
        "HOME=/home/coder"
        "USER=coder"
        "SHELL=/bin/bash"
        "LANG=C.UTF-8"
        "SSL_CERT_FILE=${toolchain}/etc/ssl/certs/ca-bundle.crt"
        "NIX_SSL_CERT_FILE=${toolchain}/etc/ssl/certs/ca-bundle.crt"
      ];
    };
    layers = [
      (n2c.buildLayer {deps = [toolchain];})
      (n2c.buildLayer {deps = [seed];})
    ];
  }
