#!/bin/bash
# Driver for all test layers. Fails fast.
#
# Layer 1 (unit): runs cloudron_init.sh and cloudron_start.sh against
# tempdirs with stubbed node / stubbed init. No network or docker.
#
# Layer 2 (integration): builds the Cloudron image and runs end-to-end
# container tests. Hard-fails if docker is not on PATH.
set -euo pipefail

cd "$(dirname "$0")"

echo "=========================================="
echo " Layer 1: unit tests"
echo "=========================================="
./test_init.sh
./test_start_gate.sh

echo
echo "=========================================="
echo " Layer 2: docker integration"
echo "=========================================="
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not on PATH; integration tests cannot run." >&2
  exit 1
fi
./integration.sh

echo
echo "All test layers passed."
