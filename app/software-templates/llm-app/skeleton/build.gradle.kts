// ${{ values.name }}: Quarkus + LangChain4j backend, React UI in src/main/webui (built by npm into
// src/main/resources/META-INF/resources, see the Dockerfile).
plugins {
    java
    id("io.quarkus")
}

val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

group = "${{ values.packageName }}"
version = "1.0.0"

repositories {
    mavenCentral()
    mavenLocal()
}

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-bom:$quarkusPlatformVersion"))
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-langchain4j-bom:$quarkusPlatformVersion"))
    implementation("io.quarkus:quarkus-rest-jackson")
    implementation("io.quarkus:quarkus-smallrye-health")
    implementation("io.quarkus:quarkus-micrometer-registry-prometheus")
    implementation("io.quarkus:quarkus-opentelemetry")
    implementation("io.quarkiverse.langchain4j:quarkus-langchain4j-openai")
    testImplementation("io.quarkus:quarkus-junit5")
    testImplementation("io.rest-assured:rest-assured")
}

java {
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

// Optional local convenience: ./gradlew buildUi (needs Node 22 on the PATH)
tasks.register<Exec>("buildUi") {
    group = "build"
    description = "Builds the React UI into src/main/resources/META-INF/resources"
    workingDir = layout.projectDirectory.dir("src/main/webui").asFile
    commandLine("sh", "-c", "npm install && npm run build")
}
