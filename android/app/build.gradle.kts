import groovy.json.JsonSlurper
import java.util.Properties
import org.gradle.api.GradleException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}


val localProperties = Properties().apply {
    val localFile = rootProject.file("local.properties")
    if (localFile.exists()) {
        localFile.inputStream().use { load(it) }
    }
}

// This Gradle property controls the Android namespace/applicationId.
// A Dart define with the same name does not change the Android package.
val appId = providers.gradleProperty("FRIENDIFY_APP_ID")
    .orElse(localProperties.getProperty("friendify.appId") ?: "com.powerx.friendify")
    .get()

val isReleaseBuildRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}

val googleServicesFile = project.file("google-services.json")
data class FirebaseAndroidClientInfo(
    val packageName: String,
    val appId: String,
)

val googleServicesAndroidClients = if (googleServicesFile.exists()) {
    val parsed = JsonSlurper().parseText(googleServicesFile.readText()) as? Map<*, *>
    val rawClients: List<*> = (parsed?.get("client") as? List<*>) ?: emptyList<Any?>()
    rawClients.mapNotNull { rawClient ->
        val client = rawClient as? Map<*, *> ?: return@mapNotNull null
        val clientInfo = client["client_info"] as? Map<*, *> ?: return@mapNotNull null
        val androidClientInfo = clientInfo["android_client_info"] as? Map<*, *> ?: return@mapNotNull null
        val packageName = androidClientInfo["package_name"]?.toString()?.trim().orEmpty()
        val appId = clientInfo["mobilesdk_app_id"]?.toString()?.trim().orEmpty()
        if (packageName.isBlank() || appId.isBlank()) {
            null
        } else {
            FirebaseAndroidClientInfo(packageName = packageName, appId = appId)
        }
    }
} else {
    emptyList<FirebaseAndroidClientInfo>()
}
val googleServicesPackageNames = googleServicesAndroidClients.map { it.packageName }.distinct().sorted()
val googleServicesMatchingClients = googleServicesAndroidClients.filter { it.packageName == appId }
val googleServicesExamplePackageNames = googleServicesPackageNames.filter { it.startsWith("com.example") }

val firebaseOptionsFile = rootProject.projectDir.parentFile.resolve("lib/firebase_options.dart")
val firebaseOptionsText = if (firebaseOptionsFile.exists()) {
    firebaseOptionsFile.readText()
} else {
    ""
}

if (isReleaseBuildRequested && appId.startsWith("com.example")) {
    throw GradleException(
        "Release build blocked: set ORG_GRADLE_PROJECT_FRIENDIFY_APP_ID " +
            "(or friendify.appId in android/local.properties) to the final package name, " +
            "replace android/app/google-services.json, regenerate lib/firebase_options.dart, " +
            "and stop using com.example.* before shipping."
    )
}

if (isReleaseBuildRequested && !googleServicesFile.exists()) {
    throw GradleException(
        "Release build blocked: android/app/google-services.json is missing. " +
            "Download the Firebase Console file for com.powerx.friendify first."
    )
}

if (isReleaseBuildRequested && googleServicesAndroidClients.isEmpty()) {
    throw GradleException(
        "Release build blocked: android/app/google-services.json does not contain any readable Android client entries. " +
            "Replace it with the Firebase Console file for com.powerx.friendify."
    )
}

if (isReleaseBuildRequested && googleServicesMatchingClients.isEmpty()) {
    throw GradleException(
        "Release build blocked: android/app/google-services.json does not contain an Android client for applicationId '$appId'. " +
            "Found package_name entries: ${googleServicesPackageNames.joinToString(", ")}. Replace the file with the Firebase Console file for $appId " +
            "and rerun flutterfire configure."
    )
}

if (isReleaseBuildRequested && googleServicesMatchingClients.size > 1) {
    throw GradleException(
        "Release build blocked: android/app/google-services.json contains multiple Android clients for applicationId '$appId'. " +
            "Keep only one matching Firebase Android app registration before shipping."
    )
}

if (isReleaseBuildRequested && googleServicesExamplePackageNames.isNotEmpty()) {
    throw GradleException(
        "Release build blocked: android/app/google-services.json still contains stale example Android client(s): " +
            googleServicesExamplePackageNames.joinToString(", ") +
            ". Replace the file with the Firebase Console file for $appId before shipping."
    )
}

if (
    isReleaseBuildRequested &&
    (
        firebaseOptionsText.contains("REGENERATION REQUIRED:") ||
            firebaseOptionsText.contains("REGENERATE_WITH_FLUTTERFIRE") ||
            firebaseOptionsText.contains("pre-migration setup")
        )
) {
    throw GradleException(
        "Release build blocked: lib/firebase_options.dart is still marked as stale pre-migration config. " +
            "Run flutterfire configure --project=friendify-ef682 --platforms=android after replacing " +
            "android/app/google-services.json."
    )
}

val keystoreProperties = Properties().apply {
    val keystoreFile = rootProject.file("key.properties")
    if (keystoreFile.exists()) {
        keystoreFile.inputStream().use { load(it) }
    }
}

if (isReleaseBuildRequested && keystoreProperties.isEmpty) {
    throw GradleException(
        "Release build blocked: android/key.properties is missing. " +
            "Create it locally with storeFile, storePassword, keyAlias, and keyPassword " +
            "before building a signed release."
    )
}

android {
    namespace = appId
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = appId
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        if (!isReleaseBuildRequested) {
            ndk {
                // Manual audit phones are arm64. Keep debug APK installs small.
                abiFilters += listOf("arm64-v8a")
            }
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            if (!isReleaseBuildRequested) {
                excludes += setOf(
                    "lib/x86/**",
                    "lib/x86_64/**",
                    "lib/armeabi/**",
                    "lib/armeabi-v7a/**"
                )
            }
            if (isReleaseBuildRequested) {
                keepDebugSymbols += setOf(
                    "**/libagora*.so",
                    "**/libaosl.so",
                    "**/libvideo_dec.so"
                )
            }
        }
    }

    buildTypes {
        debug {
            ndk {
                // Local audit phones are arm64. Avoid building/installing
                // unused x86 and 32-bit native debug libraries on every run.
                abiFilters += listOf("arm64-v8a")
                // Full native symbols make local debug builds much heavier,
                // especially with Agora and other native plugins. Keep the
                // release build on FULL, but make debug iteration lighter.
                debugSymbolLevel = "SYMBOL_TABLE"
            }
        }

        release {
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.create("release") {
                    keyAlias = keystoreProperties.getProperty("keyAlias")
                    keyPassword = keystoreProperties.getProperty("keyPassword")
                    storeFile = file(keystoreProperties.getProperty("storeFile"))
                    storePassword = keystoreProperties.getProperty("storePassword")
                }
            } else {
                null
            }
            isMinifyEnabled = true
            isShrinkResources = true
            ndk {
                debugSymbolLevel = "FULL"
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:33.16.0"))
    implementation("com.google.firebase:firebase-messaging")
}

flutter {
    source = "../.."
}
