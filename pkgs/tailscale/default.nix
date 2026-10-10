# Held below 1.98; see pin.json.
{
  tailscale,
  pin,
  src,
}:
tailscale.overrideAttrs {
  inherit (pin) version;
  inherit src;
  inherit (pin.hashes) vendorHash;
}
