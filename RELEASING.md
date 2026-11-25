# Releasing

## Channels

A Git tag starts a release. The tag must be on `main`. It must also match `HALOGEN_VERSION` in
`versions.env`.

| Channel | Git tag | Image tag | Meaning | GitHub release |
|---|---|---|---|---|
| Edge | None, every push to `main` | `edge` | Newest build, for tests | None |
| Kernel next | None, every push to `main` | `kernel-next` | Edge with a test kernel (a Linux 7.4 release candidate from Fedora 46) in place of the Fedora 45 kernel | None |
| Alpha | `v0.20.7-2-alpha` | `0.20.7-2-alpha`, `alpha` | Builds and installs in a VM. Not proven on hardware | Pre-release |
| RC | `v0.20.7-2-rc` | `0.20.7-2-rc`, `rc` | Passed the hardware checklist on one machine. No known blockers | Pre-release |
| Stable | `v0.20.7-2-stable` | `0.20.7-2-stable`, `0.20.7`, `stable`, `latest` | Recommended | Release |

For the other edition, add `-no-npu` to an image tag, for example `0.20.7-2-rc-no-npu`.

### Release names

A release name has three parts: `<Halogen version>-<halOS number>-<stage>`. For example,
`v0.20.7-2-alpha` is the second halOS release on Halogen 0.20.7, at the alpha stage.

- The Halogen version comes from `HALOGEN_VERSION` in `versions.env`.
- The halOS number counts halOS's own changes on that Halogen version. Each alpha takes the next
  number. An RC and a stable release keep the number of the release that they promote. The number
  starts again at 1 with each new Halogen version.
- The stage is `alpha`, `rc` or `stable`.

The order of releases is: Halogen version, then halOS number, then stage. So `v0.20.7-2-alpha` is
newer than `v0.20.7-1-stable`. Thus you can release a new halOS feature as an alpha after a
stable release on the same Halogen version, and then promote it to RC and stable.

Releases from before November 2026 have the old names (`v0.20.7-alpha.3`, `v0.20.7-rc.1`,
`v0.20.7`, `v0.20.7-r2`). They stay as they are. Each new name is newer than all old names of the
same Halogen version. So the first new release (`v0.20.7-1-alpha`) moves the `alpha` channel past
`v0.20.7`. Machines follow channel tags, so no machine must do anything. An old stable release
has no own exact image tag: its image tag is the plain version (`0.20.7`).

There is no beta step since November 2026: an RC promotes the newest alpha. Old beta releases
stay as they were. The `beta` channel tag moves with every RC and stable release. So a machine
that still follows `beta` gets the same releases as `rc`.

`0.20.7` and the channel tags move. The workflows never rebuild `0.20.7-2-alpha`, `0.20.7-2-stable`
and other exact tags. Each Monday, a workflow rebuilds the newest *published* stable release with Fedora
updates. A stable tag whose release run failed has no release, so the workflow never rebuilds it.

Each channel points to the newest release that is at least that stable. A stable release also
moves `rc`, `beta` and `alpha`. An RC also moves `beta` and `alpha`. A channel does not move when
it already has a newer release. So a machine on `alpha` gets an RC or stable release when that
release is newer than the newest alpha. A channel never moves backwards: if you run an old release
again, it moves no channel. `scripts/channels.sh` calculates this from the git tags, for the
release and for the Monday rebuild.

To pick a channel on a machine, run `sudo halosctl switch alpha|rc|release|edge|kernel-next`.
Then `sudo halosctl upgrade` gets the newest release of that channel.

The workflows build and sign `kernel-next` together with `edge`, from the same commit. It uses the
kernel that `versions.env` pins (`KERNEL_NEXT_*`) in place of the Fedora 45 kernel. These are
exact Fedora packages. The build checks their sha256 and Fedora's signature. It also checks the
kernel's Secure Boot signature against the image's own shim. Releases never use `kernel-next`. It
is for tests of a newer kernel on the test machine. To go back, run `sudo halosctl
switch edge`. `rollback` also goes back, before any upgrade on `kernel-next`.

The kernel-next update workflow runs every Tuesday. When Fedora has a newer plain build, the
workflow opens a pull request. A plain build is the build of a release candidate or a final
release, never a debug snapshot. When you merge the pull request, the channel moves at the next
push to `main`.

## Cut a release

On GitHub, open **Actions > Release > Run workflow**. Keep the branch as `main`. Pick what to
release. Then choose **Run workflow**. You never type a tag: the workflow takes the next number.

| Pick | What it does | Example |
|---|---|---|
| `alpha` | Builds `main` with the next halOS number | `v0.20.7-3-alpha` after `v0.20.7-2-stable` |
| `rc` | Promotes the newest published alpha: it builds the same code again, with the same number | `v0.20.7-3-alpha` becomes `v0.20.7-3-rc` |
| `stable` | Promotes the newest published RC, with the same number | `v0.20.7-3-rc` becomes `v0.20.7-3-stable` |

To build an RC or stable from `main` in place of a promotion, tick **from main**. The release
then takes the next halOS number. Use this for example for an urgent stable fix: `v0.20.7-4-stable`
after `v0.20.7-3-stable`.

A new alpha is always newer than all releases before it, also after a stable release. If a
release would move no channel, the workflow stops at once and tells you why. This can occur, for
example, when you promote an RC that is older than the newest stable release.

The workflow promotes only published releases. So it skips a tag whose run failed. An alpha never
uses that number again. If a promotion fails (for example `v0.20.7-3-rc`), run the same promotion
again: the workflow uses the same tag again, because that tag has no release. It does this only
when the tag is on the same commit. A promotion builds the same code again, so its Fedora packages can be
newer than in the release it came from. Do not use **Draft a new release**, because the workflow
makes the release itself.

