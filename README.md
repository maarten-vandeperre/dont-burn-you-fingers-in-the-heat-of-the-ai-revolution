# OpenShift 4.22 AI platform stack

Kustomize manifests plus one bash script that turn a fresh **OpenShift 4.22** cluster into a
complete AI and application platform. Every layer can be installed with `oc` or handed to Argo CD.

| Area | What gets installed and configured | Where to look |
|---|---|---|
| OpenShift AI 3.4 | Operator (`stable-3.4`), lean DataScienceCluster, dashboard, workbenches, KServe | console app launcher |
| MLflow | `mlflowoperator` component + cluster `MLflow` instance (SQLite + PVC, dev sizing) | OpenShift AI > Applications > MLflow UI |
| Gen AI studio playground | `llamastackoperator` + `genAiStudio`, plus a ready-made playground with both models in project `ai-tenants` | OpenShift AI > Gen AI studio > Playground |
| Models-as-a-Service | Kuadrant, MaaS gateway, PostgreSQL, free/premium subscriptions, API keys | `https://maas.<apps-domain>/v1` |
| Models | `gemma-3-270m-it` + `qwen3-0-6b` on vLLM (CPU, or GPU with `--accelerator gpu`) | `./deploy.sh test` |
| Tracing | Tempo (monolithic) + OpenTelemetry collector; vLLM and the mesh send spans to it; console tracing plugin | console > Observe > Traces |
| MaaS observability | RHOAI monitoring stack, token metrics per model/subscription | `./deploy.sh usage` |
| Kafka + Debezium | Streams for Apache Kafka (KRaft), Kafka Connect with the Debezium PostgreSQL connector, demo database | `./deploy.sh cdc-demo` |
| Service Mesh | OpenShift Service Mesh 3 (Istio + CNI), mesh-wide tracing, Kiali, Bookinfo demo with traffic | Kiali route |
| Developer Hub | RHDH with the full platform catalog, APIs, Kubernetes / Topology / Tekton / Argo CD views, source links to GitLab, platform templates and the "LLM application" project template (`app/software-templates`) | Developer Hub route |
| Single sign-on | Red Hat build of Keycloak, realm `demo`, one user (`admin` / `redhatdemo`) for Developer Hub and GitLab | Keycloak route `/admin` |
| GitLab | GitLab CE with the whole repository (`ai-platform/platform`), Keycloak sign-in, registered in Argo CD | GitLab route |
| Argo CD + Argo Rollouts | OpenShift GitOps (default instance) + cluster-scoped Argo Rollouts | Argo CD route |
| Tekton | OpenShift Pipelines | console > Pipelines |

```bash
export HF_TOKEN=hf_...            # Gemma is gated, see "Hugging Face token for Gemma"
./deploy.sh stack                 # everything with oc
./deploy.sh stack-argocd          # everything through Argo CD (folder must be in a pushed git repo)
./deploy.sh urls                  # all UIs
```

`stack` installs all operators at once, waits for them, creates the layers in dependency order
and ends with a URL overview. Anything that is not ready yet is listed at the end (exit code 1)
instead of blocking the rest. Plan for 30 to 45 minutes on a fresh cluster. Sizing: the default
CPU models need about 12 vCPU / 28 Gi on top of the platform services; the whole stack is
comfortable on 3 workers with 16 vCPU / 64 Gi each.

`stack-argocd` installs only the OpenShift GitOps operator with `oc`, then creates one Argo CD
Application per layer (`argocd/stack-applications.yaml` plus the MaaS ones). Secrets, the initial
DataScienceCluster and the MaaS glue steps stay imperative, exactly as described further down.
For the first run: `./deploy.sh configure`, commit and push the three `cluster-params.env`
files, then `./deploy.sh stack-argocd`.

## Getting started

From an empty OpenShift 4.22 cluster to running demos, in this order. Every step can be repeated
safely: it only creates or updates what is missing.

### 0. Before you start

* An OpenShift 4.22 cluster, and `oc login` as cluster admin in this terminal
  (sizing: about 3 workers with 16 vCPU / 64 Gi each)
* On your laptop: `bash`, `oc`, `curl`, `jq`, `git`, `tar` (macOS works as is)
* A **Hugging Face token** with access to Gemma (see "Hugging Face token for Gemma" below)
* Optional: an **OpenAI API key**; it enables the model alias `openai` and the fallback of `auto`

