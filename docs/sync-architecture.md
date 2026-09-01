# Sync architecture

How a call gets from the handset to the server, and what guarantees each part
carries. Written after an audit of the upload pipeline found the client and the
native coordinator disagreeing about their shared state — see *What was wrong*
at the end for the specific defects this design replaced.

## The one rule

**The native `SyncCoordinator` is the only thing that uploads.**

Everything else — the Flutter UI, the drift DAO, `SyncRepository` — reads the
queue, corrects it, or displays it. Nothing else posts a call or a recording.

This is not a style preference. The product promise is that calls keep syncing
with the app swiped away, and the Flutter engine does not exist in that state.
Any uploader written in Dart is therefore a second implementation that can only
run in the case that was already covered, while racing the first one over the
same rows.

## Storage: one table, two writers

Both sides share `zebu_calls.sqlite` → table `local_calls`.

| | Dart | Kotlin |
|---|---|---|
| Opens via | drift `AppDatabase` | `ZebuDatabaseHelper` (`SQLiteOpenHelper`) |
| Path | `getApplicationDocumentsDirectory()` | `filesDir/../app_flutter/` |
| Schema version | `AppDatabase.schemaVersion` | `ZebuDatabaseHelper.DATABASE_VERSION` |

Both enable WAL and a 10 s busy timeout, which is what makes two processes on
one file safe.

**The two schema versions are locked together.** `SQLiteOpenHelper` throws
outright when it opens a database newer than its own version. Raising drift's
number alone does not produce a migration — it takes background sync offline,
silently, at the next call. Move both or neither. Both files say so at the
declaration.

Because of that lock, the legacy-value migration is *not* a schema migration.
It is a set of idempotent `UPDATE`s run on every open, from drift's `beforeOpen`
and from `ZebuDatabaseHelper.onOpen`. Whichever side opens first does the work.

## State vocabulary

One vocabulary, defined twice and marked as a contract:

- `lib/core/storage/sync_state.dart` — `CallSyncState`, `RecordingUploadStatus`
- `android/.../background/SyncStates.kt` — `SyncStates`, `RecordingStates`

```
WAITING ──claim──> UPLOADING ──ok────────> UPLOADED
                       │
                       ├──transient──> RETRY_PENDING ──backoff elapsed──> (claim)
                       └──permanent──> FAILED ──manual retry──> WAITING
```

`sync_state` tracks **the call**, never its audio. `recording_upload_status`
tracks the audio independently:

```
waiting_for_recording ──match──> pending ──ok──> uploaded
          │                         │
          └──window expires─────────┴──unsendable──> absent
                    ↓                └──rejected, retryable──> failed
                  absent
```

A call is routinely `UPLOADED` with its recording still `pending` — OEM dialers
write the audio file seconds after the call-log row, so the metadata goes first
and the recording follows on a later pass. **A recording that can never be
delivered leaves the call `UPLOADED`**, with the bad news in
`recording_upload_status`. Dragging the whole row to `FAILED` would hide a call
the server genuinely has and cause its metadata to be re-posted.

## Triggers

Every trigger converges on `SyncCoordinator.runSync`, which holds an
`AtomicBoolean` so only one drain runs at a time.

| Trigger | Mechanism | Survives app kill |
|---|---|---|
| Call ends | `CallStateReceiver` → `BackgroundScheduler.enqueueNow` | yes |
| Call ends, +10 s / +30 s | delayed `CallIngestWorker` | yes |
| **Periodic, 15 min** | **`WorkManager` — ingest + sync jobs** | **yes** |
| Boot / package replaced | `BootReceiver` | yes |
| App start, app resume | `MainActivity`, `HomeShell` | n/a |
| Network restored | `ConnectivityManager` callback, and the `NetworkType.CONNECTED` constraint on the periodic sync job | yes (via the constraint) |
| Manual "Sync now" | `triggerNativeSync` | n/a |

