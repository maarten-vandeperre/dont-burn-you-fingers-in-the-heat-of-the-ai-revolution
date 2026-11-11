# ${{ values.name }}

${{ values.description }}

Created from the Developer Hub software template **LLM application** (Quarkus, LangChain4j, React).

| | |
|---|---|
| Use case | `${{ values.useCase }}` (instructions in `UseCase.java`) |
| Size | `${{ values.size }}`: at most ${{ values.maxChars }} characters per question, answers up to ${{ values.maxTokens }} tokens |
| Model | `${{ values.modelId }}` ([details](model.md)) |
| Deployment | Argo CD application `${{ values.name }}`, namespace `${{ values.name }}` ([details](deployment.md)) |
| Stack | Java 25, Quarkus 3.40 LTS, LangChain4j, React 19 + Vite + Tailwind, Gradle |

## API

| | |
|---|---|
| `GET /api/config` | name, use case, size and the character limit |
| `POST /api/ask` `{"question": "..."}` | `{"answer": "...", "useCase": "...", "maxChars": n, "elapsedMs": n}`; 400 when the question is longer than the limit |

## Run locally

```bash
# backend (needs an OpenAI compatible endpoint: MaaS, Podman Desktop AI Lab, OpenAI, ...)
export LLM_BASE_URL=http://localhost:35000/v1   # e.g. a Podman Desktop AI Lab model service
export LLM_API_KEY=not-needed
./gradlew quarkusDev                            # http://localhost:8080/api/config

# UI with hot reload (proxies /api to :8080)
cd src/main/webui && npm install && npm run dev  # http://localhost:5173
```
