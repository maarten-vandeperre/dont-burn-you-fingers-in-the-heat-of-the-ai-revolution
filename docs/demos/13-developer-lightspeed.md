# Demo 13: Developer Lightspeed — an assistant that knows *this* platform

**The story:** Red Hat Developer Lightspeed for Developer Hub is a chat assistant inside the
developer portal. Out of the box it knows the Developer Hub documentation. Here it gets two more
things that make it useful for the developers on *this* platform:

* **its brain from the platform itself**: the LLM is Qwen3-0.6B, served by OpenShift AI and called
  through Models-as-a-Service with its own API key and token budget, exactly like every other
  application. No data leaves the cluster.
* **live platform knowledge through MCP tools** (Model Context Protocol): which models are deployed
  in OpenShift AI, how the catalog fits together, and for every catalog component what it is
  linked to and what its CI / CD / runtime status is right now.

**Duration:** 11 minutes (3 Part A, 6 Part B, 2 Part C).

```
Developer Hub pod (namespace rhdh)
 ├─ backstage-backend                              lightspeed-core (sidecar, "lightspeed" flavour)
 │   Lightspeed frontend + backend plugins  ──────▶  Lightspeed Core Service + Llama Stack (library)
 │   (system prompt, per-server MCP tokens)          │ inference: provider vllm ──▶ MaaS gateway ──▶ qwen3-0-6b (OpenShift AI)
 │                                                   │                         (API key of SA developer-lightspeed,
 │   mcp-actions-backend  /api/mcp-actions/v1  ◀─────┤                          subscription developer-lightspeed)
 │   + software-catalog-mcp-extras                   │ MCP server "mcp-integration-tools"
 │     (query-catalog-entities)                      │
 │   catalog REST API  ◀───────────┐                 │ MCP server "platform-tools"
 └───────────────────────────────  │                 ▼
                                   └──── platform-mcp (Deployment, namespace rhdh, Python stdlib)
                                          list_deployed_models   LLMInferenceService / InferenceService,
                                                                 MaaSModelRef, MaaSSubscription
                                          get_catalog_overview   catalog entities + relations
                                          get_catalog_ci_status  every component/resource: CI-tab
                                                                 pipeline status (N/A) + last build
                                          get_ci_status          one item: pipeline + build status,
                                                                 links to its catalog page and CI tab
                                          get_component_details  relations + Builds, PipelineRuns,
                                                                 Argo CD, Deployments, Rollouts
```

| Piece | Real or mocked |
|---|---|
| The Lightspeed chat, its backend and the Lightspeed Core sidecar | **real**: Red Hat's plugins and sidecar, added by the Developer Hub operator's `lightspeed` flavour |
| The LLM | **real**: `qwen3-0-6b` (vLLM on CPU) behind MaaS; Lightspeed has its own key, quota and usage metrics |
| Developer Hub's MCP endpoint (`/api/mcp-actions/v1`) | **real**: upstream `mcp-actions-backend` + Red Hat's `software-catalog-mcp-extras` (Developer Preview) |
| Models, catalog relations, CI / CD / runtime status | **real, live**: `platform-mcp` reads the Kubernetes API and the catalog on every question (no cache beyond 30 s) |
| Answer quality | **small model**: 0.6B parameters on CPU; it picks the right tool reliably, and phrases answers simply. `OPENAI_API_KEY` adds OpenAI models to the model picker for comparison |

---

## Before you start

1. The platform stack is installed (`./deploy.sh stack`). It already installs everything
   Developer Lightspeed needs on the operator side: the **Developer Hub operator** (its
   `lightspeed` flavour adds the sidecar and the plugins), **OpenShift AI + MaaS** (the model),
   and the two MCP plugins in Developer Hub's plugin list. No extra operator is needed.
2. Connect Lightspeed to the model and the tools (idempotent, ~5-8 min the first time, mostly the
   Developer Hub restart; ends with an end-to-end test):
   ```bash
   ./deploy.sh lightspeed setup
   # optional: also offer OpenAI models in the chat's model picker
   OPENAI_API_KEY=sk-... ./deploy.sh lightspeed llm
   ```