The periodic WorkManager pair is the floor that makes the guarantee true.
`CallTrackingService` runs a faster loop on top of it, but it is an
**accelerator, not the mechanism**:

- a `dataSync` foreground service is capped at six hours per 24 from Android 15,
  and must stand down in `onTimeout` or the system kills the app;
- OEM battery managers on this fleet stop such services earlier than that;
- Android 12+ forbids starting one from a background broadcast at all.

If the service never runs, the app still syncs — just on the 15-minute
schedule. Nothing may depend on it being alive.

### Why the call-state receiver uses WorkManager

`ACTION_PHONE_STATE_CHANGED` reaches a manifest receiver even when the process
is stopped, which is what makes background detection work. But that receiver is
by definition running in the background, so `startForegroundService` from it
throws on Android 12+. Enqueuing WorkManager work is permitted and is the only
correct move there.

## Why there is a local database at all

A reasonable question is why calls are staged in SQLite instead of being posted
to the server as they happen. The staging is not duplicated work — it is the
only place four unavoidable facts can live:

1. **The network is not available when the call ends.** A call taken in a lift
   or on the road has to survive until there is a connection. Without a queue it
   is simply lost.
2. **The recording does not exist yet.** OEM dialers write their audio file
   seconds to minutes after the call-log row appears. The call must be held
   somewhere while its recording is matched, and re-offered once it is.
3. **Retries need durable state.** Which calls the server has, how many attempts
   each has had, when the next one is due — none of that can live in memory in a
   process the OEM battery manager kills routinely.
4. **The UI has to show status.** Pending, uploading, failed, synced — that is a
   read of the queue.

This is the outbox pattern, and it is one job, not two: *capture* writes to the
queue, *drain* empties it. What was genuinely duplicated is that the app has
**two ingestors** — Kotlin's `NativeCallIngestor` and Dart's
`ingestNativeCallLogs` — writing the same rows to the same table. Both are
cursor-bounded now, and they converge on identical idempotency keys, so the
second one through is a no-op. Consolidating on the native ingestor remains the
obvious next simplification.

## Queue policy

The server accepts **one call per request**, which makes the shape of the queue
load-bearing. Three rules follow from that and are not optional:

**Newest first.** `claimNextWaitingCall` orders by `started_at DESC`. Ordering
oldest-first put the call the user had just made at the back of the entire
backlog; on a handset with months of history it would not be sent for hours,
which is indistinguishable from "uploads are broken". The newest call is also
the one whose recording is most likely to still be on disk.

**Bounded backfill.** First-run capture reaches back `BACKFILL_DAYS` (30), not
over the whole call log. An unbounded backfill queued up to 15,000 rows — and
the server rejects anything past its `max_call_age_days` policy (90), so most of
them could never be accepted. Those rows sat ahead of every live call. History
older than the window is still visible in the app: the call-history screen reads
the system call log directly, not this table.

**Bounded runs.** A drain stops at `RUN_BUDGET_MILLIS` (8 minutes) and reports
`hasMoreWork`. WorkManager kills a worker at 10 minutes, so a run that ignored
the limit was killed mid-upload and the next one started over. `CallSyncWorker`
turns `hasMoreWork` into `Result.retry()` rather than re-enqueuing — the
coordinator usually runs *inside* the unique work named `WORK_SYNC_NOW`, and
`enqueueSync` uses `REPLACE`, so enqueuing from there would cancel itself.

A single call failing on the network no longer aborts the queue; the run stops
only after `MAX_CONSECUTIVE_NETWORK_FAILURES` (3), because one oversized
recording or one bad response is not evidence the connection is gone.

## Termination

The drain loop claims one row at a time and cannot rely on the claim predicate
alone to terminate: a row that comes back still matching it means no progress
was made. `runSync` therefore tracks the keys it has already handled and stops
if one is claimed twice, deferring it with a backoff instead of retrying
immediately. Without that, a permanently-unsendable recording spins the loop for
as long as the process lives.

