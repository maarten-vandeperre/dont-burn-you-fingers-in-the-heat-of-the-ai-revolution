// frontend: Quarkus backend-for-frontend + the React UI (Vite + Tailwind) in src/main/webui.
// The UI is built with npm (Dockerfile stage, or `npm run build` locally) into
// src/main/resources/META-INF/resources, from where Quarkus serves it.
dependencies {
    implementation("io.quarkus:quarkus-rest-client-jackson")
}

val webui = layout.projectDirectory.dir("src/main/webui")

// Optional local convenience: ./gradlew :frontend:buildUi (needs Node 22 on the PATH)
tasks.register<Exec>("buildUi") {
    group = "build"
    description = "Builds the React UI into src/main/resources/META-INF/resources"
    workingDir = webui.asFile
    commandLine("sh", "-c", "npm ci && npm run build")
}