3. Check right before presenting (asks the five demo questions through the same API the chat UI
   uses; on CPU every answer takes 30-90 s):
   ```bash
   ./deploy.sh lightspeed test
   ./deploy.sh lightspeed urls
   ```
4. Browser tabs: **Developer Hub** signed in as `admin` / `redhatdemo` (Keycloak), page
   `/lightspeed`; **OpenShift AI** dashboard > *Models* > *Deployments*; optionally the OpenShift
   console on project `rhdh`, Deployment `platform-mcp`, tab *Logs* (every tool call is logged).
5. Ask one warm-up question: the first answer after a restart is the slowest.

---

## Part A: the platform's own model (3 minutes)

**A1. Lightspeed in Developer Hub.**
* **Do:** Developer Hub > **Lightspeed** in the left navigation (or the Lightspeed button at the
  bottom right of any page). Open the model picker at the top of the chat.
* **You see:** the welcome prompts *Deployed models*, *Catalog overview*, *Component status*,
  *Catalog CI status*, *CI of one component*, *Model router*; one model `qwen3-0-6b` (provider `vllm`), plus `openai/...` models only when you
  ran `lightspeed llm` with `OPENAI_API_KEY`.
* **Say:** "This is Red Hat Developer Lightspeed. The model behind it is not a SaaS endpoint: it is
  the Qwen model we serve ourselves in OpenShift AI, called through Models-as-a-Service with the
  same API keys and quotas as every other team."

**A2. Lightspeed is a MaaS tenant.**
* **Do:** OpenShift console > search `MaaSSubscription` > `developer-lightspeed` (namespace
  `models-as-a-service`).
* **You see:** owner `system:serviceaccount:rhdh:developer-lightspeed`, model `qwen3-0-6b`,
  200 000 tokens / minute.
* **Say:** "The assistant has its own identity, its own key and its own budget. Its token use shows
  up per subscription in the usage dashboards (`./deploy.sh usage`), next to the apps."

---

## Part B: live platform knowledge through MCP (6 minutes)

**B1. Deployed models in OpenShift AI.**
* **Do:** click the welcome prompt **Deployed models** ("Which models are deployed in OpenShift AI?").
* **You see:** first a collapsible *reasoning* section (Qwen3 thinks before it answers and decides
  to call `list_deployed_models`), then the tool call, then the answer: `gemma-3-270m-it` and
  `qwen3-0-6b`, Ready, served by vLLM on CPU, published through MaaS with their endpoints and the
  subscriptions / token limits that apply.
* **Do:** OpenShift AI dashboard > *Models* > *Deployments*: the same two models.
* **Say:** "Lightspeed did not guess and did not read documentation: it called a tool that reads
  the `LLMInferenceService`, `MaaSModelRef` and `MaaSSubscription` objects right now. Scale a model
  down and ask again: the answer changes."

