# halOS

A purpose-built operating system that runs Halogen.

It is an image-based Fedora 45 appliance for one 128 GB AMD Strix Halo machine. It installs
from USB, boots with Secure Boot on, and runs
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) pinned to one
release, with or without its NPU models. The host is already configured, and there is no
desktop after install.

halOS is an independent project, formerly called halogen-bootc. It runs Peonist's
halogen-flash-server ("Halogen") unmodified, and is not made, endorsed or supported by Peonist.
"halogen" is a trademark of Peonist, LLC
([trademark policy](https://github.com/peonist-ai/halogen-flash-server/blob/main/TRADEMARKS.md)).

> **Status:** both editions build, install and boot in a virtual machine with Secure Boot on.
> Neither has run on real hardware, so the GPU, NPU, model download, TPM enrollment and
> Halogen itself are still untested on a Strix Halo.

This is an independent project. It is not made, endorsed or supported by Peonist, LLC.
For problems with this OS, use this repository's issues. Report problems in Halogen itself
to [Halogen](https://github.com/peonist-ai/halogen-flash-server/issues) only if you can
reproduce them on a supported host.

## AI usage disclaimer

The code, tests, CI workflows and documentation in this repository were written entirely by
[Claude](https://claude.ai), Anthropic's AI model, working from direction given by the
repository owner, [n4berius](https://github.com/n4berius). n4berius reviewed and merged the
code. AI-written software can contain mistakes, so read it and test it on your own hardware
before relying on it. This software comes with no warranty, as stated in the
[license](LICENSE).

## How it follows Halogen

This project tracks the official
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) and does not fork
or change it.

- Each image tag names the Halogen release it carries, such as `0.19.0`.
- `versions.env` pins that release, the commit it matches, and hashes for the files taken
  from it. The build then pins the container by digest.
- The container runs unmodified, pulled from Halogen's own registry on first boot.
- The list of allowed options is generated from Halogen's `docs/FLAGS.md`.

New Halogen releases are not picked up automatically. Each one is a reviewed change to
`versions.env`, so this project can lag behind upstream.

## Official documentation

Halogen's own documentation is the reference for what each setting does and how the server
behaves. This README covers only what this OS adds or fixes in place. If they disagree on
how Halogen works, follow Halogen's documentation for your version.

| Topic | Official documentation |
|---|---|
| Every setting | [`docs/FLAGS.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md) |
| Configuration and memory | [`docs/configuration.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md) |
| NPU models and host needs | [`docs/NPU.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md) |
| API | [`docs/api.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/api.md) |
| Host setup | [`docs/host-setup.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/host-setup.md) |
| Troubleshooting | [`docs/troubleshooting.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md) |
| Changes between releases | [`CHANGELOG.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md) |

Those links follow Halogen's latest code, which may be newer than the version pinned here.
For an exact match, view the same file at the commit in `versions.env`.

Base image: Fedora's official `quay.io/fedora/fedora-bootc:45`. There is no separate
image-based Fedora Server edition, so this adds only what the appliance needs.

## Install

See **[INSTALL.md](INSTALL.md)**. In short: write the ISO for your edition to USB, boot it, and
answer the guided installer's few questions (the disk, LUKS or not, root or not, your admin
account). Then run `sudo halosctl setup` and let the first boot download the models.

## What lives where

| Location | Contents | Changes through |
|---|---|---|
| OS image | Kernel arguments, services, firewall, Halogen digest | Rebuild and `bootc upgrade` |
| `/srv/configs` | `halogen.env` (yours), `halogen.env.example` (every option, refreshed each boot), `api-key`, `flash-checkpoint` (which Flash checkpoint is served) | Edit `halogen.env`; `sudo halogenctl flash use` for `flash-checkpoint` |
| `/usr/share/halogen` | Locked settings and the allowed-option list | Rebuild only, read-only |
| `/srv/models` | Flash weights and NPU models, about 125 GB, on their own volume | Fetched on first boot |
| `/srv/models/flash` | Your own Flash checkpoints, about 60 to 110 GB each | `sudo halogenctl flash pull` ([how](INSTALL.md#your-own-flash-checkpoint)) |
| BIOS | UMA frame buffer at its explicit minimum, not Auto; newest firmware | Set by hand |

## Editions

| | With NPU | Without NPU |
|---|---|---|
| Image | `halos-flash:0.19.0` | `halos-flash:0.19.0-no-npu` |
| Serves | Flash and NPU models | Flash only |
| IOMMU | `iommu=pt`, which the NPU needs | `amd_iommu=off`, for Halogen's measured 13-16% more prefill |
| Includes | The fabric clock service | No |
| KV pool | 262,144 positions, leaving room for NPU models | Halogen's default |

`amd_iommu=off` turns off DMA translation machine-wide. That suits a dedicated server,
but it is a real security trade-off. To keep the IOMMU on, change the edition's `kargs.d` file.

## Releases

Releases come in alpha, beta, RC and stable channels, published as git tags and matching
image tags. [RELEASING.md](RELEASING.md) defines them.

| Use | Image tag |
|---|---|
| Recommended | `stable`, or a version such as `0.19.0` |
| Testing a release | `beta`, `rc`, or an exact tag such as `0.19.0-beta.1` |
| Earliest testing | `alpha` |
| Newest `main` build | `edge` |

Add `-no-npu` for the edition without the NPU.

## Build

Images are tagged with the Halogen version they carry, for example
`ghcr.io/n4berius/halos-flash:0.19.0`.

Pushing to `main` publishes the `edge` images, and tags publish releases. Each Monday, the
newest stable release is rebuilt with Fedora updates. Changes to the image or installer also
run the full ISO install test.

To build the image or ISO yourself, follow [BUILDING.md](BUILDING.md). In short:

```bash
tests/run.sh
sudo scripts/build.sh        # the OS image
sudo scripts/build-iso.sh    # the USB installer, under output/
```

`versions.env` pins Halogen by digest, so every build runs the same container until the pin
is changed on purpose.

## Configure

Every option Halogen allows on this system is listed, commented out, in
`/srv/configs/halogen.env`. Uncomment a line, set its value, and apply it:

```bash
sudo nano /srv/configs/halogen.env
sudo halogenctl restart
sudo halogenctl config    # what is in effect, and the locked settings
```

Only listed options reach Halogen. Typos and locked settings are ignored and logged, so they
cannot change the server or stop it. The file is read as plain settings and never run as a
script. Locked values live in `/usr/share/halogen/locked.env`, on the read-only OS, and
upgrades keep your file exactly as it is. To see what a newer Halogen added:

```bash
sudo halogenctl options --new   # options your halogen.env doesn't mention yet, with what they do
sudo halogenctl options         # every option: set, commented, or new
```

`/srv/configs/halogen.env.example` always holds the full list for the release you run, rewritten
at every boot; copy a line from it into `halogen.env`. Each release on GitHub also has the list
for each edition attached (`halos-flash-<version>-<edition>-halogen.env.example`).

See [`docs/FLAGS.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md)
for what each option does and how options interact. Which Flash checkpoint Halogen loads
(`HALOGEN_CHECKPOINT`) isn't set here: `sudo halogenctl flash use` chooses it, from the official
checkpoint and the ones you downloaded and checked.

To change what is allowed or locked, edit `files/usr/share/halogen/locked.env` or `BLOCKED` in
`scripts/gen-options.py`, run that script on the new `docs/FLAGS.md`, and rebuild.

## Operate

`halogenctl`, `halosctl` and `halogen-enroll-tpm` complete with Tab: their commands, options,
channels, and the names of your own checkpoints (those only when you can read `/srv/models`,
since `sudo` completes as you).

```bash
sudo halosctl setup          # first-boot questions: TPM unlock, HF token, settings (again any time)
sudo halogenctl status       # service state
sudo halogenctl fetch-logs   # first-boot download progress
sudo halogenctl logs         # server and fetch logs; add a number for more lines
sudo halogenctl doctor       # BIOS, kernel, NPU, clock and memlock checks
sudo halogenctl restart      # after editing /srv/configs/halogen.env
sudo halogenctl config       # show the settings in effect, and any set twice
sudo halogenctl api-key      # print the API key
sudo halogenctl hf-token     # save a Hugging Face token for faster model downloads
sudo halogenctl selftest     # the hardware checklist; prints nothing private
sudo halogenctl bench        # measure speed (--quick: under a minute); reports in /srv/configs/bench
sudo halogenctl model list   # your own NPU checkpoints (NPU edition)
sudo halogenctl flash list   # the official Flash checkpoint and your own; flash use switches
```

[Your own NPU checkpoints](INSTALL.md#your-own-npu-checkpoints) and [your own Flash
checkpoint](INSTALL.md#your-own-flash-checkpoint) explain `model` and `flash`.

A live dashboard of Halogen's load and health (speed, slots, queue, KV pool, prompt cache, NPU,
30 days of charts) is at `http://<host>:8732`: [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard)
by Quaternion, built in. It has no login and only reads; `sudo halosctl dashboard off` turns it
off ([details](INSTALL.md#the-dashboard)).

The machine's screen shows Halogen's state above the login prompt (downloading, starting, or
`ready` with the address), and the SSH login message shows it too, with the release, channel and
any staged update. The first time Halogen answers after a boot, logged-in users get a notice.

`logs` and `fetch-logs` follow new lines in a terminal until you press Ctrl+C. Piped into
`tail` or `grep`, or saved to a file, they print and stop.

Clients use `http://<host>:8731/v1` with `Authorization: Bearer <api-key>`. The API listens on
IPv4 and IPv6.

## Upgrade and roll back

Automatic updates are off because a reboot stops inference and takes the model reload.
If the GHCR package is private, the machine needs a read-only token in
`/etc/ostree/auth.json` to reach it.

`halosctl` handles the OS, as `halogenctl` handles Halogen. Changes apply at the next reboot,
or at once with `--reboot`, and each one asks first:

```bash
sudo halosctl version            # release, edition, channel, Halogen version, staged update, rollback image
sudo halosctl switch beta        # follow a channel: alpha, beta, rc, release (stable) or edge
sudo halosctl upgrade            # stage the newest release on your channel (--check only looks)
sudo halosctl rollback           # back to the previous image (--to 0.19.0-alpha.1 for an older one)
sudo halosctl history            # every change made with halosctl
sudo halosctl npu off            # the no-NPU edition (faster prefill, IOMMU off); npu on goes back
sudo halosctl power performance  # firmware power profile: low-power, balanced or performance (the default)
```

`power` is the exception: it applies at once and needs no reboot. halOS sets `performance` at every
boot unless you choose another. Some machines ship at `balanced`, which holds the chip to less
power: Halogen's [troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md)
measured its own numbers at about 85 W, and reports one owner's machine at about 70 W at
`balanced` against about 127 W at `performance`. On freyja,
`performance` read prompts about 22% faster. `balanced` or `low-power` run cooler and quieter.

A channel also gets newer releases of the more stable channels, so `beta` gets an RC or stable
release when it is newer than the newest beta. Without a channel, a machine stays on the exact
release it was installed from. `sudo bootc status` shows the same from bootc itself.

Machines from before `halosctl` (`v0.19.0-alpha.1` and older, including those on the old image
name `ghcr.io/n4berius/halogen-flash-bootc`) switch once by hand, then use `halosctl`:
`sudo bootc switch ghcr.io/n4berius/halos-flash:alpha` (or `beta`, `rc`, `stable`; add
`-no-npu` on that edition).

What each release changed is in [CHANGELOG.md](CHANGELOG.md), and what comes next in
[ROADMAP.md](ROADMAP.md). To publish a new version, follow [RELEASING.md](RELEASING.md). NPU models are kept in one
folder, `/srv/models/npu/<model>`, and every file is checked against the new version's record,
so a new version downloads only the NPU files that changed. Rolling back to a version that
keeps one folder too downloads only the files that differ. Rolling back to an image from before
the single folder (the 0.18.23 releases and earlier) downloads all its NPU models again, about
15 GB.

## Choices worth knowing

- **The official Flash checkpoint is always kept.** A [checkpoint of your
  own](INSTALL.md#your-own-flash-checkpoint) sits beside it, so going back never waits for a
  110 GB download. Only a checkpoint that matches its repository's hashes and passes Halogen's
  `verify` can be chosen, and after a Halogen update the next start checks it again with the new
  version.

- **XRT comes with Halogen.** Since 0.19.1 Halogen's image carries AMD's XRT 2.25 with its
  NPU plugin, so halOS installs and mounts none ([Halogen's NPU host
  notes](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#host)). Only
  the NPU driver and firmware come from the OS.
- **The NPU edition keeps the IOMMU on** because the NPU needs it, at the cost of the
  prefill gain the no-NPU edition takes.
- **Root never logs in over SSH,** with a password or a key, even if it was allowed in the
  installer. Log in as your admin user and use `sudo`.
- **Halogen's script and terms are fetched at build time** and checked by hash, so this
  repo redistributes none of them. Halogen's image and weights keep their own licenses.

## Name

Halogen's trademark policy does not allow "halogen" in another machine-learning product or
project name without written permission. This name is provisional until that is settled with
Peonist, LLC, and the project may be renamed.

## License

This project's own files are under the [MIT license](LICENSE). That license does not cover
Halogen, model weights, or the other components in the images. They keep their own terms,
listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). halOS builds in two tools by Quaternion
([Quat3rnion](https://github.com/Quat3rnion)): [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard)
and [bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn), both MIT or Apache-2.0. Thank you. Halogen's
[EULA](https://github.com/peonist-ai/halogen-flash-server/blob/main/LICENSE.md) applies to
Halogen.
