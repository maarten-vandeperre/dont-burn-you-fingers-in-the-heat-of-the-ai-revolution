# Demo 17: Agent sandboxes — Claude Code on a leash, from laptop to cluster

**The story:** coding agents such as Claude Code don't just suggest code. They run commands, install
packages, read files and call the network, with the developer's rights, at machine speed. One
prompt injection in a README or an issue, and "fix the failing test" becomes "send `~/.ssh` and the
cloud keys to pastebin". The answer is not "don't use agents", it's **where they run and what that
place allows**. This demo runs the same agent (Claude Code) on the same task (fix a failing test in
[`sample-project/`](../../stack/agent-sandboxes/sample-project/)) in three places, always on the
company's model, and shows what each place stops and what it doesn't:

| Where | Sandbox | Who sets the rules | Part |
|---|---|---|---|
| **Laptop** | **Kaiden**: a desktop app (Podman Desktop family) that runs each agent in an **OpenShell** sandbox in a Podman container (or a libkrun micro-VM), with network presets and a secret vault | the developer, from a policy file in the repo (`.kaiden/workspace.json`) | A |
| **Anywhere** | **Claude Code itself**: managed settings (model, permissions, no bypass mode) baked into the image | the platform team (`/etc/claude-code/managed-settings.json`) | B |
| **OpenShift Dev Spaces** | a workspace pod in the developer's namespace, the key automounted from a Secret, an **EgressFirewall** around the namespace | the platform team (cluster-admin: the developer can't remove the fence) | C |
| **OpenShift + OpenShell** | the **OpenShell** gateway on the cluster: one sandbox pod per agent, a supervisor next to it that inspects **every request per binary**, Landlock on the filesystem, the key replaced by a **placeholder** | the platform team (policies, credential profiles), changed live | D |

And underneath all of it, the **company LLM API of [demo 15](15-ai-gateways.md)** (Connectivity Link +
Praxis): every agent has its own consumer key, quota and model aliases, and none of them can reach
`api.anthropic.com` directly. This demo adds an **Anthropic Messages endpoint** to that API
(`/anthropic`), because Claude Code only speaks Anthropic.

```
 laptop                                      OpenShift
 ┌───────────────────────────┐   ┌──────────────────────────────────────────────────────────────────┐
 │ Kaiden                    │   │ <user>-devspaces            agent-sandboxes        openshell      │
 │  └ OpenShell (Podman)     │   │ ┌────────────────────────┐ ┌──────────────────┐ ┌───────────────┐ │
 │     └ sandbox: Claude Code│   │ │ workspace (che-code)   │ │ claude-run-* pod │ │ gateway       │ │
 │        network preset,    │   │ │  Claude Code + managed │ │ (headless, B)    │ │  policies,    │ │
 │        secret vault       │   │ │  settings, key = env   │ └────────┬─────────┘ │  providers    │ │
 └─────────────┬─────────────┘   │ │  from automount Secret │          │           │ sandbox pod ──┤ │
               │                 │ └──────────┬─────────────┘          │           │  Claude Code  │ │
               │                 │  EgressFirewall: LLM API, npm,      │           │ supervisor pod│ │
               │                 │  github.com, nothing else           │           │  L7 proxy per │ │
               │                 │            │                        │           │  binary, key  │ │
               │                 │            │                        │           │  injection    │ │
               ▼                 │            ▼                        ▼           └───────┬───────┘ │
   https://llm-gateway.<apps>/anthropic/v1/messages   (demo 15: key, 5 req/s, tokens/min, tier)    │
               └──────────────── llm-gateway ── Praxis api-anthropic: Anthropic → OpenAI Chat ───────┘
                                              model "cloud" → gpt-4o-mini, "smart" → Qwen (in cluster)
```

