# Native Access Verification — run on real hardware

**Device:** Samsung SM-M356B (Galaxy M35) · **Android 16 / API 36** · adb over Wi-Fi
**Date:** 2026-08-28 · **Result: 8/8 probes pass**

Reproduce with:

```bash
flutter build apk --debug
adb install -r -g build/app/outputs/flutter-apk/app-debug.apk   # -g grants runtime perms
flutter test integration_test/native_access_probe_test.dart -d <device-id>
```

> `-g` matters. `flutter test` reinstalls the APK, and a reinstall of a *changed*
> APK drops previously `pm grant`-ed permissions — which silently turns the
> call-log probes into no-ops that still report "pass". Install with `-g` first.

---

## What was proven

| Capability | Result | Evidence from the run |
|---|---|---|
| Flutter → Kotlin MethodChannel | **Works** | `samsung / SM-M356B / Android 16 (API 36)` returned across the bridge |
| Permission snapshot | **Works** | all five permissions round-tripped as typed booleans |
| Call log read | **Works** | **2000 rows** present on device; 10 fetched |
| Call direction | **Works** | `incoming` / `outgoing` correctly mapped from `CallLog.Calls.TYPE` |
| Phone number | **Works** | e.g. `+917******538` (masked in output by design) |
| Call duration | **Works** | `10s`, `114s`, `45s`, `199s`, `0s` — real values, not computed from broadcast timing |
| Call start time (UTC) | **Works** | `2026-08-28T04:25:29.223Z` — stored UTC, converted only for display |
| Number presentation | **Works** | `pres=allowed`; withheld/payphone numbers map to a null number with a reason, so the record survives |
| **Incremental cursor** | **Works** | rows newer than the newest known row: **0**. This is what stops re-uploading 2000 rows on every sync. |
| Newest-first ordering | **Works** | 50 rows verified monotonically descending |
| Dual SIM / subscription | **Partial (as predicted)** | `activeModemCount=2`, one active subscription: `slot 0, subId=1, carrier="Airtel \| Airtel FastLane", country=in`. Call-log rows carry `sim=1`, which joins to `subId=1`. |
| Contact resolution | **Works** | numbers resolved to contact names via `PhoneLookup`; an unmatched number returned `<none>` rather than throwing |
| Background receiver registration | **Works** | system resolves `in.mynt.zebu_call_tracker.call.CallStateReceiver`, `enabled=true exported=true priority=1000`, 1 of 10 apps listening for `PHONE_STATE` (Truecaller is another) |
| Recording capability | **Correctly refused** | see below |

### Real output (numbers masked in the probe itself)

```
--- CALL LOG ---
  rows on device : 2000
  fetched        : 10
  incoming  +917******538       10s  sim=1  pres=allowed  2026-08-28T04:25:29.223Z
  incoming  +917******538      114s  sim=1  pres=allowed  2026-08-28T04:23:06.239Z
  incoming  +917******538       45s  sim=1  pres=allowed  2026-08-28T04:07:04.613Z
  incoming  +919******446      199s  sim=1  pres=allowed  2026-08-27T16:11:11.047Z
  outgoing  +917******538        0s  sim=1  pres=allowed  2026-08-27T15:34:07.566Z
  rows newer than newest : 0 (expected 0)
```

The probe never prints a raw phone number or contact name — masking happens before
stdout, because test logs are not a safe home for call data (brief §26).

---

## Bug found and fixed by running on hardware

The first run failed with `NativeFailure(platformError: Invalid token LIMIT)`.

Modern Android's call-log provider validates the sort-order clause against SQL
injection and **rejects a trailing `LIMIT`**, so the common
`"DATE DESC LIMIT 100"` idiom — which appears in most call-log tutorials and in
several pub.dev packages — throws on API 30+. The row cap must go in the URI via
the documented `CallLog.Calls.LIMIT_PARAM_KEY` instead. Fixed in
`CallLogReader.read()`; the cap still applies at the SQL layer, so a device with
2000+ rows never materialises them all.

This is exactly the class of failure that only surfaces on a real device, and the
reason this probe exists.

---

## Recording — the feasibility finding, now confirmed empirically

```
--- RECORDING ---
  verdict : osRestricted
  reason  : Android 36 (API 36) blocks third-party capture of call audio.
            VOICE_CALL needs the privileged CAPTURE_AUDIO_OUTPUT permission,
            and MIC capture is silenced during calls.
```

`RECORD_AUDIO` was **granted** on this device and the verdict is still
`osRestricted` — because the blocker is the platform, not a permission. The probe
asserts that on API ≥ 29 the verdict must never be `supported`; claiming support
would mean shipping silent audio files as "recordings".

### Evidence for feasibility option B (harvest the OEM dialer's own recordings)

```
  oem dir MIUI/sound_recorder/call_rec : exists=false
  oem dir Recordings/Call              : exists=true  readable=true  files=0
  oem dir Sounds/CallRecord            : exists=false
  oem dir Record/Call                  : exists=false
  oem dir PhoneRecord                  : exists=false
```

**`Recordings/Call` exists and is readable on this Samsung device.** It is empty
because call recording is not switched on in the system dialer. That is a real,
concrete path for option B on Samsung hardware — but it needs confirming with
recording actually enabled, and `files=0` under scoped storage means "nothing
visible to us", which is not the same as "nothing there".

---

## Not yet proven — needs a real call

The background receiver is **registered and resolvable**, but firing it requires an
actual phone call. `adb shell am broadcast -a android.intent.action.PHONE_STATE` is
refused by the system: `PHONE_STATE` is a protected broadcast that only the platform
may send. That refusal is itself a useful security property — no third-party app can
inject fake call events into this receiver.

To close this gap, on the test device: make or receive one call, then run the probe
again and read the `CALL STATE JOURNAL` section. It should show the
`ringing → offhook → idle` transitions with `reconcilePending=true`.

---

## Conclusion

Every piece of call data the product needs — direction, number, contact name,
duration, start time, status, SIM attribution — **is reachable from Flutter through
the native bridge on a current Android 16 device**, incrementally and without
re-reading history.

Call *audio* is not, and no amount of engineering changes that from inside a normal
app. See [feasibility.md](feasibility.md) §2.4 for the four compliant alternatives.
