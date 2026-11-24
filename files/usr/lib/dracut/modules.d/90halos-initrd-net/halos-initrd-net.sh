#!/bin/bash
# Runs in the initramfs: the early-boot network for unlocking the disk, shared by halos-ssh-unlock
# (#13) and halos-tang-unlock (#44). Each starts it only when this machine is set up for it, so a
# machine with neither never starts the network before the system.
#   halos-initrd-net up        wired network with DHCP, through the initramfs's NetworkManager;
#                              a second call does nothing
#   halos-initrd-net teardown  before the real system starts: drop it, so the system's own
#                              NetworkManager settings (static address, zone) apply
set -u
run=/run/halos-initrd-net

case "${1:-}" in
  up)
    # mkdir is atomic: of two units asking at once, one starts it.
    mkdir "$run" 2> /dev/null || exit 0
    chmod 0700 "$run"
    [ -x /usr/libexec/nm-initrd-generator ] || { echo "halos-initrd-net: no NetworkManager in the initramfs"; exit 1; }
    /usr/libexec/nm-initrd-generator -- ip=dhcp rd.neednet=1
    # nm-initrd.service starts only when "neednet" exists, which dracut writes only for network
    # kernel arguments, so write it here.
    mkdir -p /run/NetworkManager/initrd && : > /run/NetworkManager/initrd/neednet
    : > "$run/up"
    systemctl start --no-block nm-initrd.service || true
    ;;
  teardown)
    [ -e "$run/up" ] || exit 0
    timeout 20 systemctl stop nm-initrd.service 2> /dev/null || true
    rm -f /run/NetworkManager/system-connections/default_connection.nmconnection \
      /run/NetworkManager/conf.d/15-carrier-timeout.conf /run/NetworkManager/initrd/neednet
    for d in /sys/class/net/*; do
      n="${d##*/}"; [ "$n" != lo ] || continue
      ip addr flush dev "$n" 2> /dev/null || true
      ip link set "$n" down 2> /dev/null || true
    done
    ;;
  *) echo "usage: halos-initrd-net up|teardown" >&2; exit 2 ;;
esac
