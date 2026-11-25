# Installing halOS

This guide tells you how to install halOS from USB, from the choice of edition to a working API.
After the installation, [Running halOS](docs/GUIDE.md) tells how to use the machine. For
information about how Halogen itself works, see its
[official documentation](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs).

> **Note:** halOS is in alpha. Only the hardware below is tested. So on your first install, do
> the [checks](#7-check-the-install) and
> [report the result](https://github.com/n4berius/halos-flash/issues/new?template=hardware-report.yml).

## Tested hardware

| Machine | Memory | Disk | Release | Edition |
|---|---|---|---|---|
| [AMD Ryzen AI Halo Developer Platform](https://www.microcenter.com/product/711961/amd-ryzen-ai-halo-developer-platform-linux-os) (Micro Center) | 128 GB | 2 TB NVMe | `v0.18.23-alpha.2` to `v0.20.6`, and the `kernel-next` test kernel | With NPU, and without NPU through `halosctl npu off` |

On that machine, these items work:

- USB install with Secure Boot on, and no MOK enrollment. The guided install works since
  `v0.20.0`, and automatic storage makes each volume.
- First-boot download of the Halogen container and about 130 GB of models.
- Halogen on the GPU, with all 5 NPU models loaded.
- Access to the API from other machines: Hermes, Open WebUI, Claude Code, Pi and oh-my-pi.

Since `v0.20.0`, these items also work:

- The selftest, the benchmark and `flash check`
- The change between the two editions with `halosctl npu off` and `on`
- Tab completion and restarts
- A `model pull` of OvisOCR3
- LUKS with TPM unlock, and the fabric clock with Secure Boot on

Not yet confirmed on hardware: a long soak test under real load.

The BIOS of that machine has no UMA frame buffer setting. This is not a problem: the GTT kernel
settings give Halogen its memory in all cases.

## What you need

- A dedicated AMD Strix Halo machine with 128 GB of memory. The GTT settings are for 128 GB.
- A USB drive of 4 GB or more. When you write the ISO to the drive, you erase all data on it.
- An internal disk of 480 GB or more (a 500 GB or 512 GB drive is sufficient). The models use
  about 130 GB (about 120 GB for the edition without NPU).
- Internet access at first boot, to get the Halogen container and the models.
- A second computer, to download the ISO and write it to the USB drive.

## 1. Choose an edition

| | With NPU | Without NPU |
|---|---|---|
| Serves | Flash and NPU models | Flash only |
| IOMMU | On, with `iommu=pt`, which the NPU needs. DMA protection stays on | Off, with `amd_iommu=off`, for 13-16% more prefill (Halogen's measurement). DMA protection is off |
| Fabric clock service | Yes | No |
| KV pool | 262,144 positions, which leaves space for NPU models | Halogen's default |
| Image | `halos-flash:0.20.7` | `halos-flash:0.20.7-no-npu` |

**Note:** Use the no-NPU edition only where no untrusted person can touch the machine. With the
IOMMU off, a device in a USB4/Thunderbolt port or a PCIe slot can read all the memory of the
machine. While the machine runs, this memory includes the disk encryption key.

You can change the edition later, without a new install: `sudo halosctl npu off` moves to the
no-NPU edition, and `sudo halosctl npu on` moves back. The change keeps the same channel or
release, and applies at the next reboot. `/srv` does not change. The NPU models and your own
checkpoints stay on disk, so a return to the NPU edition downloads nothing. While the NPU is off,
the `HALOGEN_NPU_*` settings have no effect. For each one, the log shows "ignored
HALOGEN_NPU_…: not an option this system allows". This is normal.

## 2. Prepare the BIOS

1. Install the newest BIOS from the maker of your machine. Halogen's
   [NPU docs](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#what-the-host-needs)
   tell why this is important.
2. If your BIOS has a UMA frame buffer setting (or a dedicated graphics memory setting), set it
   to its explicit minimum, not Auto. Some machines don't have this setting. This is not a problem.
3. If you want Secure Boot, leave it on. You don't need MOK enrollment.
4. Set the BIOS power settings that you want. Halogen's published numbers are for about 85 W.

## 3. Get the ISO

Download the ISO of your edition and its `.sha256` file from the
[Releases page](https://github.com/n4berius/halos-flash/releases) of this repository. Use the
`-npu` files for the NPU edition and the `-no-npu` files for the other edition. Alpha and RC
releases are pre-releases. [RELEASING.md](RELEASING.md) gives information about each channel.

GitHub limits release files to 2 GiB. So the ISO comes in one of three forms. Check the file in
the folder that you downloaded it to. The check must show `OK`:

| You downloaded | Do this |
|---|---|
| One `.iso` | `sha256sum -c *.iso.sha256` |
| One `.iso.xz` | Run `sha256sum -c *.iso.xz.sha256`. Then unpack the file with `xz -d` (7-Zip on Windows). balenaEtcher can write the `.xz` file directly |
| Several `.iso.partNN` files | Only older releases. Join the files with `cat *.iso.part* > halogen.iso`. Then check with `sha256sum -c *.iso.sha256` |

From `v0.18.23-alpha.3`, each release has one file if compression makes it smaller than the limit.

To build an ISO yourself, see [BUILDING.md](BUILDING.md).

## 4. Write the USB drive

Use [Fedora Media Writer](https://fedoraproject.org/workstation/download/) with its custom image
option, or use `dd` on Linux.

**Warning:** Check the device name before you use `dd`. `dd` overwrites the device and does not
ask first.

```bash
lsblk
sudo dd if=halos-flash-v0.20.7-npu.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## 5. Run the installer

Boot from the USB drive. The first menu entry, **Install halOS**, is the guided install. It asks
some questions on a text screen, and then installs automatically. It erases nothing until you
answer all the questions and say yes at the end.

1. **The disk.** The installer shows the internal disks of the machine. It never shows USB
   drives, including the installer. It shows disks smaller than 480 GB as too small (the models
   alone use about 130 GB).
   - One empty disk: the installer shows the disk and asks **"Erase it and install halOS?"**
   - More than one disk, or a disk with data on it (partitions, an old install, LUKS): the
     installer shows the name, size and model of each disk, and what is on it. **Type the name**
     of the disk to erase, for example `nvme0n1`. If you press Enter instead, the installer stops
     and changes nothing. The machine then powers off at the next Enter.
2. **Name of this machine** on the network. Press Enter to keep `halos`.
3. **Encrypt the disk (LUKS)?** If yes, type the passphrase two times. You type it at each boot,
   until you let the TPM unlock the disk in
   [first-boot setup](#6-first-boot-setup-then-let-the-first-boot-finish).
   With the passphrase, encryption protects the machine and its disk while the machine is off.
   With TPM unlock, it protects only a disk that somebody removes from the machine. See
   [what TPM unlock protects](#what-tpm-unlock-protects-and-what-it-doesnt).
   Use letters, digits and the symbols of a US keyboard, because the boot prompt has that layout.
4. **Enable the root account?** If yes, type its password two times. Root can log in only at the
   screen of the machine, never over SSH. Most people answer no and use `sudo`.
5. **Admin user:** a name and a password. You log in with this account, at the machine and over
   SSH. This account can use `sudo`.
6. **How the disk unlocks at each boot** (only with encryption):
   1. **TPM and SSH** (recommended, Enter): the machine unlocks itself. If it can't (for
      example, after a BIOS update), type the passphrase from another computer over SSH.
   2. **TPM only:** if the TPM can't unlock the disk, type the passphrase at the keyboard of the
      machine.
   3. **SSH only:** type the passphrase from another computer at each boot.
   4. **Neither:** type the passphrase at the keyboard of the machine at each boot.

   The TPM setup occurs at the first boot, in
   [first-boot setup](#6-first-boot-setup-then-let-the-first-boot-finish). For SSH, the installer
   asks where your public keys are:

   - **GitHub, GitLab or Codeberg:** type your user name. This needs a network cable, with DHCP.
   - **Type one key:** the screen of the machine has no clipboard, so an account is easier.

   The installer names the account and shows each key that it found. It asks before it uses the
   keys. If an account has no keys, the installer tells you and asks again. Type **back** to go
   back to the unlock choice. Then the installer asks if the same keys can also log the admin user
   in over SSH (Enter: no).

   The first boot still asks for the passphrase at the keyboard. Then `sudo halosctl setup` sets
   up the TPM. It also shows two lines to add on the computer that you unlock from (see
   [Unlock over SSH at boot](#unlock-over-ssh-at-boot)). From the next boot, SSH unlock works.
7. The installer shows a summary and asks one more time:
   **"Erase nvme0n1 and install halOS now?"**

The install copies the OS from the USB drive, so it needs no network. It takes a few minutes. Then
the machine restarts. When it restarts, remove the USB drive. If you forget, and the machine boots
the USB drive again, the installer does nothing until you answer. The disk now has halOS on it,
so the installer asks you to type its name before it erases anything.

The guided install sets the clock to UTC and gets the network address from DHCP. The time zone
has no effect on Halogen. To change the time zone later, use `sudo timedatectl set-timezone <zone>`.

The disk layout is the same on every machine. Two plain partitions come first: a 1 GiB EFI
partition (`/boot/efi`) and a 2 GiB `/boot`. The `/boot` partition has space for the kernels of
the running system, its rollback and a staged upgrade. The rest of the disk is one LVM volume
with XFS volumes in it. The LVM volume is encrypted if you set a passphrase. The volume group is
always `halos`, whatever the name of the machine:

| Mount | Volume | Size |
|---|---|---|
| `/` | `halos-root` | 40 GiB |
| `/var` | `halos-var` | 60 GiB |
| `/var/log` | `halos-log` | 10 GiB |
| `/var/log/audit` | `halos-audit` | 5 GiB |
| `/var/home` | `halos-home` | 50 GiB |
| `/var/srv/configs` | `halos-configs` | 1 GiB |
| `/var/srv/logs` | `halos-logs` | 4 GiB, for [request records](docs/GUIDE.md#request-records) |
| `/var/srv/models` | `halos-models` | the remaining space: about 300 GiB on a 512 GB disk, 1,690 GiB on a 2 TB disk |

Each [Flash checkpoint of your own](docs/GUIDE.md#your-own-flash-checkpoint) uses about 110 GB more of the
models volume.

**Custom partitioning.** The second menu entry, **Install halOS (custom partitioning)**, opens the
full graphical installer, for unusual configurations. Under **Installation Destination**, select
the disk. **Automatic** makes the volumes above, with sizes that change with the disk size. Its
volume group has the name of the machine, for example `halos_freyja`. **Custom** lets you change
the volumes. Keep 150 GiB or more for `/var/srv/models`.

For LUKS with custom partitioning, select **Encrypt my data**. Make an admin account with admin
rights.

The third entry, **unattended test install**, is for the automated VM test of halOS. It reads its
answers from a prepared volume, and stops if there is no such volume. You don't need it. The other
entries ignore such a volume.

The installed system starts at a text login. You don't need to make another account.

## 6. First-boot setup, then let the first boot finish

Log in as your admin user and run:

```bash
sudo halosctl setup
```

It asks four groups of questions. You can skip each one:

1. **How the disk unlocks at boot.** With the TPM, you type no passphrase while Secure Boot and
   the BIOS stay the same. Setup runs `halogen-enroll-tpm` for you. Or you can type the
   passphrase at each boot. On an encrypted disk, setup also offers SSH unlock (if it is not set
   up already) and unlock from a tang server ([section 8](#8-optional-unlock-the-disk-at-boot)).
   If your account already has an SSH key, it offers
   [SSH logins with keys only](docs/GUIDE.md#ssh-logins-with-keys-only). After a guided
   install, the answers that you gave there are the defaults (Enter). The TPM protects a disk
   that somebody removes from the machine. It doesn't protect the full machine if somebody takes
   it: see [what TPM unlock protects](#what-tpm-unlock-protects-and-what-it-doesnt).
2. **A Hugging Face token.** This is optional. Downloads work without an account, but a free read
   token increases the rate limits, and usually makes the downloads faster. Make a read token at
   [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
3. **Models and settings.** Open the settings screen (`sudo halogenctl settings`), or keep the
   defaults. On a new install, Enter opens it. The defaults are correct for most people. See
   [the settings screen](docs/GUIDE.md#the-settings-screen).
4. **HTTPS.** On a new install, Enter turns HTTPS on, with the halOS authority (self-signed). Then
   apps that use `https://` don't send prompts, replies and the API key across the network as
   plain text. Each app must trust the authority one time: `sudo halosctl https ca` prints it (see
   [HTTPS](docs/GUIDE.md#https)). Enter means yes until you answer this question one time, even
   if you run setup days later. A machine that you upgrade from an earlier release stays on plain
   HTTP until you say yes here or run `sudo halosctl https self-signed`. If HTTPS is already on,
   setup doesn't change it.

The first 130 GB download waits for setup, so your token and settings apply from the start. If
nobody runs setup in 30 minutes, the download starts with the defaults. So a machine that nobody
logs in to still starts its work automatically. `sudo halosctl setup --skip` starts the download
immediately. Machines that you upgrade from an earlier release never wait.

You can run `sudo halosctl setup` again at any time. It then offers to restart Halogen to apply
your changes. To add or change only the token later, run:

```bash
sudo halogenctl hf-token     # paste the token; it isn't shown or printed
sudo halogenctl restart      # the download resumes with the token
```

halOS keeps the token in `/srv/configs/hf-token`. Only the `halogen` service can read it, and it
uses the token only for downloads. To remove the token, run `sudo halogenctl hf-token --remove`.

After setup, the first boot does these steps in this order:

1. `halogen-prepare` makes `/srv/models`, `/srv/configs`, `/srv/logs`, the config file and an API key.
2. On the NPU edition, `halogen-fabric-clock` holds the clock that Halogen needs for GPU and NPU
   together.
3. `halogen-fetch` pulls the pinned Halogen container and downloads the models. An interrupted
   download continues where it stopped. After a network failure, the fetch tries again until it
   succeeds.
4. Halogen's `verify` mode checks the Flash checkpoint. The fetch checks the NPU files against the
   hashes in the pinned container.
5. Halogen starts, with its models read-only. It never downloads anything itself, and its
   container can't open connections out (#120). The network gets to it on port 8731 through
   [Caddy](https://caddyserver.com) ([the front door](docs/GUIDE.md#the-front-door)).

Later boots skip the download, unless the model list or the Halogen version changes.

You can monitor the progress without a login. Above the login prompt, the screen of the machine
shows one line. This line updates automatically every 30 seconds. Before setup, it shows
`waiting for setup: sudo halosctl setup`. Then it shows:

```
halOS 0.20.7-1-stable (npu edition) - downloading models 45%
```

Next it shows `checking models`, then `starting`, and at the end
`ready: https://<this machine's address>:8731/v1` (`http://` while HTTPS is off). If a problem
stops it, the line shows `download failed` or `stopped`, with the next command to run. An SSH login
shows the same line. It also shows the release, the channel, any staged update and the free space
for models. The first time that Halogen answers after a boot, all logged-in users get a one-line
message.

To see the details, log in and run:

```bash
sudo halogenctl fetch-logs
```

It shows the downloaded size every minute. Press Ctrl+C to stop the display. The download
continues.

## 7. Check the install

Run the self-check. It does the full hardware checklist in one step and changes nothing. It shows
nothing private (no keys, serial numbers or network addresses). So you can share its output when
you ask for help:

```bash
sudo halogenctl selftest | tee selftest.txt
```

Each line starts with PASS, WARN, FAIL, SKIP or INFO. For a problem, the line tells you what to
do. While the first boot still downloads, `server` and `models` show as not ready.

You can also run the individual commands:

```bash
sudo halogenctl doctor
sudo halogenctl status
sudo halogenctl config
sudo halosctl https ca > halos-ca.crt
curl --cacert halos-ca.crt -H "Authorization: Bearer $(sudo halogenctl api-key)" https://127.0.0.1:8731/v1/models
```

With HTTPS off, the last line is `curl -H "Authorization: Bearer $(sudo halogenctl api-key)"
http://127.0.0.1:8731/v1/models`, and you don't need the `https ca` line. The API shows the Flash
model, and on the NPU edition also the NPU models. Clients connect to `https://<host>:8731/v1`
(`http://` with HTTPS off) with the same key. [Connecting apps](docs/CLIENTS.md) has the settings
for Claude Code, Codex, Pi, oh-my-pi, opencode, Cline, aider and other apps.

On the first install, please confirm these items:

- `cat /proc/cmdline` shows the GTT settings and the IOMMU setting of your edition.
- If you left Secure Boot on, `bootctl status` shows it as enabled.
- `systemctl --failed` shows nothing. Upstream warns that `systemd-remount-fs.service` can fail on
  bootc systems that Anaconda installed. It did not fail in our VM test.
- `ls -l /dev/kfd /dev/dri/renderD*` shows the group `halogen`.
- `sudo journalctl -b _TRANSPORT=audit + _TRANSPORT=kernel | grep 'avc: *denied'` shows nothing.
  If `/dev/kfd` shows `denied { map }`, run `sudo setsebool -P container_use_devices true`.
- A soak test runs a mix of your real load for several hours. Kernel 7.2 has a reported GPU memory
  fault, and the reference host of Halogen ran 7.1.8.

On the NPU edition, also confirm these items:

- `ls -lZ /dev/accel/accel0` shows the group `halogen` and the type `dri_device_t`.
- `/usr/libexec/halogen/halogen-fabric-clock status` shows that the clock is held. With Secure
  Boot on, the kernel runs in lockdown. The hold works in lockdown on the test machine.

## 8. Optional: unlock the disk at boot

With LUKS, the boot asks for the passphrase at the keyboard of the machine. halOS has three other
ways to unlock the disk:

- [The TPM](#unlock-with-the-tpm) unlocks the disk by itself, while Secure Boot and the BIOS stay
  the same.
- [SSH](#unlock-over-ssh-at-boot) lets you type the passphrase from another computer.
- [A tang server](#unlock-from-a-tang-server-on-your-network) on your network unlocks the disk by
  itself, only while the machine is on that network.

SSH unlock works beside either of the others. The TPM and tang work together only as one of
the `--tpm` modes of the tang unlock (see its section). `sudo halosctl setup` offers each of them.
The passphrase always works too: keep it as your recovery key.

### Unlock with the TPM

```bash
sudo halogen-enroll-tpm
sudo systemctl reboot
```

TPM unlock uses PCR 7, which records the Secure Boot state. So `halogen-enroll-tpm` refuses when
Secure Boot is off: then PCR 7 does not stop a changed boot loader from getting the key. Turn
Secure Boot on first. OS updates and rollbacks don't change the TPM binding. These events change
it:

- You turn Secure Boot off or on.
- You change the Secure Boot keys.
- You clear the TPM.
- Some BIOS updates or Secure Boot revocation-list updates.

After one of these events, the boot asks for the passphrase. Type it, then run
`halogen-enroll-tpm` again. It replaces the old TPM binding, and doesn't add a second one. The CI
install test enrolls the TPM and reboots without a passphrase. But nobody has confirmed this on
hardware yet. If the next boot still asks for the passphrase, report it.

#### What TPM unlock protects, and what it doesn't

With the TPM, the machine unlocks its own disk each time it boots through the normal, signed boot
chain. This protects a **disk taken out of the machine**: in another machine, nobody can read it
without the passphrase. It doesn't protect the **machine taken whole**, or a person with time at
its keyboard. Such a person could boot the halOS installer USB (or another Fedora USB stick). Its
root shell can ask the same TPM to unlock the disk. Or the person could edit the kernel line of
the boot menu to get a shell.

If you type the passphrase at each boot instead, the passphrase protects against both. The cost
is that you must type it.

If somebody could take or tamper with the machine itself, make those two ways in more difficult:

1. **In the BIOS:** set an administrator (setup) password. Allow boot only from the internal disk:
   turn off USB boot and network (PXE) boot. Check that an external drive on a USB4 port can't boot
   either. To install again later, type the password and turn USB boot on again.
2. **A boot menu password,** so that nobody can edit the kernel line:

   ```bash
   sudo grub2-setpassword
   ```

   Select a password that you will keep. Use only letters, digits and the symbols of a US
   keyboard. Don't use spaces, backslashes, `*` or `?`, because the command can save them
   differently from what you type. GRUB asks for the password only when someone edits a boot entry
   or opens the GRUB command line.

   Check the password one time at the screen of the machine:

   1. Reboot. The machine must start automatically, with no password.
   2. The menu shows only for a short time. As soon as it shows, press an arrow key, then `e`.
      The machine must ask for the password.

   Nobody has tested this on halOS hardware yet. If the normal boot starts to ask for the
   password, remove the password with `sudo rm /boot/grub2/user.cfg`.

These steps make it more difficult to take the key of the disk, but not impossible. The boot files
on the disk have no encryption. So a person who can open the case can change them and put the
disk back. Only a passphrase at each boot keeps a stolen machine locked. Even that doesn't protect
a machine that someone changed before you typed the passphrase.

### Unlock over SSH at boot

When the disk waits for its passphrase, you can type the passphrase from another computer. You
don't have to type it at the keyboard of the machine. (For example, the TPM couldn't unlock the
disk after a BIOS update, or you didn't set up the TPM.) Turn this on one time with the public keys
of your GitHub, GitLab or Codeberg account, or with a key that you give:

```bash
sudo halosctl ssh-unlock on --github <your-user-name>
```

`--gitlab`, `--codeberg` and `--key 'ssh-ed25519 AAAA... you@computer'` work the same way. You can
use them together. Without any of them, the command asks. `sudo halosctl setup` also offers SSH
unlock. It shows each key before it uses it, and replaces all keys from before.
`sudo halosctl ssh-unlock` shows the current setup, and `sudo halosctl ssh-unlock off` turns it off.

Then `halosctl ssh-unlock` shows two items for the computer that you unlock from. Add both one
time:

- An entry for `~/.ssh/config`. Set its `HostName` to the name or address that you use for the
  machine:

  ```
  Host freyja-unlock
      HostName freyja
      User root
      HostKeyAlias freyja-unlock
  ```

- A `known_hosts line` for `~/.ssh/known_hosts`, which starts with `freyja-unlock`.

The server that answers before the disk unlock has its own host key, not the key of the system.
Your computer trusts that key under its own name, only for unlock, never for the running system.
`ssh freyja` doesn't change.

Then, each time the machine waits for the passphrase:

```bash
ssh freyja-unlock
```

Type the passphrase, and the boot continues. If the passphrase is wrong, it asks again. If you
connect while the TPM still tries, the prompt shows when the TPM stops trying. Only `root` can get in,
only with these keys, and only to the passphrase prompt. The network is wired, with DHCP. The boot
stops this network before the system starts, so the network settings of the system apply.

The TPM still unlocks the disk automatically when it can. SSH is the way in when the TPM can't.

**Warning:** If ssh ever says that this host key changed, don't type the passphrase. A different
machine can be the one that asks for it.

`halosctl ssh-unlock` (and `setup`) also keeps the fingerprints of these keys and of the early-boot
host key on the encrypted disk. If the copies on the EFI partition change without your knowledge,
the `ssh-unlock` line of the selftest and `sudo halosctl ssh-unlock` warn you. Then the person who
changed them had the disk, and could have copied the host key. So set it up again: run
`sudo halosctl ssh-unlock off`, then `on`. This makes a new early-boot host key. Replace its
`known_hosts` line on your computer.

A machine that the installer set up records the fingerprints at first-boot setup, or with
`sudo halosctl ssh-unlock record`. This command only makes a first record.

What it can and can't protect: halOS keeps the keys and that host key on the small unencrypted EFI
partition of the disk. (It reads only the disks of the machine, never a USB stick.) It must do this
because every halOS machine boots the same image. Your keys there are only public keys.

But a person who can remove the disk can copy the host key. That person can then act as this
machine and catch the passphrase when you unlock. Every method of network unlock has this weakness.
The TPM section above tells how to make it more difficult to tamper with the machine.

### Unlock from a tang server on your network

A tang server is a small key server that you run on your own network, for example on a NAS or on
a different machine. When halOS can get an answer from it at boot, the disk unlocks by itself. When
the machine or its disk is away from your network, the boot asks for the passphrase. This is useful
for a server where nobody types a passphrase, and where the TPM alone is not sufficient. halOS uses
[clevis](https://github.com/latchset/clevis) for this. The server is
[tang](https://github.com/latchset/tang).

First, start a tang server on a different computer that is always on. On Fedora:

```bash
sudo dnf install tang
sudo systemctl enable --now tangd.socket
```

This server uses port 80. To use a different port, change `ListenStream` in a drop-in file for
`tangd.socket`. On the tang server, this command shows its key (put the port after it if it isn't
80):

```bash
sudo tang-show-keys
```

Then, on the halOS machine:

```bash
sudo halosctl tang-unlock on http://192.168.1.5
```

The command shows the key of the server. Compare it with the output of `tang-show-keys`. Continue
only if they are the same. Then type the passphrase of the disk. `--thp <key>` gives the key in the
command. Then `--yes` asks no other questions, but you still type the passphrase.
`sudo halosctl setup` also offers this.

Use the IP address of the server. A name can fail at boot, and a `.local` name always fails, so
halOS refuses it. The
network at boot is wired, with DHCP, as for the SSH unlock. You can give more than one server. Then
each of them can unlock the disk alone. The command replaces all servers from before.

`--tpm` selects how tang and the TPM work together (`and` and `or` need Secure Boot on, as the TPM
unlock does):

- `--tpm and` (the default when the machine has a TPM): the disk unlocks only when the TPM of this
  machine agrees (Secure Boot and the BIOS did not change) **and** a tang server answers. halOS
  removes the TPM-only unlock. A disk that somebody copies stays locked, also when that person can
  get to your network. A machine that somebody takes away from your network stays locked. But a
  person who can boot the machine itself on your network can unlock it, as with the TPM alone (see
  "What TPM unlock protects, and what it doesn't" above, and its BIOS and boot menu passwords).
  After a BIOS or Secure Boot change, the boot asks for the passphrase. Type it, then run
  `sudo halosctl tang-unlock renew`. Do this only after a change that you made yourself.
  `--tpm and` and `--tpm off` remove all TPM unlocks of systemd, also one with a PIN that you
  made yourself.
- `--tpm off` (the default without a TPM): the tang server alone unlocks the disk. halOS removes the
  TPM-only unlock. BIOS updates don't change this. But a person with a copy of the disk who can get
  to your network can also unlock it.
- `--tpm or`: the TPM unlocks the disk as before, and the tang server unlocks it when the TPM can't
  (for example after a BIOS update). A machine that somebody takes away still unlocks with its TPM.

With `and` and `off`, `halogen-enroll-tpm` refuses to add a TPM-only unlock, because the machine
would then unlock away from your network.

The passphrase always works too: at the keyboard, or over SSH (see above). halOS never removes the
passphrase slot. `sudo halosctl tang-unlock` shows the current setup. `sudo halosctl tang-unlock
renew` binds again to the same servers, with the keys they had (halOS records them). If a server
now signs with another key, `renew` stops. If you changed the key yourself, set it up again with the
new key and the same `--tpm` mode: `sudo halosctl tang-unlock on <server> --tpm <mode> --thp <key>`.
`sudo halosctl tang-unlock off` removes it. The `luks-tang` line of the selftest tells if the
servers answer now.

At boot, halOS starts the network before the disk unlocks only on a machine with a tang binding (or
with the SSH unlock). It stops this network before the system starts, so the network settings of
the system apply. Other machines boot as before.

Keep the tang server on your own network, never open to the internet. The exchange with tang never
sends the key of the disk, so plain `http://` is correct here: a person who can see the network
traffic can't get the key. The CI install test unlocks a disk in a VM with a tang server, and asks
for the passphrase without the server. Nobody has tested this on real hardware yet.

## If something goes wrong

| Symptom | Check |
|---|---|
| The machine shows much less than 128 GB | If the BIOS has a UMA frame buffer setting, set it to its minimum, not Auto |
| `curl localhost:8731` gets "connection reset" | Only releases before `v0.18.23-alpha.3`. Use `127.0.0.1` instead of `localhost` |
| `/dev/accel/accel0` is missing | Use the NPU edition, and check the IOMMU and the firmware |
| The fabric clock is not held | `systemctl status halogen-fabric-clock` |
| The selftest warns about the power profile | `sudo halosctl power` shows the profile. `systemctl status halos-platform-profile` tells what occurred at boot |
| Halogen does not start after a change to the config | Run `sudo halogenctl status`, then check the NPU model names |
| "start of the service was attempted too often" | Halogen crashed 3 times in 15 minutes. This is its guard against a crash loop. To see why, run `sudo halogenctl logs`. If the GPU is stuck, reboot. If not, `sudo halogenctl restart` tries again. On releases before `v0.19.1-alpha.4`, first run `sudo systemctl --user -M halogen@ reset-failed halogen.service`, then `sudo halogenctl restart` |
| Halogen does not start after `flash use` | `sudo halogenctl logs` tells why. `sudo halogenctl flash use official` goes back |
| Halogen's start does not finish, or GTT stays in use after a crash | Reboot, as Halogen's troubleshooting guide tells |

For all other problems, see Halogen's
[troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md).

Next: [Running halOS](docs/GUIDE.md) tells how to configure and use the machine.
