#!/usr/bin/env bash
# =============================================================================
# AI gateways compared: Praxis AI, Red Hat Connectivity Link, OpenShift AI MaaS
#
#   ./deploy.sh ai-gateways deploy             namespace ai-gateways, Praxis AI, the Connectivity
#                                              Link llm-gateway (Gateway, HTTPRoutes, AuthPolicy,
#                                              RateLimitPolicy, TokenRateLimitPolicy, TelemetryPolicy),
#                                              two consumer keys and the AI Gateway Console (Part F)
#   ./deploy.sh ai-gateways openai-key         store $OPENAI_API_KEY (or ask for it) for Praxis's
#                                              OpenAI egress and restart Praxis
#   ./deploy.sh ai-gateways console            (re)build and deploy the AI Gateway Console UI only
#   ./deploy.sh ai-gateways key <user> <free|gold>
#                                              Connectivity Link: create (or re-tier) an API key
#   ./deploy.sh ai-gateways maas-key           OpenShift AI MaaS: mint a 1h API key (subscription
#                                              small-models-free) and print it
#   ./deploy.sh ai-gateways compare [model]    same prompt through all three gateways: HTTP status,
#                                              latency, tokens (default model qwen3-0-6b)
#   ./deploy.sh ai-gateways test               the checks every part of the demo relies on
#   ./deploy.sh ai-gateways guard              Praxis + NeMo Guardrails: pass, block a secret in the
#                                              prompt / the answer, mask personal data
#   ./deploy.sh ai-gateways burst              Praxis request rate limit vs. Connectivity Link
#                                              token rate limit, side by side
#   ./deploy.sh ai-gateways api                Part F from the terminal: versioning, aliases, OpenAI
#                                              guardrails, tier gate, throttle on the LLM API
#   ./deploy.sh ai-gateways metrics            Praxis token / TTFT metrics, Limitador counters
#   ./deploy.sh ai-gateways status             gateways, policies, pods
#   ./deploy.sh ai-gateways urls               the endpoints and the console
#   ./deploy.sh ai-gateways destroy            remove namespace ai-gateways, the ReferenceGrants and
#                                              the console's ClusterRoleBinding
#
# Needs: ./deploy.sh stack (OpenShift AI 3.4 with MaaS, Connectivity Link) and the two models.
# Optional: OPENAI_API_KEY in the environment (Part F, OpenAI routing); without it OpenAI answers 401.
# Demo guide: docs/demos/15-ai-gateways.md
# =============================================================================
set -Eeuo pipefail

GW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="ai-gateways"
MODELS_NS="maas-models"
KEYS_FILE="${GW_DIR}/.keys.env"   # local only (.gitignore), holds the demo consumer keys

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}OK${N} $*"; }
info() { echo "    $*"; }
warn() { echo "    ${Y}WARN${N} $*"; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "'$1' is required"; }
trap 'echo "${R}ERROR${N} failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

