# Installing halOS

This guide tells you how to install halOS from USB, from the choice of edition to a working API.
For information about how Halogen itself works, see its
[official documentation](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs).

> **Note:** halOS is in alpha. The NPU edition runs on the hardware below. Other hardware is not
> tested. So on your first install, do the [checks](#7-check-the-install) and
> [report the result](https://github.com/n4berius/halos-flash/issues/new?template=hardware-report.yml).

## Tested hardware

| Machine | Memory | Disk | Release | Edition |
|---|---|---|---|---|
| [AMD Ryzen AI Halo Developer Platform](https://www.microcenter.com/product/711961/amd-ryzen-ai-halo-developer-platform-linux-os) (Micro Center) | 128 GB | 2 TB NVMe | `v0.18.23-alpha.2` to `v0.20.6`, and the `kernel-next` test kernel | With NPU, and without NPU through `halosctl npu off` |

On that machine, these items work:

- USB install with Secure Boot on, and no MOK enrollment
- Automatic storage, which makes each volume, and the guided install (since `v0.20.0`)
- First-boot download of the Halogen container and about 130 GB of models
- Halogen on the GPU, with all 5 NPU models loaded
- Access to the API from other machines on the network, for example Hermes

Since `v0.20.0`, these items also work: the selftest, the benchmark, `flash check`, the change
between the two editions with `halosctl npu off` and `on`, tab completion, restarts and a
`model pull` of OvisOCR3.

These items are not yet confirmed on hardware:

- LUKS with TPM unlock (it passes in the VM test)
- A long soak test under real load

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
| IOMMU | On, with `iommu=pt` | Off, with `amd_iommu=off` |
| Trade-off | Slower prefill, DMA protection stays on | 13-16% more prefill (Halogen's measurement), but DMA protection is off |
| Image | `halos-flash:0.20.7` | `halos-flash:0.20.7-no-npu` |

You can change the edition later, without a new install:

- `sudo halosctl npu off` moves to the no-NPU edition.
- `sudo halosctl npu on` moves back.

The change keeps the same channel or release, and applies at the next reboot. `/srv` does not
change. The NPU models and your own checkpoints stay on disk, so a return to the NPU edition
downloads nothing. While the NPU is off, the `HALOGEN_NPU_*` settings have no effect. For each
one, the log shows "ignored HALOGEN_NPU_…: not an option this system allows". This is normal.

**Note:** Use the no-NPU edition only where no untrusted person can touch the machine. With the
IOMMU off, a device in a USB4/Thunderbolt port or a PCIe slot can read all the memory of the
machine. While the machine runs, this memory includes the disk encryption key.

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

### Moving between releases later

A machine that you install from a release stays on that exact build. So an upgrade finds nothing
new. To get new releases, select a channel one time and reboot:

```bash
sudo halosctl switch alpha
sudo systemctl reboot
```

After that, `sudo halosctl upgrade` stages the newest release on that channel. The channels are:

- `alpha`
- `rc`
- `release` (stable)
- `edge`

The old `beta` channel now gets the same releases as `rc`. Each channel also gets newer releases
of the more stable channels. `halosctl` keeps your edition, and adds `-no-npu` for you.
`sudo halosctl version` shows what the machine runs and which channel it follows.
`sudo halosctl rollback` goes back.

An install from before `halosctl` (`v0.19.0-alpha.1` and older) needs one `bootc switch` first.
Use the channel tag, for example `ghcr.io/n4berius/halos-flash:alpha`. On the no-NPU edition,
add `-no-npu`. This step also moves installs from before the rename to halOS. These installs
follow `ghcr.io/n4berius/halogen-flash-bootc`, which gets no new builds. Files, settings and
models do not change.

If you use `bootc` directly: a `bootc switch` to the name that the machine already follows does
nothing ("Image specification is unchanged"). This is also true when that tag now points to a
newer build. To get the newest build of the current name, use `sudo bootc upgrade` (or
`sudo halosctl upgrade`).

### Signed images

halOS signs every halOS image with its key. A machine accepts an update only when that signature
is correct. So nobody can give you a different image as a halOS image. `sudo halogenctl
selftest` shows this check as `image-signatures`. Machines that you install from `v0.20.0-alpha.4`
or later do the check from the start.

Older installs turn the check on at their next `sudo halosctl upgrade`, after a reboot into
`v0.20.0-alpha.4` or later. `halosctl` tells you about the check and asks. Then it stages the newest
image of the name that the machine follows, with the check on. So the first upgrade to such a
release installs without the check, and the next upgrade turns it on. Each upgrade needs a reboot.

- Releases before `0.19.1-alpha.3` don't have the key signature. So `halosctl rollback --to`
  can't go back to them. `halosctl rollback` to the previous image on the disk still works.
- The rules are in `/etc/containers/policy.json`. halOS images need the halOS signature. The
  machine accepts images from other registries (Halogen's own, or containers that you run with
  podman) as before. If somebody changes or removes that file, `halosctl` refuses to switch. It
  tells you how to put back the halOS copy
  (`sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json`).
- If you use `bootc switch` manually, add `--enforce-container-sigpolicy`. If you don't, the
  machine stops the check. `halosctl` always adds it. `sudo halosctl version` tells you if the
  machine checks updates. When it doesn't check them, the SSH login message also tells you.
- The `signature-files` line of the selftest compares the policy, the registry setting and the
  halOS public key with the copies of the image in `/usr/etc`. It also warns about a policy file
  in the home folder of root, because that file replaces the system file.
- If the name that you follow ever points back to an older build, `halosctl upgrade` tells you.
  It then does not reboot automatically, so you can examine the build first. (The other channels
  and the other edition have different build times, so `switch` and `npu` don't compare them.)
- `halosctl` also refuses to switch if `/etc/pki/containers/halos-flash.pub` isn't the copy from
  the image.

To build an ISO yourself, see [BUILDING.md](BUILDING.md).

## 4. Write the USB drive

Use [Fedora Media Writer](https://fedoraproject.org/workstation/download/) with its custom image
option, or use `dd` on Linux.

**Warning:** Check the device name before you use `dd`. `dd` overwrites the device and does not
ask first.

```bash
lsblk
sudo dd if=halos-flash-v0.20.7-alpha.1-npu.iso of=/dev/sdX bs=4M status=progress conv=fsync
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
| `/var/srv/logs` | `halos-logs` | 4 GiB, for [request records](#request-records) |
| `/var/srv/models` | `halos-models` | the remaining space: about 300 GiB on a 512 GB disk, 1,690 GiB on a 2 TB disk |

Each [Flash checkpoint of your own](#your-own-flash-checkpoint) uses about 110 GB more of the
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

It asks four questions. You can skip each one:

1. **How the disk unlocks at boot.** With the TPM, you type no passphrase while Secure Boot and
   the BIOS stay the same. Setup runs `halogen-enroll-tpm` for you. Or you can type the
   passphrase at each boot. Then setup offers SSH unlock, if SSH unlock is not set up already.
   After a guided install, the answers that you gave there are the defaults (Enter). The TPM
   protects a disk that somebody removes from the machine. It doesn't protect the full machine if
   somebody takes it: see [what TPM unlock protects](#what-tpm-unlock-protects-and-what-it-doesnt).
2. **A Hugging Face token.** This is optional. It increases the download limits. Make a read token
   at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
3. **Settings.** Open `/srv/configs/halogen.env` in an editor, or keep the defaults. The defaults
   are correct for most people.
4. **HTTPS.** On a new install, Enter turns HTTPS on, with the halOS authority (self-signed). Then
   apps that use `https://` don't send prompts, replies and the API key across the network as
   plain text. (An app that still uses `http://` sends its key one time before the redirect.)
   Each app must trust the authority one time: `sudo halosctl https ca` prints it (see
   [HTTPS](#https)). Enter means yes until you answer this question one time, even if you run
   setup days later. A machine that you upgrade from an earlier release stays on plain HTTP until
   you say yes here or run `sudo halosctl https self-signed`. If HTTPS is already on, setup
   doesn't change it.

The first 130 GB download waits for setup, so your token and settings apply from the start. If
nobody runs setup in 30 minutes, the download starts with the defaults. So a machine that nobody
logs in to still starts its work automatically. `sudo halosctl setup --skip` starts the download
immediately. Machines that you upgrade from an earlier release never wait.

You can run `sudo halosctl setup` again at any time. It then offers to restart Halogen to apply
your changes.

After setup, the first boot does these steps in this order:

1. `halogen-prepare` makes `/srv/models`, `/srv/configs`, `/srv/logs`, the config file and an API key.
2. On the NPU edition, `halogen-fabric-clock` holds the clock that Halogen needs for GPU and NPU
   together.
3. `halogen-fetch` pulls the pinned Halogen container and downloads the models. An interrupted
   download continues where it stopped. After a network failure, the fetch tries again until it
   succeeds.
4. Halogen's `verify` mode checks the Flash checkpoint. The fetch checks the NPU files against the
   hashes in the pinned container.
5. Halogen starts, with its models read-only. It never downloads anything itself. The network gets
   to it on port 8731 through [Caddy](https://caddyserver.com) (`halos-proxy.service`). See
   [The front door](#the-front-door).

You can monitor the progress without a login. Above the login prompt, the screen of the machine
shows one line. This line updates automatically every 30 seconds. Before setup, it shows
`waiting for setup: sudo halosctl
setup`. Then it shows:

```
halOS 0.20.7-alpha.1 (npu edition) - downloading models 45%
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

Downloads work without an account. A free Hugging Face read token increases the rate limits, and
usually makes the downloads faster. Make one at
[huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), then run:

```bash
sudo halogenctl hf-token     # paste the token; it isn't shown or printed
sudo halogenctl restart      # the download resumes with the token
```

halOS keeps the token in `/srv/configs/hf-token`. Only the `halogen` service can read it, and it
uses the token only for downloads. To remove the token, run `sudo halogenctl hf-token --remove`.

Later boots skip the download, unless the model list or the Halogen version changes.

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
for Claude Code, Codex, Pi, oh-my-pi, opencode, Cline, aider and other apps. The
[command reference](docs/CLI.md) shows every halOS command.

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
  Boot on, the kernel runs in lockdown. Nobody has tested this on hardware yet.

### Tools on the machine

The OS is small, but it includes these tools for maintenance:

| Command | What it's for |
|---|---|
| `amd-smi metric` | GPU temperature, power and clocks. On Strix Halo, some fields show N/A |
| `nvtop` | Live GPU use, and which process holds GPU memory |
| `htop` | Live CPU and memory use |
| `tmux` | Lets a long command continue if your SSH connection stops |
| `lspci`, `lsusb` | Show the hardware |
| `nvme list`, `sudo nvme smart-log /dev/nvme0` | Disk health |
| `fwupdmgr` | Firmware updates from the vendor, if the board supports them |

Firmware updates use [fwupd](https://fwupd.org/). To find updates, run
`sudo fwupdmgr refresh && sudo fwupdmgr get-updates`. To apply them, run
`sudo fwupdmgr update`. A BIOS update reboots the machine. This stops Halogen until the machine
starts again.

fwupd can also update the Secure Boot revocation list (dbx). This is the list of start-up programs
that the firmware must refuse. The TPM unlock of the disk is tied to the Secure Boot settings.
So after a dbx update, the next boot asks for the disk passphrase (at the screen, or over SSH if
you set that up). Have the passphrase ready. When the machine is up, run
`sudo halogen-enroll-tpm`, so that the machine unlocks automatically again. Without TPM unlock,
nothing changes at boot.

### The dashboard

For a live view of Halogen, open `https://<this machine's address>:8732` in a browser on your
network. Use `http://` with [HTTPS](#https) off. This port is next to the API port, 8731. The
dashboard shows:

- If Halogen is up
- Generation and prefill speed
- Busy slots and queued requests
- The KV pool, the prompt cache and the NPU
- Charts from the last 5 minutes to the last 30 days

`sudo halosctl dashboard` shows its state and address.

It is [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion. halOS
includes it without changes (licences in `/usr/share/licenses/halogen-dashboard/`).

The dashboard reads Halogen one time each second with your API key. It keeps its history in
`/var/lib/halos-dashboard`: 48 hours in full, then one-minute summaries for 30 days. When full,
this history is about 430 MB. The dashboard uses about 12 MB of memory and almost no CPU. It runs
as its own user, with no access to Halogen's files, models or tokens.

- **No login.** Anyone who can get to port 8732 on your network can see the dashboard. But nobody
  can change anything through it. It never shows your API key or anything sent to Halogen. It
  does show when and how much people use the server. If you don't want that, turn it off:
  `sudo halosctl dashboard off` stops it (port 8732 then only says that it's off). `on` turns it
  on again.
- **On by default**, also on machines that upgrade to a release that has it.
- **Private networks only.** The dashboard answers only this machine and private addresses: 10.x,
  172.16-31.x, 192.168.x, link-local, and 100.64.0.0 to 100.127.255.255. (This last range is
  Tailscale, and also the shared addresses of some internet providers.) A computer with a public
  address (for example, through a port forward) gets no answer. The exception is when something
  on your network sends the request on (a reverse proxy, a tunnel or `tailscale serve`). Caddy
  applies this rule, on IPv4.

  If your network uses other addresses, browsers get no answer. Then do these steps:

  1. Add your ranges to `/etc/halos/proxy.env` as `HALOS_DASHBOARD_ALLOW=<range> <range>`.
  2. Run `sudo systemctl restart halos-proxy`.
  3. Check the result with `sudo systemctl status halos-proxy`. A mistyped range stops Caddy,
     and with it the API, until you correct it.

  The dashboard itself accepts connections only from this machine.
- **The API key stays out of crash reports.** The dashboard blocks memory dumps. So if it
  crashes, nothing that it holds (including the key) goes to the disk or into the system log. It
  also listens only on its own local port, and accepts connections only from this machine
  (Caddy). `sudo halogenctl selftest` checks the crash-report protection, and that this address
  filter is really active.
- **Memory is capped at 256 MB**, so the dashboard can never take memory from Halogen. Its own
  30-day view needs about 100 MB. A special request that reads much more makes it restart after
  30 seconds. This has no effect on Halogen.
- **Only one reader of `/metrics`.** Each time something reads `/metrics`, Halogen resets two of
  its speed values. So the dashboard must be the only reader. Don't point Prometheus or a script
  at the `/metrics` of Halogen. The dashboard serves its own copy at
  `http://<address>:8732/metrics`.
- If you change the API key in `/srv/configs/api-key`, restart the dashboard:
  `sudo systemctl restart halos-dashboard`.

### The front door

[Caddy](https://caddyserver.com) (`halos-proxy.service`) answers the network on both ports:
**8731** for the API of Halogen and **8732** for the dashboard. Halogen and the dashboard listen
only on this machine (`127.0.0.1:18731` and `127.0.0.1:18732`). So every connection from another
computer goes through Caddy, over plain HTTP or [HTTPS](#https).

- Caddy sends replies on as Halogen sends them. It adds no buffer.
- While Halogen starts, downloads or is stopped, the API answers `503` with a short note (JSON, as
  Halogen's own errors are). It doesn't refuse the connection.
- Caddy writes one line for each API request to the journal (`sudo journalctl -u halos-proxy`):
  the time, the address of the client, the path and the status. It writes no request headers and
  no query string. So the API key never goes into the journal, however an app sends it.
- Caddy runs as its own user, with no access to your files and with no admin interface.
  `sudo halogenctl selftest` checks that Caddy answers (`proxy`). Its other API checks and `halogenctl
  bench` talk to Halogen directly, so their numbers are Halogen's own.
- Halogen's own [docs](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs) show no
  setting that depends on the address of the client. So Halogen works the same behind Caddy.

### HTTPS

Plain HTTP sends prompts, replies and the API key across your network without encryption. HTTPS
encrypts them. HTTPS is off until you turn it on. Machines that upgrade stay on HTTP, so no app
stops working unexpectedly.

```bash
sudo halosctl https                        # the state, and what apps use
sudo halosctl https self-signed            # on, with halOS's own authority
sudo halosctl https custom cert.pem key.pem   # on, with your certificate (PEM, key without a passphrase)
sudo halosctl https letsencrypt cloudflare halos.example.com   # on, with Let's Encrypt (see below)
sudo halosctl https off                    # back to plain HTTP
```

With HTTPS on, both ports use it. Apps use `https://<address>:8731/v1`, and the dashboard is at
`https://<address>:8732`. On each port, Caddy redirects a plain `http://` request to `https://`.
Apps that send the key over `http://` still send it one time before they follow the redirect.
So change their address to `https://`.

**Self-signed** makes the halOS certificate authority (Caddy's, which the machine keeps). It also
makes a certificate for each name and address of this machine: `localhost`, its host name, the
`.local` name and every address that it has, including Tailscale's. Apps and browsers must trust
the authority one time:

```bash
sudo halosctl https ca > halos-ca.crt
```

Then give `halos-ca.crt` to each app that connects to the machine. Most apps have a setting for a
CA file. [Connecting apps](docs/CLIENTS.md) shows that setting for each coding agent (Pi,
oh-my-pi, opencode, Codex, Claude Code, Cline, aider and others). Do this, not add the
file to the trusted certificates of your computer. An authority that the full system trusts can
vouch for any website. So anyone who stole it from this machine could act as any site on that
computer.

For a browser and the dashboard, it is sufficient to accept the warning one time for
`https://<address>:8732`. `sudo halosctl https` shows the fingerprint of the authority. Compare it
with the file that you copied. For other names (for example, a DNS name that you gave the
machine), add them to the command: `sudo halosctl https self-signed freyja.example`. If the
address of the machine changes, `sudo systemctl restart halos-proxy` adds it. Until then, the
selftest warns.

**Your own certificate** must name the address that apps use (usually a DNS name). halOS checks
that the key belongs to the certificate and that the certificate is not expired. It shows you
whose certificate it is, and asks before it uses it. It keeps both files in `/etc/halos/https/`
(root only, with the previous pair). `sudo halogenctl selftest` warns 2 weeks before the
certificate ends.

If Caddy doesn't answer with a new setting, `halosctl` puts back the previous setting, including
the certificate. To renew, run `https custom` again with the new files.

**Let's Encrypt** gives certificates that every app and browser already trusts, and renews them
automatically. It needs a public DNS name that you own (for example `halos.example.com`). Caddy
opens nothing to the internet: it proves that the name is yours with a temporary TXT record. It
writes this record through the API of your DNS provider (the DNS-01 challenge). The only
requirement is that the name points to this machine. A private address such as `192.168.1.20` is
fine.

Some home routers block public names that point to private addresses ("DNS rebinding
protection"). If the name doesn't resolve on your network, allow the name in the router.

1. Make an API credential at your DNS provider. Let it change the zone of that name and nothing
   more. A credential that can change the DNS of your main domain is valuable to an attacker who
   gets into the machine. A domain (or a DuckDNS name) that you use only for halOS decreases that
   risk:

   | Provider | What `halosctl` asks for | Where |
   |---|---|---|
   | `cloudflare` | `api_token` | My Profile > API Tokens > Create Token, template "Edit zone DNS", for that zone only |
   | `duckdns` | `api_token` | The token at the top of duckdns.org after you sign in. The name is `<yours>.duckdns.org` |
   | `porkbun` | `api_key`, `api_secret_key` | Account > API Access. Then turn on "API Access" on the domain itself |
   | `namecheap` | `api_key`, `user`, `client_ip` | Profile > Tools > Business & Dev Tools > API Access. Add the public IPv4 address of this network to its allowed list. Give the same address as `client_ip` |

   **Warning:** For Namecheap, write down your records first, or use a domain (or a DuckDNS name)
   only for this. The Namecheap API can only replace the full list of records of a domain. So
   each certificate writes the list again.

2. First, try it against the test service of Let's Encrypt. Its limits are generous. (Apps don't
   trust its certificates, so they will still warn.)

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --staging
   ```

   `halosctl` asks for the credential (it doesn't show it while you type). Then it waits for the
   certificate, usually less than a minute. If no certificate comes in 5 minutes, it shows the
   answer from Let's Encrypt and puts back the previous setting.

3. Then do it for real. `halosctl` offers to use the credential that you gave again:

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --email you@example.com
   ```

   `--email` is optional. Let's Encrypt uses it only for important notices about your account.

Apps then use `https://halos.example.com:8731/v1`, and the dashboard is at
`https://halos.example.com:8732`. The names and addresses of this machine keep the halOS authority
(as with self-signed). So apps that connect by address continue to work after they trust it.
Certificates are public: every name that you certify shows in the
[Certificate Transparency](https://certificate.transparency.dev/) logs, which anyone can search.
So don't use a name that you want to keep private.

halOS keeps the credential in `/etc/halos/https/dns/`, and only root can read it. Caddy gets it
from systemd each time it starts, read-only and in memory. Caddy loses it when it stops
(`sudo halosctl https forget-dns` deletes it and restarts Caddy). The credential never shows in a
command line, the settings file or the journal. halOS removes it from the error messages of DuckDNS
and Namecheap. It also refuses a Cloudflare token with a shape that Caddy's plugin would print back.

`sudo halogenctl selftest` checks the certificate as an app would. It warns 10 days before the
certificate ends, because then the renewal has failed.

To give a new credential, run the same command, and answer no when it offers the old one. When the
new setting works, halOS deletes the old credential. Also revoke the old credential at the
provider. If the name already has a valid certificate, Caddy keeps it and first uses a new
credential at the next renewal (Caddy renews about a month before the end). The selftest warns if
that renewal fails. When you no longer use Let's Encrypt, `sudo halosctl https forget-dns` deletes
the saved credential.

Without a terminal, `--yes` reads the credential as `field=value` lines on standard input. Put the
lines in a file that only you can read. Never put them in the command itself, because the shell
history keeps the command. Delete the file after use:

```bash
sudo halosctl https letsencrypt cloudflare halos.example.com --yes < cloudflare.txt   # api_token=...
```

halOS releases before `v0.20.1-alpha.3` don't know `letsencrypt`. After `sudo halosctl rollback` to
one of them, Caddy doesn't start until you run `sudo halosctl https off` or `self-signed`. (Caddy
never goes back to plain HTTP automatically.)

The halOS tools (`halogenctl bench`, the API checks of the selftest, the check of the login line)
connect to Halogen directly on the machine. So they work the same in each mode.

### Measuring speed

```bash
sudo halogenctl bench            # a few minutes
sudo halogenctl bench --quick    # under a minute: one prompt length, one pass
```

It measures the running server with Halogen's own
[`sweep` tool](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md#served-throughput-end-to-end-over-http).
Halogen's published numbers come from this tool, so you can compare your numbers with them. It
needs no restart, but other requests are slower while it runs. It shows:

- **pp** (prefill): how fast Halogen reads a prompt of 512, 2,048, 8,192 and 32,768 tokens.
- **tg** (generation): how fast Halogen writes 128 tokens, as the mean over the 10 prompt shapes
  of Halogen. Code is about two times as fast as prose, so compare means, not single prompts.

Each report also shows the items that the numbers depend on: the halOS and Halogen versions, the
kernel, the BIOS, the GTT size, the IOMMU, the fabric clock, the platform power profile, the Flash
checkpoint that Halogen serves and your settings. halOS saves the report as text and JSON in
`/srv/configs/bench/`, with the date in the name. So you can compare a run after an upgrade, a
BIOS change or `flash use` with an earlier run.

Halogen's [measurements](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md)
used about 85 W of sustained power. A machine with a lower power limit shows lower numbers. The
run uses the prompt cache as your server does. So compare `pp` with Halogen's "cache on (a cold
request)" rows, not with the cache-off headline figures. The prompts of the run also go into the
cache. They can push out long conversations from the cache, which then read their history again
one time.

### Prompt cache on disk

Halogen keeps the state of each conversation, so the next turn doesn't read the full conversation
again. halOS also keeps that state on disk, in `/srv/models/.prompt-cache`. So a conversation
continues after a restart of Halogen: its next turn starts in seconds, and doesn't read everything
again (Halogen's [prompt cache on disk](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md#prompt-cache-on-disk-resume-a-conversation-after-a-restart)).
Halogen writes the cache in the background, so answers don't wait for the disk.

```bash
sudo halogenctl cache          # on or off, and the space used
sudo halogenctl cache off      # keep the cache in memory only; Halogen can then only read the folder (restarts Halogen)
sudo halogenctl cache clear    # delete everything saved
```

- It uses about 27 KiB per token of conversation: 0.9 GB at 32,000 tokens, 7.2 GB at 262,000.
  Halogen keeps 64 GiB at most, and first removes the conversations that it used longest ago. To
  change the limit, set `HALOGEN_CACHE_DISK_GIB` in `halogen.env`.
- A different Halogen version, checkpoint or setting never reads the files of another. halOS tells
  Halogen to delete those files at start (`HALOGEN_CACHE_PRUNE_OLD=1`), so nothing stays behind.
  So the cache starts empty after an upgrade to a new Halogen version, and after
  `halogenctl flash use` switches checkpoint. It also starts empty after a change to a setting
  that changes what Halogen saves (for example, the context size). To keep the other files, set it
  to `0` in `halogen.env`. Then a rollback or a switch back finds its cache, but these files count
  in addition to the limit until you run `cache clear`.
- Halogen says that very long conversations (more than about 64,000 tokens) save fastest with
  `HALOGEN_KV_POOL_POSITIONS=262144`. The `halogen.env` of the NPU edition already sets it.
- The folder holds the state of your conversations, so protect it as you protect the
  conversations. Only the `halogen` user can read it. It has protection at rest only if you
  selected disk encryption at install. A backup of `/srv/models` also copies it. `cache off` keeps
  the saved data, and `cache clear` deletes it. Also use `cache clear` after you try a checkpoint
  that you don't trust.

### Request records

Halogen can keep one line for each request that it answers. Each line shows:

- The API and the client that sent the request
- Its size and settings
- How it finished
- The tokens generated and the tool calls
- The timings

The records show what your apps and agents really send. Recording is off until you turn it on.
halOS keeps **counts only**, with no message text, unless you change this. See Halogen's
[request records](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md#request-records-a-log-of-what-your-clients-send-opt-in)
for the contents of each line.

```bash
sudo halogenctl records on        # restarts Halogen
sudo halogenctl records           # on or off, what text is kept, space used
sudo halogenctl records stats     # counts by API, client, finish, cache share, tool errors
sudo halogenctl records prune --days 7    # or --gib 1, --all
sudo halogenctl records off       # what was kept stays until you prune it
```

`stats` and `prune` also work while recording is off or Halogen is stopped. They then run the
Halogen tool in a short-lived container that sees only the records folder.

The records go to `/srv/logs/halogen`, and only the `halogen` user can read them. Three settings in
`/srv/configs/halogen.env` control them. After a change, run `sudo halogenctl restart`.

- `HALOGEN_RECORD_TEXT`: `none` on halOS (counts only), or `all`, or a list of `prompt`,
  `reply`, `reasoning`, `args` and `results`. **Before you keep text on a server that other
  people use:** Halogen writes to disk everything that they send. The API key keeps strangers out,
  but Halogen also records anyone who has the key. The session fields show only what a client
  claims.
- `HALOGEN_RECORD_GIB`: the size limit of the folder, 2 GiB by default. Above this limit, Halogen
  drops new records and counts them. It never slows or refuses requests.
- `HALOGEN_RECORD_DAYS`: the number of days to keep records, 90 by default. While recording is on,
  Halogen deletes older records itself. After `records off`, use `records prune`.

The `/health` address of Halogen answers anyone who can get to port 8731. While recording is on,
it shows the counts (records written and dropped) and which text Halogen keeps. It never shows the
records.

New installs give `/srv/logs` its own 4 GiB volume, so records can never fill `/var`. Nothing
there can run as a program (`noexec`), on the volume and in Halogen's mount of the folder.
Machines installed earlier keep it as a folder on `/var` (60 GiB), where the 2 GiB limit keeps it
small. Its own volume there would need free space in the volume group (`sudo vgs`, column VFree).
The guided install leaves no free space: the models volume uses all the remaining space, and XFS
can't shrink.

### Logs and the audit trail

halOS keeps three types of log. Each type has its own size limit, so no log can fill the disk:

- **The system journal** (`sudo journalctl`): the messages of every service, including Halogen
  (`sudo halogenctl logs`). halOS keeps 4 GB at most, for 90 days at most, and keeps 1 GB free.
  `sudo journalctl --disk-usage` shows its size.
- **The audit log** (`/var/log/audit/audit.log`, auditd). It records these events:

  - Logins, `sudo` and account changes
  - Changes that an admin or root makes to the halOS settings, the update signature policy, and
    the SSH and sudo settings
  - Each time a logged-in user runs the disk-encryption tools, the update tools, `halosctl` or
    `halogenctl`

  auditd keeps 20 files of 50 MB (1 GB) and rotates them itself. If its disk becomes full, auditd
  pauses. It does not stop the machine. To read the log by topic:

  ```bash
  sudo ausearch -i -k halos-config     # changes in /etc/halos
  sudo ausearch -i -k halogen-config   # changes in /srv/configs
  sudo ausearch -i -k signature-policy # which images updates are taken from
  sudo ausearch -i -k sshd-config      # also sudoers, accounts, pam, luks-tpm, os-update, halosctl, halogenctl
  sudo ausearch -i -k quadlet          # how Halogen's container is started; also containers, systemd-config,
                                       # audit-config, modules, preload, udev, firewall, sysctl,
                                       # environment, mounts, fail2ban
  sudo aureport --summary              # counts, and sudo aureport --login for logins
  ```

  The rules are locked while the system runs. Nobody, including root, can turn auditing off or
  change a rule without a reboot, and the audit log records each attempt. So a change to the
  rules in `/etc/audit/rules.d` applies at the next boot.

  halOS excludes Halogen's own processes from this tracking, so auditing adds no work to the
  engine. It excludes only Halogen's own login session. The audit log records root or an admin
  who acts as the `halogen` user (`sudo -u`, `runuser`), as it records all other users. So it
  doesn't record files that Halogen's own services write in `/srv/configs` (benchmark reports, for
  example), but it records your changes there. The cost on the rest of the system (including the
  front door, Caddy) is probably small. Nobody has measured it yet.
- **Request records** (above), when you turn them on.

`sudo halogenctl selftest` shows:

- If auditd runs with the halOS rules, locked (`audit`)
- If the audit rules and the container definition of Halogen are still the image's own
  (`config-files`)
- If the `halogen` user has new services of its own, which halOS never makes (`halogen-autostart`)
- How large the journal is (`logs`)

Fedora keeps some plain log files (failed and past logins, `btmp` and `wtmp`). `logrotate` rotates
them monthly, as on all Fedora systems.

### Your own NPU checkpoints

On the NPU edition, Halogen also runs checkpoints that you supply. Examples are LiquidAI's `d1-2B`,
the LFM3 family, or your own fine-tune of one of its NPU models. Halogen's
[NPU guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-model)
shows what runs. To download one from Hugging Face, use:

```bash
sudo halogenctl model pull LiquidAI/LFM3-1.7B     # add --as <name> or --revision <commit> if you like
sudo halogenctl model list
sudo halogenctl model remove LFM3-1.7B
```

`model pull` uses your Hugging Face token if you saved one (gated repos need it). An interrupted
pull continues where it stopped. `model pull` puts the checkpoint in the correct folder:

| Folder | What goes there | Named in `HALOGEN_NPU_MODELS` as |
|---|---|---|
| `/srv/models/decider` | `d1-2B`, fine-tunes of `decider-0.8b` | `/models/decider/<name>` |
| `/srv/models/LFM` | LFM3-1.7B, LFM3-VL-2B, LFM3-Audio-2B, LFM3-Omni-2B | `/models/LFM/<name>` |
| `/srv/models/custom` | Fine-tunes of the embedding, reranking or guard models; OvisOCR3 | `/models/custom/<name>` |

**LFM3-1.7B's three forms.** With the name `/models/LFM/<name>`, it runs at full quality.
`/models/LFM/<name>:fast` is faster, with a small loss of quality. Since Halogen 0.20.6,
`/models/LFM/<name>:qad` runs Liquid's own 4-bit file, which is the fastest. It gives about 48
tokens a second, against 30 and 42 for the other forms (from Halogen's
[NPU guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-lfm3-17b)).

To get that 4-bit file, run `sudo halogenctl model pull LiquidAI/LFM3-1.7B --qad`. It comes from
`LiquidAI/LFM3-1.7B-GGUF`, at the commit that Halogen's image uses. Its weights are Liquid's, so a
fine-tune of your own can use only the first two forms. You can name all three forms together.
Halogen serves each form under its own name (`LFM3-1.7B`, `LFM3-1.7B-fast`, `LFM3-1.7B-qad`).

**Document parsing (OvisOCR3).** Since Halogen 0.20, the NPU reads document pages into Markdown,
with tables as HTML and formulas as LaTeX. It uses your own
[OvisOCR3](https://huggingface.co/ATH-MaaS/OvisOCR3) checkpoint (Apache 2.0, about 1.7 GB). To get
it, run `sudo halogenctl model pull ATH-MaaS/OvisOCR3 --revision
17f255e2c8ae6d18d5d5edb0a474bd4ed39aef90` (the version that Halogen 0.20.0 was tested with). Then
add `/models/custom/OvisOCR3` to `HALOGEN_NPU_MODELS`.

OvisOCR3 answers as `OvisOCR3`. It takes one or two page images for each request, and about 20
seconds for each page. Halogen's
[NPU page](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-ovisocr3)
has the prompts and limits. When OvisOCR3 and several other NPU generation models start work at
the same time, the next Flash request can wait about 40 seconds. During that time, Halogen reads
the Flash weights back. To keep them in memory, set `HALOGEN_WEIGHTS_LOCK=1` in `halogen.env`.

`model pull` then shows the line to put in `/srv/configs/halogen.env`. It offers to make the change
and restart Halogen. Halogen serves the model under the name of its folder. At its first start,
Halogen converts the checkpoint for the NPU (about a minute) and keeps the result next to it. The
download step gets only the NPU programs that the checkpoint runs on, never Halogen's weights for
them.

Only these three folders are writable for the server, so the server can keep the conversion. Use
`model pull` to fill them. A folder that root copies in manually is read-only for the server. The
server then converts it again at every start.

### Your own Flash checkpoint

Both editions can serve a different build of the Flash model in place of the official one. This
can be a community conversion, or your own fine-tune or quantization in Halogen's `.hgn` format.
The official checkpoint always stays on disk. So one command goes back to it, and downloads
nothing.

```bash
sudo halogenctl flash pull someone/Some-Flash-HGN --revision <commit> --as mine
sudo halogenctl flash list               # official and yours: size, which is active, verified
sudo halogenctl flash use mine           # switch; asks first, then restarts Halogen
sudo halogenctl flash use official       # back to the official checkpoint
sudo halogenctl flash verify mine        # check it again (done for you after a Halogen update)
sudo halogenctl flash check mine         # compare its quality with the official one (stops Halogen ~15 min, ~25 the first time)
sudo halogenctl flash remove mine
```

What `flash pull` does:

- **One exact version.** It asks Hugging Face to which commit `--revision` points (a branch, tag
  or commit; `main` if you don't give it). It downloads that commit and records it. `flash list`
  shows it.
- **Only what Halogen loads.** This is the `.hgn` checkpoint, its quality sidecar (if it has
  one), the vision tower, and `tokenizer/`. It gets the lookup table
  (`qwen38-flash-next-ngram.hgn`, about 48 GB) only when the checkpoint doesn't have its own.
  Halogen's server tells which. If the table is the same file as the official one, the checkpoint
  shares the official file, with no extra disk space. (`flash list` still counts it in the size of
  the checkpoint.) It downloads nothing else from the repository, so there's no Python pickle or
  script to run.
- **Several checkpoints.** If the repository has more than one `.hgn` checkpoint, select one with
  `--file <name>.hgn`.
- **No tokenizer.** If the repository has no tokenizer, `flash pull` copies in the official
  tokenizer. If its `tokenizer/` has a chat template and settings but no `tokenizer.json` (the
  vocabulary), it adds the official vocabulary and keeps the chat template of the checkpoint. If
  it has its own vocabulary but no `tokenizer.json`, halOS can't make one. The checkpoint then
  fails the check, and `flash use` refuses it. To correct a checkpoint that you pulled before
  halOS did this, run `sudo halogenctl flash verify <name>`. If Halogen serves it, then run
  `sudo halogenctl restart`.
- **Room first.** It checks the free space before it downloads anything. A custom checkpoint
  usually needs 60 to 110 GB, in addition to the 110 GB of the official model.
- **Checked twice.** Every file must agree with the hash that Hugging Face shows for it. The
  checkpoint must also pass Halogen's own
  [`verify`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md).
  `flash use` refuses a checkpoint that failed or that halOS didn't check. After a Halogen update,
  the next start checks the selected checkpoint again with the new Halogen. If it fails, Halogen
  serves the official checkpoint, and `flash list` and `status` tell why.
- **Updates in place.** If you pull the same name again, `flash pull` moves the checkpoint to the
  new commit of the repository. It also removes files that the new commit doesn't have. It doesn't
  replace the checkpoint that Halogen serves: first switch to the official one.
- **Resumes.** If a download stops, run the same command again to continue it. A pull can take
  hours. So over SSH, run it in `tmux`, which keeps it alive if the connection stops.
- **Your token.** It uses your Hugging Face token if you saved one. Gated and private repositories
  need it.

Downloads and checks read from the disk while Halogen continues to serve. Until they finish, long
prompts can be a little slower.

#### Converting full-precision weights

Many models are available only in full precision (BF16 `.safetensors`), the format of their
training, not as a Halogen `.hgn`. For **Qwen3.8 Flash Next** weights, halOS can convert them on
the machine. It uses [bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn), a third-party tool
(MIT or Apache-2.0) that the image includes at a pinned version:

```bash
sudo halogenctl flash convert someone/Some-Flash-BF16 --revision <commit> --as mine
sudo halogenctl flash convert-logs       # follow it (Ctrl-C stops following, not the conversion)
sudo halogenctl flash convert-stop       # stop it; add the name to delete the downloaded weights too
sudo halogenctl flash check mine         # then judge it, before serving it
```

- **Checked before the big download.** It first downloads the small files of the repository. It
  refuses anything that is not Qwen3.8 Flash Next, and weights without an MTP head or vision
  tower. (The converter uses the repository's own and puts nothing official in their place.) Then
  it checks that there is space for the weights (about 360 GB) and the result (about 119 GB).
- **Runs on its own.** After you confirm, the download, the conversion and the checks run as a
  service. So if you close the terminal, they don't stop. A stopped download continues. A
  stopped conversion starts again from the beginning.
- **Takes long.** The conversion runs on the CPU with low priority, and takes many hours, probably
  a day or more. Parts of it use several cores (`--threads`: by default half the cores, 16 at
  most). Nobody has measured the time of a full-size conversion yet. Nobody has measured how much
  it slows a Halogen that serves requests.
- **Checked twice.** bf16-to-hgn's own `verify` checks each value that it wrote against the
  weights. Then Halogen's `verify` checks the result, as for `flash pull`. The converter runs in a
  sandbox with no network. It can't see your settings, keys or token, and it can write only to its
  own work folder. The result shows under `/srv/models/flash/<name>` only after both checks pass.
- **The weights are deleted** after the conversion, to free the 360 GB. `--keep-source` keeps them
  in `/srv/models/flash/.convert/<name>/source`.
- **Judge it before serving it.** Nobody has measured the quality of a conversion yet. Before
  `flash use`, run `flash check` and compare its numbers with those of the official checkpoint.
  Halogen has also not served a converted checkpoint yet. So switch to it when you can monitor
  it. If it doesn't start, go back with `sudo halogenctl flash use official`.

Things to know:

- **Quality is yours to judge.** `verify` proves that the file has a correct form, not that its
  answers are good. `flash check` compares it with the official checkpoint. It uses Halogen's
  [`ppl`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md#how-does-it-compare-to-the-shipped-checkpoint)
  on the public wikitext-2 test text, the comparison that Halogen's docs use:
  - **perplexity**: how surprised the model is by the text. Lower is better. A good conversion is
    close to the official one.
  - **same next token**: how frequently both checkpoints would write the same word.
  - **KL median**: how different their predictions are. A few hundredths is the normal difference
    between two quantizations of the same model. Much more means that it answers differently in
    some places. This is expected of a fine-tune, and a warning sign for a plain conversion.

  The check needs the GPU, so Halogen stops while it runs. On the test machine, this takes about
  15 minutes, and about 25 the first time on a Halogen version. Then Halogen starts again, even if
  the check fails or stops, or if your SSH connection stops. If you stopped Halogen yourself, it
  stays stopped. The check downloads the text (1.3 MB) one time, before Halogen stops, and checks
  it against its known hash.

  halOS keeps the result, and `flash list` shows it. The full output, with the 5 places where the
  two checkpoints disagree most, is in `/srv/models/flash/<name>/check.json`. The check measures
  one type of text, so also try your own prompts.
- **Halogen may refuse it at start,** for example if the thinking control of its chat template
  doesn't work ([`HALOGEN_TEMPLATE_UNCHECKED`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md)),
  or if it needs more memory than is free. `sudo halogenctl status` and the selftest then tell
  you. `sudo halogenctl flash use official` brings back the official model.
- **The selftest and `flash list` show what Halogen serves.** If your choice is missing or failed
  a check, Halogen serves the official checkpoint without a message, so that it still starts. The
  selftest and `flash list` then tell you this, and why.
- **Images.** With `HALOGEN_VISION_TOWER=1`, images work only if the repository of the checkpoint
  has a vision tower (`qwen38-flash-next-vision.hgn`). Without one, images stay off, and
  `halogenctl config` tells why.
- **Not yet:** GGUF repositories. Halogen can convert them, but `flash pull` can't do this yet.
- **Where things live.** Checkpoints are in `/srv/models/flash/<name>/`. The choice is in
  `/srv/configs/flash-checkpoint`, which only `halogenctl flash use` writes. You can't set
  `HALOGEN_CHECKPOINT` in `halogen.env`.

### Shutting out repeated failed logins (fail2ban)

halOS runs [fail2ban](https://github.com/fail2ban/fail2ban). It looks for an address that fails
again and again. Then it tells the firewall to shut out that address for some time:

| Watches | Shut out after | For |
|---|---|---|
| SSH logins | 5 failures within 10 minutes | 10 minutes |
| Halogen's API on port 8731: a missing or wrong API key | 10 within 10 minutes | 10 minutes |

```bash
sudo halosctl fail2ban                       # state, and who is shut out now
sudo halosctl fail2ban unban 203.0.113.9     # let an address back in at once
sudo halosctl fail2ban off                   # turn it off (on again: fail2ban on)
```

- **This machine and private networks are never shut out**: home and office address ranges, and
  Tailscale's. Without this rule, an app on your network with an old API key would lock out its
  full computer. It would then look as if the server is down. So fail2ban protects against the
  internet, when the internet can get to the machine. fail2ban doesn't stop a device on your own network
  that guesses keys.
- To change that list or the numbers, put your own lines in
  `/etc/fail2ban/jail.d/90-local.local`. Don't put them in the halOS file `50-halos.conf`, because
  updates replace that file. Then run `sudo systemctl reload fail2ban`. For example, to exempt
  only this machine:

  ```ini
  [DEFAULT]
  ignoreip = 127.0.0.0/8 ::1
  ```
- It can't protect the [SSH unlock at boot](#unlock-over-ssh-at-boot): fail2ban starts only after
  the disk is unlocked.
- Its own messages (who was shut out and let back in) are in the journal:
  `sudo journalctl -u fail2ban`.
- A ban is complete: it also cuts the connections that the address already had open. fail2ban
  keeps the bans in its own firewall table, next to the firewalld rules. After the first ban,
  `sudo nft list table inet f2b-table` shows this table. `sudo firewall-cmd --reload` doesn't
  change the bans.
- The halOS firewall lets through only the ports that firewalld opens itself. It blocks ports that
  a container started with `sudo podman run -p …` publishes. So such a container may refuse to
  start ("Port forwarding not possible as firewalld StrictForwardPorts enabled"). Run your own
  containers without `sudo` (rootless, as Halogen runs). If you need a rootful container, set
  `StrictForwardPorts=no` in `/etc/firewalld/firewalld.conf` and run
  `sudo systemctl restart firewalld`.
- The front door refuses a request if its first line and headers together are larger than 32 KB
  (431 over HTTP/1.1, a protocol error over HTTP/2). No app comes near that limit. The limit keeps
  each request on a single log line, so no request gets past the count.

What it can't do:

- **Several people behind one address are shut out together.** Maybe you connect to the server
  from an office, a mobile network or a VPN. Then other people use the same public address. Any
  of them can get that address shut out for 10 minutes with a few wrong keys. SSH stays open when
  the API is shut (and the reverse). So `sudo halosctl fail2ban unban <address>` is always
  available.
- **A proxy or tunnel in front hides the real addresses.** With a reverse proxy on another
  machine, every client has the address of the proxy. Then one bad client shuts out all of them.
  With a tunnel that ends on this machine (cloudflared and similar tools), every client is this
  machine. This machine is never shut out, so fail2ban does nothing for the API.
- **fail2ban counts IPv6 per address,** and one network has many addresses. So fail2ban doesn't
  slow a determined sender.

The API key has 64 random characters, so nobody can guess it, with or without fail2ban. For the
API, fail2ban decreases the junk requests that get to Halogen. For SSH, it decreases the noise.

## 8. Optional: unlock LUKS with the TPM

If you selected LUKS, the TPM can unlock the disk at each boot, and you don't type the passphrase:

```bash
sudo halogen-enroll-tpm
sudo systemctl reboot
```

Keep the passphrase as your recovery key. TPM unlock uses PCR 7, which records the Secure Boot
state. OS updates and rollbacks don't change it. These events change it:

- You turn Secure Boot off or on.
- You change the Secure Boot keys.
- You clear the TPM.
- Some BIOS updates or Secure Boot revocation-list updates.

After one of these events, the boot asks for the passphrase. Type it, then run
`halogen-enroll-tpm` again. It replaces the old TPM binding, and doesn't add a second one. The CI
install test enrolls the TPM and reboots without a passphrase. But nobody has confirmed this on
hardware yet. If the next boot still asks for the passphrase, report it.

### What TPM unlock protects, and what it doesn't

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

### SSH logins with keys only

After your account can log in over SSH with a key, you can turn off passwords for SSH logins. Then
nobody on the network can try to guess a password:

```bash
sudo halosctl ssh-passwords off
```

The command refuses while your account has no key in `~/.ssh/authorized_keys` that sshd would
accept. (Add one from your computer with `ssh-copy-id`.) Before the command applies the setting, it
checks that sshd will really use it. The screen of the machine still accepts the password.
`sudo halosctl ssh-passwords on` allows passwords again. `sudo halosctl setup` also offers this,
with no as the default.

## If something goes wrong

| Symptom | Check |
|---|---|
| The machine shows much less than 128 GB | If the BIOS has a UMA frame buffer setting, set it to its minimum, not Auto |
| `curl localhost:8731` gets "connection reset" | Only releases before `v0.18.23-alpha.3`. Use `127.0.0.1` instead of `localhost` |
| `/dev/accel/accel0` is missing | Use the NPU edition, and check the IOMMU and the firmware |
| The fabric clock is not held | `systemctl status halogen-fabric-clock` |
| The selftest warns about the power profile | `sudo halosctl power` shows the profile. `systemctl status halos-platform-profile` tells what occurred at boot |
| Halogen does not start after a change to the config | Run `sudo halogenctl status`, then check the NPU model names |
| "start of the service was attempted too often" | Halogen crashed 3 times in 15 minutes. This is its guard against a crash loop. To see why, run `sudo halogenctl logs`. If the GPU is stuck, reboot. If not, `sudo halogenctl restart` tries again. On releases before this fix, first run `sudo systemctl --user -M halogen@ reset-failed halogen.service`, then `sudo halogenctl restart` |
| Halogen does not start after `flash use` | `sudo halogenctl logs` tells why. `sudo halogenctl flash use official` goes back |
| Halogen's start does not finish, or GTT stays in use after a crash | Reboot, as Halogen's troubleshooting guide tells |

For all other problems, see Halogen's
[troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md).

Next: [configure the server](README.md#configure).
