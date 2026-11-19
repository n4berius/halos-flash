# halOS

An operating system made for one job: to run Halogen.

halOS is an image-based Fedora 45 appliance for one 128 GB AMD Strix Halo machine. You install
it from USB. It starts with Secure Boot on and runs
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) at one pinned
release, with or without its NPU models. The host is already configured. There is no desktop
after the installation.

halOS is an independent project, formerly called halogen-bootc. It runs Peonist's
halogen-flash-server ("Halogen") unmodified, and is not made, endorsed or supported by Peonist.
"halogen" is a trademark of Peonist, LLC
([trademark policy](https://github.com/peonist-ai/halogen-flash-server/blob/main/TRADEMARKS.md)).

> **Status:** both editions build, install and boot in a virtual machine with Secure Boot on.
> Since `v0.20.0`, both editions also run on a real Strix Halo machine, with the GPU, the NPU
> and the model download. LUKS with TPM unlock is tested only in the virtual machine. For the
> details, see [Tested hardware](INSTALL.md#tested-hardware).

This is an independent project. It is not made, endorsed or supported by Peonist, LLC.
For problems with this OS, use this repository's issues. Report problems in Halogen itself
to [Halogen](https://github.com/peonist-ai/halogen-flash-server/issues) only if you can
reproduce them on a supported host.

## AI usage disclaimer

The code, tests, CI workflows and documentation in this repository were written entirely by
[Claude](https://claude.ai), Anthropic's AI model, working from direction given by the
repository owner, [n4berius](https://github.com/n4berius). n4berius reviewed and merged the
code. AI-written software can contain mistakes. Read it and test it on your own hardware
before you rely on it. This software comes with no warranty, as stated in the
[license](LICENSE).

## How it follows Halogen

This project follows the official
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server). It does not fork
or change it.

- Each image tag names the Halogen release that it contains, for example `0.20.6`.
- `versions.env` pins that release, the commit that it matches, and the hashes of the files
  that the build takes from it. The build then pins the container by digest.
- The container runs unmodified. The machine pulls it from Halogen's own registry on the
  first boot.
- The list of allowed options comes from Halogen's `docs/FLAGS.md`.

This project does not take new Halogen releases automatically. Each release is a reviewed
change to `versions.env`, so this project can be behind upstream.

## Official documentation

Halogen's own documentation is the reference for each setting and for how the server
operates. This README gives only what this OS adds or changes. If the two disagree about
Halogen, follow Halogen's documentation for your version.

| Topic | Official documentation |
|---|---|
| Every setting | [`docs/FLAGS.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md) |
| Configuration and memory | [`docs/configuration.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/configuration.md) |
| NPU models and host needs | [`docs/NPU.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md) |
| API | [`docs/api.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/api.md) |
| Host setup | [`docs/host-setup.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/host-setup.md) |
| Troubleshooting | [`docs/troubleshooting.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md) |
| Changes between releases | [`CHANGELOG.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md) |

These links show Halogen's newest code, which can be newer than the version that halOS pins.
For an exact match, open the same file at the commit in `versions.env`.

Base image: Fedora's official `quay.io/fedora/fedora-bootc:45`. Fedora has no separate
image-based Server edition, so halOS adds only what the appliance needs.

## Install

See **[INSTALL.md](INSTALL.md)**. In short:

- Write the ISO for your edition to a USB drive.
- Start the machine from the USB drive.
- Answer the guided installer's few questions: the disk, LUKS or not, root or not, and your
   admin account.
- Run `sudo halosctl setup`.
- Let the first boot download the models.

## Documentation

| Guide | What's in it |
|---|---|
| [INSTALL.md](INSTALL.md) | The installation, the first boot, and each feature with the reasons for it |
| [docs/CLI.md](docs/CLI.md) | Every `halosctl`, `halogenctl` and `halogen-enroll-tpm` command |
| [docs/CLIENTS.md](docs/CLIENTS.md) | How to connect apps and coding agents, and how to trust halOS's certificate |
| [CHANGELOG.md](CHANGELOG.md), [ROADMAP.md](ROADMAP.md) | What each release changed, and what comes next |
| [SECURITY.md](SECURITY.md) | How to report a security problem |

## What lives where

| Location | Contents | How to change it |
|---|---|---|
| OS image | Kernel arguments, services, firewall, Halogen digest | Rebuild, then `bootc upgrade` |
| `/srv/configs` | `halogen.env` (yours), `halogen.env.example` (every option, written again at each boot), `api-key`, `flash-checkpoint` (the Flash checkpoint that Halogen serves) | Edit `halogen.env`. For `flash-checkpoint`, use `sudo halogenctl flash use` |
| `/usr/share/halogen` | Locked settings and the list of allowed options | Rebuild only (read-only) |
| `/srv/models` | Flash weights and NPU models, about 130 GB (about 120 GB without the NPU), on their own volume | The first boot downloads them |
| `/srv/logs/halogen` | Halogen's request records, when they are on: only counts, unless you choose text | `sudo halogenctl records` ([how](INSTALL.md#request-records)) |
| `/srv/models/flash` | Your own Flash checkpoints, about 60 to 110 GB each | `sudo halogenctl flash pull` ([how](INSTALL.md#your-own-flash-checkpoint)) |
| BIOS | UMA frame buffer at its explicit minimum, not Auto; the newest firmware | Set it by hand |

## Editions

| | With NPU | Without NPU |
|---|---|---|
| Image | `halos-flash:0.20.6` | `halos-flash:0.20.6-no-npu` |
| Serves | Flash and NPU models | Flash only |
| IOMMU | `iommu=pt`, which the NPU needs | `amd_iommu=off`, for 13-16% more prefill (Halogen's measurement) |
| Includes | The fabric clock service | No |
| KV pool | 262,144 positions, which leaves space for NPU models | Halogen's default |

`amd_iommu=off` turns off DMA translation for the full machine. This is acceptable on a
dedicated server, but it is a real security trade-off. To keep the IOMMU on, change the
edition's `kargs.d` file.

## Releases

Releases come in these channels: alpha, RC and stable. Each release is a git tag and an image tag
of the same name. [RELEASING.md](RELEASING.md) defines the channels.

| Use | Image tag |
|---|---|
| Recommended | `stable`, or a version such as `0.20.6` |
| Test a release | `rc`, or an exact tag such as `0.20.6-rc.1` |
| Earliest tests | `alpha` |
| Newest `main` build | `edge` |
| Newest `main` build with a test kernel (a Linux 7.4 release candidate) | `kernel-next` |

For the edition without the NPU, add `-no-npu`.

## Build

Each image tag names the Halogen version that the image contains, for example
`ghcr.io/n4berius/halos-flash:0.20.6`.

A push to `main` publishes the `edge` images. A tag publishes a release. Each Monday, the
workflow builds the newest stable release again with the Fedora updates. A change to the image
or the installer also starts the full ISO installation test.

To build the image or the ISO yourself, follow [BUILDING.md](BUILDING.md). In short:

```bash
tests/run.sh
sudo scripts/build.sh        # the OS image
sudo scripts/build-iso.sh    # the USB installer, under output/
```

`versions.env` pins Halogen by digest. So every build runs the same container until someone
changes the pin on purpose.

## Configure

`/srv/configs/halogen.env` lists each option that halOS lets Halogen use, as a comment. To use
an option, remove the comment mark, set the value and apply it:

```bash
sudo nano /srv/configs/halogen.env
sudo halogenctl restart
sudo halogenctl config    # what is in effect, and the locked settings
```

Only the listed options get to Halogen. halOS ignores typing errors and locked settings, and
writes them to the log. So they cannot change the server or stop it. halOS reads the file as
plain settings and never runs it as a script. The locked values are in
`/usr/share/halogen/locked.env`, on the read-only OS. Upgrades keep your file exactly as it is.
To see what a newer Halogen added:

```bash
sudo halogenctl options --new   # options your halogen.env doesn't mention yet, with what they do
sudo halogenctl options         # every option: set, commented, or new
```

`/srv/configs/halogen.env.example` always has the full list for the release that you run. halOS
writes it again at each boot. Copy a line from it into `halogen.env`. Each release on GitHub
also has the list for each edition attached (`halos-flash-<version>-<edition>-halogen.env.example`).

For what each option does and how options affect each other, see
[`docs/FLAGS.md`](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/FLAGS.md).
You don't set the Flash checkpoint that Halogen loads (`HALOGEN_CHECKPOINT`) in this file.
`sudo halogenctl flash use` chooses it, from the official checkpoint and the checkpoints that
you downloaded and checked.

To change what is allowed or locked:

- Edit `files/usr/share/halogen/locked.env` or `BLOCKED` in `scripts/gen-options.py`.
- Run that script on the new `docs/FLAGS.md`.
- Build the image again.

## Operate

`halogenctl`, `halosctl` and `halogen-enroll-tpm` complete with Tab. They complete their
commands, options, channels and the names of your own checkpoints. They complete the names
only when you can read `/srv/models`, because `sudo` completes as you.

```bash
sudo halosctl setup          # first-boot questions: TPM unlock, HF token, settings, HTTPS (again any time)
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
checkpoint](INSTALL.md#your-own-flash-checkpoint) tell about `model` and `flash`. The [command
reference](docs/CLI.md) lists all commands. [Connecting apps](docs/CLIENTS.md) tells how to
connect Claude Code, Codex, Pi and other agents to the machine.

A live dashboard of Halogen's load and health is at `http://<host>:8732`. It shows speed, slots,
queue, KV pool, prompt cache, NPU and 30 days of charts. It is
[halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion, built in.
It has no login and only reads. To turn it off, run `sudo halosctl dashboard off`
([details](INSTALL.md#the-dashboard)).

The machine's screen shows Halogen's state above the login prompt: downloading, starting, or
`ready` with the address. The SSH login message also shows it, with the release, the channel and
any staged update. The first time that Halogen answers after a boot, logged-in users get a
notice.

In a terminal, `logs` and `fetch-logs` show new lines until you push Ctrl+C. If you send their
output to `tail`, `grep` or a file, they print and stop.

Clients use `http://<host>:8731/v1`, on IPv4 and IPv6, with `Authorization: Bearer <api-key>`.
After `sudo halosctl https` turns HTTPS on, they use `https://`.
[Caddy](https://caddyserver.com) answers on 8731 and 8732 and sends the requests to Halogen and
the dashboard. Halogen and the dashboard listen only on the machine.

## Upgrade and roll back

Automatic updates are off, because a reboot stops inference and Halogen must load the models
again. If the GHCR package is private, the machine needs a read-only token in
`/etc/ostree/auth.json` to get it.

`halosctl` controls the OS, and `halogenctl` controls Halogen. Changes apply at the next reboot,
or immediately with `--reboot`. Each command asks before it changes something:

```bash
sudo halosctl version            # release, edition, channel, Halogen version, staged update, rollback image
sudo halosctl switch rc          # follow a channel: alpha, rc, release (stable), edge or kernel-next
sudo halosctl upgrade            # stage the newest release on your channel (--check only looks)
sudo halosctl rollback           # back to the previous image (--to 0.20.5 for an older one)
sudo halosctl history            # every change made with halosctl
sudo halosctl npu off            # the no-NPU edition (faster prefill, IOMMU off); npu on goes back
sudo halosctl power performance  # firmware power profile: low-power, balanced or performance (the default)
```

`power` is different: it applies immediately and needs no reboot. halOS sets `performance` at
each boot, unless you choose a different profile. Some machines come at `balanced`, which gives
the chip less power. Halogen's
[troubleshooting guide](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/troubleshooting.md)
measured its own numbers at about 85 W. It reports one owner's machine at about 70 W at
`balanced` against about 127 W at `performance`. On freyja, `performance` read prompts about 22%
faster. `balanced` and `low-power` make the machine cooler and quieter.

A channel also gets newer releases of the more stable channels. For example, `alpha` gets an RC
or stable release when it is newer than the newest alpha. There are no more beta releases. A
machine that follows `beta` gets the same releases as `rc`. A machine without a channel stays on
the exact release that it was installed from. `sudo bootc status` shows the same data from bootc
itself.

Machines from before `halosctl` (`v0.19.0-alpha.1` and older, also those on the old image name
`ghcr.io/n4berius/halogen-flash-bootc`) must switch one time by hand. Then they use `halosctl`.
Run `sudo bootc switch ghcr.io/n4berius/halos-flash:alpha` (or `rc`, `stable`; on the no-NPU
edition, add `-no-npu`).

[CHANGELOG.md](CHANGELOG.md) tells what each release changed, and [ROADMAP.md](ROADMAP.md) what
comes next. To publish a new version, follow [RELEASING.md](RELEASING.md).

halOS keeps the NPU models in one folder, `/srv/models/npu/<model>`. It checks each file against
the record of the new version, so a new version downloads only the NPU files that changed. A
rollback to a version that also uses one folder downloads only the files that are different. A
rollback to an image from before the single folder (the 0.18.23 releases and earlier) downloads
all its NPU models again, about 15 GB.

## Choices worth knowing

- **halOS always keeps the official Flash checkpoint.** A [checkpoint of your
  own](INSTALL.md#your-own-flash-checkpoint) is next to it, so a return to the official one
  never waits for a 110 GB download. You can choose a checkpoint only if it matches the hashes
  of its repository and passes Halogen's `verify`. After a Halogen update, the next start checks
  it again with the new version.

- **XRT comes with Halogen.** Since 0.19.1, Halogen's image contains AMD's XRT (2.27 since
  Halogen 0.20.5) with its NPU plugin, so halOS installs and mounts no XRT ([Halogen's NPU host
  notes](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#host)). Only
  the NPU driver and firmware come from the OS.
- **The NPU edition keeps the IOMMU on,** because the NPU needs it. The cost is the prefill gain
  that the no-NPU edition gets.
- **Root never logs in over SSH,** with a password or a key, even if the installer allowed it.
  Log in as your admin user and use `sudo`.
- **The build downloads Halogen's script and terms** and checks them by hash, so this
  repository redistributes none of them. Halogen's image and weights keep their own licenses.

## Name

Halogen's trademark policy does not allow "halogen" in another machine-learning product or
project name without written permission. So the project changed its name from halogen-bootc to
halOS. The policy lets halOS say that it runs Halogen.

## License

This project's own files are under the [MIT license](LICENSE). That license does not cover
Halogen, model weights, or the other components in the images. They keep their own terms,
listed in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md). halOS builds in two tools by
Quaternion ([Quat3rnion](https://github.com/Quat3rnion)):
[halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) and
[bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn), both MIT or Apache-2.0. Thank you.
Halogen's [EULA](https://github.com/peonist-ai/halogen-flash-server/blob/main/LICENSE.md)
applies to Halogen.
