{inputs, ...}: {
  imports = inputs.canivete.canivete.${builtins.currentSystem}.devenv.modules;

  name = "SvelteKit Demo";

  languages.javascript = {
    enable = true;
    bun = {
      enable = true;
      install.enable = true;
    };
  };
  languages.typescript.enable = true;
}
