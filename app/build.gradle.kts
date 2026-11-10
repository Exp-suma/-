plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.photobridge"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.photobridge"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            // 開発用ビルド。偽装位置(mock)を受け入れてテストできる。
            buildConfigField("boolean", "ALLOW_MOCK", "true")
        }
        release {
            // 配布用ビルド。mock は常に拒否。これを解除する隠し経路は一切持たせない。
            isMinifyEnabled = false
            buildConfigField("boolean", "ALLOW_MOCK", "false")
        }
        create("releaseTest") {
            // release に近い状態(最適化・署名)で、mock を受け入れて検証するためだけのビルド。
            // 配布する release とは別アプリ(.test)としてインストールされ、配布版には影響しない。
            initWith(getByName("release"))
            applicationIdSuffix = ".test"
            versionNameSuffix = "-test"
            signingConfig = signingConfigs.getByName("debug") // インストール可能にするため
            buildConfigField("boolean", "ALLOW_MOCK", "true")
            matchingFallbacks += listOf("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
