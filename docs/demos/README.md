# Demo guides

Six demos on the OpenShift 4.22 AI platform, plus a tour of the UIs and a test checklist. Each
demo takes 5 to 10 minutes and works on its own; all of them use the same running setup.

| Guide | What it covers |
|---|---|
| [Platform tour](00-platform-tour.md) | Every UI in the stack: where it is, how to log in, what to look at first |
| [Test checklist](testing.md) | End-to-end verification, layer by layer, with expected results |
| [1. Models and RAG](01-models-and-rag.md) | MaaS with Gemma and Qwen, Gen AI playground, RAG with LangChain4j, the Camel model router and its OpenAI fallback |
| [2. Mesh security](02-mesh-security.md) | STRICT mTLS, who-can-access-who with AuthorizationPolicies |
| [3. Deployment patterns](03-deployment-patterns.md) | Canary, A/B, blue-green, mirroring, Argo Rollouts |
| [Service mesh manifests](service-mesh.md) | The same mesh demos, file by file: which field to edit and the `oc apply` that makes it live |
| [4. Change data capture](04-change-data-capture.md) | PostgreSQL to Kafka to MongoDB with Debezium |
| [5. Observability](05-observability.md) | One trace across all services, token metrics, dashboard, alerts |
| [6. Developer Hub](06-developer-hub.md) | The platform as a catalog, sign-in with Keycloak, source in GitLab, changing it with templates |
| [8. Trusted software supply chain](08-trusted-software-supply-chain.md) | Signed commit in Dev Spaces (gitsign + Trusted Artifact Signer), pipeline: verify, CI, sign, SBOM, Trusted Profile Analyzer, ACS checks, release, Argo CD |
| [Guarded Coffee](../../app/coffee-guardrails/DEMO.md) | NeMo Guardrails (TrustyAI) on the laptop: coffee only, 200 character limits, PII masking, no cappuccino after noon; same config on OpenShift AI |
| [Camel on the laptop](../../app/camel-ai-demo/README.md) | Local Camel demo: one API for Qwen (Podman AI Lab), OpenAI and Anthropic, files, live routes, Kaoto and Hawtio |
| [7. Platform Coffee](07-coffee-shop.md) | One app, every capability: AI ordering, menu releases and chaos in the mesh, CDC audit trail |

Every demo has the same structure:
* **Before you start**: the checks and the browser tabs to open
* **Parts in the UI** (OpenShift AI, OpenShift console, Kiali, Developer Hub, the demo apps) and a
  **part in IntelliJ** (the files to open and what to point at)
* every step as **Do** (what you click or open), **You see** (what appears) and **Say** (the point to make)
* **Prove it from the terminal**, **Reset** and **If something goes wrong**

Open IntelliJ on the repository folder; **Shift twice** opens any file the guides mention by name.

## Preparation (once)

```bash
export HF_TOKEN=hf_...                 # Gemma is gated
export OPENAI_API_KEY=sk-...           # optional, enables "openai" and the fallback
./deploy.sh stack                      # platform, 30 to 45 min
./deploy.sh app all                    # demo apps incl. the coffee shop, about 15 min
./deploy.sh app deploy --rollouts      # only for the Argo Rollouts part of demo 3
./deploy.sh urls; ./deploy.sh app urls # all URLs
```

One user for everything: **`admin` / `redhatdemo`** (Keycloak sign-in for Developer Hub and
GitLab; GitLab's local admin is `root` with the same password). Override with
`DEMO_ADMIN_USER` / `DEMO_ADMIN_PASSWORD` before installing.

## Five minutes before you present

```bash
./deploy.sh test               # both models answer through MaaS
./deploy.sh app pattern reset  # traffic back to v1
./deploy.sh app probe          # every line starts with OK
./deploy.sh app menu reset     # coffee menu back to v1, no faults
```

Open these tabs: the demo UI, Kiali (Traffic Graph, namespace `ai-demo`), the OpenShift console
(Observe > Traces), Developer Hub, and the OpenShift AI dashboard. Ask one question per model
beforehand: the CPU models take 10 to 60 seconds, and the first call is the slowest.

If something is not ready, `./deploy.sh debug` writes one diagnostics file (no secrets) with
everything needed to find the cause.
