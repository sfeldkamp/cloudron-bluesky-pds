#!/bin/bash
set -e

# Startup script for Bluesky PDS on Cloudron
# This script validates required environment variables and initializes the application


PDS_HOSTNAME="${CLOUDRON_APP_DOMAIN}"
PDS_EMAIL_SMTP_URL="smtps://${CLOUDRON_MAIL_SMTP_USERNAME}:${CLOUDRON_MAIL_SMTP_PASSWORD}@${CLOUDRON_MAIL_SMTP_SERVER}/"
PDS_EMAIL_FROM_ADDRESS="${CLOUDRON_MAIL_FROM}"

# Generate some secrets needed by Bluesky PDS
GENERATE_SECURE_SECRET_CMD="openssl rand --hex 16"
GENERATE_K256_PRIVATE_KEY_CMD="openssl ecparam --name secp256k1 --genkey --noout --outform DER | tail --bytes=+8 | head --bytes=32 | xxd --plain --cols 32"
PDS_ADMIN_PASSWORD=$(eval "${GENERATE_SECURE_SECRET_CMD}")
PDS_JWT_SECRET=$(eval "${GENERATE_SECURE_SECRET_CMD}")
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=$(eval "${GENERATE_K256_PRIVATE_KEY_CMD}")

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
PDS_PORT="${PDS_PORT:-3000}"
NODE_ENV="${NODE_ENV:-production}"

# Create required directories
echo "Initializing data directories..."
mkdir -p "$PDS_DATA_DIRECTORY"
mkdir -p "$PDS_BLOBSTORE_DISK_LOCATION"
mkdir -p "/run"


# Create the PDS env config. `goat` CLI reads PDS_ADMIN_PASSWORD from /pds/pds.env
# This isn't writeable in Cloudron, so we've created a symlink in Dockerfile to 
# /run/pds.env which is writeable.
touch /run/pds.env
cat <<PDS_CONFIG >"/run/pds.env"
PDS_HOSTNAME=${PDS_HOSTNAME}
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


# Export all PDS variables for the application
export PDS_HOSTNAME
export PDS_JWT_SECRET
export PDS_ADMIN_PASSWORD
export PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX
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
export PDS_PORT
export NODE_ENV

# Optional environment variables (only export if set)
if [[ -n "${PDS_EMAIL_SMTP_URL:-}" ]]; then
  export PDS_EMAIL_SMTP_URL
fi
if [[ -n "${PDS_EMAIL_FROM_ADDRESS:-}" ]]; then
  export PDS_EMAIL_FROM_ADDRESS
fi
if [[ -n "${PDS_PRIVACY_POLICY_URL:-}" ]]; then
  export PDS_PRIVACY_POLICY_URL
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
echo "  PDS_EMAIL_SMTP_URL: $PDS_EMAIL_SMTP_URL"

# Recover data dir for runtime user as recommended to help with backup restoration
chown -R cloudron:cloudron $PDS_DATA_DIRECTORY

# Start the application under cloudron user
exec /usr/local/bin/gosu cloudron:cloudron node --enable-source-maps /app/code/index.js