**B2. The overall view: how the catalog fits together.**
* **Do:** prompt **Catalog overview** ("Give me an overview of the software catalog and how the
  components relate to each other.").
* **You see:** the tool `get_catalog_overview`; the answer lists the domain `ai-platform`, the
  systems `ai-demo`, `models-as-a-service`, `openshift-platform`, their components, APIs and
  resources, and the wiring: `coffee-shop` calls `coffee-menu-api` (from `coffee-menu`) and
  `model-router-api` (from `model-router`), `model-router` depends on the model resources, ...
* **Do:** Developer Hub > Catalog > `coffee-shop` > *Dependencies* tab (the catalog graph).
* **Say:** "Same relations as the catalog graph, but as an answer to a question. They come from the
  catalog entities (`providesApis`, `consumesApis`, `dependsOn`), so they are as correct as the
  catalog-info.yaml files of the teams."

**B3. One component and everything linked to it, including CI.**
* **Do:** prompt **Component status** ("What is linked to the coffee-shop component and what is its
  CI status?").
* **You see:** the tool `get_component_details(name=coffee-shop)`; the answer: the APIs it provides
  and consumes (and which components are on the other side), the resources it depends on, the CI
  status (OpenShift `BuildConfig coffee-shop`: last build and its result), the CD status (Argo CD
  application, or that it is deployed with `oc`), and the runtime (Deployment `coffee-shop` 1/1).
* **Do:** ask "What is the CI status of coffee-menu-tssc?" (the catalog entity of the trusted supply
  chain pipeline, demo 8; in the catalog once `./deploy.sh rhdh` rendered the current catalog)
* **You see:** the Tekton pipeline `trusted-supply-chain` (namespace `tssc-ci`): the last run,
  succeeded / failed counts, and the failure message of the last failed run.
* **Do:** prompt **Model router** ("Show the details of model-router, which models does it depend on?").
* **You see:** `model-router` depends on `gemma-3-270m-it`, `qwen3-0-6b` and `openai`; provides
  `model-router-api`, used by `coffee-shop` and `rag-service`; its build and deployment status.
* **Say:** "Every catalog component works the same way: the tool joins the catalog relations with
  the cluster objects that carry the component's `backstage.io/kubernetes-id`: Builds, Tekton
  PipelineRuns, Argo CD Applications, Deployments, Rollouts, model servers."

**B4. CI status of the whole catalog, like the CI tab.**
* **Do:** prompt **Catalog CI status** ("Which items are in the catalog and what is their pipeline
  status? If no pipeline, say N/A.").
* **You see:** the tool `get_catalog_ci_status`; one table with every component and resource, the
  pipeline status its **CI tab** shows (the Tekton plugin: PipelineRuns labelled
  `backstage.io/kubernetes-id=<id>`; `N/A` when there are none) and the last OpenShift build. With
  the current catalog the components show `N/A` and their builds `Complete (<name>-2, ...)`; the
  resources without pipeline and build share one `N/A` row (keeps the answer short enough for the
  small model); `coffee-menu-tssc` (demo 8, after `./deploy.sh rhdh`) shows its last
  `trusted-supply-chain` run.
* **Do:** Developer Hub > Catalog > `coffee-shop` > *CI* tab: the same (empty) PipelineRun list.
* **Say:** "One question, one tool call, the CI tab of every component in one table. The tool
  applies the same selection as the Tekton plugin, so the assistant and the UI never disagree."

* **Do:** prompt **CI of one component** ("What is the CI status of coffee-shop? Give me the links.").
* **You see:** the tool `get_ci_status(name=coffee-shop)`; the pipeline status (`N/A`), the last
  OpenShift build, and two clickable links: the catalog page
  `https://<rhdh-host>/catalog/default/component/coffee-shop` and its CI tab `.../coffee-shop/ci`.
  Click the CI link: it opens the tab the answer describes.

**B5. Developer Hub's own MCP server.**
* **Do:** ask "Use query-catalog-entities to list all Resources of type ai-model."
* **You see:** the tool `software-catalog-mcp-extras.query-catalog-entities` (from Developer Hub's
  MCP endpoint) and the three model resources.
* **Say:** "Developer Hub itself is an MCP server. The same endpoint works from Cursor, VS Code or
  Claude with the MCP token (`./deploy.sh lightspeed urls`); and in Lightspeed's *MCP servers*
  settings every user can switch a server off or use their own token."

---

## Part C: in IntelliJ (2 minutes)

| File | What to point at |
|---|---|
| `stack/developer-hub/backstage.yaml` | `flavours: lightspeed`; `app-config-lightspeed`; `lightspeed-stack-config` and `lightspeed-secrets` mounted **only** into the `lightspeed-core` container |
| `stack/developer-hub/lightspeed/app-config-lightspeed.yaml` | the static `MCP_TOKEN` (`externalAccess`), `backend.actions.pluginSources`, `lightspeed.mcpServers` (one token per MCP server), the short `systemPrompt` that maps question types to tools, the welcome `prompts` |
| `stack/developer-hub/lightspeed/lightspeed-stack.yaml` | `mcp_servers`: `mcp-integration-tools` (Developer Hub) and `platform-tools` (platform-mcp), `Authorization: 'client'` |
| `stack/lightspeed/maas/subscription.yaml` | Lightspeed's MaaS identity and token budget |
| `stack/lightspeed/mcp-server/server.py` | five tools, pre-digested Markdown output: a 0.6B model answers well when the tool already joined and filtered the data |
| `stack/lightspeed/mcp-server/rbac.yaml` | read-only, exactly the resources the tools read |

The important snippets:

```yaml
# backstage.yaml: the operator flavour + the sidecar-only mounts
spec:
  flavours:
    - name: lightspeed
      enabled: true
  application:
    extraFiles:
      configMaps:
        - name: lightspeed-stack-config
          key: lightspeed-stack.yaml
          mountPath: /app-root
          containers: [lightspeed-core]
    extraEnvs:
      secrets:
        - name: lightspeed-secrets          # ENABLE_VLLM, VLLM_URL, VLLM_API_KEY, VLLM_MAX_TOKENS
          containers: [lightspeed-core]
```

```yaml
# lightspeed-stack.yaml (Lightspeed Core): where the tools are
mcp_servers:
  - name: mcp-integration-tools
    provider_id: 'model-context-protocol'
    url: 'http://localhost:7007/api/mcp-actions/v1'
    authorization_headers:
      Authorization: 'client'          # token sent by the Lightspeed backend (MCP-HEADERS)
  - name: platform-tools
    provider_id: 'model-context-protocol'
    url: 'http://platform-mcp.rhdh.svc:8080/mcp'
    authorization_headers:
      Authorization: 'client'
```

```yaml
# app-config-lightspeed.yaml (Developer Hub)
backend:
  auth:
    externalAccess:
      - type: static
        options: {token: ${MCP_TOKEN}, subject: mcp-clients}
  actions:
    pluginSources: [software-catalog-mcp-extras]
lightspeed:
  mcpServers:                          # names = mcp_servers above
    - {name: mcp-integration-tools, token: ${MCP_TOKEN}}
    - {name: platform-tools, token: ${MCP_TOKEN}}
  systemPrompt: |
    ... deployed models: call list_deployed_models; catalog: get_catalog_overview;
    pipelines / CI of the catalog: get_catalog_ci_status (show its table as-is);
    CI of one item + links: get_ci_status;
    one component: get_component_details ...
```

```bash
# lightspeed-secrets (written by lightspeed.sh, never in git)
ENABLE_VLLM=true
VLLM_URL=https://maas.<apps-domain>/maas-models/qwen3-0-6b/v1
VLLM_API_KEY=sk-oai-...               # minted as system:serviceaccount:rhdh:developer-lightspeed
VLLM_TLS_VERIFY=true
VLLM_MAX_TOKENS=2048                   # 8k context: reasoning + a 21-row table fit, tool results keep ~5k
```

---

## Prove it from the terminal

```bash
./deploy.sh lightspeed status                       # CR, sidecar, LLM secret, subscription, platform-mcp, MCP plugins
./deploy.sh lightspeed ask "Which models are deployed in OpenShift AI?"
./deploy.sh lightspeed ask "What is the CI status of model-router?"
./deploy.sh lightspeed test                         # MCP endpoints + the five demo questions, PASS/FAIL
oc logs -n rhdh deploy/platform-mcp                 # one line per tool call: tool, arguments, size, time
./deploy.sh usage                                   # tokens of subscription developer-lightspeed
```

`ask` sends exactly what the chat UI sends (Lightspeed backend plugin, `router.cjs.js`):
`POST /v1/streaming_query` on the sidecar with the `systemPrompt`, the RHDH docs vector store and
`MCP-HEADERS: {"<server>": {"Authorization": "<bare token>"}}`.

## Reset

Nothing to reset: the tools only read. Chat history lives in the sidecar (SQLite in `/tmp`) and is
gone after a Developer Hub restart. Remove the whole wiring with `./deploy.sh lightspeed destroy`
(Developer Hub stays; `./deploy.sh lightspeed setup` brings it back).

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| No model in the picker | `lightspeed-secrets` is still the placeholder: `./deploy.sh lightspeed setup` (or `llm`) |
| Every question fails: *Unable to connect to Llama Stack* | one MCP server of `lightspeed-stack.yaml` cannot be listed (unreachable or 401): Lightspeed Core then fails the whole question. `oc logs -n rhdh deploy/backstage-developer-hub -c lightspeed-core \| grep -i mcp`; `./deploy.sh lightspeed test` shows which endpoint fails |
| 401 from `/api/mcp-actions/v1` | the MCP token must be sent bare in `MCP-HEADERS` (Llama Stack adds `Bearer `); `MCP_TOKEN` missing in `rhdh-secrets`: `./deploy.sh rhdh` or `lightspeed setup` recreates it |
| The chat shows nothing for minutes, MaaS answers 503 to everything (after a cluster restart) | The MaaS gateway fetches the Kuadrant wasm plugin from the Kuadrant operator when it starts. If the operator is not Ready (it crash-looped on its default 200m cpu limit, `oc get pods -n openshift-operators \| grep kuadrant-operator`), the plugin stays failed closed (gateway log: `wasm_fail_stream`) until the gateway restarts. Lightspeed core gets the 503 and the chat just keeps waiting. Fixes: `operators/connectivity-link.yaml` raises the operator's cpu limit (OLM `spec.config.resources`), the `maas-gateway-watchdog` CronJob in `platform/30-gateway` restarts the gateway automatically, and `./deploy.sh lightspeed setup` does both by hand. Manual: `oc rollout restart deploy/maas-default-gateway-openshift-default -n openshift-ingress` |
| Backstage CR `Deployed=False`, *duplicate entries for key [name="dynamic-plugins-registry-auth"]* | an `extraFiles` Secret duplicates a volume the operator mounts itself; the operator then applies no change at all. `lightspeed setup` removes the duplicate entry |
| 429 from MaaS | the subscription budget (200k tokens/min) is used up: raise it in `stack/lightspeed/maas/subscription.yaml` |
| Very slow answers (minutes), vLLM log shows ~2 tokens/s | vLLM CPU starts one OpenMP thread per node core while the pod may only use its CPU limit, so it is CFS-throttled most of the time. The model specs set `VLLM_CPU_OMP_THREADS_BIND=nobind` + `OMP_NUM_THREADS` below the limit; `./deploy.sh models` applies it (with one replica the rolling update needs room for a second model pod: `oc patch deploy qwen3-0-6b-kserve -n maas-models --type=merge -p '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":1}}}}'`) |
| Slow answers (> 60 s) | Qwen3-0.6B on CPU, ~4-5k prompt tokens per turn (system prompt + tool definitions + tool result). Answers with OpenAI models take a few seconds |
| The answer ignores the tool / invents things | small-model limits: ask more directly ("call get_component_details for X"), or pick an OpenAI model. The tool outputs are short Markdown for this reason |
| A long answer (the CI table) stops halfway | Qwen3-0.6B has an 8k context that holds the tools, the tool result, its reasoning and the answer. The tools keep their output compact and say `/no_think` at the end of their result; `VLLM_MAX_TOKENS` is 2048 |
| `lightspeed test` / `ask`: `error executing command in container: signal: killed` | the Developer Hub operator replaced the pod (it can roll once more after `setup`). `ask` waits for the rollout and asks again once |
| *MCP server ... is not configured* in the MCP settings | the name in `lightspeed.mcpServers` must match `mcp_servers[].name` in `lightspeed-stack.yaml` |
