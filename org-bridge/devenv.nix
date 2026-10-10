{
  inputs,
  pkgs,
  ...
}: {
  imports = inputs.canivete.canivete.${builtins.currentSystem}.devenv.modules;

  name = "org-bridge Development";

  languages.rust = {
    enable = true;
    channel = "stable";
    components = ["rustc" "cargo" "clippy" "rustfmt" "rust-analyzer"];
  };

  packages = with pkgs; [
    cargo-watch
    cargo-nextest
    cargo-tarpaulin
    sqlite
  ];

  env = {
    ORG_DIR = "./test-fixtures/org";
    SYNCTHING_URL = "http://localhost:8384";
    SYNCTHING_API_KEY = "dev-api-key";
    CALDAV_URL = "http://localhost:5232/dav.php/calendars/admin/org/";
    CALDAV_USERNAME = "admin";
    CALDAV_PASSWORD = "admin";
    STATE_DB_PATH = "/tmp/org-bridge-dev.db";
  };

  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy.enable = true;
  };

  processes = {
    org-bridge.exec = "cargo watch -x run";
    baikal.exec = "${pkgs.podman}/bin/podman run --rm -p 5232:80 -e BAIKAL_ADMIN_PASSWORD=admin ckulka/baikal:0.10.1-nginx";
  };

  containers.org-bridge = {
    name = "org-bridge";
    startupCommand = "org-bridge";
  };

  enterShell = ''
    echo "org-bridge development environment"
    echo ""
    echo "  devenv up        start all services (hot reload + local Baikal)"
    echo "  cargo test       run tests"
    echo "  cargo nextest    run tests (faster runner)"
    echo "  cargo clippy     lint"
    echo "  cargo fmt        format"
    echo "  cargo tarpaulin  code coverage"
    echo ""

    # Create test fixtures dir if missing
    mkdir -p test-fixtures/org
  '';
}
