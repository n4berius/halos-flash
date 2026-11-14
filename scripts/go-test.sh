#!/bin/bash
# Runs the Go tests of halOS's own Caddy modules (src/caddy) without building an OS image.
# Unlike tests/run.sh it needs the network the first time: Go downloads the pinned modules
# (and, if yours is older, the Go version go.mod names). It never changes go.mod or go.sum.
set -euo pipefail
cd "$(dirname "$0")/../src/caddy"
command -v go > /dev/null || { echo "go isn't installed" >&2; exit 1; }
GOFLAGS=-mod=readonly CGO_ENABLED=0 go test ./...
