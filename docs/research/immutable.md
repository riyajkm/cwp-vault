# Immutable (ransomware-proof) backups — findings and design for v0.3

Tested 2026-10-28 on Contabo Object Storage with restic 0.19.1, on throwaway buckets (deleted afterwards).

## The threat

The engine holds a storage key that can delete. An attacker with root on the server (or a stolen key)
can run `restic forget --prune` or delete the bucket's objects and wipe every backup. Encryption does
not help against deletion.

## What we tested

| Step | Result |
|---|---|
| Bucket created with object lock, default retention GOVERNANCE 1 day | OK (versioning enabled automatically) |
| `restic init` + 2 backups on the locked bucket | Works normally |
| Attacker: `restic forget <all> --prune` | restic reports files deleted; `snapshots` shows 0 |
| What actually happened on the bucket | 17 object versions kept, 15 delete markers added |
| Attacker deletes a specific object version | `AccessDenied: forbidden by object lock` |
| Recovery: delete the delete markers, then `restic unlock --remove-all` | Snapshot is back, `restic check` clean, file restored byte-for-byte |
| `NoncurrentVersionExpiration` lifecycle rule | Supported (put/get) |

Notes:
- Removing delete markers also brings back the attacker's prune lock, so recovery must run `restic unlock`.
- Object lock can only be enabled when a bucket is created. Existing buckets need a new bucket.
- GOVERNANCE mode can be bypassed by a key with the bypass permission; COMPLIANCE cannot be bypassed by anyone
  until the retention ends. Contabo keys are full-access, so GOVERNANCE only protects against tools that
  don't ask for the bypass. **COMPLIANCE is the real protection**; GOVERNANCE is for testing.

## Design (v0.3)

- New config: `IMMUTABLE=yes|no` (default no), `LOCK_MODE=COMPLIANCE|GOVERNANCE`, `LOCK_DAYS` (default 14).
- `vault init` in immutable mode checks the bucket has object lock and a default retention ≥ `LOCK_DAYS`
  (refuses otherwise) and sets a `NoncurrentVersionExpiration` of `LOCK_DAYS + 7` so space is freed
  after the window.
- Retention: `forget --prune` keeps working; it only adds delete markers. Real space is freed by the lifecycle
  rule once versions are both non-current and out of retention. Document the storage overhead
  (≈ deleted data held for `LOCK_DAYS + 7` days).
- New command: `vault recover --account U|--all [--before TIME]` — removes delete markers newer than `TIME`
  (default: all), then `restic unlock --remove-all` and `restic check`. Dry run by default; needs `--yes`.
- Setup wizard: an "Immutable backups" step explaining COMPLIANCE vs GOVERNANCE, creating a new locked bucket
  is a manual step at the provider (show exact instructions for Contabo).
- Admin page: badge "Immutable (COMPLIANCE, 14 days)" on the dashboard; warning if the bucket's lock config drifts.

What this does **not** protect against: an attacker who waits longer than `LOCK_DAYS` while silently breaking
backups. Mitigation: heartbeat monitoring and the monthly test restore, so broken backups are noticed within days.