wait_until() {  # wait_until <seconds> <label> <command...>
  local timeout=$1 label=$2; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then warn "timed out after ${timeout}s waiting for: ${label}"; return 1; fi
    sleep 5
  done
}
rand() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "${1:-6}" || true; }
domain() { oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'; }
route_host() { oc get route "$1" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null; }
maas_host() { echo "maas.$(domain)"; }
CURL=(curl -sk --max-time 180)

# ----------------------------------------------------------------------------- deploy
deploy() {
  need oc
  oc get llminferenceservice qwen3-0-6b -n "$MODELS_NS" >/dev/null 2>&1 \
    || die "model qwen3-0-6b not found in ${MODELS_NS}: ./deploy.sh stack (or ./deploy.sh models) first"
  local d; d=$(domain)

  step "Namespace ${NS}"
  oc apply -k "${GW_DIR}/base" >/dev/null && ok "namespace ${NS}"

  step "NeMo Guardrails (config confidential)"
  oc apply -k "${GW_DIR}/guardrails" >/dev/null
  oc rollout status deploy/nemo-guardrails -n "$NS" --timeout=300s >/dev/null && ok "nemo-guardrails running"

  step "Praxis AI"
  # the via-maas listener needs the MaaS gateway's hostname as Host header
  sed -i.bak -E "s#(value: )maas\.[^ ]+(   \# rewritten by ai-gateways.sh deploy)#\1maas.${d}\2#" "${GW_DIR}/praxis/praxis-ai.yaml" \
    && rm -f "${GW_DIR}/praxis/praxis-ai.yaml.bak"
  praxis_maas_key
  praxis_openai_key
  oc apply -k "${GW_DIR}/praxis" >/dev/null
  oc delete route praxis-ai-maas -n "$NS" --ignore-not-found >/dev/null   # older versions published it
  oc rollout restart deploy/praxis-ai -n "$NS" >/dev/null                  # pick up a new key
  oc rollout status deploy/praxis-ai -n "$NS" --timeout=180s >/dev/null && ok "praxis-ai running"

  step "Connectivity Link llm-gateway"
  cat > "${GW_DIR}/connectivity-link/cluster-params.env" <<EOF
# Cluster specific value, generated by: ./deploy.sh ai-gateways deploy
# Commit this file when you deploy with Argo CD.
LLM_GATEWAY_HOSTNAME=llm-gateway.${d}
EOF
  oc apply -k "${GW_DIR}/connectivity-link" >/dev/null
  wait_until 180 "llm-gateway programmed" bash -c \
    "[[ \$(oc get gateway llm-gateway -n ${NS} -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}') == True ]]" \
    && ok "Gateway llm-gateway programmed"
  for p in authpolicy/llm-models-auth tokenratelimitpolicy/llm-models-tokens \
           authpolicy/llm-api-auth ratelimitpolicy/llm-api-throttle telemetrypolicy/llm-gateway-telemetry; do
    wait_until 120 "$p enforced" bash -c \
      "[[ \$(oc get $p -n ${NS} -o jsonpath='{.status.conditions[?(@.type==\"Enforced\")].status}') == True ]]" \
      && ok "$p Enforced"
  done
  # Gateway-level TokenRateLimitPolicy: Kuadrant reports Enforced=False ("rule(s) overridden")
  # because llm-models has its own; the limits are applied to llm-api-v1/v2. Accepted is enough.
  wait_until 120 "llm-api-tokens accepted" bash -c \
    "[[ \$(oc get tokenratelimitpolicy llm-api-tokens -n ${NS} -o jsonpath='{.status.conditions[?(@.type==\"Accepted\")].status}') == True ]]" \
    && ok "tokenratelimitpolicy/llm-api-tokens Accepted (see 'If something goes wrong' for its Enforced=False)"

  step "Consumer keys"
  key alice free >/dev/null; key bob gold >/dev/null
  ok "alice (free) and bob (gold): ${KEYS_FILE}"

  # Same race as the partner-gateway in demo 10: a new gateway Envoy can lose the fetch of the
  # Kuadrant wasm plugin at startup and then answer 503 forever. 401 = plugin loaded.
  local url="https://llm-gateway.${d}/gemma-3-270m-it/v1/models"
  if ! wait_until 45 "llm-gateway answering 401 without a key" bash -c \
      "[[ \$(curl -sk -o /dev/null -w '%{http_code}' ${url}) == 401 ]]"; then
    warn "llm-gateway not answering 401: restarting its pods once (known wasm-fetch race)"
    oc delete pod -n "$NS" -l gateway.networking.k8s.io/gateway-name=llm-gateway >/dev/null
    wait_until 90 "llm-gateway answering after restart" bash -c \
      "[[ \$(curl -sk -o /dev/null -w '%{http_code}' ${url}) == 401 ]]" && ok "llm-gateway answering"
  fi
  maas_check || true
  console
  urls
}

# ----------------------------------------------------------------------------- keys
key() {  # key <user> <free|gold>
  local user=${1:?usage: key <user> <free|gold>} tier=${2:?usage: key <user> <free|gold>} k
  [[ "$tier" == free || "$tier" == gold ]] || die "tier must be free or gold"
  k=$(oc get secret "llm-key-${user}" -n "$NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || true)
  k=${k:-sk-llm-${user}-$(rand 16)}
  # Authorino only watches Secrets labelled authorino.kuadrant.io/managed-by=authorino; the
  # AuthPolicy selects the ones with llm-gateway/consumer=true; the tier is an annotation.
  oc create secret generic "llm-key-${user}" -n "$NS" --from-literal=api_key="$k" --dry-run=client -o yaml \
    | oc label --local -f - -o yaml llm-gateway/consumer=true authorino.kuadrant.io/managed-by=authorino \
        app.kubernetes.io/part-of=ai-gateways-demo \
    | oc annotate --local -f - -o yaml "llm-gateway/tier=${tier}" \
    | oc apply -f - >/dev/null
  local var; var="KEY_$(tr '[:lower:]-' '[:upper:]_' <<<"$user")"   # bash 3.2 (macOS) safe
  touch "$KEYS_FILE"; chmod 600 "$KEYS_FILE"
  grep -v "^${var}=" "$KEYS_FILE" > "${KEYS_FILE}.tmp" || true
  echo "${var}=${k}" >> "${KEYS_FILE}.tmp"; mv "${KEYS_FILE}.tmp" "$KEYS_FILE"
  echo "$k"
}
key_of() {  # key_of <user>
  local k; k=$(oc get secret "llm-key-$1" -n "$NS" -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d || true)
  [[ -n "$k" ]] || die "no key for $1: ./deploy.sh ai-gateways key $1 <free|gold>"
  echo "$k"
}

maas_key() {
  local k
  k=$("${CURL[@]}" -X POST "https://$(maas_host)/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"ai-gateways-demo","subscription":"small-models-free","expiresIn":"1h"}' | jq -r '.key // empty' 2>/dev/null || true)
  [[ -n "$k" ]] || { maas_check; die "could not create a MaaS API key"; }
  echo "$k"
}

# Praxis's own MaaS key (720h, subscription small-models-free), injected by credential_injection
# into every request on the via-maas listener. Kept if it still works.
praxis_maas_key() {
  local k code
  k=$(oc get secret praxis-maas-key -n "$NS" -o jsonpath='{.data.MAAS_API_KEY}' 2>/dev/null | base64 -d || true)
  if [[ -n "$k" ]]; then
    code=$(curl -sk -o /dev/null -w '%{http_code}' "https://$(maas_host)/v1/models" -H "Authorization: Bearer ${k}")
    # only replace a key MaaS actually rejects (not on a flaky 5xx), so keys don't pile up
    if [[ "$code" == 200 && "$k" != placeholder-* ]]; then
      ok "Praxis MaaS key present and valid (Secret ${NS}/praxis-maas-key)"; return 0
    elif [[ "$code" != 401 && "$code" != 403 && "$k" != placeholder-* ]]; then
      # a 5xx says nothing about the key (intermittent maas-api validation error): keep it
      warn "Praxis MaaS key kept but not verified: MaaS answered ${code} (see 'If something goes wrong' in the demo guide)"
      return 0
    fi
  fi
  k=$("${CURL[@]}" -X POST "https://$(maas_host)/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"praxis-ai-gateway","subscription":"small-models-free","expiresIn":"720h"}' | jq -r '.key // empty' 2>/dev/null || true)
  if [[ -z "$k" ]]; then
    k="placeholder-maas-unavailable"
    warn "could not mint a MaaS key for Praxis (MaaS down?): via-maas /v1/messages will get 401 until 'deploy' runs again"
  else
    ok "Praxis MaaS key created (Secret ${NS}/praxis-maas-key, 30 days)"
  fi
  oc create secret generic praxis-maas-key -n "$NS" --from-literal=MAAS_API_KEY="$k" --dry-run=client -o yaml \
    | oc label --local -f - -o yaml app.kubernetes.io/part-of=ai-gateways-demo | oc apply -f - >/dev/null
}

# Praxis's OpenAI key (Part F), used by credential_injection on the 127.0.0.1 openai-egress
# listener. Taken from $OPENAI_API_KEY; an existing key is kept; otherwise a placeholder, so
# Praxis starts and OpenAI answers 401 (the guardrails still block before that).
praxis_openai_key() {
  local k=${OPENAI_API_KEY:-}
  if [[ -z "$k" ]]; then
    if oc get secret praxis-openai-key -n "$NS" >/dev/null 2>&1; then ok "Praxis OpenAI key kept (Secret ${NS}/praxis-openai-key)"; return 0; fi
    k="not-set"
    warn "OPENAI_API_KEY not set: OpenAI calls will get 401 until: ./deploy.sh ai-gateways openai-key"
  fi
  oc create secret generic praxis-openai-key -n "$NS" --from-literal=OPENAI_API_KEY="$k" --dry-run=client -o yaml \
    | oc label --local -f - -o yaml app.kubernetes.io/part-of=ai-gateways-demo | oc apply -f - >/dev/null
  [[ "$k" != not-set ]] && ok "Praxis OpenAI key stored (Secret ${NS}/praxis-openai-key)"
  return 0
}
openai_key() {
  need oc
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    [[ -t 0 ]] || die "set OPENAI_API_KEY"
    read -r -s -p "OpenAI API key (sk-...): " OPENAI_API_KEY; echo
  fi
  [[ "$OPENAI_API_KEY" == sk-* ]] || warn "that doesn't look like an OpenAI key (sk-...), storing it anyway"
  OPENAI_API_KEY="$OPENAI_API_KEY" praxis_openai_key
  # env vars from a Secret are read at start: restart Praxis to pick it up
  oc rollout restart deploy/praxis-ai -n "$NS" >/dev/null
  oc rollout status deploy/praxis-ai -n "$NS" --timeout=180s >/dev/null && ok "praxis-ai restarted with the new key"
}

# ----------------------------------------------------------------------------- console (Part F UI)
console() {
  need oc
  step "AI Gateway Console (React UI, built in the cluster)"
  oc apply -k "${GW_DIR}/console/openshift" >/dev/null
  local tmp tgz; tmp=$(mktemp -d); tgz="${tmp}/console.tgz"
  # upload the sources only (no node_modules / dist): the Dockerfile runs npm ci + vite build
  tar -C "${GW_DIR}/console" --exclude node_modules --exclude dist -czf "$tgz" .
  oc start-build ai-gateway-console -n "$NS" --from-archive="$tgz" --wait >/dev/null \
    || die "console build failed: oc logs -f bc/ai-gateway-console -n ${NS}"
  rm -rf "$tmp"
  oc rollout status deploy/ai-gateway-console -n "$NS" --timeout=180s >/dev/null && ok "console: https://$(route_host ai-gateway-console)"
}

# Praxis's via-maas listener has no public Route: reach it through a local port-forward.
PF_PID=""
praxis_maas_forward() {  # sets PM=http://127.0.0.1:18082
  oc port-forward -n "$NS" svc/praxis-ai 18082:8082 >/dev/null 2>&1 & PF_PID=$!
  trap '[[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true' EXIT
  PM=http://127.0.0.1:18082
  wait_until 20 "port-forward to praxis-ai:8082" curl -s -o /dev/null "${PM}/" || true
}

# MaaS gateway after a cluster restart: wasm plugin not loaded -> 503 wasm_fail_stream for
# everything (see platform/30-gateway/wasm-watchdog.yaml). Detect it; fixing it is a restart of
# a shared platform component, so print the command instead of doing it.
maas_check() {
  local code; code=$(curl -sk -o /dev/null -w '%{http_code}' "https://$(maas_host)/v1/models")
  if [[ "$code" == 401 ]]; then ok "MaaS gateway healthy (401 without a key)"; return 0; fi
  warn "MaaS gateway answers ${code} without a key (expected 401)."
  [[ "$code" == 503 ]] && info "Most likely the Kuadrant wasm plugin did not load after a cluster restart. Fix:" \
    && info "  oc rollout restart deploy/maas-default-gateway-openshift-default -n openshift-ingress"
  return 1
}

# ----------------------------------------------------------------------------- compare
chat_body() {  # chat_body <model> [max_tokens]
  jq -cn --arg m "$1" --argjson t "${2:-40}" \
    '{model:$m, max_tokens:$t, messages:[{role:"user", content:"In one sentence: what is an AI gateway?"}]}'
}
call() {  # call <label> <url> <body> [curl header args...] -> one table row
  local label=$1 url=$2 body=$3; shift 3
  local out code t note=""
  out=$("${CURL[@]}" -o /tmp/aigw-resp.json -w '%{http_code} %{time_total}' "$url" \
        -H 'content-type: application/json' "$@" -d "$body" || echo "000 0")
  read -r code t <<<"$out"
  if [[ "$code" == 500 ]]; then   # MaaS: intermittent maas-api key validation 500, retry once
    out=$("${CURL[@]}" -o /tmp/aigw-resp.json -w '%{http_code} %{time_total}' "$url" \
          -H 'content-type: application/json' "$@" -d "$body" || echo "000 0")
    read -r code t <<<"$out"; note=" (retried after a 500)"
  fi
  # OpenAI usage {prompt,completion}_tokens or Anthropic usage {input,output}_tokens
  printf "    %-34s %-4s %6.2fs  %s%s\n" "$label" "$code" "$t" \
    "$(jq -c '.usage | {in: (.prompt_tokens // .input_tokens), out: (.completion_tokens // .output_tokens)}' /tmp/aigw-resp.json 2>/dev/null || head -c 60 /tmp/aigw-resp.json)" "$note"
}

compare() {
  need jq
  local m=${1:-qwen3-0-6b} p g maas mk bob
  p="https://$(route_host praxis-ai)"; g="https://$(route_host llm-gateway)"; maas="https://$(maas_host)"
  bob=$(key_of bob)
  step "Same prompt, model ${m}, three gateways (first CPU call can take a minute)"
  printf "    %-34s %-4s %7s  %s\n" "gateway" "HTTP" "time" "usage"
  call "Praxis AI (no auth)"             "${p}/v1/chat/completions"        "$(chat_body "$m")"
  call "Connectivity Link (bob, gold)"   "${g}/${m}/v1/chat/completions"   "$(chat_body "$m")" -H "Authorization: APIKEY ${bob}"
  if mk=$(maas_key 2>/dev/null); then
    # MaaS on OpenShift AI 3.4 routes per model on the path, not on the body
    call "OpenShift AI MaaS (free sub)"  "${maas}/${MODELS_NS}/${m}/v1/chat/completions" "$(chat_body "$m")" -H "Authorization: Bearer ${mk}"
    praxis_maas_forward
    call "Praxis -> MaaS (OpenAI API)"   "${PM}/v1/chat/completions" "$(chat_body "$m")"
    call "Praxis -> MaaS (Anthropic API)" "${PM}/v1/messages" "$(chat_body "$m")" -H 'anthropic-version: 2023-06-01'
  else
    printf "    %-34s %s\n" "OpenShift AI MaaS" "skipped: $(maas_check >/dev/null 2>&1 || echo 'gateway unhealthy, run: ./deploy.sh ai-gateways maas-key')"
  fi
}

# ----------------------------------------------------------------------------- test
expect() {  # expect <label> <wanted-code> <curl args...>
  local label=$1 want=$2; shift 2; local got
  got=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$@" || echo 000)
  if [[ "$got" == "$want" ]]; then ok "${label}: ${got}"; else warn "${label}: got ${got}, expected ${want}"; fi
}
test_all() {
  need jq
  local p g alice bob
  p="https://$(route_host praxis-ai)"; g="https://$(route_host llm-gateway)"
  alice=$(key_of alice); bob=$(key_of bob)
  step "Praxis AI"
  expect "qwen3-0-6b by body model"        200 "${p}/v1/chat/completions" -H 'content-type: application/json' -d "$(chat_body qwen3-0-6b 10)"
  expect "gemma-3-270m-it by body model"   200 "${p}/v1/chat/completions" -H 'content-type: application/json' -d "$(chat_body gemma-3-270m-it 10)"
  expect "unknown model"                   404 "${p}/v1/chat/completions" -H 'content-type: application/json' -d "$(chat_body gpt-4o 10)"
  expect "Anthropic Messages -> OpenAI"    200 "${p}/v1/messages" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$(chat_body qwen3-0-6b 10)"
  local pg; pg="https://$(route_host praxis-ai-guarded)"
  expect "guarded: clean prompt"           200 "${pg}/v1/chat/completions" -H 'content-type: application/json' -d "$(chat_body gemma-3-270m-it 10)"
  expect "guarded: secret in prompt"       403 "${pg}/v1/chat/completions" -H 'content-type: application/json' \
    -d '{"model":"gemma-3-270m-it","max_tokens":10,"messages":[{"role":"user","content":"Summarize: CONFIDENTIAL, Project Phoenix"}]}'
  step "Connectivity Link"
  expect "no key"                          401 "${g}/gemma-3-270m-it/v1/chat/completions" -H 'content-type: application/json' -d "$(chat_body gemma-3-270m-it 10)"
  expect "alice (free) -> gemma"           200 "${g}/gemma-3-270m-it/v1/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'content-type: application/json' -d "$(chat_body gemma-3-270m-it 10)"
  expect "alice (free) -> qwen, forbidden" 403 "${g}/qwen3-0-6b/v1/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'content-type: application/json' -d "$(chat_body qwen3-0-6b 10)"
  expect "bob (gold) -> qwen"              200 "${g}/qwen3-0-6b/v1/chat/completions" -H "Authorization: APIKEY ${bob}" -H 'content-type: application/json' -d "$(chat_body qwen3-0-6b 10)"
  step "LLM API: Connectivity Link + Praxis (Part F)"
  local body; body() { jq -cn --arg m "$1" --arg c "${2:-hi}" '{model:$m, max_tokens:10, messages:[{role:"user", content:$c}]}'; }
  expect "v1 gemma"                        200 "${g}/v1/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'content-type: application/json' -d "$(body gemma-3-270m-it)"
  expect "v1 alias fast (v2 only)"         404 "${g}/v1/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'content-type: application/json' -d "$(body fast)"
  expect "v1 + x-api-version: 2, fast"     200 "${g}/v1/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'x-api-version: 2' -H 'content-type: application/json' -d "$(body fast)"
  expect "v2 smart"                        200 "${g}/v2/chat/completions" -H "Authorization: APIKEY ${bob}" -H 'content-type: application/json' -d "$(body smart)"
  expect "v2 alice cloud: tier gate"       403 "${g}/v2/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'content-type: application/json' -d "$(body cloud)"
  expect "v2 bob gpt-4o-mini lemons"       403 "${g}/v2/chat/completions" -H "Authorization: APIKEY ${bob}" -H 'content-type: application/json' -d "$(body gpt-4o-mini lemons)"
  expect "v2 confidential -> local"        200 "${g}/v2/chat/completions" -H "Authorization: APIKEY ${alice}" -H 'x-data-classification: confidential' -H 'content-type: application/json' -d "$(body gpt-4o-mini)"
  local oa; oa=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "${g}/v2/chat/completions" -H "Authorization: APIKEY ${bob}" -H 'content-type: application/json' -d "$(body gpt-4o-mini)")
  case "$oa" in 200) ok "v2 bob gpt-4o-mini (OpenAI): 200";; 401) warn "v2 bob gpt-4o-mini (OpenAI): 401, no OpenAI key: ./deploy.sh ai-gateways openai-key";; *) warn "v2 bob gpt-4o-mini (OpenAI): ${oa}";; esac
  step "OpenShift AI MaaS"
  maas_check || true
}

