#!/bin/bash
# Unit tests for cloudron_init.sh.
#
# Strategy:
#   - Copy cloudron_init.sh to a tempdir with `/app/code` rewritten to point
#     at a test-owned fake dir (init just `cd`s there before invoking node).
#   - Prepend tests/fixtures/stub-bin/ to PATH so `node -e` is our stub,
#     not the host's real node. The stub emits a fixed did:key + hex pair.
#   - Pre-seed or inspect ${PDS_DATA_DIRECTORY} per-test to drive each case.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$script_dir/lib.sh"

init_source="$script_dir/../cloudron_init.sh"
stub_bin="$script_dir/fixtures/stub-bin"
expected_stub_did="did:key:zStubTestRecoveryKey00000000000000000000000000"

# Test-scoped globals set by prepare() and consumed by the cases below.
# Kept non-local so assertions outside the function see them.
tmpdir=""
test_init=""

prepare() {
  tmpdir=$(mktemp -d)
  export PDS_DATA_DIRECTORY="$tmpdir/data"
  export PDS_HOSTNAME="test.example.com"
  mkdir -p "$PDS_DATA_DIRECTORY" "$tmpdir/app-code"
  test_init="$tmpdir/init.sh"
  # Rewrite /app/code to the test-owned fake dir. `|` delimiter keeps `/`
  # in the path from colliding with the sed separator.
  sed "s|/app/code|$tmpdir/app-code|g" "$init_source" > "$test_init"
  chmod +x "$test_init"
  export PATH="$stub_bin:$PATH"
}

cleanup() {
  [[ -n "$tmpdir" && -d "$tmpdir" ]] && rm -rf "$tmpdir"
}

echo "== test_init.sh"

# ---------------------------------------------------------------------------
echo "  - fresh run generates all secrets"
prepare
"$test_init"
assert_file_exists "    secrets file exists"     "$PDS_DATA_DIRECTORY/.pds-secrets"
assert_file_exists "    sentinel exists"         "$PDS_DATA_DIRECTORY/.pds-initialized"
assert_file_exists "    private key file exists" "$PDS_DATA_DIRECTORY/.pds-recovery-private-key.hex"
assert_file_mode   "    secrets file mode 600"   "$PDS_DATA_DIRECTORY/.pds-secrets"                 "600"
assert_file_mode   "    private key mode 600"    "$PDS_DATA_DIRECTORY/.pds-recovery-private-key.hex" "600"

_secrets=$(cat "$PDS_DATA_DIRECTORY/.pds-secrets")
assert_contains "    rotation key present"   "PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=" "$_secrets"
assert_contains "    admin password present" "PDS_ADMIN_PASSWORD="                        "$_secrets"
assert_contains "    jwt secret present"     "PDS_JWT_SECRET="                            "$_secrets"
assert_contains "    recovery key present"   "PDS_RECOVERY_DID_KEY=${expected_stub_did}"  "$_secrets"

_priv=$(cat "$PDS_DATA_DIRECTORY/.pds-recovery-private-key.hex")
assert_matches "    private key is 64 hex chars" '^[0-9a-f]{64}$' "$_priv"

_sentinel=$(cat "$PDS_DATA_DIRECTORY/.pds-initialized")
assert_contains "    sentinel records hostname" "PDS_INITIAL_HOSTNAME=test.example.com" "$_sentinel"
cleanup

# ---------------------------------------------------------------------------
echo "  - idempotent rerun preserves secrets"
prepare
"$test_init"
_first=$(md5sum "$PDS_DATA_DIRECTORY/.pds-secrets" | awk '{print $1}')
"$test_init"
_second=$(md5sum "$PDS_DATA_DIRECTORY/.pds-secrets" | awk '{print $1}')
assert_eq "    secrets md5 unchanged across reruns" "$_first" "$_second"
cleanup

# ---------------------------------------------------------------------------
echo "  - upgrade backfill appends only missing recovery key"
prepare
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=aaaa1111
PDS_ADMIN_PASSWORD=bbbb2222
PDS_JWT_SECRET=cccc3333
SEED
echo "PDS_INITIAL_HOSTNAME=test.example.com" > "$PDS_DATA_DIRECTORY/.pds-initialized"