## Wire vocabulary

**The contract is the Mobile API Guide (`MOBILE_API.md`), §4.4.** That document
is not currently in this repository — it should be, beside this one, because the
client is coded directly against it and there is no other record of what the
server accepts.

`direction` — `incoming` · `outgoing` · `unknown`
`status` — `ringing` · `dialing` · `answered` · `missed` · `rejected` ·
`failed` · `cancelled` · `ended` · `unknown`

`ended`, `missed`, `rejected`, `failed` and `cancelled` are terminal. The server
validates the values **and the combination**, and answers anything else with
`422 VALIDATION_ERROR` carrying `retryable: false` — a permanent drop.

Two combination rules bite in practice:

- an **outgoing** call can never be `missed` or `rejected`. One that never
  connected is `cancelled`;
- an **incoming** call can never be `dialing`.

Derived in exactly one place per side — `lib/core/network/call_wire_format.dart`
and `android/.../call/CallWireFormat.kt` — which are mirrors of each other, and
covered by `test/unit/call_wire_format_test.dart`. The local `status` column
stores these same values, so a row is upload-ready as written.

### Retry classification

§10.1 is expressed once, in `SyncCoordinator.isRetryableFailure`. The HTTP
status alone is not enough: a 403 is either `DEVICE_NOT_REGISTERED` (fix the
precondition and the same record is accepted) or `DEVICE_REVOKED` (stop
entirely). The coordinator therefore parses `error.code` out of the envelope and
branches on it, falling back to the status only when the body is not an
envelope. `Retry-After` on a 429 overrides the local backoff.

`FATAL_CODES` stop the whole run and record `BLOCKED`, which the Settings and
Sync screens surface as "Blocked by server" — a person has to intervene.

## Server conversation

| Endpoint | Caller | Purpose |
|---|---|---|
| `POST /auth/login`, `/mobile/register` | Dart `AuthRepository` | sign-in |
| `POST /auth/refresh` | Dart `ApiClient`, **and** `SyncCoordinator` natively | the coordinator refreshes without Flutter |
| `POST /devices/register` | Dart `AuthController` | first sign-in |
| `POST /devices/heartbeat` | Dart `SyncServiceNotifier` | queue depth, so a stalled handset is visible centrally |
| `GET /sync/status` | Dart `SyncServiceNotifier` | **reconciliation** — see below |
| `POST /sync/calls` | **`SyncCoordinator` only** | call metadata |
| `POST /calls/{id}/recording` | **`SyncCoordinator` only** | audio, streamed |
| `PATCH /calls/{id}` | Dart, during reconciliation | `has_recording: false` |

### Reconciliation

`GET /sync/status` returns `pending_recording_uploads`: calls the server has
metadata for but no audio. This is the only way to detect a recording upload
whose *response* was lost — locally such a call looks finished, so without this
pass nothing would ever offer the file again and the audio would be missing from
the server permanently.

