#!/bin/bash
# Checks that need no GPU, registry or network.
set -euo pipefail
cd "$(dirname "$0")/.."
tests/static.sh
tests/config.sh
tests/release-info.sh
tests/channels.sh
tests/next-tag.sh
tests/needs-build.sh
tests/first-boot.sh
tests/fstab.sh
tests/prepare.sh
tests/halogenctl.sh
tests/preflight.sh
tests/halogen-update.sh
tests/model-pull.sh
tests/flash.sh
tests/bench.sh
tests/selftest.sh
tests/login-status.sh
tests/halosctl.sh
tests/dashboard.sh
tests/https.sh
tests/ssh-unlock.sh
tests/completion.sh
tests/setup.sh
tests/guided.sh
echo "all checks passed"
