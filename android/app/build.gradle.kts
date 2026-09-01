import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config, loaded from android/key.properties (kept out of VCS).
// When the file is absent (fresh clone / CI without the secret) release builds
// fall back to debug signing so `flutter run --release` still works locally.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "in.mynt.zebu_call_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // java.time / WorkManager back-compat below API 26.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "in.mynt.zebu_call_tracker"
        // 24 is the floor for the call-tracking stack we rely on:
        //   - flutter_secure_storage (EncryptedSharedPreferences) needs 23+
        //   - PhoneStateListener / CallLog usage patterns are stable from 24
        // Raising it further would exclude fleet devices unnecessarily.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // ContextCompat.checkSelfPermission in the native permission inspector.
    implementation("androidx.core:core-ktx:1.13.1")
    // Background ingest. WorkManager rather than a bare foreground service:
    // Android 12+ forbids starting an FGS from a background broadcast, and
    // WorkManager owns the FGS lifecycle for expedited work, survives reboot,
    // and is the only scheduler the OEM battery managers on this fleet respect.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // EncryptedSharedPreferences for the background worker's auth session.
    // The Dart side already keeps its copy in flutter_secure_storage; without
    // this the native mirror of the same access and refresh tokens sat in a
    // world-of-root-readable plaintext XML file, which made the secure store
    // on the other side decorative.
    implementation("androidx.security:security-crypto:1.0.0")
}