For each entry the client either re-opens the upload (file still on the handset)
or `PATCH`es `has_recording: false` (it isn't), so the server stops asking.

Runs before the coordinator drains, and is best-effort: a failure here must not
block the upload run.

### Uploads are fire-and-forget

`triggerNativeSync` hands off and returns. The upload outlives the call and may
outlive the Flutter engine, so `SyncResultSummary` is a **snapshot of the
queue**, not a result. Live figures reach the UI through `syncCountersProvider`,
which watches the table the coordinator writes to.

## Ingest

Two ingestors read the same call log into the same table:

- `NativeCallIngestor` (Kotlin) — runs with no Flutter engine. Authoritative.
- `SyncServiceNotifier.ingestNativeCallLogs` (Dart) — runs while the UI is up,
  and owns the isolate-based `RecordingMatcher`.

They do not conflict because the idempotency key is a deterministic UUID v5 over
the same inputs on both sides (`zebu:call:{extId}:{dateMillis}`, DNS namespace),
so whichever arrives second is a no-op. Both keep their own cursor and neither
assumes the other has run.

This duplication is deliberate but is not free — it is the most likely place for
the two sides to drift apart again. Consolidating on the native ingestor is the
obvious next simplification; it is not done here because the Dart matcher
carries the test coverage.

## Security posture

- `allowBackup="false"` plus both rules files. The outbox holds call metadata
  and the worker holds a session; neither may leave the handset by cloud backup
  or `adb backup`.
- The background auth session lives in `EncryptedSharedPreferences`
  (`androidx.security:security-crypto:1.0.0`), matching what
  `flutter_secure_storage` gives the Dart side. Falls back to plain preferences
  and logs if the keystore is unavailable — an app that cannot sync is worse
  than one that stores its token as it used to.
- Cleartext HTTP is denied in `src/main`. The permissive config lives in
  `src/debug/res/xml/` and is substituted by the resource merger for debug
  variants only, so the LAN dev server works without any path to shipping it.
  Verified by grepping the release APK for the dev host: absent.

## What was wrong

Recorded so the same shapes are recognisable if they recur.

1. **Two state vocabularies over one column.** Writers produced
   `UPLOADED`/`FAILED`/`RETRY_PENDING`/`WAITING`; readers matched
   `synced`/`failed_permanent`/`failed_retryable`/`uploading`. They never
   intersected. Successful uploads showed as pending forever, the Failed and
   Synced tabs were permanently empty, retry updated zero rows, cleanup deleted
   nothing, and the sign-out warning counted every call as unsynced.

2. **The drain loop could not terminate.** The recording clause of the claim
   query matched on `sync_state != 'UPLOADING'`, so a row whose recording failed
   permanently stayed eligible and was re-claimed without end.

3. **No periodic recovery.** `ensurePeriodic` cancelled both WorkManager jobs
   and left a foreground service as the only periodic trigger. Once Android or
   the OEM stopped that service, nothing retried until the user opened the app
   or took another call — the exact scenario the design exists to cover.

4. **The immediate post-call pass never ran.** The receiver called
   `startForegroundService` from a background broadcast, which throws on Android
   12+, into a `catch` that swallowed it.

5. **Uploads could not reach the dev server.** `cleartextTrafficPermitted=false`
   applied to every build while the default base URL was `http://192.168.5.46`,
   so every request failed with a policy denial that reads exactly like a broken
   pipeline.

6. **A recording without a checksum sent 64 zeros**, guaranteeing a
   non-retryable server rejection — losing the audio rather than delaying it.

7. **Notification ID 1003 was shared** by the persistent foreground service and
   the coordinator's progress notification, so every finished sync cancelled the
   notification keeping that service alive.

8. **Auth tokens sat in plaintext SharedPreferences** while the Dart copy of the
   same tokens was in secure storage, and `allowBackup` was left at its default
   of true.

9. **A second, unused uploader** existed in Dart, and the reconciliation
   endpoints that recover lost recordings were never called.

10. **`status: "completed"` was sent for every answered call** — a value absent
    from the server's enum. The server replied `422 VALIDATION_ERROR` with
    `retryable: false`, so the bulk of the queue was rejected on arrival and
    dropped. Unanswered outgoing calls were sent as `(outgoing, missed)`, an
    illegal combination, and rejected the same way. The terminal status is
    `ended`; an unanswered outgoing call is `cancelled`.

11. **Failures were classified by HTTP status alone.** `403
    DEVICE_NOT_REGISTERED` — recoverable by registering the device — was treated
    as permanent, so a handset that had not registered marked its entire queue
    failed and never recovered. Nothing registered the device outside the
    sign-in path, which swallowed its own errors.

12. **The queue drained oldest-first behind an unbounded backfill.** See
    *Queue policy*. This is what made "uploads never happen" the observed
    behaviour even once the payload was correct.
