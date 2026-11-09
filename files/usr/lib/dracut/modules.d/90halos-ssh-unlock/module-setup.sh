#!/bin/bash
# shellcheck disable=SC2154 # dracut sets moddir, initdir and systemdsystemunitdir.
# halOS: an SSH server in the initramfs to unlock the disk (#13). Every machine boots the same
# initramfs from the image, so nothing machine-specific is built in: the keys are read at boot
# from the EFI system partition (/halos/ssh-unlock/), where halosctl ssh-unlock puts them. A
# machine without them starts no network and no server.

check() {
  require_binaries sshd ssh-keygen lsblk || return 1
  # Only when asked for, by dracut.conf.d/10-halogen-tpm2.conf.
  return 255
}

depends() {
  echo systemd network-manager
}

installkernel() {
  hostonly='' instmods vfat
}

install() {
  inst_multiple sshd /usr/libexec/openssh/sshd-session /usr/libexec/openssh/sshd-auth \
    lsblk mount umount cp chmod mkdir rm sleep ip timeout systemd-tty-ask-password-agent bash
  inst_multiple -o /usr/libexec/nm-initrd-generator
  inst_simple "$moddir/sshd_config" /etc/ssh/halos-unlock.conf
  inst_script "$moddir/halos-ssh-unlock.sh" /usr/libexec/halos-ssh-unlock
  inst_simple "$moddir/halos-ssh-unlock.service" "$systemdsystemunitdir/halos-ssh-unlock.service"
  inst_simple "$moddir/halos-ssh-unlock-teardown.service" "$systemdsystemunitdir/halos-ssh-unlock-teardown.service"
  $SYSTEMCTL -q --root "$initdir" add-wants initrd.target halos-ssh-unlock.service
  $SYSTEMCTL -q --root "$initdir" add-wants initrd-switch-root.target halos-ssh-unlock-teardown.service
  # Never wait for the network: halos-ssh-unlock starts it late, and a machine without a cable
  # must still boot (the TPM or a keyboard unlocks it). network-manager's own wait would block
  # the initqueue for up to an hour once its condition file exists.
  $SYSTEMCTL -q --root "$initdir" mask nm-wait-online-initrd.service
  # sshd's privilege-separated user and its empty chroot.
  grep -q '^sshd:' "$initdir/etc/passwd" 2> /dev/null || echo 'sshd:x:74:74:Privilege-separated SSH:/usr/share/empty.sshd:/sbin/nologin' >> "$initdir/etc/passwd"
  grep -q '^sshd:' "$initdir/etc/group" 2> /dev/null || echo 'sshd:x:74:' >> "$initdir/etc/group"
  mkdir -p "$initdir/usr/share/empty.sshd" && chmod 0711 "$initdir/usr/share/empty.sshd"
  # Without a shadow line for root, nss-systemd gives root a locked password ("!*"), and sshd
  # (UsePAM no) refuses a locked account even for keys. "*": no password works, keys do.
  grep -q '^root:' "$initdir/etc/shadow" 2> /dev/null || echo 'root:*:::::::' >> "$initdir/etc/shadow"
  mkdir -p "$initdir/root"
}
