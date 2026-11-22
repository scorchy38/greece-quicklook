plugins {
    id("com.android.application") version "8.7.2"
    kotlin("android") version "2.0.21"
    id("com.google.devtools.ksp") version "2.0.21-1.0.27"
    alias(libs.plugins.compose.compiler)
}

android {
    namespace = "com.example.greece"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.greece"
        minSdk = 26
        targetSdk = 35
        versionCode = 42
        versionName = "1.6.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.11.00"))
    implementation(libs.androidx.navigation.compose)
    implementation(project(":protocol"))
    ksp("com.google.dagger:hilt-compiler:2.52")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}
