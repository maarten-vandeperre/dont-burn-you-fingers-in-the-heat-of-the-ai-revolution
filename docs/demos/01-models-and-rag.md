# Demo 1: Models and RAG

**The story:** the platform team runs the models (OpenShift AI, vLLM) and publishes them with
keys and quotas (Models-as-a-Service). Application teams never talk to a model directly: they ask
the model router for an alias, and the platform decides which model answers.

**Duration:** 15 minutes (5 OpenShift AI, 5 demo UI, 5 IntelliJ). Each part also works on its own.

**Request path:** demo UI > frontend > rag-service (LangChain4j, retrieval over the platform docs)
> model-router (Apache Camel) > MaaS gateway (API key, token quota) > vLLM (Gemma or Qwen).

Every step below has three parts: **Do** (what you click or open), **You see** (what appears),
**Say** (the point to make).

---

## Before you start (5 minutes before the audience arrives)

1. In a terminal in the repository folder:
   ```bash
   ./deploy.sh test          # both models answer through MaaS
   ./deploy.sh urls          # OpenShift AI, console, Kiali, ... URLs
   ./deploy.sh app urls      # demo UI URL
   ```
2. Ask one question per model in the demo UI: the first answer of a CPU model is the slowest.
3. Open these browser tabs, signed in:
   * **OpenShift AI** (URL "OpenShift AI" from `./deploy.sh urls`)
   * **OpenShift console** (URL "OpenShift console")
   * **Demo UI** (URL "Demo UI" from `./deploy.sh app urls`)
4. Open **IntelliJ** on the repository folder (File > Open > `ocp422-ai-platform`).
   Press **Shift twice** to open any file by name; the steps below give the file names.

---

## Part A: the platform view in OpenShift AI (5 minutes)

**A1. The models are deployed and published.**
* **Do:** OpenShift AI tab > left menu **Gen AI studio** > **AI asset endpoints**. Pick project
  **maas-models** in the project picker at the top.
* **You see:** `gemma-3-270m-it` and `qwen3-0-6b`, each with its endpoint.
* **Say:** "Two small open models, running on CPU in this cluster with vLLM. The platform team
  deployed them once; every team can use them, nobody needs their own GPU or API contract."

**A2. Access is by API key, per subscription.**
* **Do:** left menu **Gen AI studio** > **API keys** > **Create API key**. Give it a name; when asked
  for a subscription pick **Small models: Free**. The key is shown once: do not show it on screen
  longer than needed.
* **Say:** "Every key belongs to a subscription. The free one allows 5,000 tokens per minute per
  model, the premium one 100,000. That is how the platform shares model capacity fairly and knows
  who used what."

**A3. Try a model without writing code.**
* **Do:** **Gen AI studio** > **Playground**, project picker **ai-tenants**. Pick **qwen3-0-6b**,
  type `What is Kubernetes? Answer in two sentences.` and send. Switch to **gemma-3-270m-it** and
  send the same question.
* **You see:** two different answers; Gemma (270 million parameters) is clearly weaker.
* **Say:** "This is the model alone, without any of our own data. Next I show how an application gets
  good answers from a small model anyway."

**A4. Where the models really run.**
* **Do:** OpenShift console tab > **Workloads** > **Topology**, project **maas-models**. Click the
  `qwen3-0-6b-kserve` circle > **Resources** tab in the side panel > the pod > **Logs**.
* **You see:** the vLLM server log, with `POST /v1/chat/completions` lines while questions come in.
* **Say:** "Plain Kubernetes: a Deployment, a pod, logs. KServe created it from one resource file,
  which I show in IntelliJ in a minute."

---

## Part B: the application view in the demo UI (5 minutes)

**B1. Ask with retrieval (RAG).**
* **Do:** Demo UI tab > **Ask (RAG)**. Click the example `How does the mesh decide who can access
  who?`. Model **qwen**. Click **Ask**.
* **You see (after 10 to 60 seconds):**
  * the **Answer**, explaining service accounts and mTLS identities
  * the badges `model: qwen`, `rag v1`, `retrieval ... ms` (milliseconds), `generation ... ms`
    (seconds), `tokens ... in / ... out`
  * **Retrieved context**: the passages from the platform docs that went into the prompt, with a score
* **Say:** "The model knows nothing about our platform. The rag-service first searched our own
  documentation in a few milliseconds, then sent the question plus those passages to the model.
  Our knowledge, a small model, a correct answer: that is retrieval augmented generation."

**B2. Same question, other models.**
* **Do:** select model **gemma**, click **Ask**. Then **openai** if an OpenAI key is configured.
* **You see:** the same **Retrieved context**, different answers and timings.
* **Say:** "Retrieval stays the same, only the model changes. The application code is identical for
  all of them: it only sends a different alias."

**B3. Local first, cloud as fallback** (needs an OpenAI key at `./deploy.sh app setup`).
* **Do:** in a terminal, stop Qwen:
  ```bash
  oc patch llminferenceservice qwen3-0-6b -n maas-models --type merge -p '{"spec":{"replicas":0}}'
  ```
  In the demo UI select model **auto**, click **Ask**.
