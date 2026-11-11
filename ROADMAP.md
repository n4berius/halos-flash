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

On edge, for the next release:
- machines refuse unsigned images (#46, done in #91, hardening in #96);
- unlocking over SSH (#13, done in #93 and #94);
- the tokenizer fix for checkpoints that ship no vocabulary (#88);
- `halogenctl flash convert` (#97), Halogen 0.20.1 (#95);
- the dashboard on port 8790 (#98, #99), running on the test machine.

## Next

1. The dashboard's last hardening: no crash report can hold the API key, only port 8790, and a
   selftest check that its private-networks rule is on (this PR).
2. HTTPS for Halogen's API and the dashboard, chosen at setup: a self-signed certificate to
   start, certificates from Let's Encrypt through DNS-01, or your own.
3. fail2ban for SSH and the Halogen API (#92), once HTTPS is in.
4. Unlock the disk from a tang server on the network (#44).
5. GGUF repositories in `flash pull` (#61).

Later: a first real `flash convert` on the test machine (time and quality), then its GPU (HIP)
build and the Qwen4 models.

## Always

- Each new Halogen release gets a pull request from the daily check. It ships as an alpha once
  its checks pass.
- A soak test on the test machine before every promotion.