# ----------------------------------------------------------------------------- guard
guard() {
  need jq
  local pg p; pg="https://$(route_host praxis-ai-guarded)"; p="https://$(route_host praxis-ai)"
  g() {  # g <label> <body>
    local code
    code=$("${CURL[@]}" -o /tmp/aigw-guard.json -w '%{http_code}' "${pg}/v1/chat/completions" -H 'content-type: application/json' -d "$2")
    printf "    %-32s %s  %s\n" "$1" "$code" \
      "$(jq -r '.choices[0].message.content // .error.message // .' /tmp/aigw-guard.json 2>/dev/null | tr '\n' ' ' | cut -c1-110 || head -c 110 /tmp/aigw-guard.json)"
  }
  step "Praxis + NeMo Guardrails (guarded listener, config confidential)"
  g "clean prompt"           '{"model":"gemma-3-270m-it","max_tokens":30,"messages":[{"role":"user","content":"Say hi in one short sentence"}]}'
  g "secret in the prompt"   '{"model":"gemma-3-270m-it","max_tokens":30,"messages":[{"role":"user","content":"Summarize: CONFIDENTIAL - Project Phoenix launches in May"}]}'
  g "secret in the answer"   '{"model":"gemma-3-270m-it","max_tokens":40,"messages":[{"role":"system","content":"Always start your reply with the words: internal use only."},{"role":"user","content":"Say hi"}]}'
  g "personal data masked"   '{"model":"gemma-3-270m-it","max_tokens":80,"messages":[{"role":"user","content":"Which placeholders in angle brackets appear in this text? List them. Text: Contact jane.doe@acme.com, IBAN BE71096123456769"}]}'
  info "(403 = blocked before the model; 'Response blocked by guardrails' = the answer was blocked;"
  info " the model lists <EMAIL_ADDRESS>/<IBAN_CODE>: it never saw the real values)"
  step "The same personal-data prompt WITHOUT guardrails (direct listener)"
  "${CURL[@]}" "${p}/v1/chat/completions" -H 'content-type: application/json' \
    -d '{"model":"gemma-3-270m-it","max_tokens":80,"messages":[{"role":"user","content":"Which placeholders in angle brackets appear in this text? List them. Text: Contact jane.doe@acme.com, IBAN BE71096123456769"}]}' \
    | jq -r '.choices[0].message.content' | tr '\n' ' ' | cut -c1-140 | sed 's/^/    /'; echo
}

