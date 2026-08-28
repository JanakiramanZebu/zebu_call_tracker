# STEP 2 — Platform Feasibility Report

Scope: what this app can *actually* do on real devices, as opposed to what packages
advertise. Verified against Flutter 3.38.6 / AGP 8.11.1 / android-36, targeting a fleet
that includes the on-hand Samsung SM-M356B running **Android 16 (API 36)**.

Legend: **SUPPORTED** · **PERMISSION REQUIRED** · **DEVICE DEPENDENT** · **RESTRICTED**
(policy/distribution-gated) · **NOT AVAILABLE**

---

## 2.1 Feature matrix

| Feature | Android | iOS | Notes |
|---|---|---|---|
| Incoming call detection | **PERMISSION REQUIRED** | **NOT AVAILABLE** | Android: manifest `PHONE_STATE` receiver (exempt from implicit-broadcast limits) + `READ_PHONE_STATE`. iOS: `CXCallObserver` only fires while the app process is alive; no background wake for cellular calls. |
| Outgoing call detection | **PERMISSION REQUIRED** (post-hoc) | **NOT AVAILABLE** | `NEW_OUTGOING_CALL` / `PROCESS_OUTGOING_CALLS` was deprecated at API 29 and is default-dialer-only. Outgoing calls are detected from the `OFFHOOK -> IDLE` transition and **confirmed from the call log after the call ends**, not at dial time. |
| Missed call detection | **PERMISSION REQUIRED** | **NOT AVAILABLE** | `CallLog.Calls.MISSED_TYPE`. A live `RINGING -> IDLE` transition is a hint only; the log is authoritative. |
| Call start / end timestamps | **SUPPORTED** | **NOT AVAILABLE** | `CallLog.Calls.DATE` + `DURATION`. Live state transitions give a fast provisional start; the log gives reconciled truth. |
| Call duration | **SUPPORTED** | **NOT AVAILABLE** | Always taken from `CallLog.Calls.DURATION` — never computed from broadcast timing alone, which is delayed and reordered. |
| Phone number capture | **PERMISSION REQUIRED** | **NOT AVAILABLE** | From API 28 the number in the `PHONE_STATE` broadcast requires `READ_CALL_LOG` *in addition to* `READ_PHONE_STATE`. Private/withheld numbers arrive empty — stored as `unknown`, record still created. |
| Call direction | **SUPPORTED** | Partial | Android: `CallLog.Calls.TYPE`. iOS: `CXCall.isOutgoing` only, with no number attached. |
| Call status | **SUPPORTED** | **NOT AVAILABLE** | Derived by the state machine, reconciled against the log. |
| Call log read | **PERMISSION REQUIRED** + **RESTRICTED** | **NOT AVAILABLE** | `READ_CALL_LOG` is an ordinary OS runtime permission but a **Google Play restricted permission** — Play grants it only to default dialer/assistant apps. Forces internal distribution. iOS exposes no cellular call log API at all. |
| Contact resolution | **PERMISSION REQUIRED** | n/a | `READ_CONTACTS` -> `PhoneLookup`. Denial is non-fatal: `contactName = null`. |
| Dual-SIM / subscription | **DEVICE DEPENDENT** | **NOT AVAILABLE** | `CallLog.Calls.PHONE_ACCOUNT_ID` -> `SubscriptionManager` for slot + carrier. Absent or non-mappable on some OEMs; the single-SIM path must never depend on it. |
| **Cellular call recording** | **NOT AVAILABLE** (see 2.4) | **NOT AVAILABLE** | The most important finding in this report. |
| Background sync | **SUPPORTED** | Partial | Android `WorkManager` with network constraints. iOS `BGProcessingTask` is best-effort and cannot be relied on. |
| Device reboot recovery | **DEVICE DEPENDENT** | **NOT AVAILABLE** | `RECEIVE_BOOT_COMPLETED` works, but only if the app is not in the "stopped" state, and OEM autostart managers (Xiaomi, Oppo/Realme, Vivo, Huawei; Samsung to a lesser degree) can suppress it. |
| Offline queue + retry | **SUPPORTED** | **SUPPORTED** | Pure app-layer; no platform constraint. |
| Secure token storage | **SUPPORTED** | **SUPPORTED** | Android Keystore / iOS Keychain via `flutter_secure_storage`. |

---

## 2.2 Verdict on iOS

**iOS cannot deliver this product.** This is a platform gap, not a package gap:

- No API exposes the cellular call log. CallKit has no read interface for it.
- `CXCallObserver` reports only `isOutgoing` / `hasConnected` / `hasEnded` plus an opaque
  UUID. It **never exposes the remote phone number** for a cellular call.
- It delivers events only while the app process is alive. There is no background launch on
  an incoming cellular call, so a backgrounded or terminated app misses calls entirely.
- Recording a cellular call is impossible, and would be an App Store rejection regardless.

**Recommendation:** ship Android only. The iOS target stays in the repo so the project builds
and the shared Dart layers stay platform-clean, but it should offer login plus a read-only
view of server-side data — never claim to track calls. Do not spend budget there.

---

## 2.3 How Android call detection will actually work

The reliable design is **not** "listen to a callback and write a record". It is two-stage:

