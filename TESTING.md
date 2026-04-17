# Testing

Three layers, each catching progressively more of the real behavior:

1. **Unit tests** — fast, no network, no docker. Exercise `cloudron_init.sh` and `cloudron_start.sh`'s gate logic against tempdirs with a stubbed `node`.
2. **Docker integration** — builds the image and boots a container, exercising the real `@atproto/crypto` path and multi-boot persistence.
3. **Manual Cloudron install** — the only way to validate real SMTP delivery, federation, backup/restore, and Cloudron dashboard affordances like the checklist.

Run both automated layers at once with `./tests/run.sh` (hard-fails if `docker` is not on `PATH`).

## Layer 1: unit tests

```sh
./tests/test_init.sh
./tests/test_start_gate.sh
```

Covers:

- **`cloudron_init.sh`** — fresh-install generation, idempotent rerun, upgrade backfill (pre-existing secrets preserved, only missing key appended), safe-parser hardening (injected `$(…)` in `.pds-secrets` not executed), crash recovery (no sentinel written if the recovery-key step fails, rerun picks up where it left off).
- **`cloudron_start.sh`** — init invoked on fresh volume, skipped when all 4 secrets present, re-invoked when sentinel is present but a required secret is missing (upgrade path), drift abort when sentinel hostname differs from `CLOUDRON_APP_DOMAIN`, recovery-key warning present/absent based on the private-key file's existence.

No dependencies beyond `bash`, `openssl`, `xxd`, `sed`, `stat`, `md5sum`. Runs in under 2 seconds.

The `node` binary used by the init script is stubbed via `tests/fixtures/stub-bin/node`, which emits a deterministic `did:key:zStub…` + 64-char hex. Real `@atproto/crypto` is exercised in Layer 2.

## Layer 2: docker integration

```sh
./tests/integration.sh
```

Requires `docker` on `PATH` and network access to pull the base image. Takes a few minutes on first run (image build), faster on subsequent runs when layers are cached.

Covers:

- **Image builds cleanly** from the current `Dockerfile`.
- **Fresh boot** populates all four secrets in `.pds-secrets` with the expected `did:key:z` prefix on `PDS_RECOVERY_DID_KEY`, and the private key file exists with mode `600`.
- **`did:key` round-trip** — re-derives the stored `did:key` from the on-disk private hex using `@atproto/crypto` and asserts equality. This is the only layer that exercises the real encoding; if `@atproto/crypto`'s API changes shape, this test catches it.
- **PDS healthcheck** returns 200 after boot.
- **Restart** leaves `.pds-secrets` byte-identical.
- **Private-key file removal** suppresses the every-boot warning on subsequent starts.
- **Hostname drift** — re-running the container with a different `CLOUDRON_APP_DOMAIN` exits non-zero with the expected error message.

The script cleans up its container and named volume on exit (including failure).

## Layer 3: manual Cloudron install

The docker layer exercises the container in isolation; it can't validate real SMTP delivery, federation with the public PLC directory and AppView, backup/restore round-trips, or Cloudron dashboard UI (checklist items, app-move flow). Those need a real Cloudron host.

Assumes you have a Cloudron instance and the `cloudron` CLI configured. Treat each numbered block as "do, then assert."

### 1. Install and first boot

```sh
cloudron install --image <registry>/cloudron-bluesky-pds:<tag> \
  --location test-pds.<your-domain>
```

- **Assert** install completes. Dashboard shows the **Save recovery key** checklist item alongside **Add alias** and **Configure encrypted backups**.
- **Assert** `cloudron logs --app test-pds.<your-domain>` contains `Running cloudron_init.sh (first boot or upgrade backfill)` and `WARNING: recovery private key is still on disk`.

### 2. Retrieve the recovery key

```sh
cloudron exec --app test-pds.<your-domain> cat /app/data/.pds-recovery-private-key.hex
```

- **Assert** output is a single 64-char hex line. Save it to your password manager or hardware token.
- **Also** grab the admin password and PLC rotation key for your records:

  ```sh
  cloudron exec --app test-pds.<your-domain> cat /app/data/.pds-secrets
  ```

