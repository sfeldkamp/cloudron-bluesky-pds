#!/bin/bash
# Docker integration test: build the Cloudron image, boot it against a
# named volume, and assert end-to-end behavior that can't be stubbed:
# the PDS process actually starts, @atproto/crypto's did:key encoding
# round-trips correctly, secrets persist across restarts, and the drift
# abort path fires when the hostname changes.
set -euo pipefail

IMAGE="cloudron-bluesky-pds:test"
CONTAINER="cloudron-bluesky-pds-itest"
VOLUME="cloudron-bluesky-pds-itest-data"
HOST_PORT="${INTEGRATION_HOST_PORT:-3333}"
HEALTH_TIMEOUT_S=30

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_envs=(
  -e CLOUDRON_APP_DOMAIN=pds.test
  -e CLOUDRON_MAIL_SMTP_USERNAME=mailuser
  -e CLOUDRON_MAIL_SMTP_PASSWORD=mailpass
  -e CLOUDRON_MAIL_SMTP_SERVER=mail.test
  -e CLOUDRON_MAIL_FROM=noreply@pds.test
)

wait_healthy() {
  local i
  for (( i=0; i<HEALTH_TIMEOUT_S; i++ )); do
    if curl -fs "http://localhost:$HOST_PORT/xrpc/_health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

echo "== integration.sh"

echo "  - building image"
docker build -t "$IMAGE" "$repo_root" >/dev/null

cleanup  # ensure clean slate

echo "  - boot 1: fresh install"
docker run -d --name "$CONTAINER" \
  -v "$VOLUME:/app/data" \
  -p "$HOST_PORT:3000" \
  "${run_envs[@]}" \
  -e CLOUDRON_APP_DOMAIN=pds.test \
  "$IMAGE" >/dev/null

if ! wait_healthy; then
  echo "    [FAIL] PDS did not become healthy within ${HEALTH_TIMEOUT_S}s" >&2
  docker logs "$CONTAINER" | tail -60 >&2
  exit 1
fi
echo "    [PASS] PDS healthy"

echo "  - all 4 secrets written on first boot"
secrets=$(docker exec "$CONTAINER" cat /app/data/.pds-secrets)
for key in PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX PDS_ADMIN_PASSWORD PDS_JWT_SECRET; do
  if ! grep -q "^${key}=" <<<"$secrets"; then
    echo "    [FAIL] $key missing from .pds-secrets" >&2
    exit 1
  fi
done
if ! grep -qE '^PDS_RECOVERY_DID_KEY=did:key:z' <<<"$secrets"; then
  echo "    [FAIL] PDS_RECOVERY_DID_KEY missing or not a did:key:z prefix" >&2
  exit 1
fi
echo "    [PASS] secrets file populated"

echo "  - private key file exists with mode 600"
mode=$(docker exec "$CONTAINER" stat -c '%a' /app/data/.pds-recovery-private-key.hex)
if [[ "$mode" != "600" ]]; then
  echo "    [FAIL] expected mode 600, got $mode" >&2
  exit 1
fi
echo "    [PASS] mode is 600"

echo "  - did:key round-trips through @atproto/crypto"
# Re-derive the did:key from the on-disk private hex and compare to what
# init stored. Catches encoding regressions if @atproto/crypto's API ever
# changes shape.
docker exec "$CONTAINER" node -e '
  const { createRequire } = require("node:module");
  const pdsRequire = createRequire(require.resolve("@atproto/pds"));
  const { Secp256k1Keypair } = pdsRequire("@atproto/crypto");
  const fs = require("fs");
  const priv = fs.readFileSync("/app/data/.pds-recovery-private-key.hex", "utf8").trim();
  const secrets = fs.readFileSync("/app/data/.pds-secrets", "utf8");
  const m = secrets.match(/^PDS_RECOVERY_DID_KEY=(.+)$/m);
  if (!m) { console.error("PDS_RECOVERY_DID_KEY not found"); process.exit(1); }
  const stored = m[1];
  Secp256k1Keypair.import(priv, { exportable: true }).then(kp => {
    if (kp.did() !== stored) {
      console.error("did mismatch: stored=" + stored + " derived=" + kp.did());
      process.exit(1);
    }
  }).catch(e => { console.error(e); process.exit(1); });
'
echo "    [PASS] did:key re-derives from stored private hex"

echo "  - boot warning about private key file present"
if ! docker logs "$CONTAINER" 2>&1 | grep -q "recovery private key is still on disk"; then
  echo "    [FAIL] warning not found in container logs" >&2
  exit 1
fi
echo "    [PASS] warning logged"

echo "  - restart: secrets unchanged"
pre=$(docker exec "$CONTAINER" md5sum /app/data/.pds-secrets | awk '{print $1}')
docker restart "$CONTAINER" >/dev/null
if ! wait_healthy; then
  echo "    [FAIL] PDS did not become healthy after restart" >&2
  docker logs "$CONTAINER" | tail -60 >&2
  exit 1
fi
post=$(docker exec "$CONTAINER" md5sum /app/data/.pds-secrets | awk '{print $1}')
if [[ "$pre" != "$post" ]]; then
  echo "    [FAIL] secrets md5 changed across restart ($pre -> $post)" >&2
  exit 1
fi
echo "    [PASS] secrets identical pre/post restart"

echo "  - private key file removed: no warning on next boot"
docker exec "$CONTAINER" rm /app/data/.pds-recovery-private-key.hex
docker restart "$CONTAINER" >/dev/null
if ! wait_healthy; then
  echo "    [FAIL] PDS did not become healthy after key-removal restart" >&2
  exit 1
fi
# Look only at logs since the most recent start.
started_at=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER")
if docker logs --since "$started_at" "$CONTAINER" 2>&1 | grep -q "recovery private key is still on disk"; then
  echo "    [FAIL] warning printed after private key file was removed" >&2
  exit 1
fi
echo "    [PASS] no warning after file removal"

echo "  - hostname drift: new domain aborts non-zero"
docker rm -f "$CONTAINER" >/dev/null
if docker run --rm --name "${CONTAINER}-drift" \
  -v "$VOLUME:/app/data" \
  -e CLOUDRON_APP_DOMAIN=other.test \
  -e CLOUDRON_MAIL_SMTP_USERNAME=mailuser \
  -e CLOUDRON_MAIL_SMTP_PASSWORD=mailpass \
  -e CLOUDRON_MAIL_SMTP_SERVER=mail.test \
  -e CLOUDRON_MAIL_FROM=noreply@pds.test \
  "$IMAGE" > "${script_dir}/.drift.log" 2>&1; then
  echo "    [FAIL] drift boot should have exited non-zero" >&2
  cat "${script_dir}/.drift.log" >&2
  rm -f "${script_dir}/.drift.log"
  exit 1
fi
if ! grep -q "hostname has changed" "${script_dir}/.drift.log"; then
  echo "    [FAIL] drift boot did not log 'hostname has changed'" >&2
  cat "${script_dir}/.drift.log" >&2
  rm -f "${script_dir}/.drift.log"
  exit 1
fi
rm -f "${script_dir}/.drift.log"
echo "    [PASS] drift aborts non-zero with expected error"

echo
echo "  integration: all checks passed"
