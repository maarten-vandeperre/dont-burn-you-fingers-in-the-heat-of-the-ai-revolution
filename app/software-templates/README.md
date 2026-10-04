# Software templates

Developer Hub templates (Create > Choose a template) that start new projects on the platform.

| Template | What it creates |
|---|---|
| `llm-app/` | "LLM application": Quarkus + LangChain4j backend, React (Vite + Tailwind) UI, Dockerfile, OpenShift manifests. Two form steps: metadata (name, description, package name) and model selection (use case, t-shirt size). |

How they get into Developer Hub: `./deploy.sh gitlab` pushes this repository (with the cluster's
GitLab host and apps domain filled in) to GitLab `ai-platform/platform`, and the catalog Location
`software-templates` (stack/developer-hub) reads `llm-app/template.yaml` from there.
Generated projects are published to the GitLab group `ai-platform` and registered in the catalog.
