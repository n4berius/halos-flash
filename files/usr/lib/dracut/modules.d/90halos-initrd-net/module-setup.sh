#!/bin/bash
# shellcheck disable=SC2154 # dracut sets moddir, initdir and systemdsystemunitdir.
# halOS: the early-boot network for unlocking the disk, started only by halos-ssh-unlock (#13) or
# halos-tang-unlock (#44) when this machine is set up for them, and dropped before switch-root.

check() {
  # Only when another module asks for it.
  return 255
}

depends() {
  echo systemd network-manager
}

install() {
  inst_multiple ip timeout rm mkdir chmod bash
  inst_multiple -o /usr/libexec/nm-initrd-generator
  inst_script "$moddir/halos-initrd-net.sh" /usr/libexec/halos-initrd-net
  inst_simple "$moddir/halos-initrd-net-teardown.service" "$systemdsystemunitdir/halos-initrd-net-teardown.service"
  $SYSTEMCTL -q --root "$initdir" add-wants initrd-switch-root.target halos-initrd-net-teardown.service
  # Never wait for the network: it starts late, and a machine without a cable must still boot (the
  # TPM or a keyboard unlocks it). network-manager's own wait would block the initqueue for up to
  # an hour once its condition file exists.
  $SYSTEMCTL -q --root "$initdir" mask nm-wait-online-initrd.service
}
