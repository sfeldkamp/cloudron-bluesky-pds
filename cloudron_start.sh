#!/bin/bash
set -e

# cloudron_start.sh — every-boot startup for the Bluesky PDS on Cloudron.
# Invoked by the Dockerfile CMD.
#
# Boot flow:
#   1. Compute PDS_DATA_DIRECTORY (handle the /pds → /app/data Cloudron quirk).
#   2. Parse .pds-secrets if present (allowlisted KEY=VALUE lines — we never
#      `source` files from the data volume), then run cloudron_init.sh if
#      any required secret is missing or the sentinel is absent.
#   3. Drift check: compare current PDS_HOSTNAME (from CLOUDRON_APP_DOMAIN)
#      against PDS_INITIAL_HOSTNAME recorded in the sentinel; abort loudly
#      if they differ, because every user's DID document encodes the original
#      hostname as serviceEndpoint and silent change breaks federation.
#   4. Warn if the one-time recovery private key file is still on disk.
#   5. Fill in email/SMTP, service URLs, rate limits, and branding defaults.
#   6. Write /run/pds.env (consumed only by the `goat` CLI).
#   7. Export env vars and exec node as the cloudron user.

# Safely load known secret names from a KEY=VALUE file. We parse line-by-line
# and assign only allowlisted keys instead of `source`-ing, because the file
# lives in the data volume and this script runs as root before exec-ing gosu.
load_pds_secrets() {
  local file="$1" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX|PDS_ADMIN_PASSWORD|PDS_JWT_SECRET|PDS_RECOVERY_DID_KEY)
        printf -v "$key" '%s' "$val"
        ;;
    esac
  done < "$file"
}

PDS_HOSTNAME="${CLOUDRON_APP_DOMAIN}"

# Set default data directory if not specified
PDS_DATA_DIRECTORY="${PDS_DATA_DIRECTORY:-/app/data}"
PDS_BLOBSTORE_DISK_LOCATION="${PDS_BLOBSTORE_DISK_LOCATION:-$PDS_DATA_DIRECTORY/blocks}"

# If application expects /pds but we're in read-only environment, ensure data is accessible
# The application will look for data at /pds, so we need to make sure it's available at that location
# In a read-only environment, we can't create symlinks, so we'll use the existing directory structure
if [[ "$PDS_DATA_DIRECTORY" == "/pds" ]]; then
  PDS_DATA_DIRECTORY="/app/data"
  PDS_BLOBSTORE_DISK_LOCATION="/app/data/blocks"
fi

# The sentinel and secrets file live in the persistent data volume, so they
# survive container restarts and are cleared on Cloudron app reinstall — the
# two semantics we want.
export PDS_DATA_DIRECTORY
export PDS_HOSTNAME
PDS_INIT_SENTINEL="${PDS_DATA_DIRECTORY}/.pds-initialized"
PDS_SECRETS_FILE="${PDS_DATA_DIRECTORY}/.pds-secrets"

# Load secrets if present so we can check which are already populated.
load_pds_secrets "${PDS_SECRETS_FILE}"

# Re-run init whenever the sentinel is absent (fresh install) OR any required
# secret is missing (upgrade that added a new required secret). Init's own
# -z guards keep already-generated secrets untouched.
if [[ ! -f "${PDS_INIT_SENTINEL}" ]] \
   || [[ -z "${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX:-}" ]] \
   || [[ -z "${PDS_ADMIN_PASSWORD:-}" ]] \
   || [[ -z "${PDS_JWT_SECRET:-}" ]] \
   || [[ -z "${PDS_RECOVERY_DID_KEY:-}" ]]; then
  echo "Running cloudron_init.sh (first boot or upgrade backfill)"
  /app/pkg/cloudron_init.sh
  # Re-load to pick up newly-generated values.
  load_pds_secrets "${PDS_SECRETS_FILE}"
fi

# Detect hostname drift. If the Cloudron app has been moved to a new domain,
# all existing user DID documents still reference the original hostname as
# their serviceEndpoint, and federation silently breaks. Abort loudly instead.
# Parse the sentinel by hand — don't `source` files from the data volume.
PDS_INITIAL_HOSTNAME=""
while IFS= read -r _line || [[ -n "${_line}" ]]; do
  if [[ "${_line}" == PDS_INITIAL_HOSTNAME=* ]]; then
    PDS_INITIAL_HOSTNAME="${_line#PDS_INITIAL_HOSTNAME=}"
    break
  fi
