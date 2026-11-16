plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    implementation("androidx.core:core:1.13.1")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.24.1")
    implementation("org.opencv:opencv:4.13.0")
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    testImplementation("junit:junit:4.13.2")
}

android {
    // Opt in for local testing with -PchoirModelBundle=<zip path>.
    val modelBundle = providers.gradleProperty("choirModelBundle")
        .orElse(providers.environmentVariable("CHOIR_MODEL_BUNDLE"))
    if (modelBundle.isPresent) {
        val bundle = file(modelBundle.get())
        require(bundle.isFile) { "Model bundle does not exist: $bundle" }
        val generated = layout.buildDirectory.dir("generated/modelAssets")
        val copyModels = tasks.register<Copy>("copyBundledModels") {
            from(bundle)
            into(generated.map { it.dir("omr") })
            rename { "models.zip" }
        }
        sourceSets.getByName("main").assets.srcDir(generated.get().asFile)
        tasks.named("preBuild").configure { dependsOn(copyModels) }
    }
    namespace = "jp.choiromr.mobile"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "jp.choiromr.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 13+: on-device OMR needs recent hardware; also enables themed icons.
        minSdk = 33
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
