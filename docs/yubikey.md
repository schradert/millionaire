# YubiKey (NixOS clients)

`profiles.yubikey.enable` (default: on for `profiles.client` hosts, see
`modules/security.nix`) turns on pam_u2f for every PAM service (login, SDDM, screen unlock; sudo is passwordless on clients), pcscd, the FIDO
udev rules, the touch detector and a rule that locks every session when the key
is unplugged. Every host uses the same origin/appid `pam://trdos`, so one
enrolment per key works fleet-wide.

## One-time enrolment, per physical key

Needs the key plugged in and a touch; nothing secret is produced (the output is
a key handle and a public key).

1. pam_u2f credential:

   ```sh
   pamu2fcfg -o pam://trdos -i pam://trdos     # prints tristan:<handle>,<pubkey>,es256,+presence
   ```

2. Add the printed line to `profiles.yubikey.keys` (one entry per key; entries
   for the same user are merged into one authfile line), e.g. in a shared
   module or the host's `static/<node>.nix`:

   ```nix
   profiles.yubikey.keys = [
     "tristan:<handle>,<pubkey>,es256,+presence"
   ];
   ```

   While the list is empty, pam_u2f reads `~/.config/Yubico/u2f_keys`
   instead; `pamu2fcfg … >> ~/.config/Yubico/u2f_keys` works as a stopgap on a
   single host.

3. Resident ssh key on the YubiKey (`ed25519-sk`), then add the `.pub` to
   GitHub / `canivete.meta.people` as needed:

   ```sh
   ssh-keygen -t ed25519-sk -O resident -O verify-required -C tristan@yubikey
   ssh-keygen -K          # on another machine: pull the resident key handle back out
   ```

A login prompt that says "Please touch the device" is pam_u2f (`cue`);
without the key it falls through to the password.
