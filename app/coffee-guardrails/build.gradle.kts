// coffee-guardrails: Quarkus backend + React UI in front of a NeMo Guardrails (TrustyAI) server.
plugins {
    java
    id("io.quarkus")
}

val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

group = "org.acme.coffee"
version = "1.0.0"

repositories {
    mavenCentral()
    mavenLocal()
}

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-bom:$quarkusPlatformVersion"))
    implementation("io.quarkus:quarkus-rest-jackson")
    implementation("io.quarkus:quarkus-rest-client-jackson")
    implementation("io.quarkus:quarkus-smallrye-health")
    testImplementation("io.quarkus:quarkus-junit5")
}

java {
    toolchain { languageVersion.set(JavaLanguageVersion.of(25)) }
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.release.set(25)
    options.compilerArgs.add("-parameters")
}

// Optional local convenience: ./gradlew buildUi (needs Node 22 on the PATH)
tasks.register<Exec>("buildUi") {
    group = "build"
    description = "Builds the React UI into src/main/resources/META-INF/resources"
    workingDir = layout.projectDirectory.dir("src/main/webui").asFile
    commandLine("sh", "-c", "npm install && npm run build")
}