```
PHONE_STATE broadcast  ──▶  wakes the process, records a provisional transition
      (fast, lossy)              (RINGING / OFFHOOK / IDLE + timestamp)
                                            │
                          on IDLE, enqueue an expedited WorkManager job
                                            │
                                            ▼
                       CallLog query for rows newer than the sync cursor
                            (authoritative: number, type, duration)
                                            │
                                            ▼
                   reconcile -> deterministic idempotency key -> DB -> upload
```

Why this shape:

- The `PHONE_STATE` broadcast is delayed, duplicated and reordered in practice, and carries
  no duration. Trusting it alone produces wrong durations and phantom records.
- The system writes the call log *after* the call ends, so it must be read on a short delay
  following `IDLE`, with a bounded retry — not immediately.
- A `ContentObserver` on `CallLog.Calls` cannot wake a dead process, so it is a
  foreground-only optimisation, never the primary path.
- On Android 12+, starting a foreground service from a background broadcast is restricted.
  Expedited `WorkManager` is the compliant mechanism; a foreground service is used **only**
  for an in-flight upload batch, never as a keepalive.

Idempotency key (brief §28):
`sha256(deviceId | normalizedNumber | callLogDateMs | direction)` — computed from **call-log**
fields rather than broadcast timing, so the same call yields the same key across process
death, reboot, and manual retries.

---

## 2.4 Call recording — the hard finding

**A normal third-party app cannot record cellular call audio on Android 10 (API 29) or
newer. That covers every device in a modern fleet, including the on-hand SM-M356B (API 36).**

- `AudioSource.VOICE_CALL` / `VOICE_DOWNLINK` / `VOICE_UPLINK` require
  `CAPTURE_AUDIO_OUTPUT`, which is `signature|privileged` — grantable only to system or
  preinstalled apps.
- The `MIC` fallback does not work either: from Android 10 the platform silences microphone
  input to non-privileged apps while a call is active. The result is a valid-looking audio
  file containing silence. **Producing that file and calling it a recording is precisely the
  "fake recording" the brief forbids**, so this app will not do it.
- Accessibility-service based capture cannot reach the far-end audio and is an explicit
  Google Play policy violation.

Any pub.dev package claiming general call recording is doing one of three things: MIC capture
that yields silence on modern Android, scraping an OEM dialer's output files, or supporting
only pre-Android-10 devices.

### Compliant options, in order of recommendation

| # | Approach | Works on API 29+ | Cost / constraint |
|---|---|---|---|
| **A** | **Ship without recording.** Full call metadata, no audio. | Yes | None. Delivers the large majority of the product immediately. |
| **B** | **Harvest the OEM dialer's own recordings.** Samsung/Xiaomi/Realme system dialers can auto-record to disk; read those files, match them to call-log rows by timestamp, upload. | Device dependent | Needs `MANAGE_EXTERNAL_STORAGE` (All files access) -> internal distribution only. Paths and formats differ per OEM and break across OS updates. Recording must be switched on in the system dialer on each device. Fragile, but real. |
| **C** | **Privileged/system app** via device-owner MDM enrolment or an OEM ROM partnership, granting `CAPTURE_AUDIO_OUTPUT`. | Yes | Requires OEM/ROM cooperation or platform signing. The only fully reliable route, and by far the most expensive. |
| **D** | **Move business calls to VoIP** (`ConnectionService` / WebRTC). The app owns the audio path, so recording is legitimate and uniform across devices. | Yes | Changes the calling model and needs a telephony/SIP backend. Highest-quality result if the business can adopt it. |

### What the app does regardless of the choice

`RecordingCapabilityService` probes at runtime and returns one of
`supported` / `permissionRequired` / `deviceUnsupported` / `osRestricted` / `disabledByConfig`.
When recording is unavailable the app **stores `recordingStatus = unavailable` together with
the reason, keeps collecting metadata, and never fabricates a file**. `ENABLE_RECORDING` in
the env config defaults to `false`.

**This is a decision needed before STEP 3**, because option B changes the permission set and
the distribution story, and option D changes the product itself.

---

## 2.5 Consent and legal

Call-recording consent is jurisdiction-dependent (in India, one-party consent covers a
participant, but employee monitoring additionally requires disclosure). If option B, C or D
is chosen, the app must ship an in-app consent record and a persistent recording indicator,
and legal/HR sign-off must precede deployment. Metadata-only collection (option A) still
requires employee notice under most workplace-privacy regimes. This is a business decision
that gates the recording subsystem — flagging it, not deciding it.

---

## 2.6 Distribution consequence

`READ_CALL_LOG` (and `MANAGE_EXTERNAL_STORAGE` under option B) are Play-restricted. The app
therefore ships via **internal APK distribution or a managed Android Enterprise / MDM
channel**, consistent with brief §30. It cannot go on the public Play Store, and no part of
the design attempts to work around that.

---

## 2.7 Recommendation

Proceed with **option A** for v1: complete, reliable, offline-first call *metadata* tracking
with idempotent sync — everything in the matrix marked SUPPORTED or PERMISSION REQUIRED.
Build the recording subsystem behind `RecordingCapabilityService` so option B can be added
per-OEM later without touching the sync engine, and evaluate option D separately if audio
proves to be a hard business requirement.
