import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

// `npm run dev` proxies /api to the Quarkus backend (./gradlew quarkusDev on :8080).
// `npm run build` writes straight into the Quarkus static resources folder.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:8080" },
  },
  build: {
    outDir: "../resources/META-INF/resources",
    emptyOutDir: true,
  },
});
