{
  system = {
    config,
    flake,
    lib,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) {
      nixpkgs.overlays = [
        (_: prev: {
          datadog-pup = prev.rustPlatform.buildRustPackage {
            pname = "datadog-pup";
            version = "0.52.0-unstable-${flake.inputs.datadog-pup.shortRev or "dirty"}";
            src = flake.inputs.datadog-pup;
            cargoLock = {
              lockFile = "${flake.inputs.datadog-pup}/Cargo.lock";
              outputHashes."datadog-api-client-0.29.0" = "sha256-ch27o26Z30UqlrRxzXOdltVpSuhJys66tfj3Ut99BAA=";
            };
            nativeBuildInputs = [prev.pkg-config];
            buildInputs =
              [prev.openssl]
              ++ lib.optionals prev.stdenv.hostPlatform.isDarwin [prev.apple-sdk]
              ++ lib.optionals prev.stdenv.hostPlatform.isLinux [prev.libsecret prev.dbus];
            doCheck = false;
            meta = {
              description = "Datadog CLI for AI agents";
              homepage = "https://github.com/datadog-labs/pup";
              license = lib.licenses.asl20;
              mainProgram = "pup";
            };
          };
        })
      ];
    };
  };
  home = {
    config,
    flake,
    lib,
    pkgs,
    ...
  }: {
    config = lib.mkIf (config.profile == "work" && config.profiles.workstation.enable) (let
      skills =
        lib.mapAttrs (name: _: "${flake.inputs.datadog-agent-skills}/${name}")
        (lib.filterAttrs (_: t: t == "directory") (builtins.readDir flake.inputs.datadog-agent-skills));
    in {
      home.packages = [pkgs.datadog-pup];
      programs.mcp.servers.datadog = {
        type = "http";
        url = "https://mcp.datadoghq.com/api/mcp?toolsets=core,apm,dbm,error-tracking";
      };
      programs.claude-code.skills = skills;
      programs.opencode.skills = skills;
      # FIXME drop when home-manager's programs.claude-code gains a `plugins` option.
      home.file.".claude/plugins/datadog-api".source = flake.inputs.datadog-api-claude-plugin;
    });
  };
}
