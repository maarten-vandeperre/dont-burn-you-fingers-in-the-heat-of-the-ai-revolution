# ${{ values.name }}

${{ values.description }}

Created from the Developer Hub template **LLM application**.

| | |
|---|---|
| Use case | `${{ values.useCase }}` (instructions in `UseCase.java`) |
| Size | `${{ values.size }}`: at most ${{ values.maxChars }} characters per question |
| Model | chosen by the platform for this use case, via the Models-as-a-Service gateway |
| Stack | Java 25, Quarkus 3.40 LTS, LangChain4j, React 19 + Vite + Tailwind, Gradle |

## Run locally

```bash
# backend (needs an OpenAI compatible endpoint: MaaS, Podman Desktop AI Lab, OpenAI, ...)
export LLM_BASE_URL=http://localhost:35000/v1   # e.g. a Podman Desktop AI Lab model service
export LLM_API_KEY=not-needed
./gradlew quarkusDev                            # http://localhost:8080/api/config

# UI with hot reload (proxies /api to :8080)
cd src/main/webui && npm install && npm run dev  # http://localhost:5173
```

## Deploy on OpenShift

```bash
oc apply -k deploy/
oc create secret generic llm-credentials -n ${{ values.name }} \
  --from-literal=LLM_API_KEY=<MaaS API key: OpenShift AI > Gen AI studio > API keys>
oc start-build ${{ values.name }} -n ${{ values.name }} --follow
oc get route ${{ values.name }} -n ${{ values.name }}
```
Developer Hub shows the pods and the route on the component's Topology and Kubernetes tabs.

## API

| | |
|---|---|
| `GET /api/config` | name, use case, size and the character limit |
| `POST /api/ask` `{"question": "..."}` | `{"answer": "...", "useCase": "...", "maxChars": n, "elapsedMs": n}`; 400 when the question is longer than the limit |

## Change the model or the limits

The platform defaults live in `src/main/resources/application.properties`
(`quarkus.langchain4j.openai.*`, `app.max-input-chars`). `LLM_BASE_URL`, `LLM_MODEL` and
`LLM_API_KEY` override them per environment, for example in the `llm-credentials` secret.
