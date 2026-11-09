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

## Now: v0.20.0 is stable

`v0.20.0` (2026-11-09) is the first stable release on Halogen 0.20.0, promoted from
`v0.20.0-rc.2`. On the test machine it passed the selftest, the benchmark, `flash check`,
`npu off`/`on`, tab completion, restarts and a `model pull` of OvisOCR3, and was reinstalled with the
guided installer. Done on the way: first-boot setup and the "API ready" line (#43), the guided
installer (#42), a full security audit (#69), the benchmark (#15), `flash check` (#56),
`halosctl npu on|off` (#40) and tab completion (#14).

On edge, for the next release: the tokenizer fix for checkpoints that ship no vocabulary (#88), and
machines refuse unsigned images (#46, phase 2, #91).

## Next

1. Unlock the disk over SSH at boot (#13).
2. Unlock the disk from a tang server on the network (#44).
3. GGUF repositories in `flash pull` (#61).

## Always

- Each new Halogen release gets a pull request from the daily check. It ships as an alpha once
  its checks pass.
- A soak test on the test machine before every promotion.
