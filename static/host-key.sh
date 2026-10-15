#!/bin/sh
# Install a provisioned ssh host key (secrets/sops/hostkeys.yaml: tristan-only, private halves of
# the &piper/&echidna/&gargoyle anchors in .sops.yaml) so the host can decrypt its sops secrets
# from its first boot. Needs `sops` (devshell) and tristan's age key.
#
#   host-key.sh ssh <host> <ssh target>   put it on a running host (sudo over ssh), restart sshd
#   host-key.sh image <host> <raw image>  write it into the root partition of an SD image (an
#                                         uncompressed .img: `zstd -d`; needs e2fsprogs and
#                                         util-linux: nix shell nixpkgs#e2fsprogs nixpkgs#util-linux)
#   host-key.sh pub <host>                print the public half
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
file="$root/secrets/sops/hostkeys.yaml"
mode=${1:?usage: host-key.sh ssh|image|pub <host> [target]}
host=${2:?host}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077
sops --decrypt --extract "[\"$host\"]" "$file" > "$tmp/key"
ssh-keygen -y -f "$tmp/key" > "$tmp/key.pub"
case $mode in
  pub) cat "$tmp/key.pub" ;;
  ssh)
    target=${3:?ssh target}
    ssh "$target" "sudo install -d -m 755 /etc/ssh && sudo tee /etc/ssh/ssh_host_ed25519_key > /dev/null && sudo chmod 600 /etc/ssh/ssh_host_ed25519_key" < "$tmp/key"
    ssh "$target" "sudo tee /etc/ssh/ssh_host_ed25519_key.pub > /dev/null && sudo systemctl restart sshd" < "$tmp/key.pub"
    ;;
  image)
    img=${3:?raw image}
    # the root partition is the last one
    read -r start size <<EOF
$(sfdisk --json "$img" | python3 -c 'import json,sys; p=json.load(sys.stdin)["partitiontable"]["partitions"][-1]; print(p["start"], p["size"])')
EOF
    dd if="$img" of="$tmp/root.ext4" bs=512 skip="$start" count="$size" status=none
    cat > "$tmp/cmds" <<EOF
mkdir /etc
mkdir /etc/ssh
write $tmp/key /etc/ssh/ssh_host_ed25519_key
write $tmp/key.pub /etc/ssh/ssh_host_ed25519_key.pub
sif /etc/ssh/ssh_host_ed25519_key mode 0100600
sif /etc/ssh/ssh_host_ed25519_key.pub mode 0100644
EOF
    debugfs -w -f "$tmp/cmds" "$tmp/root.ext4" > /dev/null
    debugfs -R "stat /etc/ssh/ssh_host_ed25519_key" "$tmp/root.ext4" 2> /dev/null | grep -q "Mode:  0600" || {
      echo "key not in the image" >&2
      exit 1
    }
    dd if="$tmp/root.ext4" of="$img" bs=512 seek="$start" conv=notrunc status=none
    echo "host key for $host written into $img"
    ;;
  *) echo "unknown mode $mode" >&2; exit 1 ;;
esac
