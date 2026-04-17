#!/bin/bash
# Unit tests for cloudron_start.sh's init-gate, drift check, and recovery
# warning — the logic that runs before the PDS is launched.
#
# Strategy:
#   - Copy cloudron_start.sh to a tempdir with two rewrites:
#       1. `/app/pkg/cloudron_init.sh` → a stub that records invocation
#          and populates .pds-secrets + sentinel.
#       2. Everything from `# Create required directories` onward replaced
#          with `exit 0`. That section writes to /run, chowns, and execs
#          node — all irrelevant to the gate logic and hostile to unit tests.
#   - Stub the Cloudron env vars the drift check and SMTP composition read.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

start_source="$script_dir/../cloudron_start.sh"

tmpdir=""
test_start=""
init_stub=""
init_log=""

prepare() {
  tmpdir=$(mktemp -d)
  export PDS_DATA_DIRECTORY="$tmpdir/data"
  mkdir -p "$PDS_DATA_DIRECTORY"

  export CLOUDRON_APP_DOMAIN="test.example.com"
  export CLOUDRON_MAIL_SMTP_USERNAME="mailuser"
  export CLOUDRON_MAIL_SMTP_PASSWORD="mailpass"
  export CLOUDRON_MAIL_SMTP_SERVER="mail.test"
  export CLOUDRON_MAIL_FROM="noreply@test.example.com"

  init_log="$tmpdir/init-was-called"
  init_stub="$tmpdir/init-stub.sh"
  cat > "$init_stub" <<STUB
#!/bin/bash
# Record that start.sh invoked us, then populate everything init.sh would.
echo "init-stub-ran" > "$init_log"
cat >> "\$PDS_DATA_DIRECTORY/.pds-secrets" <<SECRETS
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=stubrot
PDS_ADMIN_PASSWORD=stubadmin
PDS_JWT_SECRET=stubjwt
PDS_RECOVERY_DID_KEY=did:key:zStub
SECRETS
echo "PDS_INITIAL_HOSTNAME=\$PDS_HOSTNAME" > "\$PDS_DATA_DIRECTORY/.pds-initialized"
STUB
  chmod +x "$init_stub"

  test_start="$tmpdir/start.sh"
  # Truncate at the directory-creation block so we never touch /run or chown.
  # sed's /pattern/,\$d deletes from the marker line to EOF; then we append
  # a clean `exit 0`.
  sed \
    -e "s|/app/pkg/cloudron_init.sh|$init_stub|" \
    -e '/^# Create required directories$/,$d' \
    "$start_source" > "$test_start"
  echo "exit 0" >> "$test_start"
  chmod +x "$test_start"
}

cleanup() {
  [[ -n "$tmpdir" && -d "$tmpdir" ]] && rm -rf "$tmpdir"
}

echo "== test_start_gate.sh"

# ---------------------------------------------------------------------------
echo "  - fresh volume: init is invoked"
prepare
_out=$("$test_start" 2>&1)
_rc=$?
assert_eq          "    start exits 0"        "0" "$_rc"
assert_file_exists "    init stub was called" "$init_log"
assert_contains    "    'Running cloudron_init.sh' logged" "Running cloudron_init.sh" "$_out"
cleanup

# ---------------------------------------------------------------------------
echo "  - all 4 secrets present: init is NOT invoked"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=rotkey
PDS_ADMIN_PASSWORD=admin
PDS_JWT_SECRET=jwt
PDS_RECOVERY_DID_KEY=did:key:zTest
SEED
echo "PDS_INITIAL_HOSTNAME=test.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"

"$test_start" >/dev/null 2>&1
assert_file_absent "    init stub was NOT called" "$init_log"
cleanup

# ---------------------------------------------------------------------------
echo "  - upgrade backfill: sentinel present but recovery key missing triggers init"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=rotkey
PDS_ADMIN_PASSWORD=admin
PDS_JWT_SECRET=jwt
SEED
echo "PDS_INITIAL_HOSTNAME=test.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"

"$test_start" >/dev/null 2>&1
assert_file_exists "    init stub was called" "$init_log"
cleanup

# ---------------------------------------------------------------------------
echo "  - hostname drift aborts with error"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=rotkey
PDS_ADMIN_PASSWORD=admin
PDS_JWT_SECRET=jwt
PDS_RECOVERY_DID_KEY=did:key:zTest
SEED
echo "PDS_INITIAL_HOSTNAME=old.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"

_out=$("$test_start" 2>&1)
_rc=$?
assert_exit_nonzero "    start exited non-zero"          "$_rc"
assert_contains     "    error cites 'hostname has changed'" "hostname has changed"   "$_out"
assert_contains     "    error shows initial hostname"   "old.example.com"        "$_out"
assert_contains     "    error shows current hostname"   "test.example.com"       "$_out"
cleanup

# ---------------------------------------------------------------------------
echo "  - recovery private key file present: warning is logged"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=rotkey
PDS_ADMIN_PASSWORD=admin
PDS_JWT_SECRET=jwt
PDS_RECOVERY_DID_KEY=did:key:zTest
SEED
echo "PDS_INITIAL_HOSTNAME=test.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"
touch "$PDS_DATA_DIRECTORY/.pds-recovery-private-key.hex"

_out=$("$test_start" 2>&1)
assert_contains "    warning printed" "recovery private key is still on disk" "$_out"
cleanup

# ---------------------------------------------------------------------------
echo "  - recovery private key file absent: no warning"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=rotkey
PDS_ADMIN_PASSWORD=admin
PDS_JWT_SECRET=jwt
PDS_RECOVERY_DID_KEY=did:key:zTest
SEED
echo "PDS_INITIAL_HOSTNAME=test.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"
# No private key file.

_out=$("$test_start" 2>&1)
assert_not_contains "    no warning" "recovery private key is still on disk" "$_out"
cleanup

report
