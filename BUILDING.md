# Building halOS yourself

You don't need to build anything to use halOS. The ISOs on the
[Releases page](https://github.com/n4berius/halos-flash/releases) and the images on GHCR
come from the same scripts described here, run by GitHub Actions. Build it yourself if you
want to check those builds, change the image, or keep your own copy.

## What you need

- A Linux machine. It doesn't need to be the Strix Halo, and it doesn't need a GPU.
  Fedora is easiest. Ubuntu 24.04 works too, as CI uses it.
- Podman 4.9 or newer, Skopeo, Git and xz. On Fedora:
  ```bash
  sudo dnf install podman skopeo git xz
  ```
- Root access through `sudo`. Building an installer needs root Podman.
- About 40 GB of free disk space, and internet access to quay.io and ghcr.io.
- Some patience: the first build downloads several GB of base images. Later builds reuse
  them.

## 1. Get the source

```bash
git clone https://github.com/n4berius/halos-flash.git
cd halos-flash
```

To build a published release exactly, check out its tag first, for example
`git checkout v0.18.23-alpha.2`.

## 2. Run the checks

```bash
tests/run.sh
```

These checks need no GPU or network. They end with `all checks passed`.

## 3. Build the OS image

The image is what gets installed on the server. Build the edition you want:

```bash
sudo scripts/build.sh                          # with NPU
sudo HALOGEN_VARIANT=no-npu scripts/build.sh   # without NPU
```

It ends with `Built ghcr.io/n4berius/halos-flash:0.19.0 ...`. The image now sits in
root's Podman storage. `versions.env` pins Halogen by digest, so your build contains the same Halogen
container as the official one. The Fedora base is a tag (`fedora-bootc:45`) and its packages come
from Fedora's current repositories, so each build, the weekly rebuild included, picks up Fedora's
latest fixes: two builds of the same commit can differ in those (#121).

## 4. Build the USB installer

The ISO build needs the OS image from step 3 already in root's storage:

```bash
sudo scripts/build-iso.sh                          # with NPU
sudo HALOGEN_VARIANT=no-npu scripts/build-iso.sh   # without NPU
```

The ISO lands under `output/`. Write it to a USB drive as
[INSTALL.md](INSTALL.md#4-write-the-usb-drive) describes. It installs the image you built,
offline, from the ISO itself.

To package it the way releases are, as one file under GitHub's 2 GiB limit:

```bash
sudo chown -R "$USER" output
scripts/package-iso.sh "$(find output -name '*.iso' | head -1)" release halos-flash.iso
```

## Where updates come from

The installer records which image the machine came from, and `bootc upgrade` looks there for
updates. By default that's the official `ghcr.io/n4berius/halos-flash`. So:

- **An unchanged build** behaves exactly like an official install and upgrades from the
  official images.
- **A build you changed** would be replaced by the official image on its next upgrade. To keep
  your changes, give the image your own name and push it to a registry you control:

  ```bash
  export IMAGE_NAME=ghcr.io/<you>/halos-flash
  sudo -E scripts/build.sh
  sudo -E scripts/build-iso.sh
  sudo podman login ghcr.io
  sudo -E podman push "$(scripts/image-ref.sh)"
  ```

  Machines installed from that ISO then upgrade from your registry. If the package is private,
  each machine needs a token in `/etc/ostree/auth.json`.

You can also move a machine that's already installed to your image without reinstalling:

```bash
sudo bootc switch ghcr.io/<you>/halos-flash:0.19.0
sudo systemctl reboot
```

halOS's signature policy covers only `ghcr.io/n4berius/halos-flash`, so your image is taken
without a signature check, and the selftest's `image-signatures` line warns about it. To have
machines check your own key, add a `sigstoreSigned` entry for your image to
`files/etc/containers/policy.json` and a `use-sigstore-attachments` entry to
`files/etc/containers/registries.d/` (as halOS's), and sign with `scripts/sign-image.sh`.

## Where to make changes

| To change | Edit |
|---|---|
| Kernel arguments | `variants/<edition>/usr/lib/bootc/kargs.d/10-halogen.toml` |
| Services, scripts, `halogenctl` | `files/` |
| Packages in the image | `Containerfile` |
| Installer defaults, such as partitioning | `installer/` |
| The Halogen version | `versions.env`, as [RELEASING.md](RELEASING.md) describes |

Settings that Halogen reads at run time belong in `/srv/configs/halogen.env` on the machine,
not in the image. See [Configure](README.md#configure).

## Testing an ISO in a VM

`tests/iso-install.sh` is what CI runs. It installs an ISO into a QEMU VM with Secure Boot and
an emulated TPM, then logs in and checks the result. It needs `qemu-system-x86`, `ovmf`,
`swtpm`, `tesseract-ocr` and `genisoimage`, plus KVM:

```bash
tests/iso-install.sh "$(find output -name '*.iso' | head -1)" "$(scripts/image-ref.sh)" install-test npu
```

The VM has no GPU or NPU, so Halogen itself doesn't start there. Only real hardware can test
that.
