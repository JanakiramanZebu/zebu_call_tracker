#!/usr/bin/env bash
# Production builds through Shorebird. Use this instead of calling
# `shorebird release` / `shorebird patch` by hand.
#
#   scripts/shorebird.sh release            # new APK to hand out (native or Dart changes)
#   scripts/shorebird.sh patch [staging]    # Dart-only over-the-air fix (default track: stable)
#
# What it guarantees, each of which a hand-typed command can get wrong:
#   - API_BASE_URL comes from env/production.json. A patch built without it
#     ships an app whose Dart side has no server (AppConfig.hasServer false).
#   - The Flutter version is pinned to the one the project builds with, so a
#     patch is compiled by the same toolchain as its release.
#   - The artifact is an APK: READ_CALL_LOG keeps the app off Play, so it is
#     distributed internally (docs/feasibility.md §2.6).
#   - A release is refused when android/key.properties is missing, because
#     build.gradle.kts would silently sign it with this machine's debug key and
#     no later build from another machine could update it.
#   - A patch never passes --allow-native-diffs. The capture and upload
#     pipeline is Kotlin, which Shorebird cannot patch: a Kotlin change needs a
#     release, and forcing a patch would ship Dart that expects native code the
#     installed APK does not have.
set -euo pipefail

FLUTTER_VERSION="3.38.6"
ENV_FILE="env/production.json"

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "$ENV_FILE is missing (see env/README.md)."
grep -q '"API_BASE_URL": *"https://' "$ENV_FILE" \
  || die "$ENV_FILE must set API_BASE_URL to an https:// address."
grep -q 'example.com' "$ENV_FILE" && die "$ENV_FILE still holds the example URL."

# Gradle fails on this machine's default JDK 25.
if [ -d "/c/Program Files/Java/jdk-17" ]; then
  export JAVA_HOME="/c/Program Files/Java/jdk-17"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

# Generated and gitignored; a debug build leaves a copy that breaks release
# builds (env/README.md, "Known trap").
rm -f android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java

case "${1:-}" in
  release)
    [ -f android/key.properties ] \
      || die "android/key.properties is missing; refusing to sign a production release with the debug key."
    shorebird release android \
      --flutter-version="$FLUTTER_VERSION" \
      --artifact=apk \
      --dart-define-from-file="$ENV_FILE"
    echo
    echo "Distribute build/app/outputs/flutter-apk/app-release.apk."
    echo "Patches only reach phones running THIS APK, not one built with 'flutter build'."
    ;;
  patch)
    track="${2:-stable}"
    shorebird patch android \
      --release-version=latest \
      --track="$track" \
      --dart-define-from-file="$ENV_FILE"
    ;;
  *)
    die "usage: scripts/shorebird.sh release | patch [staging|beta|stable]"
    ;;
esac
