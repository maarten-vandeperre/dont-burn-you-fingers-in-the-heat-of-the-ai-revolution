// model-router: OpenAI-compatible endpoint that abstracts the models behind it with Apache Camel
// (aliases gemma / qwen / openai / auto, circuit breaker + fallback, token metrics, tracing)
val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-camel-bom:$quarkusPlatformVersion"))
    implementation("org.apache.camel.quarkus:camel-quarkus-platform-http")
    implementation("org.apache.camel.quarkus:camel-quarkus-direct")
    implementation("org.apache.camel.quarkus:camel-quarkus-bean")
    implementation("org.apache.camel.quarkus:camel-quarkus-jackson")
    implementation("org.apache.camel.quarkus:camel-quarkus-microprofile-fault-tolerance")
    implementation("org.apache.camel.quarkus:camel-quarkus-micrometer")
    implementation("org.apache.camel.quarkus:camel-quarkus-opentelemetry")
    implementation("io.quarkus:quarkus-rest-client-jackson")
}
