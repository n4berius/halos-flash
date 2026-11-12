# Installing halOS

This guide covers a new install from USB, from choosing an edition to a working API.
For how Halogen itself behaves, see its
[official documentation](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs).

> halOS is in alpha. The NPU edition runs on the hardware below; anything else is
> untested, so work through the [checks](#7-check-the-install) on your first install and
> [report how it went](https://github.com/n4berius/halos-flash/issues/new?template=hardware-report.yml).

## Tested hardware

| Machine | Memory | Disk | Release | Edition |
|---|---|---|---|---|
| [AMD Ryzen AI Halo Developer Platform](https://www.microcenter.com/product/711961/amd-ryzen-ai-halo-developer-platform-linux-os) (Micro Center) | 128 GB | 2 TB NVMe | `v0.18.23-alpha.2` | With NPU |

On that machine, these work:

- USB install with Secure Boot on, and no MOK enrollment
- Automatic storage, with each volume created
- First-boot download of the Halogen container and about 125 GB of models
- Halogen on the GPU, with all five NPU models loaded
- The API from other machines on the network, such as Hermes

Not yet confirmed on hardware: LUKS with TPM unlock (it passes in the VM test), the edition
without NPU, and a long soak under real load.

Its BIOS has no UMA frame buffer setting. That's fine: the GTT kernel settings give Halogen
its memory either way.

## What you need

- A dedicated AMD Strix Halo machine with 128 GB of memory. The GTT settings assume 128 GB.
- A USB drive of at least 4 GB. Writing the ISO erases it.
- An internal disk of 480 GB or more (a 500 or 512 GB drive is fine). The models take about 125 GB.
- Internet access on first boot, for the Halogen container and models.
- Another computer to download the ISO and write the USB drive.

## 1. Choose an edition

| | With NPU | Without NPU |
|---|---|---|
| Serves | Flash and NPU models | Flash only |
| IOMMU | On, with `iommu=pt` | Off, with `amd_iommu=off` |
| Trade-off | Slower prefill, keeps DMA protection | Halogen measured 13-16% more prefill, but DMA protection is off |
| Image | `halos-flash:0.19.0` | `halos-flash:0.19.0-no-npu` |

You can change your mind later without reinstalling: `sudo halosctl npu off` moves to the no-NPU
edition and `sudo halosctl npu on` moves back, on the same channel or release, at the next
reboot. `/srv` stays as it is: the NPU models and your own checkpoints stay on disk, so going
back needs no new download, and `HALOGEN_NPU_*` settings are ignored while the NPU is off (the log
says "ignored HALOGEN_NPU_…: not an option this system allows" for each one; that is expected).
What turning the IOMMU off costs: a device plugged into a USB4/Thunderbolt port or a PCIe slot can
then read all of the machine's memory, including the disk encryption key while it runs. Use the
no-NPU edition only where nobody untrusted can touch the machine.

## 2. Prepare the BIOS

1. Update to your maker's newest BIOS. Halogen's
   [NPU docs](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#what-the-host-needs)
   explain why this matters.
2. If your BIOS offers a UMA frame buffer, or dedicated graphics memory, setting, set it to
   its explicit minimum, not Auto. Some machines don't have this setting, and that's fine.
3. Leave Secure Boot on if you want it. No MOK enrollment is needed.
4. Use the BIOS power settings you want. Halogen's published numbers assume about 85 W.

## 3. Get the ISO

Download your edition's ISO and its `.sha256` file from this repository's
[Releases page](https://github.com/n4berius/halos-flash/releases). Use the `-npu` files for
the NPU edition and the `-no-npu` files for the other. Alpha, beta and RC releases are
pre-releases, and [RELEASING.md](RELEASING.md) explains each channel.

GitHub limits release files to 2 GiB, so the ISO comes in one of three forms. Check it in the
folder you downloaded to; it must say `OK`:

| You downloaded | Do this |
|---|---|
| One `.iso` | `sha256sum -c *.iso.sha256` |
| One `.iso.xz` | `sha256sum -c *.iso.xz.sha256`, then unpack it with `xz -d` (7-Zip on Windows). balenaEtcher can write the `.xz` without unpacking |
| Several `.iso.partNN` files | Older releases only. Join them with `cat *.iso.part* > halogen.iso`, then check with `sha256sum -c *.iso.sha256` |

From `v0.18.23-alpha.3` on, each release ships one file whenever compression gets it under
the limit.

### Moving between releases later

A machine installed from a release stays on that exact build, so an upgrade finds nothing
new. To get new releases, pick a channel once and reboot:

```bash
sudo halosctl switch alpha
sudo systemctl reboot
```

From then on, `sudo halosctl upgrade` stages the newest release on that channel. Channels are
`alpha`, `beta`, `rc`, `release` (stable) and `edge`, and each one also gets newer releases of
the more stable ones. `halosctl` keeps your edition, so it adds `-no-npu` for you.
`sudo halosctl version` shows what the machine runs and follows, and `sudo halosctl rollback`
goes back.

Installs from before `halosctl` (`v0.19.0-alpha.1` and older) need one `bootc switch` first,
with the channel tag, such as `ghcr.io/n4berius/halos-flash:alpha` (add `-no-npu` on that
edition). This also moves installs from before the rename to halOS, which follow
`ghcr.io/n4berius/halogen-flash-bootc` and get no new builds. Files, settings and models stay
as they are.

Using `bootc` directly: `bootc switch` to the name the machine already follows does nothing
("Image specification is unchanged"), even when that tag now points to a newer build. Use
`sudo bootc upgrade` (or `sudo halosctl upgrade`) to get the newest build of the current name.

### Signed images

Every halOS image is signed with halOS's key, and a machine takes an update only when that
signature checks out, so nobody else's image can be passed off as halOS's. `sudo halogenctl
selftest` shows it as `image-signatures`. Machines installed from this release on check from the
start. Older installs turn it on with their next `sudo halosctl upgrade` after rebooting into
this release: it says so, asks, and stages the newest image of the name it follows with the check
on. So the first upgrade to this release still installs without the check, and the next one turns
it on; each needs a reboot.

- Releases before `0.19.1-alpha.3` aren't signed with the key, so `halosctl rollback --to` can't go
  back to them. `halosctl rollback` to the previous image on the disk still works.
- The rules are in `/etc/containers/policy.json`: halOS's images need halOS's signature, and
  images from other registries (Halogen's own, or containers you run with podman) are taken as
  before. If that file is changed or removed, `halosctl` refuses to switch and says how to put
  halOS's copy back (`sudo cp /usr/etc/containers/policy.json /etc/containers/policy.json`).
- `bootc switch` by hand needs `--enforce-container-sigpolicy`, or the machine stops checking.
  `halosctl` always passes it. `sudo halosctl version` says whether updates are checked, and so
  does the SSH login message when they aren't.
- The selftest's `signature-files` line compares the policy, the registry setting and halOS's
  public key with the image's own copies in `/usr/etc`, and warns about a policy file in root's
  home, which would replace the system one.
- If the name you follow is ever pointed back at an older build, `halosctl upgrade` says so and
  doesn't reboot by itself, so you can look first. (Other channels and the other edition are
  built at other times, so `switch` and `npu` don't compare.)
- `halosctl` also refuses to switch if `/etc/pki/containers/halos-flash.pub` isn't the image's copy.

To build an ISO yourself, see [BUILDING.md](BUILDING.md).

## 4. Write the USB drive

Use [Fedora Media Writer](https://fedoraproject.org/workstation/download/) with its custom
image option, or use `dd` on Linux. Check the device name first, because `dd` overwrites it
without asking:

```bash
lsblk
sudo dd if=halos-flash-v0.19.0-alpha.1-npu.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

## 5. Run the installer

Boot from the USB drive. The first menu entry, **Install halOS**, is the guided install: a few
questions on a text screen, then it installs by itself. Nothing is erased until you have
answered them all and said yes at the end.

1. **The disk.** It lists the machine's internal disks. USB drives, including the installer,
   are never offered, and disks under 480 GB are listed as too small (the models alone take
   about 130 GB).
   - One empty disk: it shows it and asks **"Erase it and install halOS?"**
   - More than one disk, or a disk with anything on it (partitions, an old install, LUKS): it
     shows each disk's name, size, model and what's on it, and you **type the name** of the one
     to erase, for example `nvme0n1`. Pressing Enter instead stops without changing anything,
     and the machine powers off at the next Enter.
2. **Name of this machine** on the network. Enter keeps `halos`.
3. **Encrypt the disk (LUKS)?** If yes, type the passphrase twice. You type it at every boot,
   until you let the TPM unlock it in [first-boot setup](#6-first-boot-setup-then-let-the-first-boot-finish).
   With the passphrase, encryption protects the machine and its disk while it is switched off.
   With TPM unlock, only a disk taken out of the machine; see
   [what TPM unlock protects](#what-tpm-unlock-protects-and-what-it-doesnt).
   Use letters, digits and the symbols of a US keyboard: that's the layout the boot prompt has.
4. **Enable the root account?** If yes, type its password twice. Root can only log in at the
   machine's own screen, never over SSH. Most people answer no and use `sudo`.
5. **Admin user:** a name and a password. This is the account you log in with, locally and over
   SSH, and it can use `sudo`.
6. **How the disk unlocks at each boot** (only with encryption):
   1. **TPM and SSH** (recommended, Enter): the machine unlocks itself; when it can't (after a
      BIOS update, say), you type the passphrase from another computer over SSH.
   2. **TPM only:** when the TPM can't, type the passphrase at the machine's keyboard.
   3. **SSH only:** type the passphrase from another computer at every boot.
   4. **Neither:** type the passphrase at the machine's keyboard at every boot.

   The TPM itself is set up at the first boot, in
   [first-boot setup](#6-first-boot-setup-then-let-the-first-boot-finish). For SSH, it asks
   where your public keys are: **GitHub, GitLab or Codeberg** (type your user name; it needs a
   network cable, with DHCP), or **type one key** (there's no clipboard at the machine's own
   screen, so the account is the easier way). It names the account and shows each key it found,
   and asks before using them. If an account has no keys, it says so and asks again, and
   **back** returns to the unlock choice. Then it asks whether the same keys may also log the
   admin user in over SSH (Enter: no).

   The first boot still asks for the passphrase at the keyboard. `sudo halosctl setup` then sets
   up the TPM and shows two lines to add on the computer you unlock from (see
   [Unlock over SSH at boot](#unlock-over-ssh-at-boot)); from the next boot, SSH works.
7. It shows a summary and asks once more: **"Erase nvme0n1 and install halOS now?"**

The install copies the OS from the USB drive, so it needs no network, and takes a few minutes.
The machine then restarts: remove the USB drive. If you forget and it boots the USB drive again,
nothing happens without you: the disk now has halOS on it, so the installer asks you to type its
name before it would erase anything.

The guided install sets the clock to UTC and takes the network address from DHCP. Halogen doesn't
care about the time zone; `sudo timedatectl set-timezone <zone>` changes it later.

The disk is laid out the same way on every machine, with LVM and XFS. The volume group is
always `halos`, whatever the machine's name:

| Mount | Volume | Size |
|---|---|---|
| `/` | `halos-root` | 40 GiB |
| `/var` | `halos-var` | 60 GiB |
| `/var/log` | `halos-log` | 10 GiB |
| `/var/log/audit` | `halos-audit` | 5 GiB |
| `/var/home` | `halos-home` | 50 GiB |
| `/var/srv/configs` | `halos-configs` | 1 GiB |
| `/var/srv/models` | `halos-models` | the rest: about 300 GiB on a 512 GB disk, 1,690 GiB on a 2 TB one |

Each [Flash checkpoint of your own](#your-own-flash-checkpoint) takes about 110 GB more of the
models volume.

**Custom partitioning.** The second menu entry, **Install halOS (custom partitioning)**, opens
the full graphical installer, for unusual setups. Under **Installation Destination**, pick the
disk; **Automatic** creates the volumes above with sizes that scale with the disk (its volume
group is named after the machine, such as `halos_freyja`), and **Custom** lets you change them.
Keep at least 150 GiB for `/var/srv/models`. Tick **Encrypt my data** for LUKS, and create an
admin account with admin rights.

The third entry, **unattended test install**, is for halOS's automated VM test. It reads its
answers from a prepared volume and stops if there is none; you don't need it. From the other
entries such a volume is ignored.

The installed system starts at a text login, and you don't need to create another account.

## 6. First-boot setup, then let the first boot finish

Log in as your admin user and run:

```bash
sudo halosctl setup
```

It asks three things, and you can skip each one:

1. **How the disk unlocks at boot.** With the TPM, there's no passphrase to type while Secure
   Boot and the BIOS stay the same; it runs `halogen-enroll-tpm` for you. Or keep typing the
   passphrase at each boot. Then it offers unlocking over SSH, unless it is set up already.
   After a guided install, the answers you gave there are the defaults (Enter). The TPM protects a disk taken out of the machine, not the machine
   taken whole: see [what TPM unlock protects](#what-tpm-unlock-protects-and-what-it-doesnt).
2. **A Hugging Face token.** Optional: it raises the download limits. Create a read token at
   [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
3. **Settings.** Open `/srv/configs/halogen.env` in an editor, or keep the defaults, which suit
   most people.

The first 130 GB download waits for setup, so your token and settings count from the start. If
nobody runs setup within 30 minutes, the download starts with the defaults anyway, so a machine
nobody logs into still comes up by itself. `sudo halosctl setup --skip` starts it at once. You
can run `sudo halosctl setup` again at any time; it then offers to restart Halogen to apply your
changes. Machines upgraded from an earlier release never wait.

After setup, the first boot runs in this order:

1. `halogen-prepare` creates `/srv/models`, `/srv/configs`, the config file and an API key.
2. On the NPU edition, `halogen-fabric-clock` holds the clock Halogen needs for GPU and NPU
   together.
3. `halogen-fetch` pulls the pinned Halogen container and downloads the models. Interrupted
   downloads resume, and network failures retry until they succeed.
4. Halogen's `verify` mode checks the Flash checkpoint. NPU files are checked against the
   hashes in the pinned container.
5. Halogen starts, with its models read-only. It never downloads anything itself. The network
   reaches it on port 8731 through [Caddy](https://caddyserver.com) (`halos-proxy.service`), see
   [The front door](#the-front-door).

You can watch it without logging in. Above the login prompt, the machine's screen shows one line
that updates by itself every 30 seconds. Before setup it reads `waiting for setup: sudo halosctl
setup`, and then:

```
halOS 0.19.1-beta.1 (npu edition) - downloading models 45%
```

It then reads `checking models`, then `starting`, and finally
`ready: http://<this machine's address>:8731/v1`. If something stops it, the line says
`download failed` or `stopped`, with the command to run next. Logging in over SSH shows the same
line, plus the release, the channel, any staged update and the free space for models. The first
time Halogen answers after a boot, anyone logged in gets a one-line notice.

To follow the details, log in and run:

```bash
sudo halogenctl fetch-logs
```

It prints how much has downloaded every minute. Press Ctrl+C to stop watching; the download
carries on.

Downloads work without an account. A free Hugging Face read token raises the rate limits and
usually speeds them up. Create one at
[huggingface.co/settings/tokens](https://huggingface.co/settings/tokens), then:

```bash
sudo halogenctl hf-token     # paste the token; it isn't shown or printed
sudo halogenctl restart      # the download resumes with the token
```

The token is stored in `/srv/configs/hf-token`, readable only by the `halogen` service, and
used only for downloads. Remove it with `sudo halogenctl hf-token --remove`.

Later boots skip the download unless the model list or Halogen version changes.

## 7. Check the install

Run the self-check. It goes through the hardware checklist in one go, changes nothing, and
prints nothing private (no keys, serial numbers or network addresses), so you can share its
output when asking for help:

```bash
sudo halogenctl selftest | tee selftest.txt
```

Each line starts with PASS, WARN, FAIL, SKIP or INFO and says what to do about a problem.
While the first boot is still downloading, `server` and `models` show as not ready yet.

The individual commands, if you want them:

```bash
sudo halogenctl doctor
sudo halogenctl status
sudo halogenctl config
curl -H "Authorization: Bearer $(sudo halogenctl api-key)" http://127.0.0.1:8731/v1/models
```

The API should list the Flash model, plus the NPU models on that edition. Clients connect to
`http://<host>:8731/v1` with the same key (`https://` once you turn [HTTPS](#https) on; then add
`--cacert halos-ca.crt` to the curl above and use `https://`). [Connecting apps](docs/CLIENTS.md)
has the settings for Claude Code, Codex, Pi, oh-my-pi, opencode, Cline, aider and others, and
the [command reference](docs/CLI.md) lists every halOS command.

Please confirm these on the first install:

- `cat /proc/cmdline` shows the GTT settings and your edition's IOMMU setting.
- `bootctl status` reports Secure Boot enabled, if you left it on.
- `systemctl --failed` is clean. Upstream warns `systemd-remount-fs.service` can fail on
  Anaconda-installed bootc systems. It stayed clean in our VM test.
- `ls -l /dev/kfd /dev/dri/renderD*` shows group `halogen`.
- `sudo journalctl -b _TRANSPORT=audit + _TRANSPORT=kernel | grep 'avc: *denied'` prints
  nothing. If `/dev/kfd` shows `denied { map }`, run
  `sudo setsebool -P container_use_devices true`.
- A soak test mixes your real load for several hours. Kernel 7.2 has a reported GPU memory
  fault, and Halogen's reference host ran 7.1.8.

On the NPU edition, also confirm:

- `ls -lZ /dev/accel/accel0` shows group `halogen` and type `dri_device_t`.
- `/usr/libexec/halogen/halogen-fabric-clock status` reports the clock as held. With Secure
  Boot on, the kernel runs in lockdown, and this has not been tested on hardware.

### Tools on the machine

The OS is kept small, but these are included for looking after it:

| Command | What it's for |
|---|---|
| `amd-smi metric` | GPU temperature, power and clocks. On Strix Halo some fields show N/A |
| `nvtop` | Live GPU use, and which process holds GPU memory |
| `htop` | Live CPU and memory use |
| `tmux` | Keeps a long command running if your SSH connection drops |
| `lspci`, `lsusb` | List the hardware |
| `nvme list`, `sudo nvme smart-log /dev/nvme0` | Disk health |
| `fwupdmgr` | Firmware updates from the vendor, where the board supports it |

Firmware updates use [fwupd](https://fwupd.org/). Check for them with
`sudo fwupdmgr refresh && sudo fwupdmgr get-updates`, and apply them with
`sudo fwupdmgr update`. A BIOS update reboots the machine, which stops Halogen until it is back.

### The dashboard

Open `http://<this machine's address>:8732` (next to the API on 8731) in a browser on your network for a live view of
Halogen: whether it is up, generation and prefill speed, busy slots, queued requests, the KV pool,
the prompt cache, the NPU, and charts from the last five minutes to the last 30 days.
`sudo halosctl dashboard` shows its state and address.

It is [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion, built
into halOS unchanged (licences in `/usr/share/licenses/halogen-dashboard/`). It reads Halogen once a
second with your API key, and keeps its history in `/var/lib/halos-dashboard` (48 hours in full,
then one-minute summaries for 30 days: about 430 MB once full). It uses about 12 MB of memory and almost no CPU.
It runs as a user of its own, with no access to Halogen's files, models or tokens.

- **No login.** Anyone who can reach port 8732 on your network can view it, but nobody can change
  anything through it, and it never shows your API key or anything sent to Halogen. It does show
  when and how much the server is used. If you don't want that, turn it off:
  `sudo halosctl dashboard off` stops it (port 8732 then only says it's off); `on` turns it back on.
- **On by default**, also on machines that upgrade to a release with it.
- **Private networks only.** It answers this machine and private addresses only: 10.x, 172.16-31.x,
  192.168.x, link-local, and 100.64.0.0 to 100.127.255.255 (Tailscale; also some internet
  providers' shared addresses). A computer on a public address, such as through a port forward,
  gets no answer, unless something on your network passes it on (a reverse proxy, a tunnel or
  `tailscale serve`). Caddy applies this rule, on IPv4 (as before). If your network uses other addresses, browsers get
  no answer: add your ranges to `/etc/halos/proxy.env` as `HALOS_DASHBOARD_ALLOW=<range> <range>`,
  then `sudo systemctl restart halos-proxy` and check it with `sudo systemctl status halos-proxy`:
  a mistyped range stops Caddy, and with it the API, until it is fixed. The dashboard itself takes connections only from this
  machine.
- **The API key stays out of crash reports.** The dashboard can't be dumped, so if it ever
  crashes, nothing it holds (the key included) lands on disk or in the system log. It may also
  listen on its own local port only, and takes connections only from this machine (Caddy).
  `sudo halogenctl selftest` checks the crash-report protection, and that this address filter is
  really active.
- **Memory is capped at 256 MB**, so it can never take memory from Halogen. Its own 30-day view
  needs about 100 MB. A request crafted to read far more makes it restart after 30 seconds, and
  Halogen is unaffected.
- **Only one reader of `/metrics`.** Halogen resets two of its speed figures each time something
  reads `/metrics`, so the dashboard must be the only reader. Don't point Prometheus or a script at
  Halogen's `/metrics`; the dashboard serves its own copy at `http://<address>:8732/metrics`.
- If you change the API key in `/srv/configs/api-key`, restart the dashboard:
  `sudo systemctl restart halos-dashboard`.

### The front door

[Caddy](https://caddyserver.com) (`halos-proxy.service`) answers the network on both ports:
**8731** for Halogen's API and **8732** for the dashboard. Halogen and the dashboard themselves
listen on this machine only (`127.0.0.1:18731` and `127.0.0.1:18732`), so every connection from
another computer goes through Caddy, over plain HTTP or [HTTPS](#https).

- Replies stream through as Halogen sends them; Caddy adds no buffering.
- While Halogen starts, downloads or is stopped, the API answers `503` with a short note (JSON, as
  Halogen's own errors are) instead of refusing the connection.
- Caddy writes one line per API request to the journal (`sudo journalctl -u halos-proxy`): the
  time, the client's address, the path and the status. It writes no request headers and no
  query string, so the API key never lands there, whichever way an app sends it.
- Caddy runs as a user of its own with no access to your files, and with no admin interface.
  `sudo halogenctl selftest` checks it answers (`proxy`); its other API checks and `halogenctl
  bench` talk to Halogen directly, so their numbers are Halogen's own.
- Halogen's own [docs](https://github.com/peonist-ai/halogen-flash-server/tree/main/docs) list no
  setting that depends on the client's address, so Halogen behaves the same behind Caddy.

### HTTPS

Plain HTTP sends prompts, replies and the API key across your network as they are. HTTPS
encrypts them. It is off until you turn it on; machines that upgrade stay on HTTP, so no app
breaks by surprise.

```bash
sudo halosctl https                        # the state, and what apps use
sudo halosctl https self-signed            # on, with halOS's own authority
sudo halosctl https custom cert.pem key.pem   # on, with your certificate (PEM, key without a passphrase)
sudo halosctl https letsencrypt cloudflare halos.example.com   # on, with Let's Encrypt (see below)
sudo halosctl https off                    # back to plain HTTP
```

With HTTPS on, both ports speak it: apps use `https://<address>:8731/v1`, and the dashboard is
`https://<address>:8732`. A plain `http://` request on either port is redirected to `https://`.
Apps that send the key over `http://` still send it once before they follow the redirect, so
change their address to `https://`.

**Self-signed** makes halOS's own certificate authority (Caddy's, kept by the machine) and a
certificate for each of this machine's names and addresses: `localhost`, its host name, the
`.local` name and every address it has, including Tailscale's. Apps and browsers must trust the
authority once:

```bash
sudo halosctl https ca > halos-ca.crt
```

Then give `halos-ca.crt` to each app that talks to the machine: most have a setting for a CA
file, and [Connecting apps](docs/CLIENTS.md) lists it for each coding agent (Pi, oh-my-pi,
opencode, Codex, Claude Code, Cline, aider and others).
Prefer that over adding it to your computer's trusted certificates: an authority trusted
system-wide can vouch for any website, so anyone who stole it from this machine could pass for
any site on that computer. For a browser and the dashboard, accepting the warning once for
`https://<address>:8732` is enough. `sudo halosctl https` shows the authority's fingerprint, to
compare with the file you copied. For other names (a DNS name
you gave the machine), list them: `sudo halosctl https self-signed freyja.example`. If the
machine's address changes, `sudo systemctl restart halos-proxy` adds it; the selftest warns until
then.

**Your own certificate** must name the address apps use (a DNS name, usually). halOS checks the
key belongs to it and that it hasn't expired, shows you whose it is and asks before using it, keeps
both in `/etc/halos/https/` (root only, with the previous pair), and `sudo halogenctl selftest`
warns two weeks before it ends. If Caddy doesn't answer with a new setting, `halosctl` puts the
previous one back, certificate included. Renewing is running `https custom`
again with the new files.

**Let's Encrypt** gives certificates every app and browser already trusts, and renews them by
itself, for a public DNS name you own (such as `halos.example.com`). Nothing is opened to the
internet: Caddy proves the name is yours by writing a temporary TXT record through your DNS
provider's API (the DNS-01 challenge). The name only has to point to this machine, and a private
address such as `192.168.1.20` is fine. Some home routers block public names that point to private
addresses ("DNS rebinding protection"); allow the name there if it doesn't resolve on your network.

1. Make an API credential at your DNS provider, allowed to change that name's zone and no more.
   A credential that can change your main domain's DNS is valuable to an attacker who got into
   the machine; a domain (or a DuckDNS name) used only for halOS limits that:

   | Provider | What `halosctl` asks for | Where |
   |---|---|---|
   | `cloudflare` | `api_token` | My Profile > API Tokens > Create Token, template "Edit zone DNS", for that zone only |
   | `duckdns` | `api_token` | The token at the top of duckdns.org once you sign in; the name is `<yours>.duckdns.org` |
   | `porkbun` | `api_key`, `api_secret_key` | Account > API Access; then turn on "API Access" on the domain itself |
   | `namecheap` | `api_key`, `user`, `client_ip` | Profile > Tools > Business & Dev Tools > API Access; add this network's public IPv4 address to its allowed list, and give the same address as `client_ip` |

   Namecheap's API can only replace a domain's whole list of records, so each certificate rewrites
   the list. Note your records first, or use a domain (or a DuckDNS name) only for this.

2. Try it against Let's Encrypt's test service first, whose limits are generous (its certificates
   aren't trusted, so apps will still warn):

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --staging
   ```

   `halosctl` asks for the credential (it isn't shown while you type), then waits for the
   certificate, usually under a minute. If none comes within five minutes, it says what Let's
   Encrypt answered and puts the previous setting back.

3. Then for real; it offers to reuse the credential you gave:

   ```bash
   sudo halosctl https letsencrypt cloudflare halos.example.com --email you@example.com
   ```

   `--email` is optional: Let's Encrypt uses it only for important notices about your account.

Apps then use `https://halos.example.com:8731/v1`, and the dashboard is
`https://halos.example.com:8732`. This machine's own names and addresses keep halOS's authority
(as with self-signed), so apps that connect by address keep working once they trust it.
Certificates are public: every name you certify appears in the
[Certificate Transparency](https://certificate.transparency.dev/) logs anyone can search, so
don't use a name you want to keep private. The credential is kept in `/etc/halos/https/dns/`,
readable by root only, and Caddy gets a copy each time it starts; it never appears in a command
line, the settings file or the journal (halOS removes it from DuckDNS's and Namecheap's error
messages, and refuses a Cloudflare token whose shape Caddy's plugin would print back).
`sudo halogenctl selftest` checks the certificate as an app would, and warns ten days before it
ends, which means renewing has failed.

To give a new credential, run the same command and answer no to reusing the old one. halOS
deletes the old one once the new setting works; revoke it at the provider too. When the name
already has a valid certificate, Caddy keeps using that one, so a new credential is first used at
the next renewal (Caddy renews about a month before the end); the selftest warns if that fails.
`sudo halosctl https forget-dns` deletes the saved credential once you no longer use Let's Encrypt.

Without a terminal, `--yes` reads the credential as `field=value` lines on standard input. Put
them in a file readable only by you, never in the command itself (the shell's history keeps it),
and delete the file afterwards:

```bash
sudo halosctl https letsencrypt cloudflare halos.example.com --yes < cloudflare.txt   # api_token=...
```

halOS releases before this one don't know `letsencrypt`: after `sudo halosctl rollback` to one of
them, Caddy won't start until you run `sudo halosctl https off` or `self-signed` (it never falls
back to plain HTTP by itself).

halOS's own tools (`halogenctl bench`, the selftest's API checks, the login line's check) talk to
Halogen directly on the machine, so they work the same in either mode.

### Measuring speed

```bash
sudo halogenctl bench            # a few minutes
sudo halogenctl bench --quick    # under a minute: one prompt length, one pass
```

It measures the running server with Halogen's own
[`sweep` tool](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md#served-throughput-end-to-end-over-http),
which Halogen's published numbers come from, so yours can be compared with them. It needs no
restart, but other requests are slower while it runs. It reports:

- **pp** (prefill): how fast a prompt of 512, 2,048, 8,192 and 32,768 tokens is read.
- **tg** (generation): how fast 128 tokens are written, as the mean over Halogen's ten prompt
  shapes. Code runs about twice as fast as prose, so compare means, not single prompts.

Each report also lists what the numbers depend on: the halOS and Halogen versions, kernel, BIOS,
GTT size, IOMMU, the fabric clock, the platform power profile, the Flash checkpoint served and
your settings. It is saved as text and JSON in `/srv/configs/bench/`, named by date, so a run
after an upgrade, a BIOS change or `flash use` can be put beside an earlier one. Halogen's
[measurements](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/performance.md)
were taken at about 85 W of sustained power; a machine with a lower power limit reads lower.
The run uses the prompt cache as your server does, so compare `pp` with Halogen's "cache on (a
cold request)" rows, not the cache-off headline figures. Its prompts also go into the cache, and
can push out long conversations cached there, which then read their history again once.

### Your own NPU checkpoints

On the NPU edition, Halogen also runs checkpoints you supply, such as LiquidAI's `d1-2B` and
the LFM3 family, or your own fine-tune of one of its NPU models. Halogen's
[NPU guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-model)
lists what runs. Download one from Hugging Face with:

```bash
sudo halogenctl model pull LiquidAI/LFM3-1.7B     # add --as <name> or --revision <commit> if you like
sudo halogenctl model list
sudo halogenctl model remove LFM3-1.7B
```

`model pull` uses your Hugging Face token if you saved one (gated repos need it), resumes if
interrupted, and puts the checkpoint in the folder that fits:

| Folder | What goes there | Named in `HALOGEN_NPU_MODELS` as |
|---|---|---|
| `/srv/models/decider` | `d1-2B`, fine-tunes of `decider-0.8b` | `/models/decider/<name>` |
| `/srv/models/LFM` | LFM3-1.7B, LFM3-VL-2B, LFM3-Audio-2B, LFM3-Omni-2B | `/models/LFM/<name>` |
| `/srv/models/custom` | Fine-tunes of the embedding, reranking or guard models; OvisOCR3 | `/models/custom/<name>` |

**Document parsing (OvisOCR3).** Since Halogen 0.20 the NPU reads document pages into Markdown, with
tables as HTML and formulas as LaTeX, from your own [OvisOCR3](https://huggingface.co/ATH-MaaS/OvisOCR3)
checkpoint (Apache 2.0, about 1.7 GB): `sudo halogenctl model pull ATH-MaaS/OvisOCR3 --revision
17f255e2c8ae6d18d5d5edb0a474bd4ed39aef90` (the version Halogen 0.20.0 was tested with), then add
`/models/custom/OvisOCR3` to `HALOGEN_NPU_MODELS`. It answers as `OvisOCR3`, one or two page images a
request, about 20 seconds a page. Halogen's [NPU page](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#your-own-ovisocr3)
has the prompts and limits. When OvisOCR3 and several other NPU generation models start work at the
same time, Flash's next request can wait about 40 seconds while its weights are read back;
`HALOGEN_WEIGHTS_LOCK=1` in `halogen.env` keeps them in memory.

It then prints the line to put in `/srv/configs/halogen.env`, and offers to make the change and
restart. Halogen serves the model under its folder's name. Its first start converts the
checkpoint for the NPU (about a minute) and keeps the result beside it. The download step
fetches only the NPU programs the checkpoint runs on, never Halogen's weights for them.

These three folders are the only ones the server can write to, so it can keep the conversion.
Use `model pull` to fill them: a folder copied in by hand as root is read-only for the server,
which then converts it again at every start.

### Your own Flash checkpoint

Both editions can serve another build of the Flash model in place of the official one: a
community conversion, or your own fine-tune or quantization in Halogen's `.hgn` format. The
official checkpoint always stays downloaded, so going back is one command and downloads
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

- **One exact version.** It asks Hugging Face which commit `--revision` (a branch, tag or
  commit; `main` if you leave it out) points to, downloads that commit, and records it.
  `flash list` shows it.
- **Only what Halogen loads.** That's the `.hgn` checkpoint, its quality sidecar if it has
  one, the vision tower, and `tokenizer/`. The lookup table (`qwen38-flash-next-ngram.hgn`,
  about 48 GB) is fetched only when the checkpoint doesn't carry its own; Halogen's server
  says which. If it is the very same file as the official one, that file is shared instead,
  using no extra disk (`flash list` still counts it in the checkpoint's size). Nothing else in the repository is downloaded, so there's no Python pickle or
  script to run.
- **Several checkpoints.** If the repository holds more than one `.hgn` checkpoint, choose one
  with `--file <name>.hgn`.
- **No tokenizer.** If the repository has none, it copies in the official tokenizer. If its
  `tokenizer/` has a chat template and settings but no `tokenizer.json` (the vocabulary), the
  official vocabulary is added and its own chat template stays. If it has a vocabulary of its own
  but no `tokenizer.json`, halOS can't build one: it fails the check, and `flash use` refuses it.
  A checkpoint pulled before halOS did this is fixed with `sudo halogenctl flash verify <name>`,
  then `sudo halogenctl restart` if Halogen serves it.
- **Room first.** It checks the free space before the first byte. A custom checkpoint
  typically needs 60 to 110 GB, on top of the official model's 110 GB.
- **Checked twice.** Every file must match the hash Hugging Face lists for it, and the
  checkpoint must pass Halogen's own
  [`verify`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md).
  `flash use` refuses a checkpoint that failed or wasn't checked. After a Halogen update, the
  next start checks the chosen checkpoint again with the new Halogen; if it fails, Halogen
  serves the official checkpoint and `flash list` and `status` say why.
- **Updates in place.** Pulling the same name again moves it to the repository's new commit and
  removes files the new commit no longer has. It won't replace the checkpoint Halogen is
  serving: switch to the official one first.
- **Resumes.** An interrupted download resumes when you run the same command again. A pull can
  take hours, so over SSH run it inside `tmux`, which keeps it going if the connection drops.
- **Your token.** It uses your Hugging Face token if you saved one; gated and private
  repositories need it.

Downloads and checks are read from disk while Halogen keeps serving, which can slow long
prompts a little until they finish.

#### Converting full-precision weights

Many models are published only in full precision (BF16 `.safetensors`), the format they were
trained in, not as a Halogen `.hgn`. For **Qwen3.8 Flash Next** weights, halOS can convert them
on the machine with [bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn), a third-party tool
(MIT or Apache-2.0) built into the image from a pinned version:

```bash
sudo halogenctl flash convert someone/Some-Flash-BF16 --revision <commit> --as mine
sudo halogenctl flash convert-logs       # follow it (Ctrl-C stops following, not the conversion)
sudo halogenctl flash convert-stop       # stop it; add the name to delete the downloaded weights too
sudo halogenctl flash check mine         # then judge it, before serving it
```

- **Checked before the big download.** It downloads the repository's small files first and
  refuses anything but Qwen3.8 Flash Next, and weights without an MTP head or vision tower: the
  converter uses the repository's own and puts nothing official in their place. Then it checks
  there is room for the weights (about 360 GB) and the result (about 119 GB).
- **Runs on its own.** After you confirm, the download, the conversion and the checks run as a
  service, so closing the terminal doesn't stop them. A stopped download resumes; a stopped
  conversion starts over.
- **Takes long.** The conversion runs on the CPU with low priority, and takes many hours, likely a
  day or more. Parts of it use several cores (`--threads`, by default half the cores, at most 16).
  No full-size conversion has been timed yet, and how much it slows a serving Halogen hasn't been
  measured.
- **Checked twice.** bf16-to-hgn's own `verify` checks every value it wrote against the weights,
  then Halogen's `verify` checks the result, as for `flash pull`. The converter runs in a sandbox
  with no network, unable to see your settings, keys or token, and able to write only its own
  work folder. The result appears under `/srv/models/flash/<name>` only once both checks passed.
- **The weights are deleted** afterwards, to free the 360 GB. `--keep-source` keeps them in
  `/srv/models/flash/.convert/<name>/source`.
- **Judge it before serving it.** A conversion's quality hasn't been measured by anyone: run
  `flash check` and compare its numbers with the official checkpoint's before `flash use`. Halogen
  hasn't served a converted checkpoint yet either, so switch to it while you can watch, and go
  back with `sudo halogenctl flash use official` if it doesn't start.

Things to know:

- **Quality is yours to judge.** `verify` proves the file is well formed, not that its answers
  are good. `flash check` measures it against the official checkpoint with Halogen's
  [`ppl`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/checkpoint-tools.md#how-does-it-compare-to-the-shipped-checkpoint)
  on the public wikitext-2 test text, the comparison Halogen's docs use:
  - **perplexity**: how surprised the model is by the text; lower is better, and close to the
    official one is what a good conversion looks like.
  - **same next token**: how often both checkpoints would write the same word.
  - **KL median**: how far apart their predictions are. A few hundredths is the normal
    difference between two quantizations of the same model; much more means it answers
    differently in places, which is expected of a fine-tune and a warning for a plain conversion.

  It needs the GPU, so Halogen stops while it runs (on the test machine about 15 minutes, and about
  25 the first time on a Halogen version) and starts again afterwards, also if the check fails, is interrupted or
  your SSH connection drops; if you had stopped Halogen yourself, it stays stopped. The text
  (1.3 MB) is downloaded once, before Halogen stops, and checked against its known hash. The result is kept, and `flash list`
  shows it; the full output, with the five places the two disagree most, is in
  `/srv/models/flash/<name>/check.json`. It measures one kind of text: still try your own
  prompts.
- **Halogen may refuse it at start,** for example if its chat template's thinking control
  doesn't work ([`HALOGEN_TEMPLATE_UNCHECKED`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md))
  or it needs more memory than is free. `sudo halogenctl status` and the selftest then say so,
  and `sudo halogenctl flash use official` brings the official model back.
- **The selftest and `flash list` show what Halogen serves.** If your choice is missing or
  failed a check, Halogen quietly serves the official checkpoint so it still starts; both then
  say so, and why.
- **Images.** With `HALOGEN_VISION_TOWER=1`, images work only if the checkpoint's repository
  has a vision tower (`qwen38-flash-next-vision.hgn`). Without one, images stay off and
  `halogenctl config` says why.
- **Not yet:** GGUF repositories (Halogen can convert them, but `flash pull` doesn't do that
  yet).
- **Where things live.** Checkpoints live in `/srv/models/flash/<name>/`. The choice is
  `/srv/configs/flash-checkpoint`, which only `halogenctl flash use` writes, and
  `HALOGEN_CHECKPOINT` can't be set in `halogen.env`.

## 8. Optional: unlock LUKS with the TPM

If you chose LUKS, you can avoid typing the passphrase at each boot:

```bash
sudo halogen-enroll-tpm
sudo systemctl reboot
```

Keep the passphrase as your recovery key. TPM unlock uses PCR 7, which records the Secure Boot
state. OS updates and rollbacks don't change it. Turning Secure Boot off or on, changing its
keys, clearing the TPM, and some BIOS or Secure Boot revocation-list updates do. After one of
those, boot asks for the passphrase. Enter it, then run `halogen-enroll-tpm` again. It replaces
the old TPM binding rather than adding another. The CI install
test enrolls the TPM and reboots without a passphrase, but this hasn't been confirmed on
hardware yet. If the next boot still asks for the passphrase, report it.

### What TPM unlock protects, and what it doesn't

With the TPM, the machine unlocks its own disk whenever it boots through the normal, signed
boot chain. That protects a **disk taken out of the machine**: elsewhere it is unreadable
without the passphrase. It doesn't protect the **machine taken whole**, or someone with time at
its keyboard: they could boot the halOS installer USB (or another Fedora USB stick), whose root
shell can ask the same TPM to unlock the disk, or edit the boot menu's kernel line to get a shell. With the passphrase at every
boot instead, both are protected, at the cost of typing it.

If the machine itself could be taken or tampered with, make those two ways in harder:

1. **In the BIOS:** set an administrator (setup) password, and allow booting only from the
   internal disk: turn off USB boot and network (PXE) boot, and check that an external drive on
   a USB4 port can't boot either. To reinstall later, enter the password and turn USB boot back on.
2. **A boot menu password,** so the kernel line can't be edited:

   ```bash
   sudo grub2-setpassword
   ```

   Choose a password you will keep, using only letters, digits and the symbols of a US keyboard:
   no spaces, backslashes, `*` or `?`, which the command can save differently from what you
   type. It is asked for only when someone edits a boot entry or opens the GRUB command line.
   Check it once at the machine's own screen: reboot, and the machine should start by itself
   with no password. The menu shows only briefly, so press an arrow key as soon as it appears,
   then `e`: that should ask for the password. This hasn't been tested on halOS hardware yet. If booting itself starts asking for the
   password, remove it with `sudo rm /boot/grub2/user.cfg`.

These make taking the disk's key harder, not impossible: the boot files on the disk aren't
encrypted, so someone who can open the case can change them and put the disk back. Only typing
the passphrase at every boot keeps a stolen machine locked, and even that doesn't protect a
machine someone tampered with before you typed it.

### Unlock over SSH at boot

When the disk waits for its passphrase (the TPM couldn't unlock it after a BIOS update, or you
didn't set the TPM up), you can type the passphrase from another computer instead of at the
machine's keyboard. Turn it on once with the public keys of your GitHub, GitLab or Codeberg
account, or with a key you give:

```bash
sudo halosctl ssh-unlock on --github <your-user-name>
```

`--gitlab`, `--codeberg` and `--key 'ssh-ed25519 AAAA... you@computer'` work the same way, and can
be combined. Without any of them it asks. `sudo halosctl setup` offers it too. It shows each key
before using it, and replaces any keys set before. `sudo halosctl ssh-unlock` shows what is set
up, and `sudo halosctl ssh-unlock off` turns it off.

`halosctl ssh-unlock` then prints two things for the computer you unlock from. Add both once:

- an entry for `~/.ssh/config`. Set its `HostName` to how you reach the machine (its name or
  address):

  ```
  Host freyja-unlock
      HostName freyja
      User root
      HostKeyAlias freyja-unlock
  ```

- a `known_hosts line` for `~/.ssh/known_hosts`, starting with `freyja-unlock`.

The server that answers before the disk is unlocked has its own host key, not the system's. Under
its own name, your computer trusts that key only for unlocking, never for the running system,
and `ssh freyja` stays as it was.

Then, whenever the machine waits for the passphrase:

```bash
ssh freyja-unlock
```

Type the passphrase, and the boot goes on. A wrong one is asked again; if you connect while the TPM
is still trying, the prompt appears when it gives up. Only `root` gets in, only with these keys,
and only to the passphrase prompt; the network is wired, with DHCP, and is dropped before the
system starts, so its own network settings apply. The TPM still unlocks the disk by itself when it
can: SSH is the way in when it can't. If ssh ever says this host key changed, don't type the
passphrase: someone else could be asking for it.

`halosctl ssh-unlock` (and `setup`) also keeps the fingerprints of these keys and the early-boot
host key on the encrypted disk. If the copies on the EFI partition ever change without you, the
selftest's `ssh-unlock` line and `sudo halosctl ssh-unlock` warn. Then whoever changed them had
the disk and could have copied the host key, so set it up afresh: `sudo halosctl ssh-unlock off`,
then `on`. That makes a new early-boot host key; replace its `known_hosts` line on your computer.
A machine set up by the installer records them at first-boot setup, or with
`sudo halosctl ssh-unlock record`, which only ever makes a first record.

What it can and can't protect: the keys and that host key are kept on the disk's small
unencrypted EFI partition (only the machine's own disks are read, never a USB stick), because every
halOS machine boots the same image. Your keys there are
only public keys. But someone who can take the disk out can copy the host key, and then pretend
to be this machine to catch the passphrase when you unlock. Every way of unlocking over the network
has this weakness; the TPM section above has ways to make the machine harder to tamper with.

### SSH logins with keys only

Once your account logs in over SSH with a key, passwords can be turned off for SSH logins, so
nobody on the network can try to guess one:

```bash
sudo halosctl ssh-passwords off
```

It refuses while your account has no key sshd would accept in `~/.ssh/authorized_keys` (add one
from your computer with `ssh-copy-id`), and checks that sshd will really use the setting before
applying it. The machine's own
screen still takes the password. `sudo halosctl ssh-passwords on` allows passwords again.
`sudo halosctl setup` offers it too, defaulting to no.

## If something goes wrong

| Symptom | Check |
|---|---|
| Machine reports far less than 128 GB | Set the UMA frame buffer to its minimum, not Auto, if the BIOS offers it |
| `curl localhost:8731` gets "connection reset" | Releases before alpha.3 only. Use `127.0.0.1` instead of `localhost` |
| `/dev/accel/accel0` is missing | Use the NPU edition, and check the IOMMU and firmware |
| Fabric clock is not held | `systemctl status halogen-fabric-clock` |
| Selftest warns about the power profile | `sudo halosctl power` shows it; `systemctl status halos-platform-profile` says what happened at boot |
| Halogen stays down after a config edit | `sudo halogenctl status`, then check the NPU model names |
| "start of the service was attempted too often" | Halogen crashed 3 times in 15 minutes, its guard against a crash loop. See why with `sudo halogenctl logs`; if the GPU is stuck, reboot. Otherwise `sudo halogenctl restart` tries again. On releases before this fix, first run `sudo systemctl --user -M halogen@ reset-failed halogen.service`, then `sudo halogenctl restart` |
| Halogen stays down after `flash use` | `sudo halogenctl logs` says why; `sudo halogenctl flash use official` goes back |
| Start hangs, or GTT stays in use after a crash | Reboot, as Halogen's troubleshooting guide explains |

For anything else, see Halogen's
[troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md).

Next: [configure the server](README.md#configure).
