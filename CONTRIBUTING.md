# Contributing

1. Branch from `main` and open a pull request. Rules block direct pushes to `main`.
2. Run `tests/run.sh`. If you changed `src/caddy`, also run `scripts/go-test.sh` (needs Go and the network).
3. Keep Halogen unmodified. This project configures and deploys it.
4. Say in the pull request whether you tested on real Strix Halo hardware.

Docs-only pull requests skip the image build. Changes to `Containerfile*`, `files/`,
`variants/`, `installer/` or `scripts/` also run the full ISO install test in CI,
which takes about 40 minutes per edition. A new push cancels older runs on the same pull
request.

Most of this project is AI-written, so review every change as you would a stranger's.
Use the issue forms for bugs, ideas and hardware test reports. Hardware reports are especially
useful, because CI cannot test a real GPU or NPU. See [RELEASING.md](RELEASING.md) to publish
a release.
