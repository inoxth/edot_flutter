group = "co.inoxth.inoxth_edot_flutter"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "co.inoxth.inoxth_edot_flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Pinned exactly per ADR-0001, matching the React Native SDK (Fleet Alignment).
    //
    // Do not bump these casually. Newer agent-sdk releases raise the minSdk floor
    // above 24, which is a hard platform requirement for this Plugin.
    //
    // Note: ADR-0001 cites the Kotlin 2.1.x line as part of the rationale for
    // 1.1.0. That constraint came from stock React Native's toolchain and does
    // not bind here — Flutter 3.44 supplies a newer Kotlin, which compiles
    // against this agent fine. The minSdk 24 floor and Fleet Alignment are the
    // reasons the pin stands.
    implementation("co.elastic.otel.android:agent-sdk:1.1.0")
    implementation("io.opentelemetry:opentelemetry-api:1.51.0")
    // Needed for Resource, to set both deployment.environment spellings through
    // the Agent's resource interceptor. Same version as the API pin above.
    implementation("io.opentelemetry:opentelemetry-sdk:1.51.0")

    // Native crash reporting is deliberately absent (ADR-0009). Android's
    // instrumentation discovery installs everything on the classpath with no
    // runtime opt-out, so shipping crash-library here would make it
    // unconditional. Do not add it.

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
