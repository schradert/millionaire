{
  home = {
    can,
    config,
    lib,
    pkgs,
    ...
  }: {
    options.languages.rust.enable = can.enable "rust toolchain" {default = config.profiles.languages.enable;};
    config = lib.mkIf config.languages.rust.enable {
      home.sessionVariables.CARGO_HOME = "${config.xdg.dataHome}/cargo";
      home.packages = with pkgs; [cargo clippy rust-analyzer rustc rustfmt];
      programs.doom-emacs = {
        tangle.init.lang.rust = ["+lsp" "+tree-sitter"];
        tangle.config = ''
          (after! dap-mode
            (dap-register-debug-template "Rust::GDB Run Configuration"
                                         (list :type "gdb"
                                               :request "launch"
                                               :name "GDB::Run"
                                               :gdbpath "rust-gdb"
                                               :target nil
                                               :cwd nil)))
        '';
      };
    };
  };
}
