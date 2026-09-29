plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "org.toothbrush.collector.wear"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.toothbrush.collector"
        minSdk = 30
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
    }
    signingConfigs.getByName("debug") {
        storeFile = rootProject.file(".tools/debug.keystore")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].java.srcDir("../shared/src/main/java")
    sourceSets["main"].res.srcDir("../shared/src/main/res")
    buildFeatures { buildConfig = true }
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":core"))
    implementation("androidx.lifecycle:lifecycle-service:2.9.4")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("com.google.android.gms:play-services-wearable:19.0.0")
}
