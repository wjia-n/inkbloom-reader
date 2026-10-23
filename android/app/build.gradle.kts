plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.reader.wajiha.inkbloom.app.book.read"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.reader.wajiha.inkbloom.app.book.read"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Stable release signing: CI restores the keystore from the
    // INKBLOOM_* secrets into INKBLOOM_STORE_FILE. Without it
    // (local builds), release falls back to the debug keys.
    // The stable key is what makes future updates install over
    // the old app with all books and progress intact, so the
    // user never has to back up or reinstall again.
    val inkbloomStoreFile = System.getenv("INKBLOOM_STORE_FILE")
        ?.let { file(it) }
        ?.takeIf { it.exists() && it.length() > 0 }
    signingConfigs {
        if (inkbloomStoreFile != null) {
            create("release") {
                storeFile = inkbloomStoreFile
                storePassword = System.getenv("INKBLOOM_STORE_PASSWORD")
                keyAlias = System.getenv("INKBLOOM_KEY_ALIAS")
                keyPassword = System.getenv("INKBLOOM_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (inkbloomStoreFile != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
