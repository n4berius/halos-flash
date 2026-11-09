# Releasing

## Channels

Git tags start a release. Each one must be on `main` and match `HALOGEN_VERSION` in
`versions.env`.

| Channel | Git tag | Image tag | Meaning | GitHub release |
|---|---|---|---|---|
| Edge | None, every push to `main` | `edge` | Newest build, for testing | None |
| Alpha | `v0.18.23-alpha.1` | `0.18.23-alpha.1`, `alpha` | Builds and installs in a VM, not proven on hardware | Pre-release |
| Beta | `v0.18.23-beta.1` | `0.18.23-beta.1`, `beta` | Passed the hardware checklist on one machine | Pre-release |
| RC | `v0.18.23-rc.1` | `0.18.23-rc.1`, `rc` | Passed a soak test, no known blockers | Pre-release |
| Stable | `v0.18.23` | `0.18.23`, `stable`, `latest` | Recommended | Release |
| Stable fix | `v0.18.23-r2` | `0.18.23`, `stable`, `latest` | Fix to this project on the same Halogen version | Release |

Add `-no-npu` to any image tag for the other edition, such as `0.18.23-beta.1-no-npu`.

`0.18.23` and the channel tags move. `0.18.23-alpha.1` and the like are never rebuilt. Each
Monday, the newest stable release is rebuilt with Fedora updates.

Each channel points to the newest release that is at least that stable. A stable release also
moves `rc`, `beta` and `alpha`, an RC also moves `beta` and `alpha`, and a beta also moves
`alpha`, unless that channel already has something newer. So a machine following `beta` gets an
RC or stable release when it is newer than the newest beta. A channel never moves backwards:
running an old release again moves none. `scripts/channels.sh` works this out from the git
tags, for both the release and the Monday rebuild.

Machines pick a channel with `sudo halosctl switch alpha|beta|rc|release|edge`, and
`sudo halosctl upgrade` then fetches its newest release.

## Cut a release

On GitHub, open **Actions > Release > Run workflow**, keep the branch as `main`, pick what to
release and choose **Run workflow**. You never type a tag: the workflow takes the next number.

| Pick | What it does | Example |
|---|---|---|
| `alpha` | Builds `main` as the next alpha | `v0.19.0-alpha.3` after alpha.2 |
| `beta` | Promotes the newest published alpha: the same code, built again | alpha.3 becomes `v0.19.0-beta.1` |
| `rc` | Promotes the newest published beta | `v0.19.0-rc.1` |
| `stable` | Promotes the newest published RC. A second stable of the same version becomes `-r2` | `v0.19.0`, then `v0.19.0-r2` |

Tick **from main** to build a beta, RC or stable from `main` instead of promoting, for example
for a stable fix. Only published releases are promoted, so a tag whose run failed is skipped,
but its number is never used again. A promotion builds the same code again, so Fedora packages
can be newer than in the release it came from. Do not use **Draft a new release**, because the
workflow creates the release itself.

You can still push a tag by hand from your own computer:

```bash
git checkout main && git pull
git tag v0.19.0-alpha.3
git push origin v0.19.0-alpha.3
```

Either way, the workflow runs checks, builds both images, runs a full VM install of each ISO, and
then creates the GitHub release. Nothing is published as a release unless both installs pass, but the images are
pushed before the ISO tests run. If a run fails, fix it on `main` and run it again: it takes the
next number. A promotion builds its old code again, so a fix on `main` doesn't reach it: cut a
new alpha and promote that, or tick **from main**.

A promotion takes the newest *published* release one step down. Check on the Releases page that
it is the one you mean before promoting, for example that the alpha you tested is there.

## Signatures

