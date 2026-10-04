// coffee-shop: the coffee ordering app from "owning the inference layer", extended for the
// platform demos. LangChain4j interprets the order (through the model-router), prices come from
// coffee-menu (through the mesh, with fault tolerance), orders live in PostgreSQL (captured by
// Debezium) and the audit trail is read back from MongoDB.
val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-langchain4j-bom:$quarkusPlatformVersion"))
    implementation("io.quarkiverse.langchain4j:quarkus-langchain4j-openai")
    implementation("io.quarkus:quarkus-rest-client-jackson")
    implementation("io.quarkus:quarkus-smallrye-fault-tolerance")
    implementation("io.quarkus:quarkus-hibernate-orm-panache")
    implementation("io.quarkus:quarkus-jdbc-postgresql")
    implementation("io.opentelemetry.instrumentation:opentelemetry-jdbc")
}

val webui = layout.projectDirectory.dir("src/main/webui")

// Optional local convenience: ./gradlew :coffee-shop:buildUi (needs Node 22 on the PATH)
tasks.register<Exec>("buildUi") {
    group = "build"
    description = "Builds the React UI into src/main/resources/META-INF/resources"
    workingDir = webui.asFile
    commandLine("sh", "-c", "npm ci && npm run build")
}
