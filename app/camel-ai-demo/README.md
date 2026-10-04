# Camel AI gateway demo (local, single instance)

One Apache Camel instance on your laptop that shows integration and AI side by side:

| Capability | What you show |
|---|---|
| **Model abstraction** | One API, `POST /api/chat/{provider}`, for **Qwen** on Podman Desktop AI Lab, **OpenAI** and **Anthropic**. Callers send the same JSON and get the same JSON back; the routes translate to the OpenAI chat API and to Anthropic's Messages API. |
| **Central API key configuration** | All endpoints, models and keys in one file, `config/llm.env`. No key in any route, nothing returned by the API. |
| **Local first, cloud fallback** | Alias `auto`: local Qwen behind a circuit breaker, falls back to OpenAI or Anthropic when the local model is down or too slow. |
| **File system access** | Drop a text file in `data/inbox`, get an AI summary in `data/outbox`. |
| **Enabling routes** | `files-translate` starts disabled; switch it on live from the CLI, Hawtio or the developer console. |
| **New routes without restart** | Copy a route file into `routes/` and it is loaded at once (dev mode); delete it and it is gone. |
| **Visual design and editing** | Open the routes in **Kaoto**, change a step or draw a new route, save, and the running instance reloads it. |
| **Runtime UIs** | **Hawtio** (live route diagrams, statistics, start/stop, debugging), the Camel **developer console** and the Camel CLI. |

Everything is YAML routes run by the Camel CLI (Camel JBang): no build, no project, live reload.
Location: `app/camel-ai-demo`, next to the platform's Quarkus services but independent of the
Gradle build (it is not listed in `settings.gradle.kts`).

```
                 curl / demo.sh                    data/inbox/*.txt          data/inbox/translate/*
                       |                                   |                          |
                POST /api/chat/{provider}          files-summarize            files-translate (off)
                       |                                   |                          |
                       +-------------------> direct:chat <-+--------------------------+
                                                 |
                       +------------+------------+------------+
                       |            |            |            |
                    qwen         openai     anthropic       auto = circuit breaker
              (Podman AI Lab)  (chat API)  (Messages API)      qwen -> fallback openai | anthropic
```

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| Java 21+ | runs Camel | e.g. `brew install openjdk@21` or https://adoptium.net |
| JBang + Camel CLI | runs the routes | https://www.jbang.dev, then `jbang app install camel@apache/camel` |
| Podman Desktop + AI Lab extension | serves Qwen locally | https://podman-desktop.io, then Extensions > AI Lab |
| VS Code + Kaoto extension | visual route designer | Marketplace: "Kaoto" (Red Hat) |
| OpenAI and/or Anthropic API key | optional, for the cloud providers and the fallback | your provider accounts |

Check: `camel version` prints the Camel CLI version. The routes are validated against the Camel YAML
DSL schema of 4.18 (LTS) and later; pin a version with `CAMEL_VERSION=4.18.2 ./run.sh`.

## Setup (once)

**1. Start Qwen in Podman Desktop AI Lab.**
Podman Desktop > AI Lab > **Catalog**: download a Qwen model (any Qwen instruct model from the
catalog, or **Import model** for a Qwen GGUF file). Then **Services** > **New Model Service**, pick
the model and start it. The service page shows the endpoint, for example `http://localhost:35000/v1`.

**2. Configure the providers in one place.**
```bash
cp config/llm.env.example config/llm.env
```
Edit `config/llm.env`: set `QWEN_BASE_URL` to the port from step 1, and add `OPENAI_API_KEY`
and/or `ANTHROPIC_API_KEY`. `config/llm.env` is git-ignored. `routes/application.properties`
maps these values onto Camel properties (`{{openai.api-key}}` and so on); routes only use
the properties.

## Run

```bash
./run.sh
```
Camel starts in dev mode with everything in `routes/`:
* API: `http://localhost:8080/api`
* developer console: `http://localhost:8080/q/dev`
* the log shows every route, request and reload

Keep this terminal visible during the demo; use a second one for the steps below.

## Demo script

The step-by-step guide is **[DEMO.md](DEMO.md)**: every step as **Do** (what to type, click or
open), **You see** and **Say**, in seven parts that also work on their own:

| Part | Shows | Where |
|---|---|---|
| A. Local model and central configuration | Qwen in Podman Desktop AI Lab, `config/llm.env` | Podman Desktop, IntelliJ |
| B. One API, three providers | the same request to Qwen, OpenAI, Anthropic; the adapters | terminal, IntelliJ |
| C. Local first, cloud fallback | stop the local model, `auto` keeps answering | Podman Desktop, terminal, IntelliJ |
| D. File system | inbox to summary; a route that starts disabled and is enabled live | terminal, IntelliJ |
| E. Change the running instance | add routes, edit a route, all without restart | terminal, IntelliJ |
| F. Visual design | edit and create routes in Kaoto | VS Code + Kaoto |
| G. Watch it run | developer console, Hawtio (diagram, start/stop, debugger), CLI | browser, terminal |

## Configuration reference

| `config/llm.env` | Meaning |
|---|---|
| `QWEN_BASE_URL`, `QWEN_MODEL` | AI Lab model service (OpenAI compatible), e.g. `http://localhost:35000/v1` |
| `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL` | OpenAI, or any OpenAI compatible endpoint (vLLM, the platform's MaaS gateway) |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` | Anthropic Messages API |
| `LLM_FALLBACK` | provider behind `auto` when the local model fails: `openai` or `anthropic` |
| `LLM_LOCAL_TIMEOUT_MS` | how long `auto` waits for the local model |
| `LLM_MAX_TOKENS` | answer length limit for all providers |
| `FILES_PROVIDER` | provider for the file routes: `auto`, `qwen`, `openai`, `anthropic` |

Change values in `config/llm.env` and restart `./run.sh`. The shared system prompt is
`llm.system-prompt` in `routes/application.properties` (no double quotes in it: it is placed in
the JSON templates).

Pointing `OPENAI_BASE_URL` at the platform's Models-as-a-Service endpoint
(`https://maas.<apps-domain>/maas-models/qwen3-0-6b/v1` with a MaaS API key) makes this laptop
demo use the cluster's models through the same abstraction.

## Files

```
camel-ai-demo/
  run.sh, demo.sh                start the instance / demo helpers
  config/llm.env.example         central provider configuration (copy to config/llm.env)
  routes/                        loaded and watched by Camel (dev mode)
    application.properties       maps config/llm.env onto Camel properties, circuit breaker
    llm-gateway.camel.yaml       REST API, provider adapters, auto with fallback
    files.camel.yaml             inbox summaries, translation route (starts disabled)
  extras/                        routes to add live during the demo
  samples/                       input files for the file routes
  data/inbox, data/outbox        file drop folders
```

## From laptop to platform

The same routes run on OpenShift unchanged: `camel export --runtime=quarkus --gav=org.acme:camel-ai-demo:1.0`
creates a Quarkus project from `routes/`, with `application.properties` reading the keys from a
Secret instead of `config/llm.env`. On the AI platform, the Java based `model-router` service
(app/model-router) does the same job for the RAG demo and the coffee shop.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `{"error": "...Connection refused...", "provider": "qwen"}` | the AI Lab service is not running or `QWEN_BASE_URL` has another port |
| `{"error": "...statusCode: 401..."}` | missing or wrong API key for that provider in `config/llm.env` (restart `./run.sh` after changing it) |
| `{"error": "...statusCode: 404..."}` on openai/anthropic | the model name in `config/llm.env` does not exist for your account |
| `auto` always uses the cloud | the circuit breaker is open after failures; wait 30 s, or the local model is slower than `LLM_LOCAL_TIMEOUT_MS` |
| Qwen answers start with `<think>` | a Qwen3 model with thinking enabled: add `/no_think` to the prompt or pick a non thinking Qwen model |
| nothing in `data/outbox` | only `.txt` and `.md` files are picked up; `files-translate` must be started first |
| port 8080 in use | stop the other process, or `./run.sh --port=8090` and `API=http://localhost:8090/api ./demo.sh ...` |

The developer console shows resolved configuration values; on a shared screen, avoid opening the
properties page.