You can also push a tag manually from your own computer:

```bash
git checkout main && git pull
git tag v0.20.7-3-alpha
git push origin v0.20.7-3-alpha
```

In the two cases, the workflow does these steps:

- It runs checks and builds the two images.
- It pushes the exact image tags (for example `0.20.7-3-alpha`) before the ISO tests, because the
  tests install them.
- It runs a full VM install of each ISO.
- It moves the channel tags (`alpha`, `beta`, `rc`, `stable`, `latest`) only after the two installs
  pass.
  So no machine upgrades to a release that failed them.
- It makes the GitHub release last.

A stable release also moves the plain version tag (`0.20.7`) with the channel tags, after the
two installs pass. The Monday rebuild and machines pinned to that version follow this tag.

If an alpha fails, fix the problem on `main` and run the workflow again. It takes the next number.
A promotion builds its old code again, so a fix on `main` does not get to it. Cut a new alpha and
promote it, or tick **from main**.

A promotion takes the newest *published* release one step down. Before you promote, look on the
Releases page. Make sure that it is the release you want, for example the alpha that you tested.

## Signatures

The workflows push edge, the releases and the Monday rebuild. They sign every image twice with
[cosign](https://docs.sigstore.dev/cosign/) (`scripts/sign-image.sh`). The job then checks the two
signatures. If a signature is missing, the job fails.

- **Keyless:** GitHub confirms that this repository's `build.yml`, `release.yml` or `refresh.yml`
  made the image. Sigstore's public transparency log records the repository, the workflow and the
  image digest, and nothing else.
- **With halOS's own key:** machines check this signature. Fedora's image checks can't identify
  GitHub's keyless identity, so a key pair does that job. The private key is only in the secrets
  `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD` of the `signing` environment, and in the owner's
  password manager. Only `main` and `v*` tags can use that environment. The public key is
  [`files/etc/pki/containers/halos-flash.pub`](files/etc/pki/containers/halos-flash.pub). Every
  image has it at `/etc/pki/containers/halos-flash.pub`.

**Warning:** Keep a backup of the private key and its password. Machines enforce signatures (#46):
they accept only images signed with the key that they already have.

To change the key, you need a bridge release. Sign it with **both** the old and the new key, and
put the two public keys in it. Machines upgrade to it with the old key. After that, they trust the
new key. If you lose the old key, you cannot make a bridge release. Then you must change the
policy on each machine manually, or reinstall it, to move to a new key.

If the key **leaked**, do not make a bridge release: an attacker can forge a release signed with
that key. Make a new key pair. Replace the two secrets at the same time. Put the new public key
in the image. Before the next upgrade, put the new public key in place on each machine manually:
`sudo cp halos-flash.pub /etc/pki/containers/halos-flash.pub`. Then run `sudo halosctl upgrade`.

To check an image yourself with the key, install cosign, then run:

```bash
cosign verify --key files/etc/pki/containers/halos-flash.pub ghcr.io/n4berius/halos-flash:rc
```

Or keyless:

```bash
cosign verify ghcr.io/n4berius/halos-flash:rc \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/n4berius/halos-flash/\.github/workflows/(build|release|refresh)\.yml@refs/(heads/main|tags/v.+)$'
```

Machines check the key's signature at every update. INSTALL.md, "Signed images", explains this for
owners.

## Move to a new Halogen version

Every morning, the **Halogen update** workflow looks for a newer
[halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server/releases) release.
When it finds one, it opens a pull request with the name "Move to Halogen x.y.z". The pull
request does these things:

- It updates `HALOGEN_VERSION`, `HALOGEN_DIGEST`, `HALOGEN_SOURCE_COMMIT` and the three hashes
  in `versions.env`.
- It makes the option lists again from the new `docs/FLAGS.md`, and names each added or removed
  setting.
- It copies in upstream's release notes.
- It starts the image build and the VM install test on its branch.

It does not change `HALOGEN_WEIGHTS_REVISION`. If the notes say that the Flash checkpoints
changed, change it manually. To ask for a version now, open **Actions > Halogen update > Run
workflow**. You can give a version, for example `0.20.7`. If you close its pull request without a
merge, delete its `halogen-update/x.y.z` branch. Then the workflow can open the pull request again.

Then:

1. Read the notes for host, NPU and setting changes that need work here. Push that work to the
   same branch.
2. When the builds and install tests pass, merge the pull request. Then start again at alpha.

The workflow needs the setting **Settings > Actions > General > Workflow permissions > Allow
GitHub Actions to create and approve pull requests**. Turn it on. The workflow never approves or
merges anything.

To do this manually, clone halogen-flash-server. Then run
`scripts/halogen-update.sh path/to/clone pr-body.md [version]`.

## Branch protection

The rules are in `.github/rulesets/`. To apply them, go to **Settings > Rules > Rulesets**.
Choose **New ruleset > Import a ruleset**. Pick a file. Then choose **Create**. Do this once for
each file.

| File | What it does |
|---|---|
| `protect-main.json` | Changes go through a pull request with passing builds of the two editions. No force-pushes, and nobody can delete `main` |
| `protect-release-tags.json` | Only an admin can move or delete release tags |

In an emergency, the repository owner can still bypass the two rules. The rules require no
approval, because GitHub does not let you approve your own pull request. The ISO install test is
not a required check, because it runs only when some files change. Before you merge a change to
the image or the installer, look at the result of that test.