# ----------------------------------------------------------------------------- burst
burst() {
  local l g alice
  l="https://$(route_host praxis-ai-limited)"; g="https://$(route_host llm-gateway)"; alice=$(key_of alice)
  step "Praxis: request rate limit (5/s, burst 5), 20 parallel requests, no auth involved"
  for _ in $(seq 1 20); do curl -sk -o /dev/null -w '%{http_code}\n' "${l}/v1/models" & done | sort | uniq -c | sed 's/^/    /'
  wait
  info "(200 = got past the limiter: Praxis answers /v1/models itself (catalog-v1); 429 = limited)"
  step "Connectivity Link: token rate limit, alice (free, 300 tokens/min), sequential calls of ~95 tokens"
  for i in $(seq 1 7); do
    call "alice call ${i}" "${g}/gemma-3-270m-it/v1/chat/completions" \
      "$(jq -cn '{model:"gemma-3-270m-it",max_tokens:80,messages:[{role:"user",content:"Tell me about OpenShift"}]}')" \
      -H "Authorization: APIKEY ${alice}"
  done
  info "(429 once alice's counter is over 300 tokens in the current minute; bob is not affected)"
}

# ----------------------------------------------------------------------------- api (Part F)
# The LLM API behind Connectivity Link: one row per scenario of the console, from the terminal.
api_row() {  # api_row <label> <key> <path> <model> <prompt> [curl args...]
  local label=$1 k=$2 p=$3 m=$4 prompt=$5 g out code t; shift 5
  g="https://$(route_host llm-gateway)"
  out=$("${CURL[@]}" -o /tmp/aigw-api.json -D /tmp/aigw-api.h -w '%{http_code} %{time_total}' "${g}${p}" \
        -H "Authorization: APIKEY ${k}" -H 'content-type: application/json' "$@" \
        -d "$(jq -cn --arg m "$m" --arg c "$prompt" '{model:$m, max_tokens:20, messages:[{role:"user", content:$c}]}')" || echo "000 0")
  read -r code t <<<"$out"
  printf "    %-40s %-4s %6.2fs  %s %s\n" "$label" "$code" "$t" \
    "$(jq -r '"\(.model // "") \(.usage.total_tokens // "" | tostring) \(.error.message // "")"' /tmp/aigw-api.json 2>/dev/null | cut -c1-70 || head -c 60 /tmp/aigw-api.json)" \
    "$(grep -i '^x-api-version' /tmp/aigw-api.h | tr -d '\r' | sed 's/x-api-version: /v/I')"
}
api() {
  need jq
  local alice bob g; alice=$(key_of alice); bob=$(key_of bob); g="https://$(route_host llm-gateway)"
  step "API versioning (HTTPRoutes llm-api-v1 / llm-api-v2)"
  api_row "v1, gemma-3-270m-it"                 "$alice" /v1/chat/completions gemma-3-270m-it hi
  api_row "v1, fast (alias: v2 only)"           "$alice" /v1/chat/completions fast hi
  api_row "v1 + x-api-version: 2, fast"         "$alice" /v1/chat/completions fast hi -H 'x-api-version: 2'
  api_row "v2, fast"                            "$alice" /v2/chat/completions fast hi
  "${CURL[@]}" -o /dev/null -D - "${g}/v1/models" -H "Authorization: APIKEY ${alice}" | grep -iE '^(deprecation|sunset|link):' | sed 's/^/      /'
  step "Model routing and local vs OpenAI (Praxis api-v2)"
  api_row "bob: smart -> qwen3-0-6b"            "$bob" /v2/chat/completions smart hi
  api_row "bob: cloud -> gpt-4o-mini (OpenAI)"  "$bob" /v2/chat/completions cloud hi
  api_row "bob: gpt-5 (unknown)"                "$bob" /v2/chat/completions gpt-5 hi
  api_row "alice: cloud (free tier)"            "$alice" /v2/chat/completions cloud hi
  api_row "alice: cloud + spoofed tier header"  "$alice" /v2/chat/completions cloud hi -H 'x-consumer-tier: gold'
  api_row "alice: gpt-4o-mini, confidential"    "$alice" /v2/chat/completions gpt-4o-mini hi -H 'x-data-classification: confidential'
  step "Guardrails on the way to OpenAI (bob, gpt-4o-mini vs local fast)"
  local p
  for p in "coffee for the team?" "three lemons" "mail jane.doe@acme.com" "write a haiku"; do
    api_row "OpenAI: ${p}" "$bob" /v2/chat/completions gpt-4o-mini "$p"
  done
  api_row "local:  coffee for the team?"        "$bob" /v2/chat/completions fast "coffee for the team?"
  info "(403 + no body = Praxis guardrails; 401 'Incorrect API key' = reached OpenAI without a key: ./deploy.sh ai-gateways openai-key)"
  step "Throttle (RateLimitPolicy llm-api-throttle, $(oc get ratelimitpolicy llm-api-throttle -n "$NS" -o jsonpath='{.spec.limits.per-consumer.rates[0].limit}')/s per consumer): 10 parallel GET /v2/models as bob"
  for _ in $(seq 1 10); do curl -sk -o /dev/null -w '%{http_code}\n' "${g}/v2/models" -H "Authorization: APIKEY ${bob}" & done | sort | uniq -c | sed 's/^/    /'
  wait
}

# ----------------------------------------------------------------------------- metrics
metrics() {
  step "Praxis AI: per-model tokens and time to first token (from the gateway itself)"
  oc exec -n "$NS" deploy/praxis-ai -- wget -qO- http://127.0.0.1:9902/metrics 2>/dev/null \
    | grep -E '^praxis_(ai_(prompt_tokens_total|output_tokens_total|ttft_seconds_(sum|count))|upstream_healthy_endpoints)' | sed 's/^/    /'
  step "Connectivity Link / MaaS: Limitador counters (tokens charged per consumer and limit)"
  local pod; pod=$(oc get pod -n kuadrant-system -l app=limitador -o name | head -1)
  oc exec -n kuadrant-system "$pod" -- sh -c 'curl -s localhost:8080/metrics 2>/dev/null || wget -qO- localhost:8080/metrics' 2>/dev/null \
    | grep -E '^(authorized_hits|authorized_calls|limited_calls)' | grep -E 'ai-gateways|maas-models' | head -20 | sed 's/^/    /' \
    || info "(no Limitador metrics endpoint reachable)"
}

# ----------------------------------------------------------------------------- status / urls / destroy
status() {
  step "Praxis AI"
  oc get deploy praxis-ai -n "$NS" 2>/dev/null || warn "not deployed: ./deploy.sh ai-gateways deploy"
  step "Connectivity Link"
  oc get gateway,httproute -n "$NS" 2>/dev/null
  for p in authpolicy/llm-models-auth tokenratelimitpolicy/llm-models-tokens; do
    echo "    ${p}: $(oc get "$p" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status} {.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  done
  for p in authpolicy/llm-api-auth ratelimitpolicy/llm-api-throttle tokenratelimitpolicy/llm-api-tokens telemetrypolicy/llm-gateway-telemetry; do
    echo "    ${p}: $(oc get "$p" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status} {.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  done
  oc get secret -n "$NS" -l llm-gateway/consumer=true \
    -o custom-columns='KEY SECRET:.metadata.name,TIER:.metadata.annotations.llm-gateway/tier' 2>/dev/null
  step "OpenShift AI MaaS"
  oc get maasmodelref -n "$MODELS_NS" 2>/dev/null
  oc get maassubscription -n models-as-a-service 2>/dev/null
  maas_check || true
}

urls() {
  step "Endpoints"
  info "Praxis AI               : https://$(route_host praxis-ai)/v1            (OpenAI + Anthropic, model in the body)"
  info "Praxis AI, rate limited : https://$(route_host praxis-ai-limited)/v1"
  info "Praxis AI + guardrails  : https://$(route_host praxis-ai-guarded)/v1    (NeMo Guardrails, OpenAI Chat, no streaming)"
  info "Praxis AI -> MaaS       : no public Route: oc port-forward -n ${NS} svc/praxis-ai 18082:8082, then http://127.0.0.1:18082/v1"
  info "Connectivity Link       : https://$(route_host llm-gateway)/<model>/v1  (Authorization: APIKEY <key>)"
  info "LLM API (CL -> Praxis)  : https://$(route_host llm-gateway)/v1 and /v2   (Authorization: APIKEY <key>, model in the body)"
  info "AI Gateway Console      : https://$(route_host ai-gateway-console 2>/dev/null || echo '<not deployed: ./deploy.sh ai-gateways console>')"
  info "OpenShift AI MaaS       : https://$(maas_host)/${MODELS_NS}/<model>/v1   (Authorization: Bearer <MaaS key>; /v1/models lists them)"
  [[ -f "$KEYS_FILE" ]] && info "Connectivity Link keys  : ${KEYS_FILE}"
}

destroy() {
  step "Removing the AI gateways demo"
  oc delete referencegrant allow-ai-gateways-qwen allow-ai-gateways-gemma -n "$MODELS_NS" --ignore-not-found >/dev/null
  oc delete clusterrolebinding ai-gateway-console-monitoring-view --ignore-not-found >/dev/null
  oc delete namespace "$NS" --ignore-not-found --wait=false
  rm -f "$KEYS_FILE"
  info "MaaS, Connectivity Link and the models are untouched"
}

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd=${1:-}; [[ $# -gt 0 ]] && shift
case "$cmd" in
  deploy)   deploy ;;
  key)      key "$@" ;;
  openai-key) openai_key ;;
  console)  console ;;
  api)      api ;;
  maas-key) maas_key ;;
  compare)  compare "$@" ;;
  test)     test_all ;;
  guard)    guard ;;
  burst)    burst ;;
  metrics)  metrics ;;
  status)   status ;;
  urls)     urls ;;
  destroy)  destroy ;;
  ""|-h|--help|help) usage 0 ;;
  *) echo "unknown command: $cmd" >&2; usage 1 ;;
esac