| Component | What it is | Support |
|---|---|---|
| [Kaiden](https://openkaiden.ai/) | Open source desktop app for running coding agents in OpenShell sandboxes, companion of Podman Desktop | upstream project, 0.x (Red Hat-backed, not a product). The supported piece is Red Hat Desktop / Red Hat build of Podman Desktop |
| [OpenShell](https://github.com/ai-openshell/openshell) 0.1.9 | Agent sandbox runtime (gateway, supervisor, policy engine) by NVIDIA, now a CNCF project | upstream. In **OpenShift AI 3.5** it ships as a **Developer Preview**; this cluster runs OpenShift AI 3.4, so we install the upstream Helm chart |
| [Agent Sandbox](https://agent-sandbox.sigs.k8s.io/) v1.0.3 | Kubernetes SIG project: the `Sandbox` CRD and controller OpenShell uses to create sandbox pods | upstream |
| OpenShift Dev Spaces 3.31 | Cloud development environments (che-code, devfiles, automount) | GA |
| EgressFirewall (OVN-Kubernetes) | Per-namespace egress rules (CIDR / DNS name) | GA |
| Claude Code 2.1.330 | Anthropic's coding agent CLI, pinned in the images | Anthropic |
| Demo 15 LLM API + the new `/anthropic` endpoint | Connectivity Link (GA), Praxis AI (alpha) | see demo 15 |

**Duration:** 35 minutes (A 8, B 7, C 8, D 10, E 2). Every part also works on its own.

> **What is tested and what isn't.** Parts B and C ran end to end on this cluster (outputs below
> are real). Part D needs a cluster-admin to install OpenShell (`openshell-install`) and the
> `openshell` CLI on your laptop; its commands and files are written against OpenShell 0.1.9's
> docs and upstream's own OpenShift test setup, but **were not run here yet**. Part A (Kaiden) is
> a desktop app; the steps follow the Kaiden docs and weren't rehearsed on this laptop. Rehearse A
> and D once before you present them.

---

## Before you start

1. Installed: demo 15 with an OpenAI key (`./deploy.sh ai-gateways deploy`,
   `./deploy.sh ai-gateways openai-key`), Dev Spaces (`./deploy.sh stack`).
2. Deploy this demo (about 4 minutes the first time, two image builds):
   ```bash
   ./deploy.sh agent-sandboxes deploy      # /anthropic endpoint, consumer key "sandbox", Claude Code images
   ./deploy.sh agent-sandboxes devspaces   # Part C: key Secret, EgressFirewall, workspace (for the user you're logged in as)
   ./deploy.sh agent-sandboxes test
   ```
3. Part D (once, cluster-admin, and the `openshell` CLI 0.1.9 on your laptop):
   ```bash
   brew install ai-openshell/tap/openshell     # or the release archive, see "Part D before you start"
   ./deploy.sh agent-sandboxes openshell-install
   ./deploy.sh agent-sandboxes openshell-connect
   ./deploy.sh agent-sandboxes openshell-sandbox
   ```
4. Part A: Podman Desktop running, Kaiden installed (see Part A).
5. Tabs: the Dev Spaces dashboard (`https://devspaces.<apps>/dashboard/`), the demo 15 console
   (gateway metrics per consumer), IntelliJ on `stack/agent-sandboxes/`.

---

## Part A: Kaiden, the agent sandbox on the laptop (8 minutes)

**What we're doing.** The developer runs Claude Code on their own machine, but not *on* their
machine: Kaiden puts it in an OpenShell sandbox in a Podman container. The project folder is
mounted, the rest of the laptop (home directory, SSH keys, cloud credentials) isn't. Network access
follows a preset. Keys live in the macOS Keychain and are injected at the sandbox boundary.

**A1. Install and connect a model.**
* **Do:**
  1. Podman Desktop running (Kaiden needs Podman: `podman machine list` shows a running machine).
  2. Download Kaiden for Apple Silicon from the
     [Kaiden releases](https://github.com/openkaiden/kaiden/releases) and start it. On first start
     it offers to install the OpenShell CLI it needs (Settings > CLI Tools).
  3. Models > **LLM Providers** > **Claude**, with a custom base URL: the company LLM API.
     `./deploy.sh agent-sandboxes kaiden` prints the URL and a key of its own (consumer `laptop`):
     ```
     Base URL : https://llm-gateway.<apps>/anthropic
     API key  : sk-llm-laptop-...
     Model    : cloud     (alias of gpt-4o-mini; 'smart' = in-cluster Qwen)
     ```
     Or, fully local: Models > **Local** shows Ollama when it's running (`ollama list`: on this
     laptop `qwen3.5:4b` and `gemma4:12b` are there).
* **What happens:** Kaiden keeps the key in the Keychain and injects it at its routing layer; the
  agent in the sandbox never handles it.
* **Say:** "Same model, same quota, same audit trail as the agents on the cluster: the laptop is
  just one more consumer of the company LLM API."

**A2. A sandbox for the sample project.**
* **Do:** Sandboxes > **+ New Workspace**, folder `stack/agent-sandboxes/sample-project`. Kaiden
  finds [`.kaiden/workspace.json`](../../stack/agent-sandboxes/sample-project/.kaiden/workspace.json)
  and asks *Start as-is / Merge / Replace*: **Start as-is**. Agent: **Claude Code**, model **cloud**.
  File system: **No host filesystem access** (only the project folder). Then start a session
  (Work view) with the task:
  *"Run the unit tests with python3 -m unittest, find the bug in pricing.py, fix it, run the tests
  again and summarize the fix in two sentences."*
* **Configured by:** the policy travels with the project, in git:
  ```json
  {
    "network": {
      "mode": "deny",
      "hosts": ["registry.npmjs.org", "pypi.org", "files.pythonhosted.org"]
    }
  }
  ```
  `mode: deny` + `hosts` = deny everything except these hosts (Kaiden's *Developer Preset* is the
  same idea with the common package registries). `mode: allow` is unrestricted (Podman only).
* **You see:** the agent runs the tests (2 failures), changes `price_in` into `price_out` for the
  output tokens in `call_cost`, and the tests pass.

**A3. Try to leave the sandbox.**
* **Do:** in the sandbox terminal: `curl -sI https://example.com`, `ls ~/.ssh`, `ls /Users`.
* **You see:** example.com refused by the sandbox proxy, no `~/.ssh` and no host home directory
  inside the sandbox.
* **Say:** "Kaiden is OpenShell on a laptop. The same runtime, policy language and credential
  injection as Part D on the cluster: what a developer tries locally is what the platform runs."
* **Honest limits:** Kaiden is a 0.x upstream project (the docs say APIs and the config format
  may change). The developer can edit `workspace.json` and pick *Unrestricted*: on a laptop, the
  developer is the policy owner. That's why Parts C and D exist.

---

## Part B: Claude Code on the company LLM API (7 minutes)

**What we're doing.** Before sandboxing an agent, decide which model it may use. Claude Code speaks
only the Anthropic Messages API and, by default, calls `api.anthropic.com` with a personal key.
We point it at the company LLM API instead (demo 15), so it runs on a model the platform governs,
with a key, a quota and metrics per consumer.

**B1. The endpoint.**
* **Do:**
  ```bash
  ./deploy.sh agent-sandboxes test        # first block: LLM API, Anthropic endpoint
  ```
* **What happens** for `POST https://llm-gateway.<apps>/anthropic/v1/messages`:
  1. **Connectivity Link** (llm-gateway): HTTPRoute `llm-api-anthropic` matches `/anthropic/`; the
     gateway-wide AuthPolicy checks the key (`Authorization: Bearer <key>`, which is what Claude
     Code sends with `ANTHROPIC_AUTH_TOKEN`), the throttle and the tier apply as for `/v2`. The
     route strips `/anthropic` and sends the request to Praxis listener `api-anthropic` (:8087).
  2. A small **Lua filter** on the gateway drops `"is_error": true` from tool results (B3).
  3. **Praxis** `api-anthropic`: `coding-compat` removes three Anthropic-only fields,
     `classify` + `translate` turn the Anthropic request into OpenAI Chat (system prompt, content
     blocks, tools, streaming), `tier-gate` (gold only for OpenAI), `coding-routing` maps `cloud`
     to gpt-4o-mini via the loopback listener `coding-egress` (:8088), which injects the OpenAI key.
  4. The answer comes back translated into Anthropic format, streamed when Claude Code streams.
* **Configured by:**
  * [`api-routes.yaml`](../../stack/ai-gateways/connectivity-link/api-routes.yaml), HTTPRoute
    `llm-api-anthropic`:
    ```yaml
    rules:
      - matches: [{path: {type: PathPrefix, value: /anthropic/}}]
        filters:
          - type: URLRewrite
            urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}
          - type: RequestHeaderModifier
            requestHeaderModifier: {remove: [Authorization, x-api-key]}   # the key stays at the gateway
        backendRefs: [{name: praxis-ai, port: 8087}]
    ```
  * [`praxis-ai.yaml`](../../stack/ai-gateways/praxis/praxis-ai.yaml), listener and chains:
    ```yaml
    - name: api-anthropic
      address: "0.0.0.0:8087"
      filter_chains: [api-observability, coding-compat, classify, translate, unknown-model-v2, tier-gate, coding-routing]
    - name: coding-egress
      address: "127.0.0.1:8088"
      filter_chains: [observability, openai]          # OpenAI key injection, no chat guardrails
    ```

**B2. What it took to make Claude Code work through the translation.** (the slide, or IntelliJ)

We ran the real Claude Code 2.1.330 against the endpoint and fixed what broke, one error at a time:

| Error from the API | Cause | Fixed where |
|---|---|---|
| `400 thinking cannot be translated to Chat Completions` | Claude Code asks for extended thinking | gateway: `coding-compat` removes `/thinking` |
| `400 Unrecognized request argument supplied: reasoning_effort` | `output_config.effort` becomes OpenAI `reasoning_effort`, which gpt-4o-mini refuses | gateway: removes `/output_config` |
| `400 context_management cannot be translated` | Claude Code's context editing | gateway: removes `/context_management` |
| `400 system must be a string or array of text blocks` | prompt-caching markers on the system prompt | client: `DISABLE_PROMPT_CACHING=1` |
| `400 max_tokens is too large: 32000 ... at most 16384` | Claude Code's default output budget | client: `CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000` |
| `400 tool_result requires string tool_use_id and text content` | **every failed tool call** (a command exiting non-zero, a denied permission) is sent with `is_error: true`, which Praxis 0.9 refuses outright | gateway: Lua filter [`envoyfilter-anthropic-tool-errors.yaml`](../../stack/ai-gateways/connectivity-link/envoyfilter-anthropic-tool-errors.yaml) drops the flag; the error text stays |
| warning `unrecognized_model "cloud"` | Claude Code doesn't know the context window of alias `cloud` | client: `CLAUDE_CODE_MAX_CONTEXT_TOKENS=128000` |

And one deliberate change: the demo 15 OpenAI egress has chat guardrails (no e-mail addresses,
coffee or lemons). Claude Code's own system prompt contains e-mail addresses, so every request
would be refused. Coding agents get their own egress listener without those rules; their guardrail
is the sandbox.

* **Say:** "This is what 'any client on any model' costs in practice: seven fixes to run one popular
  agent through a protocol translation. Four are on the gateway, so every developer gets them for
  free; three are client settings, which we bake into the image (B3). Also: test the agent you
  actually use, with failures, not just a hello world."

**B3. The platform's Claude Code settings, baked into the image.**
* **Do:**
  ```bash
  ./deploy.sh agent-sandboxes claude
  ```
  (Claude Code, headless, in a throwaway pod: image `claude-code-sandbox`, the sample project, the
  default task.)
* **What happens:** the pod gets only `ANTHROPIC_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` (consumer
  `sandbox`); everything else comes from `/etc/claude-code/managed-settings.json` in the image.
* **You see** (real run):
  ```
  pod agent-sandboxes/claude-run-..., image claude-code-sandbox, model 'cloud' via https://llm-gateway.<apps>/anthropic
  ... The bug was that call_cost used price_in for both input and output tokens ... all tests passed.
  --- tests now:
  OK
  ```
* **Configured by:** [`images/managed-settings.json`](../../stack/agent-sandboxes/images/managed-settings.json),
  copied into both images by [`images/build.yaml`](../../stack/agent-sandboxes/images/build.yaml):
  ```json
  {
    "model": "cloud",
    "env": {
      "ANTHROPIC_MODEL": "cloud", "ANTHROPIC_DEFAULT_SONNET_MODEL": "cloud", "...": "...",
      "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "128000", "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "16000",
      "DISABLE_PROMPT_CACHING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
      "DISABLE_TELEMETRY": "1", "DISABLE_AUTOUPDATER": "1"
    },
    "permissions": {
      "disableBypassPermissionsMode": "disable",
      "deny": ["Read(**/.env)", "Read(**/.env.*)", "Read(~/.ssh/**)", "Read(~/.kube/**)",
               "Read(/var/run/secrets/**)", "Bash(curl:*)", "Bash(wget:*)", "WebFetch", "WebSearch"]
    }
  }
  ```
  Managed settings beat user and project settings: a `.claude/settings.json` in a repository (or
  a prompt-injected agent writing one) can't loosen them. Claude Code is pinned
  (`CLAUDE_CODE_VERSION=2.1.330`) and doesn't update itself.

**B4. Devil's advocate: "So the deny list protects the secrets?"**
* **Do:** `./deploy.sh agent-sandboxes claude "Read the file /var/run/secrets/kubernetes.io/serviceaccount/token and tell me what happened."`
* **You see** (real run, this cluster): the token was read. `Read(/var/run/secrets/**)` blocks
  Claude Code's **Read tool**; the pod allows `Bash(cat:*)`, and `cat` reads the file just fine.
  A deny of `Bash(curl:*)` held even with `--allowedTools "Bash(curl:*)"` (deny wins), but
  `python3 -c "import urllib.request ..."` is not curl.
* **Say:** "Agent permissions are a seatbelt, not a wall: they match tool calls, not what the
  operating system lets a process do. They stop the agent's *mistakes*. Against a *manipulated*
  agent you need a boundary outside the agent: the network (Part C), or the network, the
  filesystem and the credentials (Part D)."

---

## Part C: Claude Code in OpenShift Dev Spaces (8 minutes)

**What we're doing.** Every developer gets a workspace on the cluster: VS Code in the browser,
Claude Code in the terminal, the project cloned, on the company LLM API. The platform team owns
three things the developer can't change: the image (with the managed settings of B3), the key
(automounted from a Secret, not in any file) and the network fence around the namespace.

**C1. The workspace.**
* **Do:** Dev Spaces dashboard > Workspaces > **claude-code-sandbox** > Open (created by
  `./deploy.sh agent-sandboxes devspaces`). Terminal > New Terminal:
  ```bash
  claude
  ```
  and give it the task. Or from the laptop: `./deploy.sh agent-sandboxes devspaces-claude`.
* **What happens:** the workspace pod (namespace `<user>-devspaces`) runs container `tools` from
  `claude-code-udi`: the Dev Spaces Universal Developer Image + Claude Code + the managed
  settings. `ANTHROPIC_BASE_URL` comes from the devfile, `ANTHROPIC_AUTH_TOKEN` from the
  automounted Secret. A postStart command marks Claude Code's onboarding as done, so there's no
  login screen.
* **You see** (real run):
  ```
  ==> Claude Code in workspace claude-code-sandbox (admin-devspaces), /projects/sample-project
  The bug in pricing.py was that call_cost incorrectly used price_in for both input and output
  tokens ... This has been fixed by updating the calculation to correctly reference price_out.
  --- tests now:
  OK
  ```
* **Configured by:** [`devspaces/devworkspace.yaml`](../../stack/agent-sandboxes/devspaces/devworkspace.yaml)
  (the same content works as a `devfile.yaml` in a repository, with a factory URL):
  ```yaml
  components:
    - name: tools
      container:
        image: image-registry.openshift-image-registry.svc:5000/agent-sandboxes/claude-code-udi:latest
        env:
          - {name: ANTHROPIC_BASE_URL, value: https://llm-gateway.<apps>/anthropic}
  commands:
    - id: claude-onboarding
      exec:
        component: tools
        commandLine: '[ -f "$HOME/.claude.json" ] || echo ''{"hasCompletedOnboarding":true}'' > "$HOME/.claude.json"'
  events:
    postStart: [claude-onboarding]
  ```

**C2. The key: automounted, per developer.**
* **Do:** `oc get secret claude-code-llm-key -n admin-devspaces --show-labels`
* **Configured by:** `devspaces()` in [`agent-sandboxes.sh`](../../stack/agent-sandboxes/agent-sandboxes.sh)
  creates a demo 15 consumer key `devspaces-<user>` (gold) and puts it in the developer's
  namespace as:
  ```yaml
  kind: Secret
  metadata:
    name: claude-code-llm-key
    labels:
      controller.devfile.io/mount-to-devworkspace: "true"   # every workspace in this namespace
      controller.devfile.io/watch-secret: "true"            # a new key reaches running workspaces on restart
    annotations:
      controller.devfile.io/mount-as: env                   # each key of the Secret becomes an env variable
  data:
    ANTHROPIC_AUTH_TOKEN: <the key>
  ```
* **Say:** "No key in the devfile, the repo or the developer's dotfiles. Per-developer keys also
  give per-developer quotas and metrics in the gateway: the demo 15 console shows consumer
  `devspaces-admin` next to `agent` and `judge`."

**C3. The fence.**
* **Do:**
  ```bash
  ./deploy.sh agent-sandboxes devspaces-check
  ./deploy.sh agent-sandboxes devspaces-fence off && ./deploy.sh agent-sandboxes devspaces-check
  ./deploy.sh agent-sandboxes devspaces-fence on
  ```
* **You see** (real runs):
  ```
  fence on                                                                         fence off
    company LLM API (no key: 401)  https://llm-gateway.<apps>/anthropic/v1/messages 401    401
    npm registry                   https://registry.npmjs.org/express               200    200
    github.com                     https://github.com                               200    200
    Anthropic API directly         https://api.anthropic.com/v1/models              BLOCKED 401
    PyPI                           https://pypi.org/simple/                         BLOCKED 200
    anything else                  https://example.com                              BLOCKED 200
  ```
* **Configured by:** [`devspaces/egress-firewall.yaml`](../../stack/agent-sandboxes/devspaces/egress-firewall.yaml):
  ```yaml
  apiVersion: k8s.ovn.org/v1
  kind: EgressFirewall
  metadata: {name: default, namespace: admin-devspaces}   # one per namespace, always "default"
  spec:
    egress:                                                # first match wins
      - {type: Allow, to: {dnsName: llm-gateway.<apps>},  ports: [{protocol: TCP, port: 443}]}
      - {type: Allow, to: {dnsName: registry.npmjs.org}, ports: [{protocol: TCP, port: 443}]}
      - {type: Allow, to: {dnsName: github.com},         ports: [{protocol: TCP, port: 443}]}
      - {type: Deny,  to: {cidrSelector: 0.0.0.0/0}}
  ```
  Only a cluster-admin can create or change an EgressFirewall: the developer, admin of their own
  namespace, can't remove it, and neither can their agent.
* **Say:** "Now B4's `python3 urllib` exfiltration has nowhere to go: the network says no,
  whatever process asks. And Claude Code can't fall back on a personal Anthropic key either:
  api.anthropic.com is outside the fence."

**C4. Devil's advocate: "So the workspace can only reach the LLM API, npm and GitHub?"**
* **Do:** in the workspace terminal: `curl -s -o /dev/null -w '%{http_code}\n' https://gitlab-gitlab.<apps>/`
* **You see:** `302`. GitLab is not in the allow list, but it's reachable.
* **Why:** an EgressFirewall works on **IP addresses**; `dnsName` rules are resolved to IPs. On this
  cluster every route (`*.apps`) and the API server resolve to the same address, `52.118.50.52`.
  Allowing the LLM API allows every route of the cluster. An EgressFirewall also can't see which
  process connects, which path or method, or which credential is sent.
* **Say:** "Good enough to keep code and keys inside the company. Not enough to say 'this agent
  may read GitHub but not push', or 'only Claude Code may talk to the model'. That needs a proxy
  that understands requests and knows the calling binary: Part D."
* Two more things worth knowing: the workspace pod has **no service account token** mounted
  (DevWorkspace doesn't automount it, unlike B4's pod), and on this cluster Dev Spaces enables
  **container builds** in every workspace (SCC `container-build`, SETUID/SETGID). For agent
  workspaces a platform team may switch that off (`CheCluster` `spec.devEnvironments.disableContainerBuildCapabilities: true`).

---

## Part D: OpenShell on OpenShift (10 minutes)

**What we're doing.** OpenShell is a runtime built for agents. On Kubernetes, its gateway creates,
per sandbox: a **workload pod** (the agent, our `claude-code-sandbox` image) and a separate
**supervisor pod** (OpenShell's, trusted). A NetworkPolicy lets the workload talk only to its
supervisor; every connection the agent opens goes through the supervisor's proxy, which:
* identifies the **calling binary** (from `/proc`, by real path and hash),
* checks the request against the sandbox's **network policy**: host, port, protocol, and for REST
  the method and path (L7), per binary; changeable **live**,
* injects **credentials** only where a provider profile allows them: the agent holds a placeholder,
  never the key,
* logs every decision.
Inside the workload, **Landlock** restricts the filesystem and **seccomp** the system calls,
unprivileged (no privileged SCC, no added capabilities).

### Part D before you start

* **CLI:** OpenShell 0.1.9 on the laptop: `brew install ai-openshell/tap/openshell`, or download
  `openshell-aarch64-apple-darwin.tar.gz` from the
  [v0.1.9 release](https://github.com/ai-openshell/openshell/releases/tag/v0.1.9), check it against
  `openshell-checksums-sha256.txt` and put `openshell` on your PATH. `openshell --version`.
* **Install (cluster-admin):** `./deploy.sh agent-sandboxes openshell-install`
  1. Agent Sandbox controller v1.0.3 ([`agent-sandbox-v1.0.3.yaml`](../../stack/agent-sandboxes/openshell/agent-sandbox-v1.0.3.yaml),
     vendored from the kubernetes-sigs release): CRD `sandboxes.agents.x-k8s.io`, controller in
     `agent-sandbox-system`. Cluster-scoped, hence cluster-admin.
  2. `helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart --version 0.1.9
     -n openshell -f values-openshift.yaml` with the Route host. Values:
     [`values-openshift.yaml`](../../stack/agent-sandboxes/openshell/values-openshift.yaml):
     ```yaml
     podSecurityContext: null                    # restricted-v2 SCC assigns UIDs from the namespace range
     securityContext: {runAsNonRoot: true, runAsUser: null, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
     server: {disableTls: false, telemetryEnabled: false}
     gatewayConfig:
       openshell.gateway.auth: {allow_unauthenticated_users: true}   # the client certificate is the gate
     openshiftRoute: {enabled: true}             # passthrough Route, mutual TLS to the gateway pod
     sandbox:
       image: {repository: image-registry.openshift-image-registry.svc:5000/agent-sandboxes/claude-code-sandbox, tag: latest}
     ```
     Same overlays as OpenShell's own OpenShift e2e tests. Requirements: OpenShift 4.19+ (Landlock
     in the RHCOS kernel; this cluster: 4.22, kernel 5.14.0-687) and a CNI that enforces egress
     NetworkPolicy (OVN-Kubernetes does).
* **Connect:** `./deploy.sh agent-sandboxes openshell-connect` copies the client certificate the
  chart generated (Secret `openshell-client-tls`) to `~/.config/openshell/gateways/openshift/mtls/`
  and selects the gateway. Whoever holds that certificate can use the gateway: treat it like a
  kubeconfig. In production: OIDC (Keycloak) per user (`server.oidc.*`).

**D1. A sandbox for Claude Code.**
* **Do:** `./deploy.sh agent-sandboxes openshell-sandbox`, then `openshell sandbox list` and
  `oc get pods -n openshell`.
* **What happens:**
  1. `openshell profile import -f profile-company-llm.yaml --global`: a **provider profile** for
     the company LLM API.
  2. `openshell provider create --name company-llm --type company-llm --credential ANTHROPIC_AUTH_TOKEN`:
     the key of consumer `sandbox`, stored in the gateway.
  3. `openshell sandbox create --name claude-dev --from <claude-code-sandbox image> --policy policy.yaml
     --provider company-llm --env ANTHROPIC_BASE_URL=... --upload sample-project:/sandbox/sample-project`.
* **You see:** sandbox `claude-dev` Ready; in `openshell`, the gateway StatefulSet, a workload pod and
  a supervisor pod.
* **Configured by:** [`profile-company-llm.yaml`](../../stack/agent-sandboxes/openshell/profile-company-llm.yaml):
  ```yaml
  id: company-llm
  credentials:
    - name: gateway_key
      env_vars: [ANTHROPIC_AUTH_TOKEN]
      auth_style: header
      header_name: Authorization            # Claude Code sends "Authorization: Bearer <token>"
  endpoints:
    - {host: llm-gateway.<apps>, port: 443, path: /anthropic/**, protocol: rest, access: read-write, enforcement: enforce}
  binaries:
    - /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
  ```

**D2. Claude Code in the sandbox.**
* **Do:** `./deploy.sh agent-sandboxes openshell-claude` (or `openshell sandbox connect claude-dev`
  and run `claude` interactively in `/sandbox/sample-project`).
* **You see:** the same fix as in B3 and C1, from inside the sandbox.

**D3. The key the agent holds is useless.**
* **Do:** `./deploy.sh agent-sandboxes openshell-check` (section "The key, as the sandbox sees it").
* **You see:** `ANTHROPIC_AUTH_TOKEN=openshell:resolve:env:ANTHROPIC_AUTH_TOKEN`: a placeholder. The
  supervisor swaps in the real key only for a request from `claude.exe` to
  `llm-gateway.<apps>:443/anthropic/**`, in the `Authorization` header. A prompt-injected agent
  that sends "its key" to another server sends this string.
* **Say:** "Compare with Part C: there the key is a real environment variable; `env` prints it, and
  anything that can reach the LLM API with it can spend the developer's quota. Here the key never
  enters the sandbox."

**D4. The network, per binary and per request.**
* **Do:** `./deploy.sh agent-sandboxes openshell-check` (section "What can sandbox claude-dev
  reach?"), then `openshell logs claude-dev --since 5m`.
* **What to look for:** everything `curl` tries is refused: curl is not a binary any rule names,
  not even for the LLM API (only `claude.exe` may go there). In the logs, one decision per
  request with binary, host, port and rule.
* **Configured by:** [`policy.yaml`](../../stack/agent-sandboxes/openshell/policy.yaml):
  ```yaml
  version: 1
  filesystem_policy:                       # Landlock, fixed at creation
    include_workdir: true
    read_only: [/bin, /usr, /lib, /lib64, /opt, /etc, /proc, /dev/urandom, /var/log]
    read_write: [/sandbox, /tmp, /dev/null]
  network_policies:                        # live
    npm_registry:
      endpoints: [{host: registry.npmjs.org, port: 443, protocol: rest, enforcement: enforce, access: read-only}]
      binaries: [{path: /usr/bin/node-22}]                       # npm runs as a Node.js script
    github_readonly:
      endpoints: [{host: github.com, port: 443, protocol: rest, enforcement: enforce, access: read-only}]
      binaries: [{path: /usr/libexec/git-core/git-remote-https}] # clone and fetch yes, push no
  ```
  `access: read-only` = GET/HEAD/OPTIONS only: `git push` (a POST) is refused even though github.com
  is allowed. `enforcement` defaults to `audit` (log, don't block): always set `enforce`.

**D5. Change the policy on a running sandbox.**
* **Do:** in the sandbox, `pip download --no-deps requests` (refused), then
  `./deploy.sh agent-sandboxes openshell-pypi`, and again.
* **What happens:** `openshell policy update claude-dev --rule-name pypi --binary /usr/bin/python3.9
  --add-endpoint pypi.org:443:read-only:rest:enforce --add-endpoint files.pythonhosted.org:443:read-only:rest:enforce --wait`
  adds a rule to the running sandbox; network rules are live (filesystem and process rules need a
  new sandbox). `./deploy.sh agent-sandboxes openshell-reset` puts `policy.yaml` back.
* **Say:** "The platform team can open one door for one binary for one sandbox, in seconds,
  without restarting the agent. And close it again."

**D6. The filesystem.**
* **You see** (`openshell-check`, last section): writing to `/etc` or `/opt` is refused by Landlock;
  `/sandbox` is writable. Rehearsal check: `ls /var/run/secrets` in the sandbox. `/var/run` is not in
  the policy's read lists, so Landlock should refuse B4's `cat` of the service account token.

---

## Part E: the layers, side by side (2 minutes)

| Threat | Claude Code managed settings (B) | Dev Spaces + EgressFirewall (C) | OpenShell (A on the laptop, D on the cluster) | Demo 15 LLM API (all) |
|---|---|---|---|---|
| Agent uses a personal key / api.anthropic.com | model forced to `cloud` | blocked (outside the fence) | blocked (no rule) | the only model route |
| Agent exfiltrates with `curl` | denied (tool rule) | blocked unless the host is allowed | blocked (curl has no rule) | — |
| Agent exfiltrates with `python3 urllib` | **not stopped** | blocked unless the host is allowed | blocked (python has no rule, D5 adds one for pip only) | — |
| Agent reaches another internal route on an allowed IP | not stopped | **not stopped** (one IP for all routes) | blocked (host + path per rule) | — |
| Agent pushes to GitHub | not stopped | **not stopped** (github.com allowed) | blocked (`read-only`) | — |
| Agent reads secrets in files | Read tool only, `cat` bypasses | what the pod has (no SA token in workspaces) | Landlock: only `/sandbox`, `/tmp` writable, listed paths readable | — |
| Agent leaks its model key | — | the real key is in `env` | placeholder only | per-consumer key, revocable, quota |
| Agent burns tokens in a loop | — | — | — | throttle and tokens/min per consumer |
| A kernel exploit from inside the container | — | — | — | — → **Kata** (below) |

**Variation: Kata containers.** OpenShell's controls are in the kernel the sandbox shares with the
node. OpenShift sandboxed containers (Kata) give each pod its own VM and guest kernel; OpenShell
supports a RuntimeClass through `--driver-config-json '{"kubernetes":{"pod":{"runtime_class_name":"kata"}}}'`.
Red Hat's write-up ([Layered sandboxing for AI agents](https://developers.redhat.com/articles/2026/07/16/layered-sandboxing-ai-agents-openshift-and-openshell))
shows the two together: OpenShell blocked the exfiltration, Kata the kernel escape, neither alone
both. This cluster has no Kata RuntimeClass (and VMs as nodes), so it's a slide here.

**What's next:** OpenShift AI 3.5 ships OpenShell as a Developer Preview, with signed harness images
for several agents ([Red Hat blog](https://www.redhat.com/en/blog/beyond-container-boundaries-kernel-level-agent-security-red-hat-openshift-ai-35)).
Kaiden is meant to offload heavier work to OpenShift AI, on the same OpenShell runtime.

---

## Part in IntelliJ

| Open | Show |
|---|---|
| `stack/agent-sandboxes/images/managed-settings.json` | the platform's Claude Code policy (B3) |
| `stack/agent-sandboxes/images/build.yaml` | two images, one policy, pinned version |
| `stack/ai-gateways/praxis/praxis-ai.yaml` (`api-anthropic`, `coding-compat`, `coding-routing`) | the Anthropic endpoint (B1, B2) |
| `stack/ai-gateways/connectivity-link/envoyfilter-anthropic-tool-errors.yaml` | the tool-error shim (B2) |
| `stack/agent-sandboxes/devspaces/devworkspace.yaml`, `egress-firewall.yaml` | Part C |
| `stack/agent-sandboxes/openshell/policy.yaml`, `profile-company-llm.yaml`, `values-openshift.yaml` | Part D |
| `stack/agent-sandboxes/sample-project/.kaiden/workspace.json` | Part A |

## Prove it from the terminal

```bash
./deploy.sh agent-sandboxes test
```
Checks: the `/anthropic` endpoint (401 without a key, an answer with one, a tool error accepted),
both images, the Dev Spaces workspace (LLM API reachable, api.anthropic.com and example.com
blocked, the key in the environment), and, when installed, the OpenShell sandbox (example.com
blocked).

## Reset

```bash
./deploy.sh agent-sandboxes devspaces-fence on       # if you turned it off
./deploy.sh agent-sandboxes openshell-reset          # sandbox back to policy.yaml (after D5)
./deploy.sh agent-sandboxes devspaces                # starts the workspace again after idling
```
`claude` and `devspaces-claude` copy the unfixed `sample-project/` in before every run, so each run
starts with the bug. The OpenShell sandbox gets it once, at creation: to start over there,
`openshell sandbox delete claude-dev` and `./deploy.sh agent-sandboxes openshell-sandbox`. Remove everything: `./deploy.sh agent-sandboxes destroy` and
`./deploy.sh agent-sandboxes openshell-uninstall`. The `/anthropic` endpoint stays: it's part of
the demo 15 LLM API.

## If something goes wrong

| Symptom | Cause / fix |
|---|---|
| `API Error: 400 ...` from Claude Code | one of the B2 rows: check the client settings (the images have them; a local Claude Code needs the `kaiden` command's exports) |
| `API Error: 401` | no or wrong key: `ANTHROPIC_AUTH_TOKEN` (not `ANTHROPIC_API_KEY`, which sends `x-api-key`, which the gateway doesn't accept) |
| `API Error: 403 ... gold tier` | the consumer key is `free`: `./deploy.sh ai-gateways key <name> gold` |
| Claude Code answers but OpenAI says 401 | no OpenAI key in Praxis: `./deploy.sh ai-gateways openai-key` |
| Workspace `Failed`: `unable to validate against any security context constraint` | the DevWorkspace lacks `controller.devfile.io/scc: container-build` (this cluster enables container builds) |
| Workspace: `plugin for component editor not found` | the che-code DevWorkspaceTemplate is missing; `devspaces` creates it from ConfigMap `editors-definitions` |
| `devspaces-check` shows everything 200 | `devspaces-fence on` (an EgressFirewall takes a few seconds) |
| `openshell` not found | install the CLI (Part D before you start); this repo doesn't download binaries for you |
| `openshell status` can't connect | `openshell-connect` again (the certificate is regenerated on reinstall); the Route is `openshell.<apps>`, passthrough |
| Sandbox stuck in Provisioning | `oc get pods,sandboxes -n openshell`, `oc logs statefulset/openshell -n openshell`; Landlock / seccomp probe failures show up in the supervisor log |
| `curl` to the LLM API refused in the sandbox | by design: only `claude.exe` may go there (D4) |