```bash
export HF_TOKEN=hf_...
export OPENAI_API_KEY=sk-...     # optional
```

### 1. The platform (30 to 45 minutes)

```bash
./deploy.sh stack
```
Installs all operators, OpenShift AI with Models-as-a-Service and the two models, tracing,
the service mesh, Kafka with Debezium, Keycloak, GitLab, Developer Hub, Argo CD and Argo Rollouts,
then pushes this repository to GitLab and wires Developer Hub. It ends with a URL overview and a
list of anything that is not ready yet.

**Check:** `./deploy.sh validate --quick`. When a step at the end did not finish, run it on its
own: `./deploy.sh gitlab` (push the source to GitLab), `./deploy.sh rhdh` (Developer Hub sign-in,
catalog, plugins), `./deploy.sh playground` (the ready-made playground), `./deploy.sh models`.

### 2. The demo applications (15 to 20 minutes)

The platform does not include the demo applications. They are deployed separately, into the
namespace `ai-demo`, with one command:

```bash
./deploy.sh app all
```

| Phase | What happens | Repeat it alone |
|---|---|---|
| setup | namespace `ai-demo` (in the mesh), a MaaS API key for the model-router, the OpenAI key (if exported), database secret, the coffee tables + Debezium connector, the MLflow experiment | `./deploy.sh app setup` |
| build | seven images built **in the cluster** from a clean copy of your local `app/` services (binary Docker builds uploaded with `oc start-build --from-dir`; about 10 minutes the first time: Gradle and Maven downloads) | `./deploy.sh app build` or `./deploy.sh app build rag-service` |
| deploy | Deployments, Services, routes, mesh policies, dashboards and alerts; waits for the pods | `./deploy.sh app deploy` |

**Check:**
```bash
./deploy.sh app urls      # demo UI and coffee shop
./deploy.sh app probe     # five lines, all OK: the mesh rules work
./deploy.sh app coffee    # a coffee order end to end, incl. the audit trail
```

**When a build fails**, the script prints the end of the first failed build log. More:
`oc logs -f bc/<service> -n ai-demo -c docker-build`; rebuild only that one with
`./deploy.sh app build <service>`. The builds run in the mesh namespace `ai-demo`, so build pods
must not get an Istio sidecar ("unable to extract binary build input" otherwise): the mesh
excludes pods labelled `openshift.io/build.name`, and `app build` adds that setting to older
installs automatically.

**OpenAI key later:** `OPENAI_API_KEY=sk-... ./deploy.sh app setup`, then
`oc rollout restart deploy/model-router -n ai-demo`.

### 2b. Optional: the trusted software supply chain (30 minutes)

```bash
./deploy.sh tssc setup     # Trusted Artifact Signer, Trusted Profile Analyzer (needs helm), Dev Spaces, pipeline
./deploy.sh tssc run       # signed commit -> verify -> CI -> sign -> SBOM -> TPA -> ACS -> release -> Argo CD
```
Details: `stack/tssc/README.md`; demo: `docs/demos/08-trusted-software-supply-chain.md`.

### 3. Check everything

```bash
./deploy.sh validate      # about 70 checks, writes validate-<date>.txt
```
A FAIL names the layer and the command that fixes it. `./deploy.sh debug` collects logs and
events into one file (without secrets) when you need help.

### 4. Demo it

* **[docs/demos](docs/demos/README.md)**: a platform tour and seven demos, each step as Do / You
  see / Say, in the OpenShift (AI) consoles and in IntelliJ
* Developer Hub: sign in with `admin` / `redhatdemo`; Create > templates
* Two laptop demos that need no cluster: `app/camel-ai-demo` (Camel with Kaoto and Hawtio) and
  `app/coffee-guardrails` (NeMo Guardrails with TrustyAI, podman compose)

### Day 2

| You changed | Run |
|---|---|
| code of a service in `app/` | `./deploy.sh app build <service>` (the pods restart with the new image) |
| manifests in `app/deploy` | `./deploy.sh app deploy` |
| something in `stack/` or `platform/` | `./deploy.sh stack` (only the differences are applied) |
| the Developer Hub catalog or templates | `./deploy.sh gitlab` and `./deploy.sh rhdh` |
| the cluster (new cluster, new domain) | `./deploy.sh configure`, then step 1 |

## Demo applications

