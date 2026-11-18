# Contributing

1. Make a branch from `main` and open a pull request. Rules block direct pushes to `main`.
2. Run `tests/run.sh`. If you changed `src/caddy`, also run `scripts/go-test.sh` (it needs Go
   and the network).
3. Do not change Halogen. This project configures and deploys it.
4. In the pull request, say if you tested on real Strix Halo hardware.

Pull requests that change only docs skip the image build. Changes to `Containerfile*`, `files/`,
`variants/`, `installer/` or `scripts/` also run the full ISO install test in CI. This test takes
about 40 minutes for each edition. A new push cancels older runs on the same pull request.

AI wrote most of this project, so review each change as you review a change from a stranger.
Use the issue forms for bugs, ideas and hardware test reports. Hardware reports are very useful,
because CI cannot test a real GPU or NPU. To publish a release, see [RELEASING.md](RELEASING.md).
