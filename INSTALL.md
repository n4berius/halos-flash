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
  `halosctl` always passes it.

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
6. It shows a summary and asks once more: **"Erase nvme0n1 and install halOS now?"**

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
   passphrase at each boot. The TPM protects a disk taken out of the machine, not the machine
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
5. Halogen starts on port 8731, with its models read-only. It never downloads anything itself.

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
`http://<host>:8731/v1` with the same key.

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

What it can and can't protect: the keys and that host key are kept on the disk's small
unencrypted EFI partition (only the machine's own disks are read, never a USB stick), because every
halOS machine boots the same image. Your keys there are
only public keys. But someone who can take the disk out can copy the host key, and then pretend
to be this machine to catch the passphrase when you unlock. Every way of unlocking over the network
has this weakness; the TPM section above has ways to make the machine harder to tamper with.

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