`app/` holds seven Quarkus services (Java 25, Gradle) and two React UIs (Vite + Tailwind) that
use the whole stack. Next to the RAG demo there is **Platform Coffee**, the coffee app from the
"owning the inference layer" talk extended with a menu service for mesh releases and chaos, and an
audit trail built by Debezium. Together they show: RAG with LangChain4j on the MaaS models and OpenAI, an Apache Camel model router with
circuit breaker and fallback, mesh mTLS and per-identity authorization, canary / A-B / blue-green /
mirroring (and an Argo Rollouts canary), Debezium CDC from PostgreSQL into a MongoDB read model,
and traces, metrics and JSON logs for every hop.

```bash
./deploy.sh app all          # = app/demo.sh all: setup, in-cluster builds, deploy (see Getting started)
./deploy.sh app pattern canary 25
./deploy.sh app menu delay 50     # chaos on the coffee menu
./deploy.sh app coffee            # coffee order end to end, incl. the MongoDB audit trail
```

See `app/README.md` for the architecture, and **[docs/demos](docs/demos/README.md)** for the demo guides:
a [platform tour](docs/demos/00-platform-tour.md) of every UI, a [test checklist](docs/demos/testing.md)
with expected results, and seven demos (models and RAG, mesh security, deployment patterns, CDC,
observability, Developer Hub, Platform Coffee), each with a UI walkthrough and test commands.
[Service mesh manifests](docs/demos/service-mesh.md) is the mesh demos with the YAML field and the
`oc apply` for each change.

## Developer Hub: everything visible and manageable

`./deploy.sh rhdh` (run automatically at the end of `stack` and `stack-argocd`) turns Developer
Hub into the entry point for the whole platform:

| What | How it is wired |
|---|---|
| Catalog | Domain `ai-platform`, systems `openshift-platform`, `models-as-a-service`, `ai-demo`; every service, model, database, Kafka cluster, connector and platform service as an entity, with ownership, dependencies and links (console, Kiali, traces, Argo CD, demo UI). Rendered from `stack/developer-hub/catalog-templates/` with the cluster's apps domain and mounted as files |
| APIs | OpenAPI definitions for the BFF, rag-service, model-router (OpenAI compatible), orders and customer-views APIs, linked as provides / consumes |
| Kubernetes + Topology | Read-only `rhdh-kubernetes` service account (cluster `view` + logs and the CRDs used here). Workloads carry `backstage.io/kubernetes-id`; Topology shows the ai-demo services with their connections, routes, the Argo Rollout, VirtualServices, the LLMInferenceServices, Kafka and Debezium resources |
| Tekton | PipelineRuns from `app/demo.sh pipeline` are labelled per component and show up in its CI tab |
| Argo CD | Sync status of the stack Applications and of `ai-demo` (`app/demo.sh gitops <git-url>`) |
| Software templates (Create) | Switch the rag-service traffic pattern (canary with weight, A/B, blue, green, mirror); start / abort / retry the model-router Argo Rollout; scale a demo Deployment; scale a MaaS model (0 replicas of Qwen shows the OpenAI fallback) |

Templates write through a Developer Hub proxy (`/platform-actions`) with the separate
`rhdh-platform-actions` token, which may only patch VirtualServices, Rollouts and replicas in
`ai-demo`, and the replicas of the models in `maas-models`. Nothing else is writable from the portal.

Plugins are version dependent (bundled paths up to 1.9, OCI artifacts afterwards), so the script
reads the `dynamic-plugins.default.yaml` of the running Developer Hub and enables Kubernetes,
Topology, Tekton, Argo CD and the HTTP request and Kubernetes scaffolder actions from there. A
plugin the installed version does not offer is reported and skipped. With Argo CD, commit the
generated `stack/developer-hub/catalog/` and `dynamic-plugins.yaml`.

Demo shortcuts, not production settings: guest sign-in (configure OIDC / Keycloak and the RBAC
plugin before sharing), `NODE_TLS_REJECT_UNAUTHORIZED=0` for the in-cluster Argo CD and API
certificates, and the Argo CD admin password as credential (use a read-only Argo CD account).

## Single sign-on and GitLab

One user for every UI: **`admin` / `redhatdemo`** by default (`DEMO_ADMIN_USER` /
`DEMO_ADMIN_PASSWORD` before installing). It becomes the Keycloak master and realm `demo` user,
the Developer Hub catalog user and GitLab's root password. Passwords and client secrets go into
Secrets created by the script and reach the realm through KeycloakRealmImport placeholders, so
none of them is in git.

