#!/bin/bash
# Checks that need no GPU, registry or network.
set -euo pipefail
cd "$(dirname "$0")/.."
# The release workflow runs these checks with its own build settings in the environment
# (HALOGEN_VARIANT=no-npu, IMAGE_TAG, TAG): the checks must not depend on them. With
# HALOGEN_VARIANT=no-npu, build-base.sh looked for the NPU build's record and failed, which
# stopped the release of v0.20.7-r2 (November 2026).
unset HALOGEN_VARIANT KERNEL_TRACK IMAGE_TAG IMAGE_NAME TAG HALOS_RELEASE HALOS_HELPERS
tests/static.sh
tests/config.sh
tests/release-info.sh
tests/channels.sh
tests/next-tag.sh
tests/needs-build.sh
tests/build-helpers.sh
tests/build-base.sh
tests/first-boot.sh
tests/fstab.sh
tests/prepare.sh
tests/halogenctl.sh
tests/preflight.sh
tests/halogen-update.sh
tests/model-pull.sh
tests/flash.sh
tests/weights-sums.sh
tests/authenticode.sh
tests/kernel-next-update.sh
tests/bench.sh
tests/selftest.sh
tests/login-status.sh
tests/halosctl.sh
tests/dashboard.sh
tests/https.sh
tests/ssh-unlock.sh
tests/tang-unlock.sh
tests/completion.sh
tests/enroll-tpm.sh
tests/setup.sh
tests/guided.sh
echo "all checks passed"
