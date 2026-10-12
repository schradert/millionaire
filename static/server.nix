# Headless-server role: srvos's server profile (no docs, no interactive niceties).
# Kept a sibling of ./k8s-node.nix in a node's `imports` (not nested under it) so
# module-merge order, and with it every host's toplevel, is unchanged by the split.
{flake, ...}: {
  imports = [flake.inputs.srvos.nixosModules.server];
}