done < "${PDS_INIT_SENTINEL}"
unset _line
if [[ "${PDS_INITIAL_HOSTNAME:-}" != "${PDS_HOSTNAME}" ]]; then
  echo "ERROR: PDS hostname has changed since first boot." >&2
  echo "  Initial: ${PDS_INITIAL_HOSTNAME:-<unset>}" >&2
  echo "  Current: ${PDS_HOSTNAME}" >&2
  echo "" >&2
  echo "User DID documents on this PDS reference the initial hostname as their" >&2
  echo "serviceEndpoint. Starting the PDS at a different hostname will break" >&2
  echo "identity resolution for all existing users." >&2
  echo "" >&2
  echo "If this move is intentional and you accept that users must re-register" >&2
  echo "their DIDs with the new endpoint manually, delete" >&2
  echo "${PDS_INIT_SENTINEL} and restart the app." >&2
  exit 1
fi

# Warn on every boot while the recovery private key file is still on disk.
# The operator is expected to retrieve it, store it offline, and delete it
# (see the save_recovery_key checklist item in CloudronManifest.json).
RECOVERY_PRIVATE_KEY_FILE="${PDS_DATA_DIRECTORY}/.pds-recovery-private-key.hex"
if [[ -f "${RECOVERY_PRIVATE_KEY_FILE}" ]]; then
  echo "WARNING: recovery private key is still on disk at ${RECOVERY_PRIVATE_KEY_FILE}." >&2
  echo "  Retrieve it, store it securely offline, then delete the file." >&2
fi

# Email / SMTP — composed from Cloudron-provided env. Moderation addresses
# default to the regular sender; operators can override either via env.
PDS_EMAIL_SMTP_URL="smtps://${CLOUDRON_MAIL_SMTP_USERNAME}:${CLOUDRON_MAIL_SMTP_PASSWORD}@${CLOUDRON_MAIL_SMTP_SERVER}/"
PDS_EMAIL_FROM_ADDRESS="${CLOUDRON_MAIL_FROM}"
PDS_MODERATION_EMAIL_SMTP_URL="${PDS_MODERATION_EMAIL_SMTP_URL:-$PDS_EMAIL_SMTP_URL}"
PDS_MODERATION_EMAIL_ADDRESS="${PDS_MODERATION_EMAIL_ADDRESS:-$PDS_EMAIL_FROM_ADDRESS}"
PDS_INVITE_REQUIRED=true

PDS_BLOB_UPLOAD_LIMIT="${PDS_BLOB_UPLOAD_LIMIT:-104857600}"

# Set default service URLs (point to public AT Protocol network)
PDS_DID_PLC_URL="${PDS_DID_PLC_URL:-https://plc.directory}"
PDS_BSKY_APP_VIEW_URL="${PDS_BSKY_APP_VIEW_URL:-https://api.bsky.app}"
PDS_BSKY_APP_VIEW_DID="${PDS_BSKY_APP_VIEW_DID:-did:web:api.bsky.app}"
PDS_REPORT_SERVICE_URL="${PDS_REPORT_SERVICE_URL:-https://mod.bsky.app}"
PDS_REPORT_SERVICE_DID="${PDS_REPORT_SERVICE_DID:-did:plc:ar7c4by46qjdydhdevvrndac}"
PDS_CRAWLERS="${PDS_CRAWLERS:-https://bsky.network}"

# Set defaults for optional variables
LOG_ENABLED="${LOG_ENABLED:-true}"
PDS_RATE_LIMITS_ENABLED="${PDS_RATE_LIMITS_ENABLED:-true}"
PDS_PORT="${PDS_PORT:-3000}"
NODE_ENV="${NODE_ENV:-production}"

# Create required directories
echo "Initializing data directories..."
mkdir -p "$PDS_DATA_DIRECTORY"
mkdir -p "$PDS_BLOBSTORE_DISK_LOCATION"
mkdir -p "/run"