### 3. Delete the private key file; confirm warning stops

```sh
cloudron exec --app test-pds.<your-domain> rm /app/data/.pds-recovery-private-key.hex
cloudron restart --app test-pds.<your-domain>
cloudron logs --app test-pds.<your-domain> | tail -40
```

- **Assert** no `recovery private key is still on disk` line in the post-restart logs.
- **Assert** checklist item can now be marked complete in the dashboard.

### 4. Admin auth and invite-required account creation

- Hit `https://test-pds.<your-domain>/xrpc/_health` → 200.
- Use the admin password from step 2 to create an invite code:

  ```sh
  curl -u "admin:<ADMIN_PASSWORD>" -XPOST \
    https://test-pds.<your-domain>/xrpc/com.atproto.server.createInviteCode \
    -H 'content-type: application/json' -d '{"useCount":1}'
  ```

- **Assert** response includes `"code":"test-pds.<your-domain>-..."`.
- **Assert** attempting `createAccount` without that code is rejected (invite-required gate working).

### 5. Register a test user and verify federation

- In a Bluesky client, create an account with handle `<you>.test-pds.<your-domain>` using the invite code.
- **Assert** the invite email arrives (validates SMTP wiring via Cloudron sendmail).
- **Assert** the new account's posts are visible on `bsky.app` from a different account (validates crawler wiring to `bsky.network`).
- **Assert** `https://plc.directory/did:plc:<the-new-did>` shows **two** rotation keys in `rotationKeys`: the PDS's and your recovery `did:key:z…`.

### 6. Restart persists identity

```sh
cloudron restart --app test-pds.<your-domain>
```

- **Assert** the test user can still log in with the same password.
- **Assert** `cloudron exec --app test-pds.<your-domain> md5sum /app/data/.pds-secrets` yields the same hash before and after.

### 7. Drift abort (destructive — do this last, expect to restore)

```sh
cloudron configure --app test-pds.<your-domain> --location other.<your-domain>
```

- **Assert** the app fails to start. Logs contain `ERROR: PDS hostname has changed since first boot.` and instructions referencing `/app/data/.pds-initialized`.
- **Restore**: `cloudron configure --app test-pds.<your-domain> --location test-pds.<your-domain>`. App boots normally.

### 8. Account Migration

The single feature that most justifies self-hosting — and the only test that proves the recovery key stored in step 2 is cryptographically usable, not just well-formed hex.

**Recommended tool: [PDS_Moover](https://pdsmoover.com/)** — a browser-based UI that walks through the multi-step ATProto migration flow (`createAccount` on the target, repo/blob/preference import, `requestPlcOperationSignature`, `signPlcOperation` with the recovery key, `activateAccount` on target, `deactivateAccount` on source). Running these xrpc calls by hand is tedious and easy to botch; PDS_Moover surfaces each step in the browser.

Use a throwaway Bluesky account — migration leaves the source deactivated.

1. On `bsky.social`, designate a throwaway account and generate an app password.
2. On the test PDS, generate an invite code (step 4).
3. Open <https://pdsmoover.com/>, point "source" at `https://bsky.social` and "target" at `https://test-pds.<your-domain>`, and supply the recovery `did:key:z…` from step 2 so it stays in `rotationKeys` on the migrated DID.

- **Assert** migration completes without errors at any step (the `signPlcOperation` step is the real validation that the recovery key works).
- **Assert** `https://plc.directory/did:plc:<the-did>` now lists the test PDS's service endpoint, and the recovery `did:key:z…` is still present in `rotationKeys`.
- **Assert** login to the migrated account on the test PDS works with the original password; posts, follows, and profile from the source are intact when viewed on `bsky.app`.
- **Assert** the source account on `bsky.social` is deactivated.

### 9. Backup/restore round-trip (optional, slow)

- `cloudron backup create --app test-pds.<your-domain>`
- Uninstall the app, reinstall from the backup.
- **Assert** the test user's DID, handle, posts, and admin password all still work (no regeneration of secrets on restore).