Every image the workflows push (edge, releases and the Monday rebuild) is signed twice with
[cosign](https://docs.sigstore.dev/cosign/) (`scripts/sign-image.sh`), and the job checks both
right away and fails if either is missing:

- **Keyless:** GitHub vouches that this repository's `build.yml`, `release.yml` or `refresh.yml`
  made it. Sigstore's public transparency log records it: the repository, the workflow and the
  image digest, nothing else.
- **With halOS's own key**, which is what machines will check. Fedora's image checks can't recognise
  GitHub's keyless identity, so a key pair does that job. The private key lives only in the
  secrets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` of the `signing` environment, which only
  `main` and `v*` tags may use (and in the owner's password manager); the public key is [`files/etc/pki/containers/halos-flash.pub`](files/etc/pki/containers/halos-flash.pub),
  in every image at `/etc/pki/containers/halos-flash.pub`.

Keep the private key and its password backed up. Machines enforce signatures (#46): they accept
only images signed with the key they already have, so changing the key needs a bridge release
signed with **both** the old and the new key and carrying both public keys. Machines upgrade to it
with the old key and trust the new one from then on. If the old key is lost, no such bridge can be
made, and each machine needs its policy changed by hand (or a reinstall) to move to a new key.

If the key **leaked**, don't bridge: a release signed with it is exactly what an attacker could
forge. Make a new pair and replace both secrets at once, ship the new public key in the image, and
on each machine put it in place by hand before the next upgrade:
`sudo cp halos-flash.pub /etc/pki/containers/halos-flash.pub`, then `sudo halosctl upgrade`.

To check an image yourself with the key, with cosign installed:

```bash
cosign verify --key files/etc/pki/containers/halos-flash.pub ghcr.io/n4berius/halos-flash:beta
```

Or keyless:

```bash
cosign verify ghcr.io/n4berius/halos-flash:beta \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/n4berius/halos-flash/\.github/workflows/(build|release|refresh)\.yml@refs/(heads/main|tags/v.+)$'
```

Machines check the key's signature on every update; INSTALL.md, "Signed images", explains it for
owners.

## Move to a new Halogen version

Every morning, the **Halogen update** workflow looks for a newer
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server/releases) release.
When it finds one, it opens a pull request named "Move to Halogen x.y.z" that:

- updates `HALOGEN_VERSION`, `HALOGEN_DIGEST`, `HALOGEN_SOURCE_COMMIT` and the three hashes
  in `versions.env`,
- regenerates the option lists from the new `docs/FLAGS.md` and names any added or removed
  settings,
- copies in upstream's release notes, and
- starts the image build and the VM install test on its branch.

It leaves `HALOGEN_WEIGHTS_REVISION` alone. Change it by hand if the notes say the Flash
checkpoints changed. To ask for a version now, open **Actions > Halogen update > Run
workflow**, optionally with a version such as `0.19.0`. If you close its pull request without
merging, delete its `halogen-update/x.y.z` branch to let the workflow open it again.

Then:

1. Read the notes for host, NPU and setting changes that need work here, and push any of
   that to the same branch.
2. Merge once the builds and install tests pass, and start again at alpha.

The workflow needs **Settings > Actions > General > Workflow permissions > Allow GitHub
Actions to create and approve pull requests** turned on. It never approves or merges
anything.

To do it by hand instead, clone halogen-flash-server and run
`scripts/halogen-update.sh path/to/clone pr-body.md [version]`.

## Branch protection

The rules live in `.github/rulesets/`. To apply them, go to **Settings > Rules > Rulesets**,
choose **New ruleset > Import a ruleset**, pick a file, then choose **Create**. Do this once
for each file.

| File | What it does |
|---|---|
| `protect-main.json` | Changes go through a pull request with passing builds of both editions. No force-pushes or deleting `main` |
| `protect-release-tags.json` | Release tags cannot be moved or deleted, except by an admin |

The repository owner can still bypass both rules in an emergency. No approval is required,
because GitHub does not let you approve your own pull request. The ISO install test is not
a required check, because it only runs when certain files change, but check it before
merging anything that touches the image or installer.
