pluginManagement {
    val quarkusPluginVersion: String by settings
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
    plugins {
        id("io.quarkus") version quarkusPluginVersion
    }
}

plugins {
    // lets Gradle download a JDK 25 for the toolchain when the local JDK is older
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

rootProject.name = "ai-platform-demo"

include("frontend", "rag-service", "model-router", "orders-service", "projection-service",
        "coffee-shop", "coffee-menu")
