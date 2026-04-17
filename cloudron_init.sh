#!/bin/bash
set -e

# cloudron_init.sh — one-time initialization for the Bluesky PDS on Cloudron.
#
# Invoked by cloudron_start.sh when either the sentinel file at
# ${PDS_DATA_DIRECTORY}/.pds-initialized is missing OR when any required
# secret is missing from ${PDS_DATA_DIRECTORY}/.pds-secrets. The second case
# handles upgrades that introduce a new required secret — init re-runs with
# -z guards so existing secrets are never regenerated, only missing ones are
# filled in.
#
# Outputs (all written into PDS_DATA_DIRECTORY):
#   .pds-secrets                    — shell-sourceable key=value file with all
#                                     PDS secrets the container runs on.
#   .pds-initialized                — sentinel recording PDS_INITIAL_HOSTNAME
#                                     for drift detection (see cloudron_start.sh).
#   .pds-recovery-private-key.hex   — operator-retrievable private half of the
#                                     recovery key. The operator must save and
#                                     delete this file (see the save_recovery_key
#                                     checklist item in CloudronManifest.json).
#
# These values are never supplied externally: if they were, a boot without
# the env var would regenerate them and destroy identity continuity. The
# script writes them; the script owns them.

# Secrets file is 0600 (umask 077 for any file we create below).
umask 077

: "${PDS_DATA_DIRECTORY:?PDS_DATA_DIRECTORY must be set by caller}"
: "${PDS_HOSTNAME:?PDS_HOSTNAME must be set by caller}"

GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"

mkdir -p "${PDS_DATA_DIRECTORY}"
PDS_SECRETS_FILE="${PDS_DATA_DIRECTORY}/.pds-secrets"
touch "${PDS_SECRETS_FILE}"

# Parse any pre-existing secrets without executing the file as shell — it
# lives in the data volume and this script runs as root. Only allowlisted
# keys get assigned.
while IFS= read -r _line || [[ -n "${_line}" ]]; do
  [[ -z "${_line}" || "${_line}" == \#* ]] && continue
  _key="${_line%%=*}"
  _val="${_line#*=}"
  case "${_key}" in
    PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX|PDS_ADMIN_PASSWORD|PDS_JWT_SECRET|PDS_RECOVERY_DID_KEY)
      printf -v "${_key}" '%s' "${_val}"
      ;;
  esac
done < "${PDS_SECRETS_FILE}"
unset _line _key _val

if [[ -z "${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX:-}" ]]; then
  PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(eval "${GENERATE_K256_PRIVATE_KEY_CMD}")
  echo "PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX}" >> "${PDS_SECRETS_FILE}"
fi
if [[ -z "${PDS_ADMIN_PASSWORD:-}" ]]; then
  PDS_ADMIN_PASSWORD=$(eval "${GENERATE_SECURE_SECRET_CMD}")
  echo "PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}" >> "${PDS_SECRETS_FILE}"
fi
if [[ -z "${PDS_JWT_SECRET:-}" ]]; then
  PDS_JWT_SECRET=$(eval "${GENERATE_SECURE_SECRET_CMD}")
  echo "PDS_JWT_SECRET=${PDS_JWT_SECRET}" >> "${PDS_SECRETS_FILE}"
fi

# Recovery key: secp256k1 keypair whose public half (did:key:z…) is registered
# as an additional rotation key on every user's DID document at account
# creation. The private half is written to a separate file for the operator
# to retrieve, save offline, and delete — see the save_recovery_key checklist.
#
# did:key encoding requires base58btc + multicodec logic not available in
# the container's shell toolchain, so we shell out to node and use the
# @atproto/crypto package the PDS already ships with. It's a transitive
# dep of @atproto/pds, so we resolve it via createRequire rooted at the
# pds entrypoint rather than relying on pnpm hoisting.
if [[ -z "${PDS_RECOVERY_DID_KEY:-}" ]]; then
  RECOVERY_OUT=$(cd /app/code && node -e '
    const { createRequire } = require("node:module");
    const pdsRequire = createRequire(require.resolve("@atproto/pds"));
    const { Secp256k1Keypair } = pdsRequire("@atproto/crypto");
    (async () => {
      const kp = await Secp256k1Keypair.create({ exportable: true });
      const priv = Buffer.from(await kp.export()).toString("hex");
      process.stdout.write(kp.did() + "\n" + priv + "\n");
    })().catch(e => { console.error(e); process.exit(1); });
  ')
  PDS_RECOVERY_DID_KEY=$(printf '%s\n' "${RECOVERY_OUT}" | sed -n 1p)
  PDS_RECOVERY_PRIVATE_KEY_HEX=$(printf '%s\n' "${RECOVERY_OUT}" | sed -n 2p)
  echo "PDS_RECOVERY_DID_KEY=${PDS_RECOVERY_DID_KEY}" >> "${PDS_SECRETS_FILE}"
  RECOVERY_PRIVATE_KEY_FILE="${PDS_DATA_DIRECTORY}/.pds-recovery-private-key.hex"
  ( umask 077 && echo "${PDS_RECOVERY_PRIVATE_KEY_HEX}" > "${RECOVERY_PRIVATE_KEY_FILE}" )
fi

# Flush secrets to disk before writing the sentinel, then atomically rename.
# If we crash before the rename, the sentinel is absent and init re-runs.
# The sentinel also records the initial hostname for drift detection on
# subsequent boots (see cloudron_start.sh).
PDS_INIT_SENTINEL="${PDS_DATA_DIRECTORY}/.pds-initialized"
cat > "${PDS_INIT_SENTINEL}.tmp" <<EOF
# PDS init sentinel. Presence of this file indicates cloudron_init.sh has
# run successfully at least once. The recorded hostname lets cloudron_start.sh
# detect drift if the Cloudron app is moved to a different domain (which would
# silently break federated identity resolution for every existing user).
#
# Do NOT edit by hand. To force re-initialization (e.g. after a legitimate
# hostname change), delete this file and restart the app. cloudron_init.sh
# preserves existing secrets via -z guards, so only missing pieces are
# regenerated.
PDS_INITIAL_HOSTNAME=${PDS_HOSTNAME}
EOF
sync
mv "${PDS_INIT_SENTINEL}.tmp" "${PDS_INIT_SENTINEL}"
