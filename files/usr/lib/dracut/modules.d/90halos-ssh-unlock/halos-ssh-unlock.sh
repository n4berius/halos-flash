#!/bin/bash
# Runs in the initramfs. When the EFI system partition holds /halos/ssh-unlock/ (put there by
# halosctl ssh-unlock), brings up wired network with DHCP and starts an SSH server whose only
# command answers the disk passphrase prompt. Otherwise it does nothing.
#   halos-ssh-unlock          start (halos-ssh-unlock.service)
#   halos-ssh-unlock teardown before the real system starts: drop the early-boot network, so the
#                             system's own NetworkManager settings (static address, zone) apply
set -u
esp_type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
run=/run/halos-ssh-unlock mnt=/run/halos-esp

if [ "${1:-}" = teardown ]; then
  [ -e "$run/network" ] || exit 0
  timeout 20 systemctl stop nm-initrd.service 2> /dev/null || true
  rm -f /run/NetworkManager/system-connections/default_connection.nmconnection \
    /run/NetworkManager/conf.d/15-carrier-timeout.conf /run/NetworkManager/initrd/neednet
  for d in /sys/class/net/*; do
    n="${d##*/}"; [ "$n" != lo ] || continue
    ip addr flush dev "$n" 2> /dev/null || true
    ip link set "$n" down 2> /dev/null || true
  done
  exit 0
fi

mkdir -p "$run" "$mnt" && chmod 0700 "$run" "$mnt"
# The machine's own disks only: an EFI partition on a USB stick could otherwise turn this on.
internal_esps() {
  lsblk -rno PATH,PARTTYPE,RM,TRAN 2> /dev/null | while read -r p t rm tran; do
    [ "$t" = "$esp_type" ] && [ "$rm" = 0 ] && [ "$tran" != usb ] && echo "$p"
  done
}
# The disk's partitions appear within seconds; give them up to 30.
found="" esps=""
for _ in {1..30}; do
  esps="$(internal_esps)"
  [ -z "$esps" ] || break
  sleep 1
done
for dev in $esps; do
  mount -t vfat -o ro,nodev,nosuid,noexec,umask=0077 "$dev" "$mnt" 2> /dev/null || continue
  src="$mnt/halos/ssh-unlock"
  if [ -s "$src/authorized_keys" ] && [ -s "$src/ssh_host_ed25519_key" ]; then
    cp "$src/authorized_keys" "$src/ssh_host_ed25519_key" "$run/" && found=1
  fi
  umount "$mnt"
  [ -z "$found" ] || break
done
if [ -z "$found" ]; then echo "halos-ssh-unlock: not set up on this machine"; exit 0; fi
chmod 0600 "$run"/*

# Wired network, DHCP, through the initramfs's NetworkManager. nm-initrd.service starts only when
# "neednet" exists, which dracut writes only for network kernel arguments, so write it here.
if [ -x /usr/libexec/nm-initrd-generator ]; then
  /usr/libexec/nm-initrd-generator -- ip=dhcp rd.neednet=1
  mkdir -p /run/NetworkManager/initrd && : > /run/NetworkManager/initrd/neednet
  : > "$run/network"
  systemctl start --no-block nm-initrd.service || true
fi
echo "halos-ssh-unlock: waiting for the disk passphrase over SSH (port 22)"
# sshd re-executes itself, so it needs its absolute path.
exec "$(command -v sshd)" -D -e -f /etc/ssh/halos-unlock.conf
