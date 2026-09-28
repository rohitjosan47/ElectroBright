import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. The previous app was released with the debug key of the
// development Mac; Android only upgrades an installed app when the signing
// certificate matches, so release builds use a backed-up copy of that key.
// `android/key.properties` is git-ignored. Without it a release build fails:
// signed with another key, the APK could never upgrade the installed app.
// `-PallowDebugSigning` (flutter: `--android-project-arg=allowDebugSigning=true`)
// signs with the local debug key anyway, for a build that is never published.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keyProperties.getProperty("storeFile") != null
val allowDebugSigning = project.hasProperty("allowDebugSigning")

gradle.taskGraph.whenReady {
    val releaseTasks = allTasks.filter {
        it.project == project && Regex("^(assemble|bundle|package|sign)Release.*").matches(it.name)
    }
    if (releaseTasks.isNotEmpty() && !hasReleaseKey && !allowDebugSigning) {
        throw GradleException(
            "Release build without the upgrade key: android/key.properties is missing " +
                "(see docs/release.md, section 4). A release signed with any other " +
                "key cannot upgrade the installed app. For an unpublished test build, pass " +
                "--android-project-arg=allowDebugSigning=true to sign with the debug key.",
        )
    }
}

android {
    namespace = "com.electrobright.electrobright_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Same id as the previous app so v2 installs as an upgrade.
        applicationId = "com.electrobright.electrobright_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Debug key only when explicitly allowed (checked above).
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Needed by MainApplication's RxJava error handler (see flutter_reactive_ble
    // README, "BLE undeliverable exception"); versions match reactive_ble_mobile.
    implementation("io.reactivex.rxjava2:rxjava:2.2.21")
    implementation("com.polidea.rxandroidble2:rxandroidble:1.16.0")
    // Pigeon's generated Kotlin uses coroutines for @async host methods.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}

flutter {
    source = "../.."
}
