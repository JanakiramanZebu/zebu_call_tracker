# Per-environment build configuration

`API_BASE_URL` is the only build-time setting this app reads. Supply it with
either form:

```sh
flutter build apk --release --dart-define=API_BASE_URL=https://calls.mynt.in
flutter build apk --release --dart-define-from-file=env/production.json
```

Copy `example.json` to `dev.json`, `staging.json` or `production.json` and fill
it in. Everything except `example.json` is gitignored.

## Rules

- **Never put a secret in here.** These values are compiled into the APK and are
  readable by anyone who unzips it.
- **`https://` for anything but local development.** The Android manifest sets
  `usesCleartextTraffic="false"`, so a release build given an `http://` address
  cannot make a single request. `AppConfig` reports that as a configuration
  error rather than letting the build look healthy and fail on the handset.
- **A release build with no `API_BASE_URL` is a broken build.** There is no
  default. `AppConfig.hasServer` answers `false`, the sign-in screen refuses to
  submit, and it says why.

The `/api/v1` suffix is optional — `AppConfig` appends it if it is missing.

## History

These files used to be `.env.dev` / `.env.example` in dotenv format, listing
`API_TIMEOUT_MS`, `UPLOAD_TIMEOUT_MS`, `MAX_RETRY_COUNT`, `ENABLE_RECORDING`,
`ENABLE_BACKGROUND_SYNC` and `LOG_LEVEL`. Nothing in the app ever read any of
them, in either format — Flutter has no built-in dotenv support, and no loader
was wired up. They are gone rather than reinstated, because six settings that
look configurable but are not are worse than none. Add one back here only
together with the code that reads it.

## Known trap: release build fails after a debug build

```
GeneratedPluginRegistrant.java:44: error:
package dev.flutter.plugins.integration_test does not exist
```

`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` is
a generated, gitignored artifact. A **debug** build writes it with
`integration_test` included (it is a `dev_dependencies` entry); a **release**
build does not regenerate it when the plugin set looks unchanged, so it tries to
compile the debug version against a classpath that has no `integration_test`.

Delete it first and the release build regenerates it correctly:

```sh
rm -f android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java
flutter build apk --release --dart-define-from-file=env/production.json
```

Verified: a release build with the file absent regenerates it with all 13
runtime plugins and no `integration_test`, and the class is present in the
release APK's dex. `flutter clean` also clears it, more slowly.

The durable fixes are to drop `integration_test` from `dev_dependencies` (which
means deleting `integration_test/`) or to wrap release builds in a script. Both
are decisions for the team rather than something to change silently.
