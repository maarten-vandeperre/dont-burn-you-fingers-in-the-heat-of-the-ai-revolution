# Platform tour

`./deploy.sh urls` and `./deploy.sh app urls` print every URL below for your cluster.

Sign-in: Developer Hub and GitLab use Keycloak (realm `demo`, **`admin` / `redhatdemo`**); GitLab
also accepts its local admin `root` with the same password. OpenShift, OpenShift AI, Kiali and
Argo CD use the OpenShift login. The demo UI and the coffee shop have no login.

| UI | Open | First thing to look at |
|---|---|---|
| Demo UI | `https://ai-demo-ai-demo.<apps-domain>` | Four tabs: Ask, Traffic patterns, CDC, Mesh access |
| Coffee shop | `https://coffee-ai-demo.<apps-domain>` | Order, Orders, Audit, Menu & resilience |
| Keycloak | `https://platform-sso-keycloak.<apps-domain>/admin` | Realm `demo`: users, clients `developer-hub` and `gitlab` |
| GitLab | `https://gitlab-gitlab.<apps-domain>` | Group `ai-platform`, project `platform` (all source) |
| OpenShift console | `https://console-openshift-console.<apps-domain>` | Workloads > Topology, project `ai-demo` |
| OpenShift AI | console app launcher (grid icon, top right) > Red Hat OpenShift AI | Gen AI studio > Playground, project `ai-tenants` |
| Kiali | `https://kiali-istio-system.<apps-domain>` | Traffic Graph, namespace `ai-demo` |
| Traces | console > Observe > Traces | Service `frontend`, newest trace |
| Dashboard | console > Observe > Dashboards | "AI demo: models, RAG, CDC and mesh" |
| Developer Hub | `https://backstage-developer-hub-rhdh.<apps-domain>` | Catalog > Systems > `ai-demo` |
| Argo CD | `https://openshift-gitops-server-openshift-gitops.<apps-domain>` | Applications (after `stack-argocd` or `app gitops`) |
| Pipelines | console > Pipelines, project `ai-demo` | PipelineRuns (after `app pipeline`) |

## What each UI shows

**Demo UI.** The application itself. Ask runs RAG against the models, Traffic patterns shows
which rag-service version answers, CDC writes to PostgreSQL and shows the MongoDB projection,
Mesh access probes who may call whom.

**OpenShift console.** Workloads > Topology, project `ai-demo`: the services with their
connections (arrows) and both rag-service versions. Project `maas-models`: the two model
servers. Project `kafka`: Kafka, Kafka Connect and the inventory database. Observe gives Traces,
Dashboards, Metrics and Alerting.

**OpenShift AI.**
* Gen AI studio > AI asset endpoints: the published models and their endpoints.
* Gen AI studio > Playground, project **`ai-tenants`**: a ready-made playground with both models
  (deployed by the stack, so there is no "Create playground" step). Project `maas-models` shows
  "Create your playground" on purpose: that is where the models run, not the playground.
* Gen AI studio > API keys: create your own MaaS API key.
* Models as a Service pages (subscriptions, auth policies, token usage). Menu names can differ
  slightly between 3.4.z builds.
* Observe & monitor > Dashboard: Cluster, Models and Usage tabs (Perses, fed by Thanos).
* Applications > MLflow UI: workspace `ai-demo`, experiment `coffee-shop` with the coffee shop's
  AI traces.

**Kiali.** Traffic Graph with lock icons (mTLS), request rates and percentages per version;
Workloads / Services with inbound and outbound metrics; Istio Config for VirtualServices,
DestinationRules, AuthorizationPolicies and their validation.

**Keycloak.** Admin console, realm `demo`: the user, groups `platform-team` / `ai-app-team`, and
the OIDC clients. Sessions show who is signed in to Developer Hub and GitLab.

**GitLab.** `ai-platform/platform` holds the manifests, the demo apps and these docs. Developer
Hub's "View source" opens the matching folder here; Argo CD and Tekton can use it as source.

**Coffee shop.** A complete small application: AI ordering, PostgreSQL orders, a MongoDB audit
trail built by Debezium, and a menu service for release and chaos experiments (demo 7).

**Developer Hub.** The catalog of the whole platform: systems, components, APIs, models,
databases and their relations. Per component: Topology, Kubernetes, CI (Tekton), CD (Argo CD),
API definitions. Create: templates that change the platform.

## Two-minute health check in the UIs

1. Console > Workloads > Topology, project `ai-demo`: every circle has a solid blue ring (running).
2. Project `maas-models`: both model deployments are running (1 of 1).
3. Kiali > Traffic Graph, `ai-demo`, last 5 minutes: green edges, after a question in the demo UI.
4. Developer Hub (sign in with Keycloak) > Catalog: the `ai-demo` system lists 7 components.
5. Console > Observe > Traces: a trace for service `frontend` appears after a question.
