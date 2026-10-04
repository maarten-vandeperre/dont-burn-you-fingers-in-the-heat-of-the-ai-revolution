// rag-service: retrieval augmented generation with LangChain4j. Models are reached through the
// model-router (Camel), so LangChain4j only sees one OpenAI-compatible endpoint with four aliases.
val quarkusPlatformGroupId: String by project
val quarkusPlatformVersion: String by project

dependencies {
    implementation(enforcedPlatform("$quarkusPlatformGroupId:quarkus-langchain4j-bom:$quarkusPlatformVersion"))
    implementation("io.quarkiverse.langchain4j:quarkus-langchain4j-openai")
}
