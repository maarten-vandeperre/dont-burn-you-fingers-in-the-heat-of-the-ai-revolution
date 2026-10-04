# Camel AI gateway: demo guide

**The story:** one Apache Camel instance on a laptop puts a single API in front of three model
providers (Qwen running locally in Podman Desktop AI Lab, OpenAI and Anthropic), falls back to the
cloud when the local model is down, processes files with AI, and changes behaviour while it runs:
routes are enabled, added and redesigned live, visually in Kaoto, and watched in Hawtio.

**Duration:** 30 minutes for everything; every part also works on its own (3 to 10 minutes).

**Screens:** a terminal with Camel running (keep it visible: the log tells the story), a second
terminal for `./demo.sh`, Podman Desktop, IntelliJ, VS Code with Kaoto (part F), a browser for
the developer console and Hawtio (part G).

Every step below has three parts: **Do** (what you type, click or open), **You see** (what
appears) and **Say** (the point to make).

Setup and configuration reference: [README.md](README.md).

---

## Before you start

**Once (see README "Setup"):** a Qwen model service runs in Podman Desktop AI Lab and
`config/llm.env` contains its port and your OpenAI / Anthropic keys.

**Five minutes before the audience arrives:**
1. Terminal 1, in `app/camel-ai-demo`:
   ```bash
   ./run.sh
   ```
   Wait for the routes to start (`Started chat`, `Started files-summarize`, ...). Make the font big.
2. Terminal 2, same folder, warm up the local model (the first answer is the slowest):
   ```bash
   ./demo.sh chat qwen "Say hello in five words."
   ```
3. Clean leftovers from a previous run:
   ```bash
   rm -f routes/compare-providers.camel.yaml routes/coffee-fact-timer.camel.yaml routes/hello-kaoto.camel.yaml
   rm -f data/outbox/*.md
   ```
4. Open **IntelliJ** on the folder `app/camel-ai-demo` (File > Open). Press **Shift twice** to open
   files by name. **Do not open `config/llm.env`** on screen: it holds your keys. Show
   `config/llm.env.example` instead.
5. Open **Podman Desktop** > **AI Lab** > **Services**.

---

## Part A: the local model and the central configuration (3 minutes)

**A1. A model running on the laptop.**
* **Do:** Podman Desktop > **AI Lab** > **Services**.
* **You see:** the Qwen model service, **Running**, with its endpoint (for example
  `http://localhost:35000/v1`).
* **Say:** "This is a real language model running on my laptop, with an OpenAI compatible API. No
  cloud account, no data leaving the machine."

**A2. One place for every provider.**
* **Do:** IntelliJ > open `config/llm.env.example`.
* **Point at:** the three blocks (Qwen, OpenAI, Anthropic) with base URL, key and model, and
  `LLM_FALLBACK`.
* **Do:** open `routes/application.properties`.
* **Point at:** `openai.api-key = {{env:OPENAI_API_KEY:}}` and the other mappings.
* **Say:** "Keys live in one file that is never committed. The routes only use property names; no
  route contains a key, and the API never returns one."

---

## Part B: one API, three providers (5 minutes)

**B1. What is configured.**
* **Do:** terminal 2:
  ```bash
  ./demo.sh providers
  ```
* **You see:** JSON with `auto`, `qwen`, `openai`, `anthropic`: URLs and model names, no keys.

**B2. The same question to each provider.**
* **Do:**
  ```bash
  ./demo.sh chat qwen      "What is a service mesh, in two sentences?"
  ./demo.sh chat openai    "What is a service mesh, in two sentences?"
  ./demo.sh chat anthropic "What is a service mesh, in two sentences?"
  ```
* **You see:** three answers in exactly the same shape:
  ```json
  { "provider": "anthropic", "model": "claude-haiku-4-5-20251001",
    "answer": "...", "inputTokens": 31, "outputTokens": 52 }
  ```
  Terminal 1 logs `chat request for provider qwen` (then openai, anthropic).
* **Say:** "Three providers, two completely different APIs, one contract for the caller."

**B3. How the abstraction works.**
* **Do:** IntelliJ > open `routes/llm-gateway.camel.yaml`.
* **Point at, top to bottom:**
  * the `rest` block: `POST /api/chat/{provider}`
  * route `chat`: the `choice` on the provider, sending to `direct:qwen`, `direct:openai`,
    `direct:anthropic` or `direct:auto`
* **Do:** scroll to `provider-openai` and `provider-anthropic`; put them side by side (right-click the
  editor tab > **Split Right**, scroll each half to one route).
* **Point at:**
  * OpenAI: header `Authorization: Bearer ...`, request with `messages` incl. a `system` message,
    answer read from `.choices[0].message.content`
  * Anthropic: headers `x-api-key` and `anthropic-version`, `system` as a separate field, answer read
    from `.content[].text`
