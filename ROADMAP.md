# Roadmap

This page shows where halOS goes next, and in which order. The
[open issues](https://github.com/n4berius/halos-flash/issues) hold the details and are the source
of truth. This page gives the order. Items that this page does not list wait until after the
stable release.

How halOS uses each release channel:

| Channel | Used for |
|---|---|
| edge | every change, always on the test machine |
| alpha | small milestones |
| rc | major milestones, after the hardware checklist on the test machine |
| stable | promotes a good rc |

## Now: v0.20.0 is stable

`v0.20.0` (2026-11-09) is the first stable release on Halogen 0.20.0. It is a promotion of
`v0.20.0-rc.2`. On the test machine it passed the selftest, the benchmark, `flash check`,
`npu off`/`on`, tab completion, restarts and a `model pull` of OvisOCR3. The test machine was
also installed again with the guided installer. Work done before this release: first-boot setup
and the "API ready" line (#43), the guided installer (#42), a full security audit (#69), the
benchmark (#15), `flash check` (#56), `halosctl npu on|off` (#40) and tab completion (#14).

These items are in `v0.20.1-alpha.1` and `alpha.2` (2026-11-10 and 11), for the next RC:
- machines refuse unsigned images (#46, done in #91, hardening in #96);
- disk unlock over SSH (#13, done in #93 and #94);
- the tokenizer fix for checkpoints that ship no vocabulary (#88);
- `halogenctl flash convert` (#97), Halogen 0.20.1 (#95);
- the dashboard (#98, #99, #101), which runs on the test machine.

On edge: the dashboard on port 8732, next to the API (#103), Caddy in front of both (#104), and
HTTPS with a self-signed certificate or your own (#105).

## Next

1. HTTPS for Halogen's API and the dashboard (#102), with Caddy in front of both. The steps:
   Caddy on HTTP (#104), then HTTPS with a self-signed certificate or your own (#105), then
   Let's Encrypt through DNS-01 (#108), then HTTPS that `halosctl setup` offers on new installs
   (#145). Status: done.
2. Logs (#107): Halogen's request records in `/srv/logs` on their own volume (#113, done). Then
   journal limits, audit logs with auditd, and rotation (#118, in review).
3. fail2ban for SSH and the Halogen API (#92): done (#129, #132).
4. When Fedora ships a fixed podman or crun (crun#2480, podman#30265), remove the crun 1.30.1
   hold (#137). The line "crun in Fedora's base today" in the build log shows when.
5. Try Linux 7.4 on the test machine through `kernel-next` (#142). Run the selftest and bench
   and compare with 7.3, with the NPU and GPU together. A weekly workflow proposes newer plain
   builds (#146). The selftest warns when the test kernel is three weeks old. When Fedora 45
   ships 7.4 itself, end the channel.
6. Unlock the disk from a tang server on the network (#44).
7. Let `flash pull` use GGUF repositories (#61).

Later: a first real `flash convert` on the test machine (time and quality). Then its GPU (HIP)
build and the Qwen4 models.

## Always

- Each new Halogen release gets a pull request from the daily check. When its checks pass, it
  ships as an alpha.
- Before each promotion, a soak test runs on the test machine.
