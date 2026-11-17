// The YAML behind every scenario: trimmed excerpts of the files in stack/ai-gateways/.
// `focus` = substrings of the lines that make the scenario happen (highlighted in the UI).
// `live`  = what the backend fetches from the cluster for the "live" view (server/index.mjs LIVE).

const PRAXIS = 'stack/ai-gateways/praxis/praxis-ai.yaml'
const CL = 'stack/ai-gateways/connectivity-link'

export const S = {
  // ----------------------------------------------------------------------------- Connectivity Link
  routes: {
    title: 'HTTPRoutes llm-api-v1 / llm-api-v2',
    file: `${CL}/api-routes.yaml`,
    owner: 'Connectivity Link · API owner',
    live: 'route-v2',
    focus: ['value: /v1/', 'value: /v2/', 'replacePrefixMatch', 'x-api-version', 'Deprecation', 'Sunset', 'successor-version', 'port: 8084', 'port: 8085'],
    why: 'Versioning is plain Gateway API. A path prefix per version; a header for clients that cannot change their base URL (the rule with more header matches wins); v1 answers carry Deprecation / Sunset / Link headers. Both versions end in a different Praxis listener.',
    code: `kind: HTTPRoute
metadata:
  name: llm-api-v1
spec:
  parentRefs: [{name: llm-gateway}]
  rules:
    - matches:
        - path: {type: PathPrefix, value: /v1/}
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove: [Authorization]       # the API key stops at the gateway
        - type: ResponseHeaderModifier
          responseHeaderModifier:
            set:
              - {name: x-api-version, value: "1"}
              - {name: Deprecation, value: "@1793491200"}             # RFC 9745
              - {name: Sunset, value: "Wed, 30 Jun 2027 23:59:59 GMT"} # RFC 8594
              - {name: Link, value: '</v2/chat/completions>; rel="successor-version"'}
      backendRefs:
        - {name: praxis-ai, port: 8084}   # Praxis listener api-v1
---
kind: HTTPRoute
metadata:
  name: llm-api-v2
spec:
  rules:
    - matches:                          # path versioning
        - path: {type: PathPrefix, value: /v2/}
      filters:
        - type: URLRewrite              # Praxis sees the OpenAI path /v1/...
          urlRewrite:
            path: {type: ReplacePrefixMatch, replacePrefixMatch: /v1/}
      backendRefs:
        - {name: praxis-ai, port: 8085}   # Praxis listener api-v2
    - matches:                          # header versioning, same /v1/ path
        - path: {type: PathPrefix, value: /v1/}
          headers:
            - {name: x-api-version, value: "2"}
      backendRefs:
        - {name: praxis-ai, port: 8085}`,
  },
  auth: {
    title: 'AuthPolicy llm-api-auth',
    file: `${CL}/api-policies.yaml`,
    owner: 'Connectivity Link · platform engineer',
    live: 'auth',
    focus: ['kind: Gateway', 'prefix: APIKEY', 'llm-gateway/consumer', 'x-consumer:', 'x-consumer-tier:', 'userid:', 'tier:'],
    why: 'Attached to the Gateway, so it is the default for every route on it. Validates the API key (a labelled Secret), then injects x-consumer and x-consumer-tier into the request to Praxis — overwriting anything the client sent — and exposes userid/tier to the limits and metrics.',
    code: `kind: AuthPolicy
metadata:
  name: llm-api-auth
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
  rules:
    authentication:
      api-key-consumers:
        apiKey:
          allNamespaces: true
          selector:
            matchLabels: {llm-gateway/consumer: "true"}   # Secret llm-key-<user>
        credentials:
          authorizationHeader: {prefix: APIKEY}
    response:
      success:
        headers:                       # -> request headers towards Praxis
          x-consumer:
            plain: {expression: auth.identity.metadata.name}
          x-consumer-tier:
            plain: {expression: 'auth.identity.metadata.annotations["llm-gateway/tier"]'}
        filters:
          identity:                    # -> auth.identity.userid / .tier
            json:
              properties:
                userid: {expression: auth.identity.metadata.name}
                tier:   {expression: 'auth.identity.metadata.annotations["llm-gateway/tier"]'}`,
  },
  consumerKey: {
    title: 'A consumer = a labelled Secret',
    file: 'created by ./deploy.sh ai-gateways key <user> <free|gold>',
    owner: 'Connectivity Link · API owner',
    focus: ['llm-gateway/consumer', 'llm-gateway/tier'],
    why: 'Changing a tier is one annotation: ./deploy.sh ai-gateways key alice gold. No redeploy, Authorino picks it up.',
    code: `apiVersion: v1
kind: Secret
metadata:
  name: llm-key-alice
  namespace: ai-gateways
  labels:
    llm-gateway/consumer: "true"                  # selected by the AuthPolicy
    authorino.kuadrant.io/managed-by: authorino   # watched by Authorino
  annotations:
    llm-gateway/tier: free                        # -> x-consumer-tier, token limit
stringData:
  api_key: sk-llm-alice-...`,
  },
  rlp: {
    title: 'RateLimitPolicy llm-api-throttle',
    file: `${CL}/api-policies.yaml`,
    owner: 'Connectivity Link · API owner',
    live: 'rlp',
    focus: ['limit: 5', 'window: 1s', 'auth.identity.userid', 'kind: Gateway'],
    why: '5 requests per second, counted per consumer (auth.identity.userid comes from the AuthPolicy). The console changes it with a merge patch; Kuadrant reconciles Limitador in a few seconds.',
    code: `kind: RateLimitPolicy
metadata:
  name: llm-api-throttle
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
  limits:
    per-consumer:
      rates:
        - limit: 5                      # "max 5 requests per second"
          window: 1s
      counters:
        - expression: auth.identity.userid   # alice and bob: separate buckets

# change it live (what the console's Apply button does):
# oc patch ratelimitpolicy llm-api-throttle -n ai-gateways --type=merge \\
#   -p '{"spec":{"limits":{"per-consumer":{"rates":[{"limit":2,"window":"1s"}]}}}}'`,
  },
  trlp: {
    title: 'TokenRateLimitPolicy llm-api-tokens',
    file: `${CL}/api-policies.yaml`,
    owner: 'Connectivity Link · API owner',
    live: 'trlp',
    focus: ['limit: 500', 'limit: 20000', 'auth.identity.tier == "free"', 'auth.identity.tier == "gold"', 'counters:', 'endsWith("/models")'],
    why: 'Tokens, not requests. The wasm shim in Envoy reads usage.total_tokens from every answer (local model or OpenAI) and charges it to the consumer in Limitador. Once over the limit, the NEXT request is refused with 429.',
    code: `kind: TokenRateLimitPolicy
metadata:
  name: llm-api-tokens
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
  limits:
    api-free:
      rates: [{limit: 500, window: 1m}]          # tokens per minute
      when:
        - predicate: auth.identity.tier == "free"
        - predicate: '!request.path.endsWith("/models")'
      counters: [{expression: auth.identity.userid}]
    api-gold:
      rates: [{limit: 20000, window: 1m}]
      when:
        - predicate: auth.identity.tier == "gold"
        - predicate: '!request.path.endsWith("/models")'
      counters: [{expression: auth.identity.userid}]`,
  },
  telemetry: {
    title: 'TelemetryPolicy llm-gateway-telemetry',
    file: `${CL}/api-policies.yaml`,
    owner: 'Connectivity Link · platform engineer',
    live: 'telemetry',
    focus: ['user: auth.identity.userid', 'tier: auth.identity.tier'],
    why: 'Adds user and tier labels to the Limitador metrics (authorized_calls, limited_calls, authorized_hits). limitador_namespace already says which route — so which API version.',
    code: `kind: TelemetryPolicy                 # extensions.kuadrant.io/v1alpha1
metadata:
  name: llm-gateway-telemetry
spec:
  targetRef: {group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway}
  metrics:
    default:
      labels:
        user: auth.identity.userid
        tier: auth.identity.tier
# -> authorized_hits{user="llm-key-alice", tier="free",
#                    limitador_namespace="ai-gateways/llm-api-v2"}`,
  },
  // ----------------------------------------------------------------------------- Praxis
  praxisListeners: {
    title: 'Praxis listeners api-v1 / api-v2 / openai-egress',
    file: PRAXIS,
    owner: 'Praxis AI · AI platform team',
    live: 'praxis:listener/api-v1,listener/api-v2,listener/openai-egress',
    focus: ['8084', '8085', '127.0.0.1:8086', 'catalog-v1', 'catalog-v2', 'model-routing', 'openai-guardrails'],
    why: 'One listener per API version (the HTTPRoutes pick the port), plus a loopback-only egress listener: the only way out to OpenAI.',
    code: `listeners:
  - name: api-v1                   # HTTPRoute llm-api-v1 -> :8084
    address: "0.0.0.0:8084"
    filter_chains: [api-observability, classify, catalog-v1, unknown-model-v1, models]
  - name: api-v2                   # HTTPRoute llm-api-v2 -> :8085
    address: "0.0.0.0:8085"
    filter_chains: [api-observability, data-classification, classify, catalog-v2,
                    unknown-model-v2, tier-gate, model-routing]
  - name: openai-egress            # not reachable from outside the pod
    address: "127.0.0.1:8086"
    filter_chains: [observability, openai-guardrails, openai]`,
  },
  classify: {
    title: 'chain classify: which API, which model?',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:classify',
    focus: ['model_to_header', 'header: X-Model', 'ai_operation'],
    why: 'Praxis reads the JSON body: "model" becomes an X-Model header that every later filter can use. Gateway API never sees the body; that is why model routing lives here.',
    code: `- name: classify
  filters:
    - filter: ai_operation                       # chat? messages? (method + path)
    - filter: openai_chat_completions_request
      conditions: [{when: {path: "/v1/chat/completions"}}]
    - filter: model_to_header                    # body "model" -> X-Model
      header: X-Model`,
  },
  modelRouting: {
    title: 'chain model-routing: one table',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:model-routing',
    focus: ['model_to_provider', 'model: fast', 'model: smart', 'model: cloud', 'upstream: openai-egress', 'target_model', 'token_count', '127.0.0.1:8086'],
    why: 'The client names a model or an alias; Praxis picks the upstream cluster and rewrites "model" in the body to what that upstream serves. Swap the model behind "smart" without touching a client.',
    code: `- name: model-routing
  filters:
    - filter: model_to_provider
      models:
        - {model: qwen3-0-6b,      upstream: qwen,          target_model: qwen3-0-6b}
        - {model: gemma-3-270m-it, upstream: gemma,         target_model: gemma-3-270m-it}
        - {model: gpt-4o-mini,     upstream: openai-egress, target_model: gpt-4o-mini}
        - {model: fast,            upstream: gemma,         target_model: gemma-3-270m-it}
        - {model: smart,           upstream: qwen,          target_model: qwen3-0-6b}
        - {model: cloud,           upstream: openai-egress, target_model: gpt-4o-mini}
        # (each entry also has paths: ["/v1/chat/completions"])
    - filter: stream_usage_inject
    - filter: token_count              # praxis_ai_*_tokens_total{model}
      provider: openai
    - filter: time_to_first_token
    - filter: load_balancer
      clusters:
        - name: qwen                     # KServe workload, service-CA TLS
          endpoints: ["qwen3-0-6b-kserve-workload-svc.maas-models.svc.cluster.local:8000"]
        - name: gemma
          endpoints: ["gemma-3-270m-it-kserve-workload-svc.maas-models.svc.cluster.local:8000"]
        - name: openai-egress            # loopback hop to the egress listener
          endpoints: ["127.0.0.1:8086"]`,
  },
  unknownModel: {
    title: 'chains catalog-v2 / unknown-model-v2',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:catalog-v2,unknown-model-v2',
    focus: ['static_response', 'status: 404', 'path: "/v1/models"', 'unless'],
    why: 'GET /v2/models is answered by Praxis itself (a catalog including the aliases). A model outside the table gets a readable 404 before anything is routed.',
    code: `- name: catalog-v2
  filters:
    - filter: static_response
      status: 200
      body: '{"object":"list","api_version":"v2","data":[...models and aliases...]}'
      conditions: [{when: {path: "/v1/models"}}]
- name: unknown-model-v2
  filters:
    - filter: static_response
      status: 404
      body: '{"error":{"type":"model_not_found", ...}}'
      conditions:                       # all must hold: not any known name
        - unless: {headers: {x-model: qwen3-0-6b}}
        - unless: {headers: {x-model: gemma-3-270m-it}}
        - unless: {headers: {x-model: gpt-4o-mini}}
        - unless: {headers: {x-model: fast}}
        - unless: {headers: {x-model: smart}}
        - unless: {headers: {x-model: cloud}}`,
  },
  openai: {
    title: 'chain openai: the only way out',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:openai',
    focus: ['api.openai.com', 'credential_injection', 'env_var: OPENAI_API_KEY', 'strip_client_credential', 'request_remove', 'sni: api.openai.com'],
    why: 'Praxis holds the OpenAI key (Secret praxis-openai-key -> env OPENAI_API_KEY) and injects it; clients never see it. Internal headers are removed before the request leaves the company.',
    code: `- name: openai
  filters:
    - filter: router
      routes: [{path_prefix: "/v1/", cluster: openai}]
    - filter: headers
      request_set: [{name: Host, value: api.openai.com}]
      request_remove: [x-consumer, x-consumer-tier, x-model, x-data-classification]
    - filter: credential_injection
      clusters:
        - name: openai
          header: Authorization
          header_prefix: "Bearer "
          env_var: OPENAI_API_KEY          # Secret praxis-openai-key
          strip_client_credential: true
    - filter: load_balancer
      clusters:
        - name: openai
          endpoints: ["api.openai.com:443"]
          tls: {sni: api.openai.com}       # public CA`,
  },
  openaiKey: {
    title: 'The OpenAI key',
    file: 'stack/ai-gateways/praxis/deployment.yaml',
    owner: 'Praxis AI · deployment',
    focus: ['OPENAI_API_KEY', 'praxis-openai-key'],
    why: 'Set it with: export OPENAI_API_KEY=sk-... && ./deploy.sh ai-gateways openai-key (creates the Secret, restarts Praxis). Without it OpenAI answers 401 — the guardrails still block before that.',
    code: `env:
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef: {name: praxis-openai-key, key: OPENAI_API_KEY}`,
  },
  confidential: {
    title: 'chain data-classification',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:data-classification',
    focus: ['x-data-classification: confidential', 'value: qwen3-0-6b', 'json_body'],
    why: 'One header pins a request to the in-house model, whatever the client asked for. It runs before classify, so X-Model, the tier gate and the routing already see qwen3-0-6b.',
    code: `- name: data-classification
  filters:
    - filter: json_body
      request_replace: [{pointer: /model, value: qwen3-0-6b}]
      conditions:
        - when:
            headers:
              x-data-classification: confidential`,
  },
  guardrails: {
    title: 'chain openai-guardrails',
    file: PRAXIS,
    owner: 'Praxis AI · security',
    live: 'praxis:openai-guardrails',
    focus: ['coffee', 'lemons?', 'contains: [email]', 'filter: guardrails'],
    why: 'Native Praxis rules, no external service: a regex or the built-in email detector matches anywhere in the request body -> 403, OpenAI never sees the prompt. guardrails is a security filter (no conditions allowed), so it sits on the egress listener that only OpenAI-bound traffic passes. Local models are not affected.',
    code: `- name: openai-guardrails
  filters:
    - filter: guardrails
      rules:
        - target: body
          pattern: "(?i)\\\\bcoffee\\\\b"     # topic: coffee
        - target: body
          pattern: "(?i)\\\\blemons?\\\\b"    # topic: lemon / lemons
        - target: body
          contains: [email]                # built-in PII detector`,
  },
  tierGate: {
    title: 'chain tier-gate',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:tier-gate',
    focus: ['x-consumer-tier: gold', 'x-model: gpt-4o-mini', 'x-model: cloud', 'status: 403'],
    why: 'WHO comes from Connectivity Link (x-consumer-tier), WHAT from the body (X-Model). Neither gateway can make this decision alone.',
    code: `- name: tier-gate
  filters:
    - filter: static_response
      status: 403
      body: '{"error":{"type":"tier_not_allowed", ...}}'
      conditions:
        - when:   {headers: {x-model: gpt-4o-mini}}
        - unless: {headers: {x-consumer-tier: gold}}
    - filter: static_response        # same for the alias
      status: 403
      conditions:
        - when:   {headers: {x-model: cloud}}
        - unless: {headers: {x-consumer-tier: gold}}`,
  },
  praxisThrottle: {
    title: 'Praxis rate_limit (listener limited)',
    file: PRAXIS,
    owner: 'Praxis AI',
    live: 'praxis:listener/limited,throttle',
    focus: ['rate: 5', 'burst: 5', 'mode: global'],
    why: 'A token bucket for the whole listener: 5 per second, at most 5 at once — for everybody together, Praxis does not know who is calling. Edited in the ConfigMap, hot-reloaded without a restart.',
    code: `listeners:
  - name: limited                  # route praxis-ai-limited
    address: "0.0.0.0:8081"
    filter_chains: [observability, throttle, catalog-v1, classify, translate, models]
filter_chains:
  - name: throttle
    filters:
      - filter: rate_limit         # security filter: no conditions, own listener
        mode: global               # one bucket for all callers (or per_ip)
        rate: 5                    # requests added per second
        burst: 5                   # bucket size`,
  },
  praxisMetrics: {
    title: 'Praxis metrics + ServiceMonitor',
    file: 'stack/ai-gateways/praxis/deployment.yaml',
    owner: 'Praxis AI · observability',
    live: 'servicemonitor',
    focus: ['token_count', 'time_to_first_token', 'port: metrics', 'interval: 15s'],
    why: 'Praxis counts tokens per model for local AND OpenAI answers (it reads the usage block) and measures latency per upstream cluster. User workload monitoring scrapes :9902.',
    code: `# praxis-ai.yaml, chain model-routing
- filter: token_count             # praxis_ai_prompt_tokens_total{model}
  provider: openai                #  praxis_ai_output_tokens_total{model}
- filter: time_to_first_token     # praxis_ai_ttft_seconds{model}
# + praxis_http_request_duration_seconds{cluster}, praxis_http_requests_total{cluster,status_class}
---
kind: ServiceMonitor
metadata:
  name: praxis-ai
spec:
  selector: {matchLabels: {app: praxis-ai}}
  endpoints:
    - port: metrics               # admin.metrics_address 0.0.0.0:9902
      path: /metrics
      interval: 15s`,
  },
}
