// Shared build logic for all services: Java 25, Quarkus platform BOMs, test setup.
plugins {
    id("io.quarkus") apply false
}

val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

subprojects {
    apply(plugin = "java")
    apply(plugin = "io.quarkus")

    group = "org.acme.aidemo"
    version = "1.0.0"

    repositories {
        mavenCentral()
        mavenLocal()
    }

    dependencies {
        "implementation"(enforcedPlatform("$quarkusPlatformGroupId:quarkus-bom:$quarkusPlatformVersion"))
        // every service: REST, health, metrics, tracing, JSON logs with trace ids
        "implementation"("io.quarkus:quarkus-rest-jackson")
        "implementation"("io.quarkus:quarkus-smallrye-health")
        "implementation"("io.quarkus:quarkus-micrometer-registry-prometheus")
        "implementation"("io.quarkus:quarkus-opentelemetry")
        "implementation"("io.quarkus:quarkus-logging-json")
        "testImplementation"("io.quarkus:quarkus-junit5")
        "testImplementation"("io.rest-assured:rest-assured")
    }

    extensions.configure<JavaPluginExtension> {
        toolchain { languageVersion.set(JavaLanguageVersion.of(25)) }
    }

    tasks.withType<JavaCompile>().configureEach {
        options.encoding = "UTF-8"
        options.release.set(25)
        options.compilerArgs.add("-parameters")
    }

    tasks.withType<Test>().configureEach {
        systemProperty("java.util.logging.manager", "org.jboss.logmanager.LogManager")
    }
}
