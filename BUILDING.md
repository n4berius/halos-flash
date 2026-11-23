# Building halOS yourself

You don't need to build anything to use halOS. GitHub Actions makes the ISOs on the
[Releases page](https://github.com/n4berius/halos-flash/releases) and the images on GHCR with the
same scripts that this file describes. Build halOS yourself if you want to check those builds,
change the image, or keep your own copy.

## What you need

- A Linux machine. It doesn't need to be the Strix Halo, and it doesn't need a GPU.
  Fedora is easiest. Ubuntu 24.04 also works, because CI uses it.
- Podman 4.9 or newer, Skopeo, Git and xz. On Fedora:
  ```bash
  sudo dnf install podman skopeo git xz
  ```
- Root access through `sudo`. To build an installer, you need root Podman.
- Approximately 40 GB of free disk space, and internet access to quay.io and ghcr.io.
- Time: the first build downloads several GB of base images. Later builds use them again.

## 1. Get the source

```bash
git clone https://github.com/n4berius/halos-flash.git
cd halos-flash
```

To build the source of a published release, check out its tag first, for example
`git checkout v0.20.6`. The Fedora parts can be newer than in the release (see step 3).

## 2. Run the checks

```bash
tests/run.sh
```

These checks need no GPU and no network. At the end, they show `all checks passed`.

## 3. Build the OS image

The server gets the image when you install it. Build the edition that you want:

```bash
sudo scripts/build.sh                          # with NPU
sudo HALOGEN_VARIANT=no-npu scripts/build.sh   # without NPU
```

At the end, the build shows `Built ghcr.io/n4berius/halos-flash:0.20.7 ...`. The image is now in
root's Podman storage.

`versions.env` pins Halogen by digest, so your build has the same Halogen container as the
official build. The Fedora base is a tag (`fedora-bootc:45`), not a digest. Its packages come
from Fedora's current repositories. So each build, also the weekly rebuild, gets Fedora's latest
fixes. Two builds of the same commit can be different in the base and in these packages.

Each build records what it used (#121):

- At the start, `build.sh` finds the digest that the tag points to. All build stages use that
  digest. The build log shows it in the line `Fedora base: ...`.
- The image keeps the digest in `/usr/share/halogen/release.env` (`HALOS_BASE_IMAGE`) and in the
  label `io.github.n4berius.halos.base`. It also keeps the list of all its packages
  (`/usr/share/halogen/packages.txt`) and the compilers of the build stages
  (`/usr/share/halogen/toolchains.txt`).
- At the end, `build.sh` writes all of this to `output/build-info-<edition>-<kernel>.txt`. Each
  release attaches the same record for each edition as
  `halos-flash-<tag>-<edition>-build-info.txt`, with the digest of the pushed image on its first
  line. The weekly rebuild keeps it as a workflow artifact. To see what changed between two
  builds, compare their files with `diff`.
- The weekly rebuild uses the code of the newest stable release. Until a stable release has this
  change, its records have only the package list and no base digest.
- The installer from `build-iso.sh` uses the same base digest as the OS image that it carries.

To use the same base as a release, put that release's `HALOS_BASE_IMAGE` value (the form
`quay.io/fedora/fedora-bootc@sha256:...`) in `FEDORA_BOOTC_IMAGE` in `versions.env`. The
packages that the build installs still come from Fedora's current repositories, so the result
is not an exact copy. quay.io can delete an old digest after Fedora replaces it, and then this
build stops when it pulls the base.

## 4. Build the USB installer

The ISO build needs the OS image from step 3 in root's storage:

```bash
sudo scripts/build-iso.sh                          # with NPU
sudo HALOGEN_VARIANT=no-npu scripts/build-iso.sh   # without NPU
```

The build puts the ISO in `output/`. Write it to a USB drive as
[INSTALL.md](INSTALL.md#4-write-the-usb-drive) describes. The ISO installs the image that you
built. It needs no network, because the image is in the ISO.

To package the ISO as the releases do, as one file below GitHub's 2 GiB limit, run:

```bash
sudo chown -R "$USER" output
scripts/package-iso.sh "$(find output -name '*.iso' | head -1)" release halos-flash.iso
```

## Where updates come from

The installer records the image that it installed. `bootc upgrade` looks for updates there. By
default, that is the official `ghcr.io/n4berius/halos-flash`. So:

- **An unchanged build** works the same as an official install. It upgrades from the official
  images.
- **A build that you changed** gets the official image at its next upgrade, and your changes go
  away. To keep your changes, give the image your own name. Then push it to a registry that you
  control:

  ```bash
  export IMAGE_NAME=ghcr.io/<you>/halos-flash
  sudo -E scripts/build.sh
  sudo -E scripts/build-iso.sh
  sudo podman login ghcr.io
  sudo -E podman push "$(scripts/image-ref.sh)"
  ```

  Machines that you install from that ISO then upgrade from your registry. If the package is
  private, each machine needs a token in `/etc/ostree/auth.json`.

You can also move an installed machine to your image without a new installation:

```bash
sudo bootc switch ghcr.io/<you>/halos-flash:0.20.7
sudo systemctl reboot
```

halOS's signature policy covers only `ghcr.io/n4berius/halos-flash`. So the machine accepts your
image without a signature check, and the selftest's `image-signatures` line shows a warning. To
make machines check your own key, do these steps:

1. Add a `sigstoreSigned` entry for your image to `files/etc/containers/policy.json`.
2. Add a `use-sigstore-attachments` entry to `files/etc/containers/registries.d/`, as halOS's
   entry does.
3. Sign with `scripts/sign-image.sh`.

## Where to make changes

| To change | Edit |
|---|---|
| Kernel arguments | `variants/<edition>/usr/lib/bootc/kargs.d/10-halogen.toml` |
| Services, scripts, `halogenctl` | `files/` |
| Packages in the image | `Containerfile` |
| Installer defaults, for example partitions | `installer/` |
| The Halogen version | `versions.env`, as [RELEASING.md](RELEASING.md) describes |

Put the settings that Halogen reads at run time in `/srv/configs/halogen.env` on the machine,
not in the image. See [Configure](README.md#configure).

## Testing an ISO in a VM

CI runs `tests/iso-install.sh`. It installs an ISO into a QEMU VM with Secure Boot and an emulated
TPM. Then it logs in and checks the result. It needs `qemu-system-x86`, `qemu-utils`, `ovmf`,
`swtpm`, `swtpm-tools`, `tesseract-ocr`, `genisoimage`, `squashfs-tools` and KVM:

```bash
tests/iso-install.sh "$(find output -name '*.iso' | head -1)" "$(scripts/image-ref.sh)" install-test npu
```

The VM has no GPU and no NPU, so Halogen itself doesn't start there. Only a test on real hardware
can check that.
