# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Zebu Call Tracker: an Android-only Flutter app that logs employees' work calls (made with the phone's own dialer) and their OEM dialer recordings, and uploads them to the Zebu CRM backend. Employees almost never open the app after pairing, so **everything that matters must work with the Flutter engine dead**. That is why the core pipeline is native Kotlin, not Dart.

The server (FastAPI backend, Vue admin console, and `docs/MOBILE_API.md`, the wire contract) lives in the sibling repo `D:\John\Zebu Projects\Zebu-calltrack`. When you need to know what the server accepts (enums, error codes, retry semantics), read that repo. Do not infer it from this client.

## Commands

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerate drift *.g.dart after editing tables/DAOs
flutter analyze
flutter test                                    # all unit tests (test/unit/)
flutter test test/unit/call_wire_format_test.dart
flutter test test/unit/sync_screen_test.dart --plain-name "<test name>"
```

Building: Gradle fails on this machine's default JDK 25, so point it at JDK 17 first:

```sh
export JAVA_HOME="/c/Program Files/Java/jdk-17"; export PATH="$JAVA_HOME/bin:$PATH"
flutter build apk --release --dart-define-from-file=env/production.json
(cd android && ./gradlew :app:compileReleaseKotlin)   # Kotlin-only check
```

- `API_BASE_URL` is the only build-time setting (see [env/README.md](env/README.md)). A release build without it is broken by design. Release builds need `https://`.
- If a release build fails with `package dev.flutter.plugins.integration_test does not exist` after a debug build, delete `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` and rebuild.
- Release builds use R8 (`isMinifyEnabled`). When touching reflection or JSON classes, build release and check `android/app/proguard-rules.pro`.
- FCM push is enabled only when `android/app/google-services.json` exists. The build still works without it.
- `integration_test/` holds on-device probes (native access, recording ingestion), not CI tests.

## Architecture

### Native owns capture and upload; Dart displays and corrects

Native code lives in `android/app/src/main/kotlin/in/mynt/zebu_call_tracker/`:
- `call/`: `CallStateReceiver` (manifest receiver for `PHONE_STATE`), `CallLogReader`, `CallEnrichment`, `CallWireFormat`.
- `background/`: `NativeCallIngestor` (call log → outbox), `SyncCoordinator`, WorkManager workers, `CallTrackingService` (always-on foreground service), `TokenRefresher`, `RateLimiter`, heartbeat and status check-in.
- `recording/`: `RecordingScanner` / `NativeRecordingMatcher`. These find audio the OEM dialer already wrote, via MediaStore + `READ_MEDIA_AUDIO`. The app has no recording engine (see [docs/recording-ingestion.md](docs/recording-ingestion.md)).
- `overlay/`: the native post-call card. It loads IBM Plex Sans from `flutter_assets`, so don't move `assets/fonts/`.
- `push/`: FCM `SYNC_REQUEST` wake-up.
- `platform/NativeBridge.kt`: the method/event channels (`in.mynt.zebu_call_tracker/native`, `.../overlay_events`, `.../call_events`). On the Dart side, only `lib/core/platform/native_call_bridge.dart` touches channels. Everything else depends on the `NativeCallBridge` interface.

[docs/sync-architecture.md](docs/sync-architecture.md) is the authoritative design doc. Read it before changing anything in the upload path. The rules it lays down:

- **`SyncCoordinator` is the only uploader.** No Dart code posts calls or recordings. Every trigger (call end, periodic WorkManager, FCM, boot, network restore, manual "Sync now") converges on `SyncCoordinator.runSync`. The foreground service only speeds things up; nothing may depend on it being alive.
- **One SQLite file, two writers.** `zebu_calls.sqlite` / table `local_calls` is opened by drift (`lib/core/storage/app_database.dart`) and by Kotlin's `ZebuDatabaseHelper` (`NativeCallOutboxDao.kt`). Drift runs on Android's **system** SQLite via `drift_sqflite`. Never bundle `sqlite3_flutter_libs`/`NativeDatabase`: two SQLite libraries on one file corrupted it.
- **Schema versions are locked together.** `AppDatabase.schemaVersion` and `ZebuDatabaseHelper.DATABASE_VERSION` must move together or not at all. Data fixes are idempotent `UPDATE`s run on every open from both sides, not schema migrations.
- **SQL must work on SQLite 3.32** (Android ≤13). No `RETURNING`/`insertReturning*`, `UPDATE … FROM`, JSON `->`/`->>`, or math functions.
- **Mirrored contracts.** Each of these pairs must change together: `lib/core/storage/sync_state.dart` ↔ `background/SyncStates.kt` (state vocabulary), and `lib/core/network/call_wire_format.dart` ↔ `call/CallWireFormat.kt` (direction/status derivation; the server rejects invalid combinations with a non-retryable 422).
- A call's `sync_state` and its `recording_upload_status` are independent. A call can be `UPLOADED` with its recording still pending or absent.
- Queue policy: newest first, 30-day backfill, 8-minute run budget, pacing at about 80% of the server rate limits (`RateLimiter.kt`).

### Auth

`POST /auth/refresh` rotates tokens, and replaying a rotated token revokes the whole session. So **`TokenRefresher.kt` is the only place that refreshes**. Dart's `ApiClient` asks it over the method channel, `IngestStore` is the store of record, and there is exactly one `ApiClient` (held by `apiClientProvider`). Pairing is `POST /mobile/register` only. The app intentionally has **no sign-out**: an employee change means the admin revokes the device, app data is cleared, and the new employee pairs again. Don't add a logout UI or an `/auth/logout` call.

### Flutter side

Riverpod 3 throughout. `lib/app.dart` `AppGate` routes between splash, login, permission onboarding and the home shell, and listens for session revocation. Code lives in `lib/features/<feature>/{data,domain,presentation}`. Shared infrastructure (network, storage, theme/design tokens, the native bridge) lives in `lib/core/`. The call-history screen reads the system call log directly, not the outbox table.

## Product constraints

- Capture and upload reliability come before battery life: the always-on service runs by default, recordings upload on any network (no Wi-Fi-only option), and recordings of every length must be matched. Don't trade reliability for battery without asking.
- UI should look like a professional Zebu product, not a generic template kit. HTML design mocks live in `design/`, and UI skills are in `.claude/skills/`. Get a design approved before restyling screens. The post-call card sits mid-screen and never auto-dismisses.
- Release builds silence `debugPrint` (logs carry phone numbers). Keep it that way.