* **Say:** "Each adapter translates our canonical request to the provider's format and the answer
  back, with one jq expression each way. Adding a provider is one more route like these."

---

## Part C: local first, cloud as fallback (3 minutes)

**C1. auto uses the local model.**
* **Do:**
  ```bash
  ./demo.sh chat auto "Give me three names for a coffee bar."
  ```
* **You see:** `"provider": "qwen"`.

**C2. Take the local model away.**
* **Do:** Podman Desktop > **AI Lab** > **Services** > stop the Qwen service. Ask again:
  ```bash
  ./demo.sh chat auto "Give me three names for a coffee bar."
  ```
* **You see:** `"provider": "anthropic"` (or openai, depending on `LLM_FALLBACK`), and in terminal 1
  the warning `local model unavailable, falling back to anthropic`.
* **Say:** "The caller asked for `auto` and got an answer. Local first for cost and privacy, the
  cloud only when needed, and no code change anywhere."

**C3. Where that is decided.**
* **Do:** IntelliJ > `routes/llm-gateway.camel.yaml` > route `provider-auto`.
* **Point at:** `circuitBreaker` with `direct:qwen` inside and `onFallback` that restores the original
  request and calls `direct:{{llm.fallback}}`. Then `routes/application.properties` >
  `camel.resilience4j.timeout-duration` and `wait-duration-in-open-state`.
* **Say:** "After a few failures the breaker opens and goes straight to the cloud; after 30 seconds it
  tries the local model again."
* **Do:** start the Qwen service again in Podman Desktop.

---

## Part D: the file system (5 minutes)

**D1. A file in, a summary out.**
* **Do:**
  ```bash
  ./demo.sh summarise samples/release-notes.txt
  ```
* **You see:** terminal 1 logs `summarising release-notes.txt with auto`, then
  `wrote data/outbox/release-notes.summary.md`.
* **Do:** IntelliJ > open `data/outbox/release-notes.summary.md` (the markdown preview shows it formatted).
* **You see:** five bullet points and `written by Camel with provider qwen`.
* **Say:** "Files are where a lot of business data still lives. Camel watches a folder, sends the text
  to the gateway and writes the result; the original moves to `data/inbox/.done`."

**D2. How the route does it.**
* **Do:** IntelliJ > open `routes/files.camel.yaml`, route `files-summarize`.
* **Point at:** the `file:` consumer with `include` (only .txt/.md) and `move`; the jq step that builds
  the prompt from the file text; `to: direct:chat` (it reuses the gateway, so it gets the fallback
  too); the `file:` producer with `fileName: ${variable.fileName}.summary.md`.

**D3. A route that is switched off.**
* **Do:**
  ```bash
  ./demo.sh routes
  ```
* **You see:** a table of routes; `files-translate` is **Stopped** (`autoStartup: false` in the file).
* **Do:**
  ```bash
  ./demo.sh translate samples/translate-me.txt
  ls data/outbox
  ```
* **You see:** no `translate-me.nl.md`: the route is off, the file waits in `data/inbox/translate`.
* **Do:**
  ```bash
  ./demo.sh enable files-translate
  ls data/outbox
  ```
* **You see:** within seconds `translate-me.nl.md`, the Dutch translation.
* **Say:** "Integrations can be deployed dormant and switched on when the business is ready, without
  a redeploy."
* **Do:** `./demo.sh disable files-translate`.

---

## Part E: change the running instance (4 minutes)

**E1. A new endpoint, no restart.**
* **Do:**
  ```bash
  ./demo.sh add compare-providers
  ```
* **You see:** terminal 1 logs the new routes starting (`compare-providers`, `compare-qwen`, ...).
* **Do:**
  ```bash
  ./demo.sh compare "Espresso or filter coffee for a long meeting?"
  ```
* **You see:** three answers in one JSON array, one per provider.
* **Do:** IntelliJ > open `routes/compare-providers.camel.yaml`.
* **Point at:** `multicast` with `parallelProcessing: true` and the three branches.
* **Say:** "Camel watches the routes folder. A new file is a new capability, live."

**E2. A scheduled route that comes and goes.**
* **Do:** `./demo.sh add coffee-fact-timer`, wait five seconds.
* **You see:** terminal 1 logs `coffee fact (qwen): ...`, then again every two minutes.
* **Do:** `./demo.sh remove coffee-fact-timer`: the route stops and disappears.

**E3. Edit a running route in IntelliJ.**
* **Do:** IntelliJ > `routes/files.camel.yaml` > in `files-summarize` change
  `at most five bullet points` to `exactly three bullet points, in Dutch`. Save (Cmd/Ctrl+S).
* **You see:** terminal 1 logs that the routes of `files.camel.yaml` were reloaded.
* **Do:** `./demo.sh summarise samples/customer-email.txt`, then open
  `data/outbox/customer-email.summary.md`.
