# halOS: Third-Party Notices

The MIT license in [`LICENSE`](LICENSE) covers only the files written for this repository.
It does not cover the components below, which keep their own licenses. Where a component's
license conflicts with this project's, that component's license governs it.

Versions below are for this repository's current pins in [`versions.env`](versions.env).
Fedora packages change with each rebuild. For the exact list in a built image, run
`rpm -qa --qf '%{NAME} %{VERSION} %{LICENSE}\n'`.

## Halogen

| Component | Version | License | How it is used |
|---|---|---|---|
| [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server) image and engine | 0.20.2, commit `2e05e1f` | [halogen EULA](https://github.com/peonist-ai/halogen-flash-server/blob/main/LICENSE.md) | Unmodified. Pulled from `ghcr.io/peonist-ai/halogen-flash-server` by digest on first boot, and not included in the OS image or ISO |
| `halogen-fabric-clock` | Same commit | halogen EULA | Unmodified copy in the NPU edition's OS image, checked by SHA-256 |
| ROCm, Python and NPU components inside the Halogen image, including AMD XRT (since 0.19.1) | See upstream | [Halogen's notices](https://github.com/peonist-ai/halogen-flash-server/blob/main/THIRD-PARTY-NOTICES.md) | Governed by Halogen's own notices |

Both editions include Halogen's `LICENSE.md` and `THIRD-PARTY-NOTICES.md` at
`/usr/share/licenses/halogen/`. This project is not made, endorsed or supported by Peonist,
LLC. "halogen" and "Peonist" are trademarks of Peonist, LLC. See their
[trademark policy](https://github.com/peonist-ai/halogen-flash-server/blob/main/TRADEMARKS.md).

## Model weights

No weights are included in this repository, the OS image or the ISO. Each machine downloads
them from Hugging Face on first boot, and they are licensed separately by their authors.

| Models | Source | License |
|---|---|---|
| Qwen3.8-Flash-Next in Halogen's format | [peonist-ai/halogen-qwen3.8-flash-next](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next) | Marked Apache-2.0, and its card says the original model's license governs. Check the base model's terms |
| NPU models | [Listed in Halogen's docs](https://github.com/peonist-ai/halogen-flash-server/blob/main/docs/NPU.md#where-the-files-are) | Differs by model. See each model's card, and `devices/NOTICE.md` where present |

Check these terms yourself before commercial use, especially for models you add.

## In the OS image

| Component | Source | License | Notes |
|---|---|---|---|
| Fedora Linux 45 `fedora-bootc` base and RPM packages | [Fedora](https://fedoraproject.org/) | Various, per package | Texts are under `/usr/share/licenses` and `/usr/share/doc` |
| `linux-firmware`, `amd-gpu-firmware` | Fedora | Various, including redistributable binary firmware | Terms are in the packages |

## In the installer ISO

The ISO's live environment adds these Fedora packages to the base above. They run only from
the USB drive and are not installed on the machine.

| Component | License |
|---|---|
| [Anaconda](https://github.com/rhinstaller/anaconda) | GPL-2.0-or-later |
| GRUB 2 and shim | Per package |
| Dracut, Plymouth and other live environment packages | Per package |

Both the OS image and the ISO are aggregates of separately licensed programs. Source for
Fedora packages is available from [Fedora](https://src.fedoraproject.org/).

## Converter in the OS image

| Component | License |
|---|---|
| [bf16-to-hgn](https://github.com/Quat3rnion/bf16-to-hgn) by Quaternion (`/usr/libexec/halogen/bf16-to-hgn`, built unmodified from the commit in `versions.env`) | MIT or Apache-2.0; its vendored trellis encoder (`native/`) Apache-2.0 only. Texts in `/usr/share/licenses/bf16-to-hgn/` |

## Dashboard in the OS image

halOS's dashboard (`halos-dashboard.service`, port 8732) is
[halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) by Quaternion, built unmodified
from the commit in `versions.env`. Thank you to its author. Its web page is built into the program,
so the program also carries the parts below.

| Component | License |
|---|---|
| [halogen-dashboard](https://github.com/Quat3rnion/halogen-dashboard) (`/usr/libexec/halogen/halogen-dashboard`) | MIT or Apache-2.0. Texts in `/usr/share/licenses/halogen-dashboard/` |
| [IBM Plex Sans](https://github.com/IBM/plex) (variable font, via [Fontsource](https://fontsource.org/)), in the web page | SIL Open Font License 1.1. Text in `/usr/share/licenses/halogen-dashboard/web/` |
| [uPlot](https://github.com/leeoniya/uPlot) (charts) and [Svelte](https://svelte.dev/) with the two small parts its runtime uses ([clsx](https://github.com/lukeed/clsx), [esm-env](https://github.com/benmccann/esm-env)), in the web page | MIT. Texts in `/usr/share/licenses/halogen-dashboard/web/` |
| The Rust crates it is built from (axum, tokio, rusqlite with SQLite, reqwest, rustls and others) | Each crate's own license, mostly MIT or Apache-2.0 (SQLite is public domain). The list with versions and licenses is `/usr/share/licenses/halogen-dashboard/crates.txt` |

## Web server in the OS image

halOS's front door (`halos-proxy.service`, ports 8731 and 8732) is [Caddy](https://caddyserver.com),
built unmodified with its standard modules and four DNS providers, from the versions pinned in
`src/caddy/go.mod` and `src/caddy/go.sum`. Thank you to its authors.

| Component | License |
|---|---|
| [Caddy](https://github.com/caddyserver/caddy) (`/usr/libexec/halogen/caddy`) | Apache-2.0 |
| DNS provider plugins [caddy-dns/cloudflare](https://github.com/caddy-dns/cloudflare) and [caddy-dns/porkbun](https://github.com/caddy-dns/porkbun) | Apache-2.0 and MIT |
| DNS libraries [libdns/duckdns](https://github.com/libdns/duckdns) and [libdns/namecheap](https://github.com/libdns/namecheap), registered with Caddy by halOS's own modules (`src/caddy/dnsproviders`) because the caddy-dns plugins for them carry no licence | MIT |
| The Go modules it is built from (certmagic, quic-go, the Go standard library and others) | Each module's own license. The list with versions is `/usr/share/licenses/halos-caddy/modules.txt`, and each module's license file is under `/usr/share/licenses/halos-caddy/modules/` |

## Build tools

These build the images and are not included in them.

| Tool | License |
|---|---|
| [image-builder](https://github.com/osbuild/image-builder) and osbuild | Apache-2.0 |
| [Podman](https://github.com/containers/podman) | Apache-2.0 |
| [bootc](https://github.com/bootc-dev/bootc) (also in the OS image) | Apache-2.0 or MIT |

This list is provided for information and is not legal advice.
