#!/bin/bash
# shellcheck disable=SC2154 # dracut sets moddir, initdir and systemdsystemunitdir.
# halOS: unlock the disk from a tang server on the network (#44). Every machine boots the same
# initramfs from the image, so nothing machine-specific is built in: at boot halos-tang-unlock
# looks for a clevis binding that names a tang server in the LUKS header (halosctl tang-unlock
# puts it there). Only then does it start the network and clevis's password agent, which asks the
# server (and the TPM, in "and" mode) and answers the passphrase prompt. Other machines start
# neither, so their boot is as before.

check() {
  require_binaries clevis clevis-luks-list clevis-decrypt-tang jose cryptsetup lsblk || return 1
  # Only when asked for, by dracut.conf.d/10-halogen-tpm2.conf.
  return 255
}

depends() {
  echo systemd halos-initrd-net clevis clevis-pin-tang clevis-pin-sss clevis-pin-tpm2
}

install() {
  inst_multiple lsblk grep sleep awk bash systemctl
  inst_script "$moddir/halos-tang-unlock.sh" /usr/libexec/halos-tang-unlock
  inst_simple "$moddir/halos-tang-unlock.service" "$systemdsystemunitdir/halos-tang-unlock.service"
  $SYSTEMCTL -q --root "$initdir" add-wants initrd.target halos-tang-unlock.service
  # clevis's own module starts its password agent on every machine, whenever a passphrase is
  # asked for; halos-tang-unlock starts it only where a tang binding exists.
  # (systemctl add-wants writes the link under /etc; either place counts.)
  rm -f "$initdir/etc/systemd/system/cryptsetup.target.wants/clevis-luks-askpass.path" \
    "$initdir$systemdsystemunitdir/cryptsetup.target.wants/clevis-luks-askpass.path"
}
