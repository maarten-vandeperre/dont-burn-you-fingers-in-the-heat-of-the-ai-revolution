// camel-ai-router: OpenAI-compatible endpoint (Camel Quarkus DSL) that routes every chat
// completion to a local model, OpenAI, Anthropic or a vLLM/OpenShift AI endpoint, with
// request-steerable routing, a circuit breaker + fallback-to-local per Camel EIPs, and an
// explicit "x failures in y minutes -> z minutes forced to local" policy.
plugins {
    java
    id("io.quarkus")
}

val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

group = "org.acme.camelrouter"
version = "1.0.0"

repositories {
    mavenCentral()
    mavenLocal()
}

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-bom:$quarkusPlatformVersion"))
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-camel-bom:$quarkusPlatformVersion"))
    implementation("org.apache.camel.quarkus:camel-quarkus-platform-http")
    implementation("org.apache.camel.quarkus:camel-quarkus-direct")
    implementation("org.apache.camel.quarkus:camel-quarkus-bean")
    implementation("org.apache.camel.quarkus:camel-quarkus-jackson")
    implementation("io.quarkus:quarkus-rest-jackson")
    implementation("org.apache.camel.quarkus:camel-quarkus-microprofile-fault-tolerance")
    implementation("org.apache.camel.quarkus:camel-quarkus-micrometer")
    implementation("io.quarkus:quarkus-micrometer-registry-prometheus")
    implementation("io.quarkus:quarkus-rest-client-jackson")
    implementation("io.quarkus:quarkus-smallrye-health")
    // Hawtio console (linked from /admin): live view of the running Camel route(s) -- diagram,
    // per-route/per-endpoint stats, start/stop/suspend, and the message debugger/tracer, which is
    // the closest thing to "editing" a route that is already compiled into a running JVM.
    // camel-quarkus-management registers the Camel context/routes as JMX MBeans, which is what
    // Hawtio actually talks to (over an embedded Jolokia HTTP bridge, not raw JMX -- works fine
    // in a container with no JMX port exposed). camel-quarkus-jaxb adds the route diagram tab.
    implementation("io.hawt:hawtio-quarkus:5.2.1")
    implementation("org.apache.camel.quarkus:camel-quarkus-management")
    implementation("org.apache.camel.quarkus:camel-quarkus-jaxb")
    // Required for the Hawtio Camel plugin's "Debug" tab (breakpoints + live message
    // inspection/editing) to work outside dev mode -- see quarkus.camel.debug.enabled below.
    implementation("org.apache.camel.quarkus:camel-quarkus-debug")
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