# Create the PDS env config. `goat` CLI reads PDS_ADMIN_PASSWORD from /pds/pds.env
# (symlinked to /run/pds.env via the Dockerfile). The file contains admin
# password, JWT secret, and PLC rotation key in plaintext — force 0600 via
# rm-then-create-under-umask so perms are right from the moment the file
# exists, not racily chmod'd afterward.
rm -f "/run/pds.env"
(
  umask 077
  cat <<PDS_CONFIG > "/run/pds.env"
PDS_HOSTNAME=${PDS_HOSTNAME}
PDS_EMAIL_SMTP_URL=${PDS_EMAIL_SMTP_URL}
PDS_EMAIL_FROM_ADDRESS=${PDS_EMAIL_FROM_ADDRESS}
PDS_INVITE_REQUIRED=${PDS_INVITE_REQUIRED}
PDS_JWT_SECRET=${PDS_JWT_SECRET}
PDS_ADMIN_PASSWORD=${PDS_ADMIN_PASSWORD}
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=${PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX}
PDS_DATA_DIRECTORY=${PDS_DATA_DIRECTORY}
PDS_BLOBSTORE_DISK_LOCATION=${PDS_DATA_DIRECTORY}/blocks
PDS_BLOB_UPLOAD_LIMIT=104857600
PDS_DID_PLC_URL=${PDS_DID_PLC_URL}
PDS_BSKY_APP_VIEW_URL=${PDS_BSKY_APP_VIEW_URL}
PDS_BSKY_APP_VIEW_DID=${PDS_BSKY_APP_VIEW_DID}
PDS_REPORT_SERVICE_URL=${PDS_REPORT_SERVICE_URL}
PDS_REPORT_SERVICE_DID=${PDS_REPORT_SERVICE_DID}
PDS_CRAWLERS=${PDS_CRAWLERS}
LOG_ENABLED=true
PDS_CONFIG
)


# Export all PDS variables for the application
export PDS_HOSTNAME
export PDS_EMAIL_SMTP_URL
export PDS_EMAIL_FROM_ADDRESS
export PDS_MODERATION_EMAIL_SMTP_URL
export PDS_MODERATION_EMAIL_ADDRESS
export PDS_INVITE_REQUIRED
export PDS_JWT_SECRET
export PDS_ADMIN_PASSWORD
export PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX
export PDS_RECOVERY_DID_KEY
export PDS_DATA_DIRECTORY
export PDS_BLOBSTORE_DISK_LOCATION
export PDS_BLOB_UPLOAD_LIMIT
export PDS_DID_PLC_URL
export PDS_BSKY_APP_VIEW_URL
export PDS_BSKY_APP_VIEW_DID
export PDS_REPORT_SERVICE_URL
export PDS_REPORT_SERVICE_DID
export PDS_CRAWLERS
export LOG_ENABLED
export PDS_RATE_LIMITS_ENABLED
export PDS_PORT
export NODE_ENV

# Optional environment variables (only export if set)
if [[ -n "${PDS_PRIVACY_POLICY_URL:-}" ]]; then
  export PDS_PRIVACY_POLICY_URL
fi
if [[ -n "${PDS_SERVICE_NAME:-}" ]]; then
  export PDS_SERVICE_NAME
fi
if [[ -n "${PDS_HOME_URL:-}" ]]; then
  export PDS_HOME_URL
fi
if [[ -n "${PDS_LOGO_URL:-}" ]]; then
  export PDS_LOGO_URL
fi
if [[ -n "${PDS_SUPPORT_URL:-}" ]]; then
  export PDS_SUPPORT_URL
fi
if [[ -n "${PDS_TERMS_OF_SERVICE_URL:-}" ]]; then
  export PDS_TERMS_OF_SERVICE_URL
fi
if [[ -n "${PDS_CONTACT_EMAIL_ADDRESS:-}" ]]; then
  export PDS_CONTACT_EMAIL_ADDRESS
fi
if [[ -n "${LOG_DESTINATION:-}" ]]; then
  export LOG_DESTINATION
fi
if [[ -n "${LOG_LEVEL:-}" ]]; then
  export LOG_LEVEL
fi

echo "Starting Bluesky PDS on Cloudron"
echo "  Hostname: $PDS_HOSTNAME"
echo "  Data directory: $PDS_DATA_DIRECTORY"
echo "  Blob storage: $PDS_BLOBSTORE_DISK_LOCATION"
echo "  Port: $PDS_PORT"

# Recover data dir for runtime user as recommended to help with backup restoration
chown -R cloudron:cloudron $PDS_DATA_DIRECTORY

# Start the application under cloudron user
exec /usr/local/bin/gosu cloudron:cloudron node --enable-source-maps /app/code/index.js
