# halOS guided install (#42): the first boot menu entry. plan-install picks the disk and asks
# for encryption, root and the admin user, then this kickstart installs with no more questions.
# The custom partitioning entry still opens the full graphical installer.
text
lang en_US.UTF-8
keyboard us
timezone Etc/UTC --utc
%include /tmp/halos-plan.ks
bootc --source-imgref containers-storage:@TARGET_IMAGE@ --target-imgref @TARGET_IMAGE@

%pre --erroronfail --interpreter=/usr/bin/bash
# Only emergencies on the screen while questions and passwords are typed.
dmesg -n 1 || true
if grep -qw halos.unattended=1 /proc/cmdline; then
  # The unattended menu entry (the VM test): answers from a volume, nothing typed. Its messages
  # go to the screen and, where there is one, the serial port.
  serial=/dev/null; [ -w /dev/ttyS0 ] && serial=/dev/ttyS0
  HALOS_UNATTENDED=1 /usr/libexec/halos/plan-install /tmp/halos-plan.ks < /dev/null 2>&1 \
    | tee "$serial" > /dev/console
  exit "${PIPESTATUS[0]}"
fi
# The questions get console 8 to themselves, away from the installer's own output. Not 2 to 6:
# switching to those makes logind start Anaconda's root shell there (autovt@, NAutoVTs=6), which
# would read the same keystrokes. If the switch fails, ask nothing: typed passwords would land in
# the installer's own console instead.
if ! chvt 8; then
  echo "The guided install needs a text console. Use the custom partitioning entry." > /dev/console
  exit 1
fi
/usr/libexec/halos/plan-install /tmp/halos-plan.ks < /dev/tty8 > /dev/tty8 2>&1
rc=$?
chvt 1 || true
exit $rc
%end

%post --nochroot --interpreter=/usr/bin/bash
# halOS images are signed (#46). The bootc line installs without checking signatures; this turns
# the check on for every update (bootc's in-place switch, made for an installer's %post). It needs
# the disk's top level at /sysroot inside the new system, which Anaconda's bootc install doesn't
# bind (only its OSTree install does), so bind it here. Should it fail, the install still boots,
# the selftest warns, and halosctl upgrade turns it on later.
root="${ANA_INSTALL_PATH:-/mnt/sysroot}"; physical=/mnt/sysimage
[ -d "$physical/ostree/deploy" ] || { echo "halOS: no OSTree deployment at $physical" > /dev/console; exit 1; }
mount --bind "$physical" "$root/sysroot" || exit 1
chroot "$root" bootc switch --mutate-in-place --enforce-container-sigpolicy @TARGET_IMAGE@ 2>&1 | tee /dev/console
rc=${PIPESTATUS[0]}
umount "$root/sysroot"
exit "$rc"
%end