* **Keycloak** (`stack/keycloak`) is named `platform-sso`, so it never collides with a Keycloak
  that already runs in namespace `keycloak` (as on workshop clusters). Realm `demo` has the user,
  groups `platform-team` and `ai-app-team`, and the clients `developer-hub` and `gitlab`.
* **Developer Hub** signs in through Keycloak (`signInPage: oidc`); the Keycloak username is
  matched to the catalog User entity of the same name.
* **GitLab** (`stack/gitlab`) runs the Omnibus CE container with Keycloak sign-in.
  `./deploy.sh gitlab` creates an API token, the public project `ai-platform/platform`, pushes this
  repository into it and registers it with Argo CD. "admin" is a reserved name in GitLab, so the
  Keycloak user shows up there as `admin1`; the local admin is `root`.

On an existing stack: `./deploy.sh sso`, then `./deploy.sh gitlab` once GitLab answers (10 to 15
minutes on first start), then `./deploy.sh rhdh`.

## AI observability: dashboard and MLflow

* **OpenShift AI dashboard** (Observe & monitor > Dashboard). On 3.4 with COO 1.5 the Cluster,
  Models and Usage tabs need a global Perses datasource for Thanos plus four workarounds (network
  policies, a missing Prometheus secret, the datasource bearer token). They live in
  `observability/dashboard-datasource`, are applied with the observability layer and can be
  re-applied with `./deploy.sh dashboards`. Taken from davidseve/rhoai-platform-ops, validated on
  RHOAI 3.4.4 / COO 1.5.2 / OCP 4.22; each file says when it can go.
