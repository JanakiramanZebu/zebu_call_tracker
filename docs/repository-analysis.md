# STEP 1 — Repository Analysis

Date: 2026-08-28 · Project: `zebu_call_tracker` · Path: `C:\Users\Zebu\Projects\zebu_call_tracker`

## 1.1 Starting point

There was **no existing call-tracking repository**. The brief assumed a project to
inspect; none existed, so the inspection below covers (a) the toolchain actually
installed on this machine, and (b) the sibling Flutter apps whose conventions this
project deliberately inherits. The project was then created fresh.

Existing Flutter projects on this machine:

| Project | Purpose | Relevance |
|---|---|---|
| `C:\Users\Zebu\Projects\zebu_helpdesk` | osTicket `/api/v2` staff client | Source of the adopted stack: riverpod + dio + go_router + flutter_secure_storage; `in.mynt.*` namespace; `key.properties` release-signing pattern |
| `C:\Users\Zebu\Projects\zebu_events` | Trading-class income/expense tracker | Minor; riverpod + shared_preferences only |

Neither is a base to extend — this is a greenfield app.

## 1.2 Toolchain (verified, not assumed)

| Component | Version | Notes |
|---|---|---|
| Flutter | 3.38.6 (stable) | `C:\flutter_3_38` |
| Dart | 3.10.7 | pins `meta` **1.17.0** — this constrains drift (see 1.5) |
| Android SDK | 36.1.0, platform **android-36** | android-37 **not installed** |
| AGP | 8.11.1 | from `android/settings.gradle.kts` |
| Kotlin Gradle Plugin | 2.2.20 | |
| Gradle | 8.14 | |
| JDK | OpenJDK 21 (Android Studio bundled) | |
| Test device | SM-M356B (Samsung M35), **Android 16 / API 36**, adb over Wi-Fi | Critical: this is a post-API-29 device — see feasibility report |

`flutter doctor -v`: no issues.

## 1.3 What was created

```
zebu_call_tracker/
├── lib/
│   ├── core/          constants errors network storage permissions
│   │                  security utils config logging
│   ├── features/      authentication call_tracking call_logs recording
│   │                  synchronization settings device   (each: data/domain/presentation)
│   └── shared/        widgets models services
├── android/app/src/main/kotlin/in/mynt/zebu_call_tracker/
│   └── call/ recording/ background/ permissions/ platform/ util/
├── env/               .env.example (tracked) · .env.dev (ignored)
├── docs/              repository-analysis.md · feasibility.md
└── test/              unit/ integration/
```

- Application ID / namespace: `in.mynt.zebu_call_tracker` (matches `zebu_helpdesk`'s `in.mynt.*`).
- Platforms generated: **android + ios**. iOS is scaffolded for build parity only; see the
  feasibility report for why it cannot carry this feature set.

## 1.4 Android configuration applied

- `minSdk = 24` (was `flutter.minSdkVersion`). Floor set by `flutter_secure_storage`
  (EncryptedSharedPreferences, 23+) and stable `CallLog`/`PhoneStateListener` behaviour.
- Core-library desugaring enabled (`desugar_jdk_libs 2.1.5`) for `java.time` on API < 26.
- Release signing reads `android/key.properties`, falling back to debug signing when absent
  (same pattern as `zebu_helpdesk`), so a fresh clone still builds.
- R8 minify + resource shrinking enabled for release. **Verified by an actual release build**,
  not assumed.
- `network_security_config.xml`: `cleartextTrafficPermitted="false"` for all domains including
  debug, so a mis-set `API_BASE_URL` fails loudly instead of leaking call metadata over HTTP.
- Manifest permissions declared with a per-permission rationale comment. Nothing speculative:
  every entry maps to a subsystem in the feasibility matrix.

## 1.5 Dependency resolution — three real conflicts found and resolved

These were discovered by building, not by reading changelogs. All three are version
**holds**, documented inline in `pubspec.yaml`:

1. **drift / drift_dev pinned to exactly `2.28.0`.**
   `drift_dev >= 2.34.2` requires `meta ^1.18.0`, but Flutter 3.38.6 pins `meta 1.17.0` →
   unresolvable. Going below 2.32 means `sqlite3` 2.x, which rules out `drift_flutter`
   (needs `sqlite3` 3.x). 2.28.0 is the newest pair satisfying both ends.
2. **`sqlite3_flutter_libs` held at `0.5.41`.** `pub add` initially resolved `0.6.0+eol`,
   which is an **empty no-op package** — it ships no native SQLite at all and only applies
   after migrating to `sqlite3` 3.x. Shipping it with drift 2.28 would have produced an app
   that fails to open its database at runtime.
3. **`permission_handler` held at `^12.0.1`, `flutter_secure_storage` at `^10.3.1`.**
   `permission_handler_android 14.0.0` declares AGP 9.0.1 / Kotlin 2.3.20 / `compileSdk 37`;
   `flutter_secure_storage 11.0.0` also needs `android-37`. Both break against AGP 8.11.1 and
   the installed android-36 platform. 10.3.1 is the version already in production in
   `zebu_helpdesk`.

Adopted stack: `flutter_riverpod` · `dio` · `go_router` · `flutter_secure_storage` ·
`shared_preferences` · `connectivity_plus` · `drift` + `sqlite3_flutter_libs` ·
`permission_handler` · `device_info_plus` · `package_info_plus` · `path_provider` ·
`crypto` · `uuid` · `phone_numbers_parser` · `intl` · `collection`.
Dev: `drift_dev` · `build_runner` · `mocktail` · `flutter_lints`.

**Not yet added, deliberately:** a background-work package. `workmanager`'s published
versions have known compatibility churn against current AGP, and the background design
(§16 of the brief) leans on native `WorkManager` from Kotlin anyway. This is decided at
STEP 3, not guessed at now.

## 1.6 Pre-existing state carried over

- Authentication: **none exists.** To be built (`features/authentication`).
- API layer: **none exists.** To be built (`ApiClient` + repositories over dio).
- Local database: **none exists.** drift chosen; schema at STEP 3.
- Screens: only the generated counter app in `lib/main.dart` — placeholder, to be replaced.

## 1.7 Conflicts / risks identified

| # | Risk | Impact |
|---|---|---|
| 1 | Test device runs **Android 16 (API 36)** | Call recording is unavailable on it. Any recording work must be validated on a genuinely permissive device, or it is untestable. See feasibility §2.4. |
| 2 | `READ_CALL_LOG` is a Play-restricted permission | Forces internal/managed distribution. Confirmed compatible with the brief's §30. |
| 3 | drift pinned to a narrow window | A Flutter SDK upgrade that raises `meta` unblocks it; until then, do not bump drift casually. |
| 4 | Samsung/OEM battery management | Can kill the process and suppress `BOOT_COMPLETED`. Mitigation is a design input, not an afterthought. |
| 5 | R8 + drift/dio reflection | Release build verified; re-verify after adding native platform channels. |

## 1.8 Build verification

| Check | Result |
|---|---|
| `flutter analyze` | **No issues found** |
| `flutter build apk --debug` | **Succeeded** |
| `flutter build apk --release` (R8 + resource shrinking) | **Succeeded** — 45.5 MB |
