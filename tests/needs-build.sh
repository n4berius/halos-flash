#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
printf 'README.md\nINSTALL.md\n.github/ISSUE_TEMPLATE/bug.yml\nLICENSE\n' | { if scripts/needs-build.sh; then echo "docs triggered a build" >&2; exit 1; fi; }
printf 'tests/halosctl.sh\ntests/vm-login.py\n.claude/skills/ste100/check.py\n' | { if scripts/needs-build.sh; then echo "tests triggered a build" >&2; exit 1; fi; }
printf 'tests/halosctl.sh\nsrc/authenticode-check.py\n' | scripts/needs-build.sh
printf 'README.md\nContainerfile\n' | scripts/needs-build.sh
printf 'files/usr/bin/halogenctl\n' | scripts/needs-build.sh
printf '.github/workflows/build.yml\n' | scripts/needs-build.sh
echo "ok: docs, tests and Claude's files skip the build, and everything else runs it"
