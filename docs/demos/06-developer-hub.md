# Demo 6: Developer Hub

**The story:** the whole platform is one catalog. Developers find every service, API, model and
database with its owner, source code and live status; day-2 operations and new projects are
self-service templates with tightly scoped permissions.

**Duration:** 15 minutes (10 UI, 5 IntelliJ).

Every step below has three parts: **Do**, **You see**, **Say**.

---

## Before you start

1. Terminal: `./deploy.sh validate --quick` (the rhdh lines, including the `Topology data` checks, PASS).
2. Browser: **Developer Hub** (URL from `./deploy.sh urls`), **Demo UI**, **GitLab**.
3. **IntelliJ** on the repository folder.

---

## Part A: the catalog (5 minutes)

**A1. Sign in.**
* **Do:** Developer Hub > **Sign in** (Keycloak) > `admin` / `redhatdemo`.
* **Say:** "Single sign-on: the same account works for GitLab and Developer Hub."

**A2. The systems.**
* **Do:** **Catalog**, filter **Kind: System**.
* **You see:** `openshift-platform`, `models-as-a-service`, `ai-demo`.
* **Do:** open **ai-demo** > **Diagram** (or the relations card).
* **You see:** the seven components, their APIs, the models, Kafka, the connector and the databases.
* **Say:** "A new developer sees in one picture what exists, who owns it and what depends on what."

**A3. One component, everything about it.**
* **Do:** open component **rag-service**. Walk through the tabs:
  * **Topology**: v1 and v2 pods with live status; click a pod for its logs
  * **Kubernetes**: Deployments, pods, VirtualService and DestinationRule
  * **API**: `rag-api` (OpenAPI) and what it consumes (`model-router-api`)
  * **CI** (Tekton) and **CD** (Argo CD), after `./deploy.sh app pipeline <url>` / `app gitops <url>`
  * **View source** on Overview: opens `app/rag-service` in GitLab
* **Say:** "No cluster login, no kubectl: everything a developer needs about their service, on one page."

**A4. Models are entities too.**
* **Do:** **Catalog**, **Kind: Resource**, type **ai-model** > `qwen3-0-6b` > **Kubernetes** tab.
* **You see:** the LLMInferenceService and its MaaSModelRef; on **Dependencies**, the model-router depends on it.

---

## Part B: change the platform from the portal (5 minutes)

**B1. Traffic pattern.**
* **Do:** **Create** > **Mesh: switch rag-service traffic pattern** > canary, 30% > **Create**.
* **You see:** the run with its step; then in the demo UI **Traffic patterns** > **Send traffic**: about 30% v2.
* **Say:** "A developer releases without cluster rights. The template runs with a token that may
  only patch VirtualServices, Rollouts and replicas in this project."

**B2. Scale a model (and see the fallback).**
* **Do:** **Create** > **Models-as-a-Service: scale a model** > `qwen3-0-6b`, 0 replicas. Ask with
  **auto** in the demo UI (OpenAI answers). Then the same template with 1 replica.

**B3. Chaos on the coffee menu.**
* **Do:** **Create** > **Coffee menu: traffic & chaos** > delay, 50% (then see demo 7).

**B4. Start a new application.**
* **Do:** **Create** > **LLM application (Quarkus, LangChain4j, React)**:
  * **Metadata**: name `recipe-helper`, a description, package name `com.example.recipes`
  * **Model selection**: use case **FOOD QUESTIONS**, t-shirt size **SMALL (max 200 characters text)**
  * **Create**
* **You see:** three steps (generate, GitLab repository, register); links to the repository and the
  new catalog entry.
* **Say:** "Nobody chose a model: the platform maps the use case to a model and the size to limits.
  Code, repository, manifests and catalog entry exist in thirty seconds."
* **Do (optional):** the three commands on the result page deploy it; its **Topology** tab then shows it.

---

## Part C: how it is wired, in IntelliJ (5 minutes)

**C1. The catalog is YAML.**
* **Do:** open `stack/developer-hub/catalog-templates/ai-demo.yaml`.
* **Point at:** component `rag-service` with annotations `backstage.io/kubernetes-id` (links to the
  pods), `backstage.io/source-location` (GitLab), `providesApis` / `consumesApis`.

**C2. A day-2 template.**
* **Do:** open `stack/developer-hub/catalog-templates/template-traffic-pattern.yaml`.
* **Point at:** `parameters` (the form) and a step with `action: http:backstage:request`, `PATCH` on
  `/proxy/platform-actions/...virtualservices/rag-service`.

**C3. Why the templates cannot do more.**
* **Do:** open `app/deploy/base/rhdh-actions-rbac.yaml`.
* **Point at:** the Role: only `patch` on virtualservices, rollouts and deployments/scale.

**C4. The new-project template.**
* **Do:** open `app/software-templates/llm-app/template.yaml`, then the folder `skeleton`.
* **Point at:** the two parameter steps (Metadata, Model selection), the hidden mapping under
  `values` (`modelId`, `maxChars`), the steps `fetch:template`, `publish:gitlab`, `catalog:register`;
  the skeleton files with `${{ values.name }}` placeholders.

---

## Part D: prove it from the terminal (optional)

```bash
./deploy.sh rhdh-plugins tekton argo topology kubernetes http-request gitlab
TOKEN=$(oc get secret rhdh-platform-actions-token -n rhdh -o jsonpath='{.data.token}' | base64 -d)
oc --token="$TOKEN" auth can-i patch virtualservices -n ai-demo     # yes
oc --token="$TOKEN" auth can-i delete deployments -n ai-demo        # no
oc --token="$TOKEN" auth can-i get secrets -n ai-demo               # no
```

## If something goes wrong

* **Sign-in fails:** `oc get keycloakrealmimport demo-realm -n keycloak` must be Done; then `./deploy.sh rhdh`.
* **Topology says "No resources found":** `./deploy.sh validate` shows per component whether the
  workloads are missing (`./deploy.sh app all`) or Developer Hub cannot see them (`./deploy.sh rhdh`).
* **A tab is missing:** `./deploy.sh rhdh-plugins <word>`, then `./deploy.sh rhdh`.
* **LLM application template missing:** `./deploy.sh gitlab`, then `./deploy.sh rhdh`.
* **Template fails with 403:** `oc get rolebinding rhdh-platform-actions -n ai-demo` (created by
  `./deploy.sh app deploy`) and `-n maas-models`.
