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
| stable | the recommended release: it promotes a good rc |

## Now: v0.20.6 is stable

`v0.20.6` (2026-11-18) is the stable release on Halogen 0.20.6. It passed the hardware checklist on
the test machine (#147). It contains all the work since `v0.20.0` (2026-11-09). `v0.20.0` was the
first stable release, with first-boot setup (#43), the guided installer (#42), a full security audit
(#69), the benchmark (#15), `flash check` (#56), `halosctl npu on|off` (#40) and tab completion
(#14). Since then:

- Halogen 0.20.1 to 0.20.6 (#95, #100, #111, #140, #143), and the 4-bit `:qad` form of LFM3 on the
  NPU (#144).
- Machines refuse unsigned images (#46, done in #91, hardening in #96).
- Disk unlock over SSH (#13, done in #93 and #94).
- `halogenctl flash convert` (#97) and the tokenizer fix for checkpoints that have no
  vocabulary (#88).
- The dashboard on port 8732, next to the API (#98, #99, #101, #103).
- HTTPS for the API and the dashboard (#102), with Caddy in front of both (#104): a self-signed
  certificate or your own (#105), Let's Encrypt through DNS-01 (#108), and the offer in
  `halosctl setup` on new installs (#145).
- Logs (#107): request records in `/srv/logs` on their own volume (#113), and journal limits,
  audit logs with auditd, and rotation (#118).
- fail2ban for SSH and the Halogen API (#92, done in #129, #132 and #134).
- The crun 1.30.1 hold, which keeps Halogen's container able to start (#137).
- The `kernel-next` channel with a Linux 7.4 test kernel (#142, #146). It passed its checks on the
  test machine (#147), which runs it.

`v0.20.7-alpha.1` (2026-11-18) has Halogen 0.20.7 (#149) and safer releases: the channel tags
move only after the install tests pass (#150).

On edge: fixed sizes for the boot partitions of new installs (#151), and the documentation in
Simplified Technical English (#152).

## Next

1. Test `v0.20.7-alpha.1` on the test machine: the download of the new draft head, the
   concurrency mode, and a benchmark against 0.20.6. Then promote it to rc and stable.
2. When Fedora ships a fixed podman or crun (crun#2480, podman#30265), remove the crun 1.30.1
   hold (#137). The line "crun in Fedora's base today" in the build log shows when.
3. Keep `kernel-next` on the newest plain Linux 7.4 build: a weekly workflow proposes each one
   (#146). When Fedora 45 ships 7.4 itself, end the channel.
4. Unlock the disk from a tang server on the network (#44).
5. Let `flash pull` use GGUF repositories (#61).

Also open, not yet in order: a record
of the exact Fedora build inputs (#121), and faster image builds that reuse the Caddy layers
(#122).

Later: a first real `flash convert` on the test machine (time and quality). Then its GPU (HIP)
build and the Qwen4 models.

## Always

- Each new Halogen release gets a pull request from the daily check. When its checks pass, it
  ships as an alpha.
- Before each promotion, a soak test runs on the test machine.
