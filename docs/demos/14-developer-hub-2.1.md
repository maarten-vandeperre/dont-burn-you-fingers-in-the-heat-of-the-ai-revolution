# Demo 14: Developer Hub 2.1 — an agent-ready developer portal

**The story:** the Red Hat Developer Hub 2.1 announcement
(https://www.redhat.com/en/blog/red-hat-developer-hub-21-agent-ready-extended-support-new-plugin-architectures)
puts the portal between AI coding agents and the organization: agents (and the developers behind
them) find what exists and what is allowed in the catalog, act through MCP tools, and the AI assets
themselves become catalog entries. On this platform every part of that runs live:

| Blog topic | What you show here | Maturity in 2.1 |
|---|---|---|
| AI Catalog, integrated with OpenShift AI | `/ai-catalog`: the models OpenShift AI serves (OpenShift AI connector, model cards from the OpenShift AI model catalog), the platform's MCP servers, skills, rules and an agent | Developer Preview |
| MCP tools from plugins | Developer Hub as MCP server: catalog, TechDocs, templates, and new in 2.1 **Kubernetes** and **Scorecard** tools | Developer Preview |
| Intelligent assistant (formerly Developer Lightspeed) | the assistant on the platform's own models with organization-specific tools and prompts | see demo 13 |
| Agent-friendly CLI | `rhdh-cli`: OAuth login against Developer Hub, catalog / docs / templates as JSON for agents | community preview |
| New plugin architecture | the new frontend system: plugins wire themselves; header, AI Catalog and Scorecard configured in `app-config` only | GA |
| Extended support | 10-month support window per release (was 6 for 1.x) | talk track |

Orchestrator MCP tools (the third integration the blog names) need OpenShift Serverless, Knative and
the Serverless Logic operator; they are **not** part of this platform.

**Duration:** 15 minutes (A 4, B 4, C 3, D 2, E 2).

```
OpenShift AI                                  Developer Hub 2.1 (namespace rhdh)
 LLMInferenceService qwen3-0-6b ──┐            kserve-kubeflow-connector ──▶ AiModelServerAPI maas-models-qwen3-0-6b
   rhdh.io/catalog-source         │ informer    (in-process, 2.1; no sidecars)     techdocs: model card
   rhdh.io/catalog-model          ├───────────▶ catalog-backend-module-model-catalog
 model catalog (rhoai-model-      │             ai-catalog page ◀── API mcp-server, AiResource skill/rule/agent
   registries), source "Platform  │                                 (catalog-templates/ai-assets.yaml)
   models" = model cards ─────────┘             mcp-actions-backend /api/mcp-actions/v1/backstage
 model registry platform-registry                  catalog, techdocs, scaffolder, kubernetes, scorecard tools
                                               auth (/oauth2) + Client ID Metadata Documents ◀── rhdh-cli
```

## Before you start

```bash
./deploy.sh stack                 # once; Developer Hub 2.1 operator (fast-2.1), OpenShift AI incl. model registry
./deploy.sh rhdh                  # catalog, plugins (stack/developer-hub/dynamic-plugins.yaml), ~10 min
./deploy.sh lightspeed setup      # the intelligent assistant (demo 13)
./deploy.sh gitlab                # pushes app/software-templates to GitLab (the LLM application template)
```
Checks: `oc get pods -n rhdh` (Developer Hub `2/2`), `oc get modelregistry -n rhoai-model-registries`,
and in Developer Hub the **AI Catalog** shows two models. Tabs to open: Developer Hub, OpenShift AI
(app launcher in the Developer Hub header), Argo CD.

---

## Part A: the AI Catalog, fed by OpenShift AI (4 minutes)

**A1. Models straight from OpenShift AI.**
* **Do:** Developer Hub > **AI Catalog** (`/ai-catalog`). Filter on type *ai-model-server*. Open
  `maas-models-qwen3-0-6b`.
* **You see:** both served models (`maas-models-qwen3-0-6b`, `maas-models-gemma-3-270m-it`), kind
  `AiModelServerAPI`, system `models-as-a-service`, owner `platform-team`; the **Docs** tab is the model
  card ("Qwen3-0.6B on this platform": endpoint, runtime, what it is good for).
* **Say:** "Nobody registered these by hand. The OpenShift AI connector watches the inference services
  in the cluster and publishes every served model; the model card comes from the OpenShift AI model
  catalog. The source of truth stays in OpenShift AI: only models whose inference service is Ready
  are published, and the entity follows the service."
* **Do:** OpenShift AI (app launcher > OpenShift AI) > the **model catalog**, source **Platform models**:
  the same card. Then the **model registry** page: `platform-registry`.

**A2. MCP servers, skills, rules and agents as catalog entries.**
* **Do:** AI Catalog, filter *mcp-server*, then *skill*, *rule*, *agent*.
* **You see:** `developer-hub-mcp` (all tools), `developer-hub-mcp-compact`, `platform-mcp`; the skill
  `catalog-explore`; the rules `use-maas-models` and `deploy-with-gitops` (category + rationale); the
  agent `platform-assistant` (instructions, tools, model).
* **Say:** "This is what an AI coding agent should read before it writes code: which MCP servers
  exist, which skills to load, which rules apply. Same ownership, lifecycle and search as every other
  catalog entity, defined in git (`stack/developer-hub/catalog-templates/ai-assets.yaml`)."

## Part B: MCP tools from plugins (4 minutes)

**B1. The tool list.**
* **Do (terminal):**
  ```bash
  TOKEN=$(oc get secret rhdh-secrets -n rhdh -o jsonpath='{.data.MCP_TOKEN}' | base64 -d)
  RHDH=https://$(oc get route backstage-developer-hub -n rhdh -o jsonpath='{.spec.host}')
  curl -s -X POST $RHDH/api/mcp-actions/v1/backstage -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | sed -n 's/^data: //p' | jq -r '.result.tools[].name'
  ```
* **You see:** 26 tools, among them `kubernetes-mcp-extras.get-kubernetes-resources-for-entity` and
  `scorecard.get-entity-metrics` (new in 2.1) next to the catalog, TechDocs and template tools.
* **Say:** "Each plugin contributes its own actions; one setting (`backend.actions.pluginSources`)
  decides which ones become MCP tools. The agent asks Developer Hub, Developer Hub asks Kubernetes or
  the scorecard, with the caller's permissions."

**B2. Kubernetes and Scorecard through MCP.**
* **Do:** in an MCP client (Cursor, Claude Code, VS Code: server URL `$RHDH/api/mcp-actions/v1/backstage`,
  header `Authorization: Bearer $TOKEN`) ask "Which pods does model-router run and what is its
  scorecard?". Or with curl:
  ```bash
  call() { curl -s -X POST $RHDH/api/mcp-actions/v1/backstage -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
    | sed -n 's/^data: //p' | jq -r '.result.content[0].text' | head -c 600; echo; }
  call kubernetes-mcp-extras.get-kubernetes-resources-for-entity '{"kind":"Component","name":"model-router"}'
  call scorecard.get-entity-metrics '{"entityRef":"component:default/model-router"}'
  ```
* **You see:** the live pods of `model-router` in `ai-demo`; the file checks (README, Dockerfile,
  build script) of its source in GitLab.
* **Do:** Developer Hub > catalog > `model-router` > **Scorecard** tab: the same metrics as cards.

## Part C: the intelligent assistant (3 minutes)

* **Do:** the assistant button (bottom right). The three welcome prompts: *Catalog overview*,
  *Introduction to OpenShift AI and Developer Hub*, *Model router*. Click the second one.
* **You see:** the answer comes from the `list_deployed_models` tool of platform-mcp: the models of
  OpenShift AI, how to call them through MaaS.
* **Say:** "Renamed from Developer Lightspeed to the intelligent assistant in 2.1. The system prompt
  is ours: it tells the model to ground every answer in this organization's catalog, templates and
  deployments, and which tool to use for which question." Full walkthrough: demo 13.

## Part D: the agent-friendly CLI (2 minutes)

* **Do (terminal, with Node.js / npx):**
  ```bash
  npx @red-hat-developer-hub/cli auth login --backend-url $RHDH       # browser: Keycloak, then "Allow"
  npx @red-hat-developer-hub/cli actions sources add catalog
  npx @red-hat-developer-hub/cli actions sources add scaffolder
  npx @red-hat-developer-hub/cli actions sources add techdocs-mcp-extras
  npx @red-hat-developer-hub/cli catalog list --kind Component --fields metadata.name,spec.owner --output json
  npx @red-hat-developer-hub/cli catalog get model-router
  ```
* **You see:** the consent page of Developer Hub (`/oauth2/...`), then JSON a coding agent can use.
* **Say:** "No static tokens on laptops: the CLI registers itself with a Client ID Metadata Document
  and signs the developer in with their own identity. Give an agent this CLI and the skill
  `catalog-explore`, and it learns the domains, the governance docs and the right template before it
  generates a line of code."

## Part E: a new LLM application, model from the catalog, deployed by Argo CD (2 minutes)

* **Do:** Developer Hub > **Self-service** (header) > **LLM application**. Name `my-llm-app`, use case
  *FOOD QUESTIONS*, size *SMALL*, **Model**: `qwen3-0-6b` (the picker lists the models OpenShift AI
  serves; empty = the platform picks one for the use case). Create.
* **You see:** four steps: generate, GitLab repository, register, **Deploy with Argo CD**. Links to
  the repository, the catalog entry, the Argo CD application and the app.
* **Do:** open the component: the **Docs** tab (TechDocs from `mkdocs.yml` + `docs/`: overview, model,
  deployment), the **Argo CD** tab (Synced), **Topology** (the first build runs by itself), and on the
  overview the relation *depends on* `qwen3-0-6b`.
* **Say:** "Golden path: the developer picks a model the platform serves, gets code, docs and a GitOps
  deployment in one click. The model choice is recorded in the catalog as a dependency."
* **Then:** `oc create secret generic llm-credentials -n my-llm-app --from-literal=LLM_API_KEY=<MaaS key>`
  and `oc rollout restart deployment/my-llm-app -n my-llm-app` to let it answer.

---

## Part F: in IntelliJ

| File | What to point at |
|---|---|
| `stack/developer-hub/dynamic-plugins.yaml` | curated for 2.1: `ref://` for supported plugins, `oci://...:bs_1.54.9__<version>` for the AI connector, AI Catalog, MCP extras, Argo CD, Tekton, auth |
| `stack/developer-hub/app-config.yaml` | `catalog.providers.modelCatalog.kserve-kubeflow-connector` (reuses the Kubernetes cluster), `app.extensions` (AI Catalog, Scorecard tab), `globalHeader` (Self-service button, app launcher), `auth.clientIdMetadataDocuments`, `argocd.projectSettings` |
| `stack/developer-hub/catalog-templates/ai-assets.yaml` | `API` type `mcp-server` (`remotes`), `AiResource` skill / rule / agent |
| `stack/rhoai/model-catalog-sources.yaml` | the "Platform models" source of the OpenShift AI model catalog: the model cards |
| `models/qwen3-0-6b/llminferenceservice.yaml` | `rhdh.io/catalog-source`, `rhdh.io/catalog-model`, `rhdh.io/system`, `rhdh.io/owner` |
| `app/software-templates/llm-app/template.yaml` | the `EntityPicker` on `kind: Resource, spec.type: ai-model`; the `argocd:create-resources` step |
| `stack/developer-hub/backstage.yaml` | flavour `intelligent-assistant`, the 6Gi plugin volume |
| `stack/developer-hub/networkpolicy.yaml` | the 2.1 operator NetworkPolicies and what this platform opens on top |

## Upgrading from Developer Hub 1.10

What changed for this platform (all handled in the repository; the database step is manual):

| Change | What to do |
|---|---|
| Channel `fast` stays on 1.10 | subscription `rhdh` on `fast-2.1` (`stack/operators/developer-hub.yaml`) |
| Local database PostgreSQL 15 → 18, no in-place upgrade (the pod crash-loops: *data directory is of version '15'*) | before the upgrade `oc exec -n rhdh backstage-psql-developer-hub-0 -- pg_dumpall -U postgres > rhdh-pg15.sql`; after it: empty data directory (new PVC, or move `userdata` aside), then `oc exec -i -n rhdh backstage-psql-developer-hub-0 -- psql -U postgres < rhdh-pg15.sql` with Developer Hub scaled to 0. Only expected error: `role "postgres" already exists` |
| Sign-in fails with *Unknown auth provider 'oidc'* (404 on `/api/auth/oidc/start`) | the auth provider modules are plugins, disabled by default: enable `ref://backstage-plugin-auth-backend-module-oidc-provider` in `dynamic-plugins.yaml`. The upstream module has no `preferredUsernameMatchingUserEntityName` resolver (the backend then stops with *Sign-in resolver ... is not available*): use `emailMatchingUserEntityProfileEmail` (the User entity has the Keycloak e-mail in `spec.profile.email`) |
| Flavour `lightspeed` → `intelligent-assistant`, config key `lightspeed:` → `intelligent-assistant:` | `backstage.yaml`, `app-config-lightspeed.yaml` |
| Lightspeed Core: no separate Llama Stack `config.yaml`, LLMs under `inference.providers`, no `ENABLE_*` flags | `./deploy.sh lightspeed setup` |
| No bundled `./dynamic-plugins/dist/...` plugins, Backstage 1.54.9 | the curated `dynamic-plugins.yaml` |
| New frontend system: `mountPoints` / `dynamicRoutes` of 1.x plugins are replaced by `app.extensions`; header links via `globalHeader.menuItems` | `app-config.yaml` |
| OpenShift AI connector: the bridge sidecars (location, storage-rest, rhoai-normalizer) are replaced by the in-process `kserve-kubeflow-connector-backend` | plugins + `catalog.providers.modelCatalog` |
| `publish:gitlab`: `description` moved to `settings.description` | `app/software-templates/llm-app/template.yaml` |
| Operator NetworkPolicies around the Developer Hub pod (default deny) | `stack/developer-hub/networkpolicy.yaml` |
| More OCI plugins than fit in the 2Gi plugin volume (`ENOSPC`) | `spec.deployment.patch` with a 6Gi volume |

## Reset

* Generated applications: delete the Argo CD application (it prunes the namespace content),
  `oc delete project <name>`, unregister the component in Developer Hub, delete the GitLab repository
  `ai-platform/<name>`.
* AI assets: edit `ai-assets.yaml`, `./deploy.sh rhdh`.

## If something goes wrong

| Symptom | Cause and fix |
|---|---|
| AI Catalog empty | `oc logs -n rhdh deploy/backstage-developer-hub -c backstage-backend \| grep kserve-kubeflow-connector`: it must say *Catalog route discovered: yes* and *Reconciling LLMInferenceService*. The key under `catalog.providers.modelCatalog` must be `kserve-kubeflow-connector` |
| Models listed, Docs tab empty | the LLMInferenceService lacks `rhdh.io/catalog-source` / `rhdh.io/catalog-model`, or the model is not in the model catalog: `curl -H "Authorization: Bearer $(oc whoami -t)" https://model-catalog.<apps-domain>/api/model_catalog/v1alpha1/models?source=platform_models`. The model catalog rejects `hf://` artifact URIs (log: *unsupported scheme*) |
| `mcp-server` APIs missing, log *must have required property 'definition'* | the upstream `catalog-backend-module-ai-model` plugin is missing |
| Template fails at *Deploy with Argo CD*: `ETIMEDOUT ... :443` | the 2.1 NetworkPolicies: `oc apply -n rhdh -f stack/developer-hub/networkpolicy.yaml` |
| Argo CD app: *Namespace is not permitted in project* | `argocd.projectSettings.clusterResourceWhitelist` (Namespace) in `app-config.yaml` |
| Plugin installer `Init:Error`, *ENOSPC* | the plugin volume: `spec.deployment.patch` in `backstage.yaml` |
| `rhdh-cli auth login` fails at the consent page | the `backstage-plugin-auth` plugin and `auth.clientIdMetadataDocuments.enabled` |
