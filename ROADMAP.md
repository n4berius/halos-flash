# Roadmap

Where halOS is heading, and in what order. The [open issues](https://github.com/n4berius/halos-flash/issues)
hold the details and are the source of truth; this page is the order. Anything not listed here
waits until after the stable release.

How releases are used:

| Channel | Used for |
|---|---|
| edge | every change, always on the test machine |
| alpha | small milestones |
| beta | major milestones, after the hardware checklist |
| rc and stable | about quarterly, after a soak test |

## Now: test alpha.6, then Halogen 0.20 on edge

`v0.19.1-alpha.6` carries everything from #66 to #77 on Halogen 0.19.1. Halogen 0.20.0 (#78) is on
edge and goes out in the next alpha once the test machine has run it. Before beta, the test
machine checks:
- normal use on the official checkpoint and on a custom one
- the selftest clean on both
- the login screen and SSH message show Halogen's state, and say "ready" once it answers
- one rollback and back
- one real install with the guided installer, from the alpha's ISO

## Before the release candidate

In this order. Each ships as an alpha, then is promoted to beta once tested.

1. **Machines refuse unsigned images** (#46, phase 2). Images are signed with halOS's own key
   since #65. Next, machines check that signature, once every channel points to a key-signed
   image. Until then it protects nothing.
2. **First-boot setup and an "API ready" line on the login screen** (#43). Done: the login
   status (#63), then `halosctl setup` (#64).
3. **Guided installer** (#42). It picks the disk, asks only for encryption, root and the admin user,
   and uses fixed `halos-*` volume names. Done; needs one real install before beta.
4. **A full security audit** of the whole image, not just of single changes. Done (#69), and its
   follow-up hardening (#76, #77).

## After the release candidate, before stable

**Stable waits for Halogen 0.20.** halOS moved to Halogen 0.20.0 in #78: no setting, host need or
container change was needed, and OvisOCR3 document parsing works through `model pull` (INSTALL.md).
What's left is running it on the test machine. Then stable.

Built, to check on the test machine:

- **Benchmark command** (#15). A fixed-length run with Halogen's `ignore_eos` (new in
  [0.19.1](https://github.com/peonist-ai/halogen-flash-server/blob/main/CHANGELOG.md)), to compare
  releases and checkpoints fairly. A first version is done (`halogenctl bench`, Halogen's `sweep`
  against the running server); the fixed-length `ignore_eos` run, NPU models and several
  requests at once can follow.
- **`halogenctl flash check`** (#56). Compare a custom checkpoint's quality with the official
  one's, on request. Done; to try on the test machine.
- **`halosctl npu on|off`** (#40). Switch between the two editions. Done; to try on the test machine.
- **Tab completion** (#14). Done for bash; to try on the test machine.

## Later, after stable

- Unlock the disk over SSH at boot (#13).
- Unlock the disk from a tang server on the network (#44).
- GGUF repositories in `flash pull` (#61).

## Always

- Each new Halogen release gets a pull request from the daily check. It ships as an alpha once
  its checks pass.
- A soak test on the test machine before every promotion.