* **You see:** three Dutch bullet points.
* **Say:** "Any editor works: save, and the running instance follows. Next: the same, visually."
* **Do (revert):** change the text back and save.

---

## Part F: design and edit routes visually with Kaoto (5 to 10 minutes)

Kaoto is the visual designer for Camel routes. It runs as a VS Code extension; open the folder
`app/camel-ai-demo` in VS Code. Files ending in `.camel.yaml` open in Kaoto.

**F1. A running route as a diagram.**
* **Do:** open `routes/llm-gateway.camel.yaml`.
* **You see:** each route as a flow: the REST endpoints, `chat` with its choice branches, the provider
  routes step by step, `provider-auto` with the circuit breaker and its fallback branch.
* **Say:** "The same YAML as in IntelliJ, as a picture. Kaoto and Camel read and write the same file."

**F2. Change a step.**
* **Do:** open `routes/files.camel.yaml`. Click the **Set Body** step with the jq prompt in
  `files-summarize`. In the side panel change `five bullet points` to `three bullet points`. Save.
* **You see:** terminal 1 reloads; `./demo.sh summarise samples/release-notes.txt` gives three bullets.

**F3. Add a step.**
* **Do:** hover over the arrow after **To** `direct:chat`, click **+**, choose **Log**, message
  `answer from ${variable.usedProvider}`. Save.
* **You see:** after the next `./demo.sh summarise ...` the new log line in terminal 1.

**F4. A new route from scratch.**
* **Do:**
  1. In the Kaoto view: **New Camel Route** (YAML), save it as `routes/hello-kaoto.camel.yaml`.
  2. Replace the default source with **Timer**, period `30000`.
  3. Add **Set Body**, constant `{"prompt": "Write a haiku about integration."}`.
  4. Add **Set Header**, name `provider`, constant `qwen`.
  5. Add **To**, uri `direct:chat`, then **Log**, message `${body}`.
  6. Save.
* **You see:** the route starts at once and logs a haiku every 30 seconds.
* **Say:** "Designed visually, running in seconds, using the gateway like any other route."
* **Do:** delete the file to stop it.

**Without VS Code:** run the Kaoto web app as a container and open `http://localhost:8081`:
```bash
podman run --rm -p 8081:8080 quay.io/kaotoio/kaoto-app:main
```
It shows the same designer, but it cannot save into this folder; paste the YAML in and copy it out.

---

## Part G: watch it run: developer console, Hawtio, CLI (5 minutes)

**G1. The developer console.**
* **Do:** browser > `http://localhost:8080/q/dev`.
* **You see:** pages for the routes (state and statistics), health, the source of each route and the
  last messages.

**G2. Hawtio.**
* **Do:** terminal 2: `./demo.sh hawtio` (it connects to the instance `camel-ai-demo` and opens the browser).
* **You see / Do:**
  * **Camel** > the context `camel-ai-demo` > **Routes**: every route with its state, number of
    messages, failures and processing time. Start and stop routes here: start `files-translate`.
  * select route `chat` > **Route Diagram**, then send a few `./demo.sh chat ...` requests: the
    counters on the steps go up live.
  * select route `provider-anthropic` > **Debug**: start debugging, set a breakpoint on the step that
    calls Anthropic, send `./demo.sh chat anthropic "hi"`: the exchange stops there and you see the
    body Camel built for Anthropic. Resume to continue.
* **Say:** "Operations sees the same routes as running things: what flows, where it is slow, and it
  can step through a message like a debugger."

**G3. The CLI.**
* **Do:**
  ```bash
  camel get route      # state, uptime and throughput per route
  camel trace          # the messages flowing through the routes, step by step (Ctrl+C to stop)
  camel top            # memory and CPU of the instance
  ```

---

## Reset

```bash
rm -f routes/compare-providers.camel.yaml routes/coffee-fact-timer.camel.yaml routes/hello-kaoto.camel.yaml
./demo.sh disable files-translate
rm -f data/outbox/*.md
```
Start the Qwen service in Podman Desktop again if you stopped it, and undo prompt edits in
`routes/files.camel.yaml`.

## If something goes wrong

* **`"error": "...Connection refused..."` for qwen:** the AI Lab service is stopped or `QWEN_BASE_URL`
  has another port.
* **`"error": "...statusCode: 401..."`:** wrong or missing key in `config/llm.env`; restart `./run.sh`
  after changing it.
* **auto keeps using the cloud:** the circuit breaker is open; wait 30 seconds after starting Qwen again.
* **A saved change does nothing:** Camel only watches `routes/`; check terminal 1 for a YAML error
  (the previous version keeps running until the file is valid again).
* **Hawtio does not find the instance:** the instance must run (`./run.sh`); its name is `camel-ai-demo`.
* More in [README.md](README.md#troubleshooting).