"$test_init"

mapfile -t _lines < "$PDS_DATA_DIRECTORY/.pds-secrets"
assert_eq "    original rotation key preserved" "PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=aaaa1111" "${_lines[0]}"
assert_eq "    original admin password preserved" "PDS_ADMIN_PASSWORD=bbbb2222" "${_lines[1]}"
assert_eq "    original jwt secret preserved"    "PDS_JWT_SECRET=cccc3333"     "${_lines[2]}"
assert_eq "    recovery key appended at tail"    "PDS_RECOVERY_DID_KEY=${expected_stub_did}" "${_lines[3]}"
assert_file_exists "    private key file written on backfill" "$PDS_DATA_DIRECTORY/.pds-recovery-private-key.hex"
cleanup

# ---------------------------------------------------------------------------
echo "  - safe parser does not execute injected shell"
prepare
# If init ever goes back to `source`-ing .pds-secrets, this canary would be
# created by the command substitution. The expectation is that init treats
# the literal $(...) as a string value for PDS_ADMIN_PASSWORD.
canary="$tmpdir/pwned-$$"
rm -f "$canary"
cat > "$PDS_DATA_DIRECTORY/.pds-secrets" <<SEED
PDS_ADMIN_PASSWORD=\$(touch $canary)
SEED

"$test_init"

assert_file_absent "    canary file never created" "$canary"
# The injected value should have satisfied the -z guard, so no regeneration.
_count=$(grep -c '^PDS_ADMIN_PASSWORD=' "$PDS_DATA_DIRECTORY/.pds-secrets")
assert_eq "    admin password not duplicated" "1" "$_count"
cleanup

# ---------------------------------------------------------------------------
echo "  - crash mid-init leaves no sentinel and preserves written secrets"
prepare
# Drop a node stub that always fails, ahead of the normal stub on PATH.
crash_stub="$tmpdir/crash-bin"
mkdir -p "$crash_stub"
cat > "$crash_stub/node" <<'CRASH'
#!/bin/bash
echo "simulated node failure" >&2
exit 1
CRASH
chmod +x "$crash_stub/node"

PATH="$crash_stub:$PATH" "$test_init"
_rc=$?
assert_exit_nonzero "    init exited non-zero" "$_rc"
assert_file_absent  "    sentinel absent after crash" "$PDS_DATA_DIRECTORY/.pds-initialized"

_secrets=$(cat "$PDS_DATA_DIRECTORY/.pds-secrets")
# The three openssl-generated secrets run before the node call, so they
# should already be on disk; recovery key should not.
assert_contains     "    rotation key written pre-crash" "PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=" "$_secrets"
assert_contains     "    admin password written pre-crash" "PDS_ADMIN_PASSWORD=" "$_secrets"
assert_contains     "    jwt secret written pre-crash" "PDS_JWT_SECRET=" "$_secrets"
assert_not_contains "    recovery key not written" "PDS_RECOVERY_DID_KEY=" "$_secrets"

# Recovery: rerun with the good stub, only the recovery key should be added.
"$test_init"
_secrets=$(cat "$PDS_DATA_DIRECTORY/.pds-secrets")
assert_contains "    recovery key written on rerun" "PDS_RECOVERY_DID_KEY=${expected_stub_did}" "$_secrets"
assert_file_exists "    sentinel written on rerun" "$PDS_DATA_DIRECTORY/.pds-initialized"
# Guard against a regression where the rerun re-appends existing openssl secrets.
assert_eq "    rotation key not duplicated on rerun"   "1" "$(grep -c '^PDS_PLC_ROTATION_KEY_K256_PRIVATE_KEY_HEX=' "$PDS_DATA_DIRECTORY/.pds-secrets")"
assert_eq "    admin password not duplicated on rerun" "1" "$(grep -c '^PDS_ADMIN_PASSWORD=' "$PDS_DATA_DIRECTORY/.pds-secrets")"
assert_eq "    jwt secret not duplicated on rerun"     "1" "$(grep -c '^PDS_JWT_SECRET=' "$PDS_DATA_DIRECTORY/.pds-secrets")"
cleanup

report
