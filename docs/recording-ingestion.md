# Recording Ingestion — verified on real hardware

**The app has no recording engine.** It discovers audio the device's own dialer
already wrote, matches it to a call-log row with evidence, and uploads it.

**Device:** Samsung SM-M356B · Android 16 / API 36 · **Date:** 2026-08-28
**Result: all probes pass — 35 of 35 connected calls associated, 0 ambiguous.**

---

## 1. The finding that makes this viable

My earlier feasibility report rated OEM-recording harvest as *fragile, needs
all-files access*. **On this device that is wrong, and the correction is
strongly in your favour.**

The Samsung dialer is recording: **1863 files, 3.4 GB** in `/sdcard/Recordings/Call/`.

| Access path | Result |
|---|---|
| `File.listFiles()` on the directory | **Returns nothing.** Owned by the dialer's uid and not world-readable. `canRead()` returns `true` while the listing is empty — a silently wrong answer, and the reason my first probe reported `files=0`. |
| **MediaStore.Audio** | **Full access**, including `DURATION`, `SIZE`, `DATE_ADDED`, `DATE_MODIFIED`, `RELATIVE_PATH`, `MIME_TYPE`. |

So the app reads through **MediaStore with `READ_MEDIA_AUDIO`** — an ordinary
runtime permission on API 33+. **`MANAGE_EXTERNAL_STORAGE` is not needed at
all.** That removes the worst part of the earlier plan: no all-files access, a
far cleaner permission story, and no scoped-storage workaround anywhere.

---

## 2. The matching model, derived from paired data

Not assumed — measured, by pairing the two content providers on the same device:

| Call start | Call duration | Recording `date_added` | Recording duration |
|---|---|---|---|
| 1787890024 | 45 s | +14 s | 44.757 s |
| 1787890986 | 114 s | +9 s | 114.046 s |
| 1787891129 | 10 s | +4 s | 10.133 s |

Two invariants fall out, and they carry the matching:

1. **Recording duration ≈ call CONNECTED duration**, within about a second.
   `CallLog.DURATION` excludes ring time, and recording only starts on answer —
   so the two measure the same interval.
2. **Recording start = call start + ring time.** The gap is small and always
   positive. `date_modified − date_added` reproduces the duration, giving a free
   internal consistency check.

### Scoring

| Signal | Weight | Why |
|---|---|---|
| Duration delta | **0.45** | Held to ~1 s across every observed pair. The strongest evidence available. |
| Timing (ring gap) | **0.35** | Must be positive and plausible. Orders candidates when durations are close. |
| Filename identity | **0.20** | Weakest, and scored **neutral (0.5) when absent** — so it can lift a match but never sink one. |

Hard gates that run before scoring: a call with `duration <= 0` can never have a
recording (this is what stops a neighbouring call's audio being stapled to a
missed call); duration delta > 15 s; ring gap outside −15 s…180 s.

`MATCHED` requires confidence ≥ 0.70 **and** a ≥ 0.15 margin over the runner-up.
Everything else becomes `AMBIGUOUS` — surfaced for review, never auto-associated.

### Why filenames are only a tie-breaker

The reference device carries **two different naming schemes at once**:

```
Call recording +917305739666_250611_092515.m4a   <- 2025 One UI builds
Call +918888787777_260820_125113.m4a             <- 2026 One UI builds
```

Same vendor, same phone. A filename parser written against either one silently
breaks on the other. Worse, the name half is the *contact name* where one
exists, so renaming a contact changes future filenames. Duration and timing are
stable; names are not.

---

## 3. On-device results

```
--- MATCH ---
  calls examined     : 60
  recordings in pool : 200
  connected calls    : 35

  MATCHED   : 35
  AMBIGUOUS : 0
  UNMATCHED : 0
  NOT_FOUND : 25          <- exactly the missed/rejected calls

  incoming call=   9s  rec=    8.4s  delta=0.64s  ring=  8s  conf=0.943
  incoming call=  10s  rec=   10.1s  delta=0.13s  ring=  4s  conf=0.988
  incoming call= 114s  rec=  114.0s  delta=0.05s  ring=  9s  conf=0.996
  incoming call=  45s  rec=   44.8s  delta=0.24s  ring= 14s  conf=0.978
  incoming call= 199s  rec=  199.1s  delta=0.14s  ring= 15s  conf=0.887
  incoming call=  68s  rec=   67.8s  delta=0.16s  ring= 12s  conf=0.986
```

Every connected call was associated against a pool of 200 candidate recordings.
Nothing landed in `AMBIGUOUS`, and no missed call picked up audio.

### Checksums

```
--- CHECKSUM ---
  sha256    : 46b88befa731ec2e...
  bytesRead : 136337  (MediaStore size 136337)
```

SHA-256 is computed **natively, streaming in 64 KB blocks**, so multi-megabyte
audio never crosses the platform channel just to be hashed. `bytesRead` is
returned alongside so a truncated or still-being-written file is caught before
upload bandwidth is spent on it. Hashing is deterministic across calls, which is
what makes server-side duplicate detection meaningful.

A recording deleted between scan and upload returns `null` rather than throwing —
a user clearing storage must not break the sync engine.

---

## 4. Second provider bug, same root cause

`MediaStore` rejects a trailing `LIMIT` in the sort order exactly as the call-log
provider does. The fix differs per provider:

| Provider | Correct row cap |
|---|---|
| `CallLog.Calls` | `LIMIT_PARAM_KEY` as a URI query parameter |
| `MediaStore.Audio` | `ContentResolver.QUERY_ARG_LIMIT` in a query-args `Bundle` (API 30+) |

Both were found by running on hardware, not by reading documentation.

---

## 5. Match status vocabulary

| Status | Meaning |
|---|---|
| `MATCHED` | One candidate wins clearly. Safe to associate and upload. |
| `AMBIGUOUS` | Plausible candidates, no clear winner — typically back-to-back calls of similar length. Held for review. |
| `UNMATCHED` | Candidates existed in the window; all were ruled out. |
| `NOT_FOUND` | No candidate at all. The correct, common outcome for a missed call or a device whose dialer is not recording. |

Upload states (`UPLOAD_PENDING` / `UPLOADED` / `UPLOAD_FAILED`) are tracked
separately, so a re-upload never disturbs a settled association.

---

## 6. What still needs proving

- **Other OEMs.** Only Samsung One UI is confirmed. `RecordingScanner`'s path
  list covers Xiaomi, Oppo/Realme/OnePlus and Vivo, but none are verified.
  Each needs one device and one run of this probe.
- **Outgoing calls.** Every matched sample above happened to be incoming. The
  model predicts outgoing behaves identically (ring gap becomes dial-to-answer
  time), but it is not yet demonstrated on real rows.
- **Ambiguity in the wild.** Zero ambiguous results here is a good sign, not
  proof; the back-to-back-similar-length case is covered by unit test rather
  than field data.
- **Dialer recording is a per-device setting.** If an employee turns call
  recording off in the system dialer, this app discovers nothing and must say so
  plainly rather than reporting an error.

---

## 7. Reproducing

```bash
flutter test test/unit/recording_matcher_test.dart          # 15 tests, no device
flutter build apk --debug
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk
flutter test integration_test/recording_ingestion_test.dart -d <device>
```

The `-g` matters: `flutter test` reinstalls, and a reinstall of a *changed* APK
drops previously granted permissions — which turns the probes into no-ops that
still report "pass".

No raw phone number, contact name or recording filename reaches stdout. Recording
filenames embed contact names, so they are masked to `Call ***_260828_131859.m4a`,
keeping the timestamp (evidence) and dropping the identity.