* **You see:** an answer, now produced by OpenAI.
* **Say:** "`auto` means: our own model first. When it is down or too slow, the model router falls
  back to OpenAI. Nobody changed or redeployed the application."
* **Do (restore):**
  ```bash
  oc patch llminferenceservice qwen3-0-6b -n maas-models --type merge -p '{"spec":{"replicas":1}}'
  ```
  The same switch exists in Developer Hub: Create > "Models-as-a-Service: scale a model" (demo 6).

---

## Part C: the code in IntelliJ (5 minutes)

Follow one request through the code, top to bottom.

**C1. The application asks for an alias, not a model.**
* **Do:** open `RagResource.java` (app/rag-service), go to the method **`ask`**.
* **Point at:** `knowledgeBase.search(request.question(), topK)` (retrieval), the prompt templates
  **`V1`** and **`V2`** at the top of the class, and the call to the model.
* **Say:** "Search our docs, put the best passages in the prompt, ask the model. v1 and v2 differ only
  in prompt style and retrieval depth; demo 3 uses that for canary releases."

**C2. Where the knowledge comes from.**
* **Do:** open `KnowledgeBase.java`, then the folder `app/rag-service/src/main/resources/docs`.
* **Point at:** the class comment (BM25 keyword search, no vector database needed) and the markdown
  files such as `service-mesh.md` and `models-as-a-service.md`.
* **Say:** "The knowledge base is these markdown files. Add one, rebuild, and the assistant knows about
  it. For semantic search you swap this single class for an embedding store."

**C3. One endpoint for all models.**
* **Do:** open `ModelRegistry.java`, then `app/rag-service/src/main/resources/application.properties`.
* **Point at:** the four named models (`gemma`, `qwen`, `openai`, `auto`) and their `base-url`, which is
  the same for all four: the model router (`ROUTER_URL`). The `api-key` is `handled-by-model-router`.
* **Say:** "The rag-service has no model URL and no API key. It only knows the model router."

**C4. The model router decides (Apache Camel).**
* **Do:** open `ChatRoutes.java` (app/model-router).
* **Point at:**
  * route **`chat-completions`**: `choice()` on the alias: `openai` goes to `direct:openai`, `auto` to
    `direct:auto`, everything else to `direct:maas`
  * route **`auto-with-fallback`**: `circuitBreaker()` with a timeout, `.to("direct:maas")`, and
    `onFallback()` that logs "local model unavailable, falling back to OpenAI"
* **Say:** "This is the abstraction layer: a dozen lines of Camel. Swapping a model, adding a provider
  or changing the fallback happens here, once, for every application."

**C5. How the router calls the platform.**
* **Do:** open `MaasGateway.java`.
* **Point at:** `client.chat(namespace, model, "Bearer " + key, request)`.
* **Say:** "Only the router holds the MaaS API key. The gateway checks the key and counts the tokens
  against the subscription."

**C6. How the platform team publishes a model.**
* **Do:** open, one after the other: `models/qwen3-0-6b/llminferenceservice.yaml`,
  `models/qwen3-0-6b/maasmodelref.yaml`, `governance/subscription-free.yaml`.
* **Point at:** `uri: hf://Qwen/Qwen3-0.6B` and the vLLM arguments; the MaaSModelRef that publishes the
  model; `limit: 5000` and `window: 1m` in the subscription.
* **Say:** "Three small files: run the model, publish it, decide who may use how much. That is the
  whole contract between the platform team and the application teams."

---

## Part D: prove it from the terminal (optional)

```bash
./deploy.sh test
```
Expected: an API key is created and both models answer (`OK gemma-3-270m-it: ...`, `OK qwen3-0-6b: ...`).

```bash
./deploy.sh app ask "Why does the model router use a circuit breaker?" qwen
```
Expected: JSON with `answer`, `"model": "qwen"`, `"version": "v1"` and sources such as
"Model router with Apache Camel".

```bash
oc logs deploy/model-router -n ai-demo -c app | grep -i "falling back"   # after B3
./deploy.sh usage --window 1h                                            # tokens per model and subscription
```

## Reset

```bash
oc patch llminferenceservice qwen3-0-6b -n maas-models --type merge -p '{"spec":{"replicas":1}}'
```

## If something goes wrong

* **Ask spins for a long time:** CPU models need 10 to 60 seconds; the first call after a restart is
  slower. Use **qwen**; `./deploy.sh models` when a model is not ready.
* **502 for gemma:** the Hugging Face token cannot download it: `./deploy.sh hf-check`.
* **429:** the free quota (5,000 tokens per minute) is used up. Wait a minute, or add yourself to
  `maas-premium-users`, delete the `model-router-secrets` secret in `ai-demo` and run `./deploy.sh app setup`.
* **auto does not fall back:** there was no OpenAI key at `./deploy.sh app setup`.
* **AI asset endpoints is empty:** check the project picker (maas-models); the models must be Ready:
  `oc get llminferenceservice -n maas-models`.
* **Playground shows "Create your playground":** you are in project `maas-models`; switch to
  `ai-tenants` (`./deploy.sh playground` creates it when missing).