* **MLflow tracing.** The OpenTelemetry collector in `tracing-system` has a second pipeline: spans
  marked `mlflow.export` (the coffee shop's order flow) go to the OpenShift AI MLflow server's OTLP
  endpoint, experiment `coffee-shop`, workspace `ai-demo`, authenticated with the collector's
  service account (role `mlflow-integration`). `./deploy.sh app setup` creates the experiment.
  Everything else, and these spans too, still goes to Tempo.

## Stack notes

* **Operators that are already installed** (common on demo/sandbox clusters) are detected: a
  Succeeded CSV in any namespace counts, a second Subscription for the same package elsewhere is
  removed again, and so is a second OperatorGroup in a namespace that already had one. When OLM
  reports a problem (ResolutionFailed, TooManyOperatorGroups, unsupported install mode, failed
  CSV) the script prints it after 2 minutes and moves on instead of waiting 20.
* **OpenShift AI version.** The stack pins 3.4 (`stable-3.4`). If another version is installed,
  run `./deploy.sh switch-rhoai --to 3.4 --no-deploy` first.
* **Gateway API and Service Mesh side by side.** On 4.22 the ingress operator runs the MaaS
  gateway through its embedded Sail library, not through an OLM subscription, so installing
  Service Mesh 3 does not collide with it. The mesh additionally only manages namespaces labelled
  `istio-discovery=enabled` (`istio-system`, `mesh-demo`). To add your own namespace: that label,
  `istio-injection=enabled`, and a copy of `stack/servicemesh/demo/podmonitor.yaml`.
* **Tracing.** One OTLP endpoint for everything: `otel-collector.tracing-system.svc:4317` (gRPC) /
  `:4318` (HTTP). Apps, Camel routes, LangChain4j calls, JDBC / MongoDB / Kafka clients and the mesh
  sidecars all report there; a trace ends with the model-router's call to the MaaS gateway. vLLM
  itself is not traced by default: the Red Hat vLLM CPU image has no OpenTelemetry packages and
  refuses to start with `--otlp-traces-endpoint`. With an image that has them, deploy with
  `--vllm-tracing` (uses the `*-traced` model overlays, service names `vllm-<model>`).
  OpenShift AI's own monitoring stack keeps its separate Tempo in `redhat-ods-monitoring`.
* **Kafka.** Single dual-role KRaft node and replication factor 1 to keep the footprint small;
  raise `replicas` in `stack/kafka/kafka.yaml` and the replication factors for anything real.
  Kafka Connect builds its image (OpenShift Build into the `debezium-connect` ImageStream) from
  the Red Hat Maven repository; bump Debezium by changing the version in the artifact URL. The
  connector reads its password from the `inventory-db` Secret through the Strimzi Kubernetes
  secret config provider.
* **Argo Rollouts** is cluster scoped through `CLUSTER_SCOPED_ARGO_ROLLOUTS_NAMESPACES` on the
  GitOps subscription, with the `RolloutManager` in `argo-rollouts`.
* **MLflow** uses SQLite on a PVC (single replica). For production switch to
  `backendStoreUriFrom` (PostgreSQL) and S3 artifacts.
* **Argo CD RBAC.** `argocd/rbac.yaml` gives the GitOps application controller cluster-admin,
  which a platform bootstrap like this needs; scope it down afterwards.

## Troubleshooting commands

| Command | What it does |
|---|---|
| `./deploy.sh validate` | End-to-end check of every layer through `oc` and the routes (about 70 checks: operators, OpenShift AI, models and MaaS calls, playground, tracing, mesh, Kafka/Debezium, GitOps, Keycloak, GitLab, Developer Hub plugins and sign-in, every demo app, mesh probe, RAG answer, coffee order with audit trail). PASS / WARN / FAIL report in `validate-<date>.txt`, no secret values. `--quick` skips the model calls |
| `./deploy.sh status` | Platform resources, models, MaaS objects, stack services, Argo CD apps |
| `./deploy.sh debug` | Writes `debug-<date>.txt`: operator versions, node capacity, Developer Hub plugin install log, extensions, backend errors, model pods with download and server logs, events, MaaS gateway. No secret values; share this file when asking for help |
| `./deploy.sh models` | Re-applies the model deployments (for example after changing `--accelerator` or `--vllm-tracing`) and waits for them, with diagnostics on failure |
| `./deploy.sh wait` | Restarts crash-looping model pods and waits for the models and their MaaS registration |
| `./deploy.sh hf-check` | Checks that the Hugging Face token may download Gemma, and explains the fix for its token type |
| `./deploy.sh rhdh-plugins [words]` | Lists the plugin packages this Developer Hub offers, e.g. `./deploy.sh rhdh-plugins tekton argo` |
| `./deploy.sh rhdh` | Re-renders the catalog, rewires tokens and enables the plugins found, then restarts Developer Hub |
| `./deploy.sh sso` / `gitlab` | Installs or updates Keycloak and GitLab / pushes the repository into GitLab and registers it with Argo CD |
| `./deploy.sh playground` | Re-creates the playground MaaS key and the ready-made playground in `ai-tenants` |
| `./deploy.sh dashboards` | Data for the OpenShift AI observability dashboard (Perses datasource and COO 1.5 workarounds) |
| `./deploy.sh app mlflow` | (Re)creates the MLflow experiment `coffee-shop` and points the collector's MLflow pipeline at it |
| `./deploy.sh test` / `usage` | Calls both models through MaaS / token usage per model and subscription |
| `./deploy.sh app status` / `app probe` | Demo app pods and mesh objects / who-can-access-who check |

## Layout

```
stack/
  operators/               all operator subscriptions of the stack (+ ../../operators)
  rhoai/                   MLflow instance
  tracing/                 Tempo, OpenTelemetry collector, console tracing plugin
  tssc/                    trusted software supply chain: RHTAS, RHTPA, Dev Spaces, signing pipeline (./deploy.sh tssc)
  servicemesh/             Istio, Istio CNI, Telemetry, Kiali, monitoring, demo/ (Bookinfo)
  kafka/                   Kafka (KRaft), Kafka Connect + Debezium, demo database, connector
  developer-hub/           Backstage instance, app-config (Keycloak sign-in, GitLab), catalog, templates
  keycloak/                Keycloak "platform-sso", its database, route and realm "demo"
  gitlab/                  GitLab CE (Omnibus) with Keycloak sign-in
  gitops/                  Argo Rollouts RolloutManager
operators/                 Connectivity Link, LeaderWorkerSet, cert-manager subscriptions
rhoai/                     OpenShift AI operator subscription + lean DSCs (switch-rhoai, stack)
platform/                  MaaS platform: Kuadrant, Authorino TLS, gateway, PostgreSQL, DSC fields,
                           60-playground (ready-made Gen AI playground, 3.4)
  30-gateway/cluster-params.env   MaaS hostname + TLS secret (./deploy.sh configure)
models/                    Gemma + Qwen; overlays cpu|gpu, and cpu-traced|gpu-traced (--vllm-tracing)
governance/                MaaSAuthPolicy + free / premium MaaSSubscriptions
observability/             RHOAI monitoring stack, telemetry (+ Loki usage logs on 3.5)
argocd/                    Application templates (MaaS, observability, stack) + RBAC
app/                       demo applications (Quarkus, React, Camel, LangChain4j) + deploy/ + demo.sh
docs/demos/                short demo guides
deploy.sh
```

## MaaS details

Everything below covers the Models-as-a-Service part, which also works on its own:
`./deploy.sh oc` / `./deploy.sh argocd` on a cluster that already runs OpenShift AI 3.4 or 3.5.

### Prerequisites

* Stack: OpenShift **4.22**, cluster-admin, egress to `registry.redhat.io`, Hugging Face and
  `maven.repository.redhat.com`
* MaaS only: OpenShift 4.19.9+ with **OpenShift AI 3.4 or 3.5** installed and a `default-dsc` DataScienceCluster
* **Red Hat Connectivity Link** operator (or pass `--with-operators`)
* `oc` logged in as cluster-admin; `jq` and `curl` for `./deploy.sh test`
* For Argo CD: the **OpenShift GitOps** operator and this folder in a git repo Argo CD can read
* `export HF_TOKEN=hf_...` (Gemma is gated, see [Hugging Face token for Gemma](#hugging-face-token-for-gemma))

### Deploy with oc

```bash
export HF_TOKEN=hf_xxx
./deploy.sh oc                         # auto-detects 3.4 vs 3.5, CPU serving
./deploy.sh oc --accelerator gpu       # 1 NVIDIA GPU per model (Ampere or newer)
./deploy.sh test
```

### Deploy with Argo CD

```bash
export HF_TOKEN=hf_xxx
./deploy.sh configure                  # writes platform/30-gateway/cluster-params.env
git add -A && git commit -m "maas: cluster params" && git push
./deploy.sh argocd                     # secrets + RBAC + Applications, then waits for sync
./deploy.sh test
```

Options: `--repo-url`, `--revision` (default: `origin` remote and current branch),
`--rhoai-version`, `--accelerator`, `--with-operators`. Private repos need a repository
credential in Argo CD first. To create the Applications by hand, replace the `__...__`
placeholders in `argocd/applications.yaml`, but still run the bootstrap part of the script
(or create the secrets yourself), because secrets are deliberately not in git.

What the script does imperatively in both modes, and why:

| Step | Reason |
|---|---|
| `hf-token`, `postgres-creds`, `maas-db-config` secrets | never in git (use Sealed Secrets / ESO for production) |
| enable User Workload Monitoring | merges into an existing `cluster-monitoring-config` instead of overwriting it |
| `SSL_CERT_FILE` env on the Authorino deployment | object owned by the Authorino operator |
| 3.5 only: copy `maas-db-config` to `redhat-ai-gateway-infra` | namespace only exists after MaaS is enabled |
| label the maas-api namespace `maas.opendatahub.io/gateway-access=true` | same |

### Hugging Face token for Gemma

`google/gemma-3-270m-it` is a gated repo. Qwen needs no token. The token ends up in the
`hf-token` secret in `maas-models` and reaches the KServe storage-initializer through the
`hf-model-puller` ServiceAccount. It only works if **both** of these are true:

1. The Hugging Face account that owns the token has accepted the Gemma license. Open
   https://huggingface.co/google/gemma-3-270m-it while logged in with that account: it either says
   you have been granted access, or shows the button to accept.
2. The token may read gated repos. Classic `read` / `write` tokens always can. A **fine-grained**
   token needs, under Settings > Access Tokens > edit token > Repositories:
   **"Read access to contents of all public gated repos you can access"**. Editing it keeps the
   token value, so nothing changes in the cluster.

If either is missing, the storage-initializer fails with `403 ... Cannot access gated repo ...
you are not in the authorized list` and the pod goes to `Init:CrashLoopBackOff`.

Check and fix:

```bash
./deploy.sh hf-check     # tests HF_TOKEN from your shell, or else the token in the cluster secret
```

It prints the account and token type and, when access is denied, the exact steps for that token
type. Hugging Face's own denials are recognised by their `X-Error-Code` header, so a 403 from a
corporate proxy is reported as "could not verify" instead. The same check runs at the start of
every deploy (warning only).

After fixing:

| What you changed | Next step |
|---|---|
| Accepted the license and/or edited the fine-grained token | `./deploy.sh wait` (same token, it restarts the Gemma pod and retries) |
| Created a new token | `export HF_TOKEN=hf_...; ./deploy.sh oc` (updates the secret), or update the secret yourself and run `./deploy.sh wait` |

Manual equivalent of `hf-check`:

```bash
T=$(oc get secret hf-token -n maas-models -o jsonpath='{.data.HF_TOKEN}' | base64 -d)
curl -s -H "Authorization: Bearer $T" https://huggingface.co/api/whoami-v2 | jq -r '.name, .auth.accessToken.role'
curl -sI -H "Authorization: Bearer $T" https://huggingface.co/google/gemma-3-270m-it/resolve/main/config.json | grep -iE '^HTTP|x-error'
# OK = HTTP 200 or 302 and no x-error-code line
```

No token at all: point Gemma at an ungated copy of the same weights (Gemma license terms still
apply), e.g. `uri: hf://unsloth/gemma-3-270m-it` in `models/gemma-3-270m-it/llminferenceservice.yaml`.

### Switching OpenShift AI version (3.5 <-> 3.4)

```bash
export HF_TOKEN=hf_...
./deploy.sh switch-rhoai --to 3.4        # asks you to type 'switch' before touching anything
./deploy.sh switch-rhoai --to 3.5        # back to the stable-3.x channel
```

OLM cannot downgrade an operator, so this is a **reinstall**, not an upgrade:

| Step | What happens |
|---|---|
| 1 | Removes `governance/`, `maas-models` and the PoC database `maas-db` (MaaS API keys are lost) |
| 2 | Documented CLI uninstall (`delete-self-managed-odh` ConfigMap): the operator removes its components and `redhat-ods-*` namespaces |
| 3 | Deletes the operator Subscription + CSV, leftover webhooks and **all OpenShift AI CRDs**. Required: 3.5 stores for example LLMInferenceService as `v1alpha2`, and OLM refuses a 3.4 CRD that drops a stored version |
| 4 | Installs the operator from `stable-3.4` (latest 3.4.z) or `stable-3.x`, and a lean DSC from `rhoai/datasciencecluster-<version>.yaml` |
| 5 | Runs the normal `./deploy.sh oc` (skip with `--no-deploy`) |

Before confirming, the script lists every InferenceService / LLMInferenceService in the cluster:
they disappear with their CRDs. User projects themselves, Kuadrant, the MaaS gateway and the
observability operators stay. Argo CD managed installs: `./deploy.sh destroy` first, then switch,
then `./deploy.sh argocd`.

What changes on 3.4: the playground works through the regular `llamastackoperator` component (no
OGX module issue), MaaS lives in `redhat-ods-applications`, and the logs based usage dashboards
(Loki) do not exist; the metrics based MaaS observability dashboard does. Gateway telemetry needs
3.4.4 or newer and is skipped on older 3.4.z builds.

### Token consumption dashboards

| Where | What | Version |
|---|---|---|
| RHOAI dashboard > Observe & monitor | Per-request usage: tokens per model, subscription and user, admin and per-user views (logs based, Loki) | 3.5 |
| RHOAI dashboard > MaaS observability dashboard | Token consumption, request counts and rate-limit hits per subscription, CSV export | 3.4 + 3.5 (Tech Preview) |
| `./deploy.sh usage [--window 7d]` | Tokens / requests / 429s per model and subscription, straight from Prometheus | 3.4 + 3.5 |

What gets switched on: the monitoring stack in `default-dsci`, gateway telemetry on the MaaS
tenant config (adds `model` and `subscription` labels to the token counters), and on 3.5 the
usage-log pipeline. Per-user metrics are off by default for privacy; enable them with
`--capture-user`. To add only the dashboards to an existing install: `./deploy.sh observability`.

Rate-limit counters live in Limitador memory, so `usage` numbers reset when that pod restarts.
The 3.5 logs-based dashboards do not have that limitation.

### Gen AI playground

**RHOAI 3.5 known issue:** on several 3.5.x builds the OGX module CRD is not shipped. Setting
`ogx: Managed` then leaves `OGXReady=False` ("no matches for kind OGX") and keeps the whole DSC
NotReady. On 3.5 the playground is therefore opt-in: `./deploy.sh playground` enables `ogx`,
and rolls it back to `Removed` automatically if it hits this issue. Every run also starts with
a self-heal check: if `ogx: Managed` is stuck on this error (from an earlier run or a manual
edit), it is set back to `Removed` before anything else happens. MaaS itself is not affected.

The DSC gets `ogx` (3.5, via `./deploy.sh playground`) or `llamastackoperator` (3.4) set to `Managed`, the dashboard gets
`genAiStudio: true`, and both models carry the `opendatahub.io/genai-asset: "true"` label so
they show up as AI asset endpoints. Qwen also has tool calling enabled (`hermes` parser), so it
can use MCP servers in the playground. Gemma 3 270M is too small for reliable tool calling.

A playground is created per project, from the UI (one click, it deploys an OGX / Llama Stack
server into the project):

1. RHOAI dashboard > **Gen AI studio > AI asset endpoints**, project `maas-models`
2. **Add to playground** on both models, then **Create playground**
3. **Gen AI studio > Playground**

### Use it

```bash
HOST=maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
KEY=$(curl -sk -X POST https://$HOST/maas-api/v1/api-keys \
  -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
  -d '{"name":"my-key","subscription":"small-models-free","expiresIn":"24h"}' | jq -r .key)

curl -sk https://$HOST/v1/models -H "Authorization: Bearer $KEY" | jq '.data[].id'
```

Any OpenAI compatible client works with `base_url=https://$HOST/v1` and the API key.
Use the model `id` returned by `/v1/models`. Premium quota:
`oc adm groups add-users maas-premium-users <user>` and create keys with `"subscription":"small-models-premium"`.

### Design choices and caveats

* **Gateway exposure.** The gateway runs as a ClusterIP service behind a TLS passthrough
  Route on `maas.<apps-domain>`, serving the default ingress wildcard cert. This works on any
  platform without a LoadBalancer or DNS changes. For a cloud LoadBalancer instead, remove the
  `networking.istio.io/service-type` annotation and `route.yaml`.
* **Partial objects.** `DataScienceCluster`, `OdhDashboardConfig` and the Authorino objects are
  applied with server-side apply, so only the MaaS fields are owned. Argo CD will never prune or
  delete them (`Prune=false,Delete=false`).
* **3.4 vs 3.5.** 3.4 enables MaaS via `kserve.modelsAsService`, 3.5 via
  `aigateway.modelsAsAService` (the 3.4 field is frozen in 3.5).
* **Gemma token.** See [Hugging Face token for Gemma](#hugging-face-token-for-gemma). If the
  `hf-check` passes but the pod still fails with 401, your KServe build does not pass the token
  from the ServiceAccount on: mirror the model into an OCI modelcar image and use `uri: oci://...`.
* **Xet download hang.** If a storage-initializer is stuck in `Init:0/1`, the script sets
  `HF_HUB_DISABLE_XET=1` on it after 5 minutes. KServe can revert that on reconcile.
* **PostgreSQL** in `maas-db` and **MinIO** in `redhat-ods-monitoring` are single-replica PoCs.
  Use `--postgres-url` and real S3/ODF storage for anything that matters.
* **Namespace labels.** Both the maas-api namespace and `redhat-ods-applications` get
  `maas.opendatahub.io/gateway-access=true`. On 3.5 a missing label on `redhat-ods-applications`
  makes the dashboard fail with "Error loading API keys ... (unmarshall)" and "Models as a Service
  could not be loaded" (RHOAIENG-83207).
* **Stuck models** no longer block the script. Error states (`Error`, `CrashLoopBackOff`,
  `OOMKilled`, `ImagePullBackOff`) are diagnosed immediately; silent states (`Pending`, a hanging
  download, running but never ready) are reported every minute and diagnosed after
  `--model-timeout` minutes (default 30). The script then finishes the rest and exits non-zero.
  After a fix: `./deploy.sh wait`.
* **Argo CD RBAC.** `argocd/rbac.yaml` grants the GitOps controller cluster-admin. Scope it down
  for production.
* **Swap models** by editing `spec.model.uri` (for example `hf://Qwen/Qwen2.5-0.5B-Instruct`)
  and the names in `governance/`.

### Clean up

```bash
./deploy.sh destroy                 # models, governance, gateway, PoC DB (or the Argo CD apps)
./deploy.sh destroy --disable-maas  # also switch MaaS off in the DSC
```

Stack layers are removed per layer, in reverse order, for example
`oc delete -k stack/developer-hub`, `stack/kafka`, `stack/servicemesh`, `stack/tracing`. With
Argo CD: `oc delete application.argoproj.io -n openshift-gitops stack-<layer>` (cascading).
Operators stay installed on purpose (`Delete=false`); remove their Subscriptions and CSVs if needed.
