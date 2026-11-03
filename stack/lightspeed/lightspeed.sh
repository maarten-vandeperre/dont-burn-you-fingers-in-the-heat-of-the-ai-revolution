#!/usr/bin/env bash
# =============================================================================
# Developer Lightspeed for Red Hat Developer Hub, on the platform's own models (MaaS) + MCP tools
#
#   ./deploy.sh lightspeed setup        everything below, idempotent (re-run any time)
#   ./deploy.sh lightspeed llm          only (re)create the LLM wiring: MaaS subscription, API key,
#                                       Secret lightspeed-secrets (--rotate: always mint a new key)
#   ./deploy.sh lightspeed mcp          only (re)deploy platform-mcp (after changing server.py)
#   ./deploy.sh lightspeed test         end-to-end checks: MCP endpoints, tools, and three questions
#                                       through Lightspeed Core (the same path the chat UI uses)
#   ./deploy.sh lightspeed ask "<question>" [model]
#                                       one question through Lightspeed Core, prints the tool calls
#   ./deploy.sh lightspeed status       what is configured and running
#   ./deploy.sh lightspeed urls         where to click
#   ./deploy.sh lightspeed destroy      remove platform-mcp, the MaaS subscription/key and the
#                                       Lightspeed wiring of the Backstage CR (Developer Hub stays)
#
# What `setup` does
#   1. Heals two known issues that block it: a Backstage CR that cannot reconcile (duplicate
#      dynamic-plugins-registry-auth volume) and a MaaS gateway whose Kuadrant wasm plugin did not
#      load after a cluster restart (every MaaS call answers 503 "wasm_fail_stream").
#   2. LLM: Developer Lightspeed becomes a MaaS tenant: ServiceAccount rhdh/developer-lightspeed,
#      MaaSSubscription developer-lightspeed (200k tokens/min on Qwen3-0.6B), an API key minted with
#      that identity, Secret rhdh/lightspeed-secrets (ENABLE_VLLM, VLLM_URL, VLLM_API_KEY, ...).
#      OPENAI_API_KEY (exported before running setup/llm) adds the OpenAI models to the picker.
#   3. MCP: Developer Hub's MCP endpoint (mcp-actions-backend + software-catalog-mcp-extras plugins,
#      static MCP_TOKEN) and platform-mcp (stack/lightspeed/mcp-server): deployed models, catalog
#      overview and relations, CI/CD/runtime status per component.
#   4. Developer Hub: app-config-lightspeed + lightspeed-stack-config ConfigMaps, the two MCP
#      plugins in dynamic-plugins-rhdh, the Backstage CR mounts them into the lightspeed-core
#      sidecar (operator "lightspeed" flavour), rollout, then `test`.
#
# Needs: the platform stack (./deploy.sh stack: Developer Hub operator with the lightspeed flavour,
# OpenShift AI + MaaS with qwen3-0-6b). Demo guide: docs/demos/13-developer-lightspeed.md
#
# Environment
#   LIGHTSPEED_MODEL   MaaS model Lightspeed talks to (default qwen3-0-6b; must support tool calls)
#   OPENAI_API_KEY     optional: also offer OpenAI models (gpt-4o-mini, ...) in the model picker
# =============================================================================
set -Eeuo pipefail

LS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${LS_DIR}/../.." && pwd)"
RHDH_DIR="${ROOT_DIR}/stack/developer-hub"
NS=rhdh
CR=developer-hub
DEPLOY=backstage-developer-hub
MODEL="${LIGHTSPEED_MODEL:-qwen3-0-6b}"
MODELS_NS=maas-models
SUB=developer-lightspeed
LS_SA=developer-lightspeed
ROTATE=false
LAST_TOOLS=""

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}OK${N} $*"; }
info() { echo "    $*"; }
warn() { echo "    ${Y}WARN${N} $*" >&2; }
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
  ok "$label"
}
domain() { oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'; }
maas_host() { echo "maas.$(domain)"; }
rhdh_host() { oc get route "$DEPLOY" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true; }
rand_token() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40; }
secret_value() { oc get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true; }

preflight() {
  need oc; need jq; need curl
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  oc get backstage "$CR" -n "$NS" >/dev/null 2>&1 \
    || die "no Backstage '${CR}' in namespace ${NS}: run ./deploy.sh stack (or ./deploy.sh rhdh) first"
  oc get llminferenceservice "$MODEL" -n "$MODELS_NS" >/dev/null 2>&1 \
    || die "model ${MODEL} not found in ${MODELS_NS}: run ./deploy.sh stack (or LIGHTSPEED_MODEL=<model>)"
}

# ----------------------------------------------------------------------------- heal
# 1. The Backstage CR lists a Secret in extraFiles that the operator mounts itself
#    (dynamic-plugins-registry-auth): the operator then refuses to apply ANY change to the
#    deployment ("duplicate entries for key [name=dynamic-plugins-registry-auth]").
heal_backstage_cr() {
  local msg idx
  msg=$(oc get backstage "$CR" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Deployed")].message}' 2>/dev/null || true)
  [[ "$msg" == *"duplicate entries for key [name=\"dynamic-plugins-registry-auth\"]"* ]] || return 0
  idx=$(oc get backstage "$CR" -n "$NS" -o json \
        | jq '[.spec.application.extraFiles.secrets // [] | .[].name] | index("dynamic-plugins-registry-auth")')
  if [[ "$idx" != "null" ]]; then
    oc patch backstage "$CR" -n "$NS" --type=json \
      -p "[{\"op\":\"remove\",\"path\":\"/spec/application/extraFiles/secrets/${idx}\"}]" >/dev/null
    warn "Backstage CR could not reconcile (duplicate volume dynamic-plugins-registry-auth): removed the"
    info "     extraFiles entry, the operator mounts that Secret itself (optional) at the same place"
  fi
}

# 2. After a cluster restart the MaaS gateway sometimes starts without the Kuadrant wasm plugin
#    (fail closed): every call gets 503 with response flag wasm_fail_stream. A restart reloads it.
maas_code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "https://$(maas_host)/v1/models" || echo 000; }
heal_maas_gateway() {
  local code; code=$(maas_code)
  [[ "$code" == "503" ]] || { ok "MaaS gateway answers (HTTP ${code} without key)"; return 0; }
  if oc logs -n openshift-ingress deploy/maas-default-gateway-openshift-default --tail=200 2>/dev/null | grep -q wasm_fail_stream; then
    # The gateway fetches the wasm plugin from the Kuadrant operator at start. If the operator is
    # not Ready (CrashLoopBackOff with its default 200m cpu limit), a restart fails again.
    if [[ -z "$(oc get endpoints kuadrant-operator-wasm -n openshift-operators -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]]; then
      warn "Kuadrant operator not Ready (no kuadrant-operator-wasm endpoint): applying operators/connectivity-link.yaml (higher cpu limit)"
      oc apply --server-side --force-conflicts --field-manager=maas-deploy -f "${ROOT_DIR}/operators/connectivity-link.yaml" >/dev/null
      wait_until 600 "Kuadrant operator serves the wasm plugin" bash -c \
        "[[ -n \"\$(oc get endpoints kuadrant-operator-wasm -n openshift-operators -o jsonpath='{.subsets[*].addresses[*].ip}')\" ]]" \
        || die "Kuadrant operator still not Ready: oc get pods -n openshift-operators | grep kuadrant-operator"
    fi
    warn "MaaS gateway answers 503 (Kuadrant wasm plugin not loaded): restarting it"
    oc rollout restart deploy/maas-default-gateway-openshift-default -n openshift-ingress >/dev/null
    oc rollout status deploy/maas-default-gateway-openshift-default -n openshift-ingress --timeout=300s >/dev/null
    wait_until 120 "MaaS gateway serves requests again" bash -c "[[ \"\$(curl -sk -o /dev/null -w '%{http_code}' https://$(maas_host)/v1/models)\" != 503 ]]" \
      || die "MaaS still answers 503: oc logs -n openshift-ingress deploy/maas-default-gateway-openshift-default"
  else
    die "MaaS answers 503: check ./deploy.sh status and the gateway logs"
  fi
}

# ----------------------------------------------------------------------------- MCP token
# Developer Hub reads MCP_TOKEN from rhdh-secrets (static externalAccess token), platform-mcp
# checks it, Lightspeed sends it. deploy.sh keeps the value when it rewrites rhdh-secrets.
ensure_mcp_token() {
  if [[ -n "$(secret_value "$NS" rhdh-secrets MCP_TOKEN)" ]]; then ok "MCP_TOKEN present in ${NS}/rhdh-secrets"; return 0; fi
  oc patch secret rhdh-secrets -n "$NS" --type=merge \
    -p "{\"data\":{\"MCP_TOKEN\":\"$(rand_token | base64 | tr -d '\n')\"}}" >/dev/null
  ok "MCP_TOKEN generated in ${NS}/rhdh-secrets"
}

# ----------------------------------------------------------------------------- LLM (MaaS)
key_works() {  # key_works <key>: the key can call the model (GET /v1/models of the model path)
  [[ -n "$1" ]] || return 1
  [[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -H "Authorization: Bearer $1" \
        "https://$(maas_host)/${MODELS_NS}/${MODEL}/v1/models")" == "200" ]]
}

setup_llm() {
  step "LLM: Developer Lightspeed as a MaaS tenant (model ${MODEL})"
  heal_maas_gateway
  oc apply -f "${LS_DIR}/maas/subscription.yaml" >/dev/null
  if [[ "$MODEL" != "qwen3-0-6b" ]]; then
    oc patch maassubscription "$SUB" -n models-as-a-service --type=json \
      -p "[{\"op\":\"replace\",\"path\":\"/spec/modelRefs/0/name\",\"value\":\"${MODEL}\"}]" >/dev/null
  fi
  wait_until 120 "MaaSSubscription ${SUB} active" bash -c \
    "[[ \"\$(oc get maassubscription ${SUB} -n models-as-a-service -o jsonpath='{.status.phase}')\" == Active ]]" || true

  local key resp sa_token openai
  key=$(secret_value "$NS" lightspeed-secrets VLLM_API_KEY)
  if [[ "$ROTATE" == false ]] && key_works "$key"; then
    ok "existing MaaS API key of Lightspeed still valid"
  else
    sa_token=$(oc create token "$LS_SA" -n "$NS" --duration=10m)
    resp=$(curl -sk --max-time 60 -X POST "https://$(maas_host)/maas-api/v1/api-keys" \
      -H "Authorization: Bearer ${sa_token}" -H "Content-Type: application/json" \
      -d "{\"name\":\"developer-lightspeed\",\"subscription\":\"${SUB}\",\"expiresIn\":\"720h\"}")
    key=$(jq -r '.key // empty' <<<"$resp" 2>/dev/null || true)
    [[ -n "$key" ]] || die "could not mint a MaaS API key for ${LS_SA}: $(jq -c 'del(.key)' <<<"$resp" 2>/dev/null || echo "$resp" | head -c 300)"
    wait_until 60 "new MaaS API key accepted by the gateway" key_works "$key" || die "the new key is rejected (check: oc get maassubscription ${SUB} -n models-as-a-service -o yaml)"
    ok "MaaS API key minted as system:serviceaccount:${NS}:${LS_SA} (subscription ${SUB}, 30 days)"
  fi

  openai="${OPENAI_API_KEY:-}"
  # ENABLE_* must be absent (not "false") to disable a provider in the Llama Stack config
  local args=(--from-literal=ENABLE_VLLM=true
              --from-literal=VLLM_URL="https://$(maas_host)/${MODELS_NS}/${MODEL}/v1"
              --from-literal=VLLM_API_KEY="$key"
              --from-literal=VLLM_TLS_VERIFY=true
              --from-literal=VLLM_MAX_TOKENS=1024)
  [[ -n "$openai" ]] && args+=(--from-literal=ENABLE_OPENAI=true --from-literal=OPENAI_API_KEY="$openai")
  oc create secret generic lightspeed-secrets -n "$NS" "${args[@]}" --dry-run=client -o yaml \
    | oc apply --server-side --force-conflicts --field-manager=lightspeed -f - >/dev/null
  ok "Secret ${NS}/lightspeed-secrets: vLLM provider -> https://$(maas_host)/${MODELS_NS}/${MODEL}/v1$([[ -n "$openai" ]] && echo ', OpenAI provider enabled' || echo ' (no OPENAI_API_KEY: MaaS only)')"
}

# ----------------------------------------------------------------------------- MCP server
setup_mcp() {
  step "platform-mcp (MCP tools: deployed models, catalog relations, CI/CD per component)"
  ensure_mcp_token
  oc apply -k "${LS_DIR}/mcp-server" >/dev/null
  oc rollout status deploy/platform-mcp -n "$NS" --timeout=300s >/dev/null && ok "platform-mcp running (http://platform-mcp.${NS}.svc:8080/mcp)"
}

# ----------------------------------------------------------------------------- Developer Hub
# Package reference of an extension plugin, from the catalog index of the running Developer Hub
extension_package() {  # extension_package <name>
  oc exec -n "$NS" "deploy/${DEPLOY}" -c backstage-backend -- sh -c \
    "grep -rhoE 'dynamicArtifact:[[:space:]]*[^[:space:]]+' /extensions 2>/dev/null" 2>/dev/null \
    | sed -E 's/^dynamicArtifact:[[:space:]]*//; s/["'"'"']//g' | grep -E "/$1:" | head -1
}

ensure_dynamic_plugins() {
  local cm file name pkg added=0
  file=$(mktemp)
  oc get cm dynamic-plugins-rhdh -n "$NS" -o jsonpath='{.data.dynamic-plugins\.yaml}' > "$file"
  for name in backstage-plugin-mcp-actions-backend red-hat-developer-hub-backstage-plugin-software-catalog-mcp-extras; do
    if grep -q "$name" "$file"; then ok "plugin ${name} already enabled"; continue; fi
    pkg=$(extension_package "$name")
    [[ -n "$pkg" ]] || die "plugin ${name} is not offered by this Developer Hub (./deploy.sh rhdh-plugins mcp)"
    printf "  - package: '%s'  # extensions\n    disabled: false\n" "$pkg" >> "$file"
    ok "plugin ${name}: ${pkg}"
    added=1
  done
  if [[ "$added" == 1 ]]; then
    oc create cm dynamic-plugins-rhdh -n "$NS" --from-file=dynamic-plugins.yaml="$file" --dry-run=client -o yaml \
      | oc apply --server-side --force-conflicts --field-manager=maas-stack -f - >/dev/null
  fi
  rm -f "$file"
}

# Add the Lightspeed wiring to the Backstage CR without touching anything else in it (the CR may
# carry entries of other demos). Same result as stack/developer-hub/backstage.yaml in git.
patch_backstage_cr() {
  local spec new
  spec=$(oc get backstage "$CR" -n "$NS" -o json | jq '.spec.application')
  new=$(jq '
    .appConfig.configMaps = ((.appConfig.configMaps // []) | if any(.name == "app-config-lightspeed") then . else . + [{"name":"app-config-lightspeed"}] end)
    | .extraEnvs.secrets = ((.extraEnvs.secrets // []) | if any(.name == "lightspeed-secrets") then . else . + [{"name":"lightspeed-secrets","containers":["lightspeed-core"]}] end)
    | .extraFiles.configMaps = ((.extraFiles.configMaps // []) | if any(.name == "lightspeed-stack-config") then . else . + [{"name":"lightspeed-stack-config","key":"lightspeed-stack.yaml","mountPath":"/app-root","containers":["lightspeed-core"]}] end)
  ' <<<"$spec")
  if [[ "$(jq -S . <<<"$spec")" == "$(jq -S . <<<"$new")" ]]; then
    ok "Backstage CR already wired for Lightspeed"; return 1
  fi
  oc patch backstage "$CR" -n "$NS" --type=merge -p "{\"spec\":{\"application\":${new}}}" >/dev/null
  ok "Backstage CR: app-config-lightspeed, lightspeed-secrets and lightspeed-stack-config -> lightspeed-core"
}

rhdh_config_hash() {
  oc get cm app-config-lightspeed lightspeed-stack-config dynamic-plugins-rhdh -n "$NS" -o json \
    | jq -c '[.items[].data]' | cksum | cut -d' ' -f1
  secret_value "$NS" lightspeed-secrets VLLM_URL | cksum | cut -d' ' -f1
}

wait_rhdh() {
  local i pod reason
  info "Developer Hub restarts (dynamic plugins install + Lightspeed sidecar, ~2-6 min)"
  sleep 15
  for i in $(seq 1 72); do
    if oc rollout status "deploy/${DEPLOY}" -n "$NS" --timeout=5s >/dev/null 2>&1; then
      ok "Developer Hub ready"; return 0
    fi
    pod=$(oc get pods -n "$NS" -l rhdh.redhat.com/app=backstage-developer-hub --sort-by=.metadata.creationTimestamp -o name | tail -1)
    reason=$(oc get "$pod" -n "$NS" -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-dynamic-plugins")].state.waiting.reason}{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null || true)
    if [[ "$reason" == *CrashLoopBackOff* ]]; then
      warn "a container of ${pod} crash-loops:"
      oc get "$pod" -n "$NS" -o jsonpath='{range .status.containerStatuses[*]}{.name}={.state}{"\n"}{end}' | cut -c1-200 | sed 's/^/      /'
      info "logs: oc logs -n ${NS} ${pod} -c backstage-backend (or lightspeed-core, install-dynamic-plugins)"
      return 1
    fi
    (( i % 6 == 0 )) && info "... still waiting ($((i / 4)) min)"
    sleep 10
  done
  warn "Developer Hub not ready after 12 min: oc get pods -n ${NS}"; return 1
}

setup_rhdh() {
  step "Developer Hub: Lightspeed + MCP configuration"
  local before after changed=false
  heal_backstage_cr
  before=$(rhdh_config_hash 2>/dev/null || true)
  oc apply --server-side --force-conflicts --field-manager=maas-stack -n "$NS" \
    -f "${RHDH_DIR}/lightspeed/app-config-lightspeed.yaml" >/dev/null && ok "ConfigMap app-config-lightspeed"
  oc create cm lightspeed-stack-config -n "$NS" --from-file=lightspeed-stack.yaml="${RHDH_DIR}/lightspeed/lightspeed-stack.yaml" \
    --dry-run=client -o yaml | oc apply --server-side --force-conflicts --field-manager=maas-stack -f - >/dev/null \
    && ok "ConfigMap lightspeed-stack-config (Lightspeed Core: MCP servers mcp-integration-tools + platform-tools)"
  ensure_dynamic_plugins
  after=$(rhdh_config_hash)
  if patch_backstage_cr; then changed=true; fi   # the operator rolls out on a CR change
  if [[ "$changed" == false && "$before" != "$after" ]] || [[ "${LS_FORCE_RESTART:-false}" == true ]]; then
    oc rollout restart "deploy/${DEPLOY}" -n "$NS" >/dev/null   # ConfigMap/Secret content changed only
  fi
  if [[ "$changed" == true || "$before" != "$after" || "${LS_FORCE_RESTART:-false}" == true ]]; then
    wait_until 120 "operator reconciled the Backstage CR" bash -c \
      "[[ \"\$(oc get backstage ${CR} -n ${NS} -o jsonpath='{.status.conditions[?(@.type==\"Deployed\")].status}')\" == True ]]" \
      || { oc get backstage "$CR" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Deployed")].message}' | sed 's/^/      /'; echo; die "the operator did not apply the Backstage CR"; }
    wait_rhdh || die "Developer Hub did not come back"
  else
    ok "nothing changed, no restart needed (LS_FORCE_RESTART=true to force one)"
  fi
}

# ----------------------------------------------------------------------------- test / ask
LCS_PY='
# Same request as the Lightspeed backend plugin (router.cjs.js, POST /v1/query of the chat UI):
# streaming_query + system_prompt (lightspeed.systemPrompt) + the RHDH docs vector store +
# MCP-HEADERS with the bare token per MCP server (Llama Stack adds "Bearer ").
import json, sys, urllib.request
q, model, provider, headers, system_prompt = sys.argv[1:6]
base = "http://127.0.0.1:8080"
body = {"query": q, "model": model, "provider": provider, "media_type": "application/json"}
if system_prompt.strip():
    body["system_prompt"] = system_prompt
try:
    vs = json.load(urllib.request.urlopen(base + "/v1/vector-stores", timeout=30)).get("data", [])
    ids = [v["id"] for v in vs if v.get("name", "").startswith("rhdh-product-docs")]
    if ids:
        body["vector_store_ids"] = ids[:1]
except Exception:
    pass
req = urllib.request.Request(base + "/v1/streaming_query", data=json.dumps(body).encode(),
      headers={"Content-Type": "application/json", "MCP-HEADERS": headers})
tools, text, errors = [], [], []
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            try:
                ev = json.loads(line[5:].strip())
            except ValueError:
                continue
            kind, data = ev.get("event"), ev.get("data") or {}
            if kind == "tool_call" and data.get("type") != "mcp_list_tools":
                name = data.get("name") or "?"
                args = json.dumps(data.get("args") or {})
                tools.append(f"{name}({args})")
            elif kind == "token":
                text.append(str(data.get("token", "")))
            elif kind == "turn_complete" and data.get("token"):
                text = [str(data["token"])]
            elif kind == "error":
                errors.append(json.dumps(data)[:400])
except urllib.error.HTTPError as e:
    print(json.dumps({"error": e.code, "body": e.read().decode()[:600]})); sys.exit(0)
out = {"response": "".join(text).strip(), "tool_calls": [{"name": t} for t in tools]}
if errors:
    out["errors"] = errors
print(json.dumps(out))
'
lcs_models() {
  oc exec -n "$NS" "deploy/${DEPLOY}" -c lightspeed-core -- python3 -c '
import json, urllib.request
print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:8080/v1/models", timeout=30))))'
}
lcs_model_id() {  # model id + provider of the MaaS model as Lightspeed Core lists it
  lcs_models | jq -r --arg m "$1" '.models[] | select(.model_type == "llm" and ((.identifier|endswith($m)) or (.provider_resource_id == $m))) | "\(.provider_resource_id // .identifier) \(.provider_id)"' | head -1
}

ask() {  # ask <question> [model]
  local q=$1 m=${2:-$MODEL} id provider tok headers out sp
  read -r id provider <<<"$(lcs_model_id "$m")"
  [[ -n "$id" ]] || die "Lightspeed Core does not list a model '${m}' (./deploy.sh lightspeed status)"
  tok=$(secret_value "$NS" rhdh-secrets MCP_TOKEN)
  # same shape as the Lightspeed backend plugin: the bare token, Llama Stack adds "Bearer "
  headers=$(jq -cn --arg t "${tok}" '{"mcp-integration-tools":{"Authorization":$t},"platform-tools":{"Authorization":$t}}')
  sp=$(oc get cm app-config-lightspeed -n "$NS" -o jsonpath='{.data.app-config-lightspeed\.yaml}' \
       | awk '/^  systemPrompt: \|/ {f=1; next} f && /^  [a-zA-Z]/ {f=0} f {sub(/^    /, ""); print}')
  info "Q (${provider}/${id}): ${q}"
  local since; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  out=$(oc exec -n "$NS" "deploy/${DEPLOY}" -c lightspeed-core -- python3 -c "$LCS_PY" "$q" "$id" "$provider" "$headers" "$sp")
  if jq -e '.error' <<<"$out" >/dev/null 2>&1; then warn "Lightspeed Core answered $(jq -c . <<<"$out")"; return 1; fi
  jq -e '.errors' <<<"$out" >/dev/null 2>&1 && warn "errors in the stream: $(jq -c .errors <<<"$out")"
  # Ground truth from platform-mcp's own log (the stream does not always carry the tool name);
  # calls to Developer Hub's MCP endpoint only appear in the stream
  LAST_TOOLS=$( { oc logs -n "$NS" deploy/platform-mcp --since-time="$since" 2>/dev/null \
                   | sed -nE 's/^[^ ]+ tool ([a-z_]+) (\{.*\}) -> .*/\1(\2)/p'
                 jq -r '.tool_calls[]?.name | select(. != "?" and . != "" and (startswith("software-catalog") or startswith("query")))' <<<"$out"; } \
               | awk 'NF && !seen[$0]++' | paste -sd, -)
  info "MCP tools called: ${LAST_TOOLS:-none}"
  echo "    ${G}A:${N} (Qwen3 reasoning <think>...</think> omitted here; the chat UI shows it as a collapsible section)"
  jq -r '.response' <<<"$out" | perl -0pe 's/<think>.*?<\/think>\s*//gs' | sed '/^[[:space:]]*$/N;/^\n$/D' | sed 's/^/    | /'
}

mcp_call() {  # mcp_call <url-from-inside-the-rhdh-pod> <json-rpc body>
  local tok; tok=$(secret_value "$NS" rhdh-secrets MCP_TOKEN)
  oc exec -n "$NS" "deploy/${DEPLOY}" -c backstage-backend -- curl -s --max-time 60 -X POST "$1" \
    -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$2"
}

test_all() {
  preflight
  local fails=0 out
  step "MCP endpoints"
  out=$(mcp_call http://localhost:7007/api/mcp-actions/v1 '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | sed -n 's/^data: //;/^{/{p;q;}')
  if jq -e '.result.tools | length > 0' <<<"$out" >/dev/null 2>&1; then
    ok "Developer Hub MCP (mcp-integration-tools): $(jq -r '[.result.tools[].name] | join(", ")' <<<"$out")"
  else warn "Developer Hub MCP endpoint: ${out:0:300}"; fails=$((fails + 1)); fi
  out=$(mcp_call http://platform-mcp.${NS}.svc:8080/mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
  if jq -e '.result.tools | length > 0' <<<"$out" >/dev/null 2>&1; then
    ok "platform-mcp (platform-tools): $(jq -r '[.result.tools[].name] | join(", ")' <<<"$out")"
  else warn "platform-mcp: ${out:0:300}"; fails=$((fails + 1)); fi
  out=$(mcp_call http://platform-mcp.${NS}.svc:8080/mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_deployed_models","arguments":{}}}')
  jq -e '.result.isError == false' <<<"$out" >/dev/null 2>&1 && ok "tool list_deployed_models works" || { warn "list_deployed_models: ${out:0:300}"; fails=$((fails + 1)); }
  out=$(mcp_call http://platform-mcp.${NS}.svc:8080/mcp '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_component_details","arguments":{"name":"coffee-shop"}}}')
  jq -e '.result.isError == false' <<<"$out" >/dev/null 2>&1 && ok "tool get_component_details works (catalog API + cluster)" || { warn "get_component_details: ${out:0:300}"; fails=$((fails + 1)); }

  step "Lightspeed Core: models"
  info "$(lcs_models | jq -r '[.models[] | select(.model_type == "llm") | "\(.provider_id)/\(.provider_resource_id // .identifier)"] | join(", ")')"

  step "Questions through Lightspeed Core (same request as the chat UI; Qwen3 on CPU: ~30-90 s each)"
  local q expect
  while IFS='|' read -r expect q; do
    if ask "$q"; then
      if [[ ",${LAST_TOOLS}," == *",${expect}("* ]]; then ok "the model used ${expect}"
      else warn "expected a call to ${expect}, got: ${LAST_TOOLS:-none}"; fails=$((fails + 1)); fi
    else fails=$((fails + 1)); fi
    echo
  done <<'QUESTIONS'
list_deployed_models|Which models are deployed in OpenShift AI?
get_catalog_overview|Give me an overview of the software catalog and how the components relate to each other.
get_component_details|What is linked to the coffee-shop component and what is its CI status?
QUESTIONS
  [[ "$fails" == 0 ]] && ok "all Lightspeed checks passed" || die "${fails} check(s) failed"
}

# ----------------------------------------------------------------------------- status / urls
status() {
  need oc; need jq
  step "Developer Lightspeed status"
  info "Backstage CR      : $(oc get backstage "$CR" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Deployed")].status} {.status.conditions[?(@.type=="Deployed")].reason}' 2>/dev/null)"
  info "Developer Hub pod : $(oc get pods -n "$NS" -l rhdh.redhat.com/app=backstage-developer-hub --no-headers 2>/dev/null | awk '{print $1" "$2" "$3}' | tr '\n' ' ')"
  info "lightspeed-core   : $(oc get deploy "$DEPLOY" -n "$NS" -o json | jq -r '[.spec.template.spec.containers[].name] | join(", ")')"
  info "LLM secret        : $(secret_value "$NS" lightspeed-secrets VLLM_URL || true) $([[ -n "$(secret_value "$NS" lightspeed-secrets ENABLE_OPENAI)" ]] && echo '+ OpenAI')"
  info "MaaS subscription : $(oc get maassubscription "$SUB" -n models-as-a-service -o jsonpath='{.status.phase}' 2>/dev/null || echo missing)"
  info "platform-mcp      : $(oc get deploy platform-mcp -n "$NS" -o jsonpath='{.status.readyReplicas}/{.spec.replicas} ready' 2>/dev/null || echo 'not deployed')"
  info "MCP plugins       : $(oc get cm dynamic-plugins-rhdh -n "$NS" -o jsonpath='{.data.dynamic-plugins\.yaml}' | grep -oE '(mcp-actions-backend|software-catalog-mcp-extras)' | sort -u | tr '\n' ' ')"
  info "LCS models        : $(lcs_models 2>/dev/null | jq -r '[.models[] | select(.model_type == "llm") | "\(.provider_id)/\(.provider_resource_id // .identifier)"] | join(", ")' || echo 'lightspeed-core not reachable')"
}

urls() {
  step "Developer Lightspeed"
  info "Chat              : https://$(rhdh_host)/lightspeed   (or the Lightspeed button, bottom right)"
  info "MCP endpoint      : https://$(rhdh_host)/api/mcp-actions/v1   (Bearer MCP_TOKEN, for Cursor / Claude / VS Code)"
  info "MCP token         : oc get secret rhdh-secrets -n ${NS} -o jsonpath='{.data.MCP_TOKEN}' | base64 -d"
  info "Token usage       : ./deploy.sh usage   (subscription ${SUB})"
}

destroy() {
  preflight
  step "Removing Developer Lightspeed wiring (Developer Hub itself stays)"
  oc delete -k "${LS_DIR}/mcp-server" --ignore-not-found >/dev/null && ok "platform-mcp removed"
  local spec
  spec=$(oc get backstage "$CR" -n "$NS" -o json | jq '.spec.application
    | .appConfig.configMaps |= map(select(.name != "app-config-lightspeed"))
    | .extraEnvs.secrets |= map(select(.name != "lightspeed-secrets"))
    | .extraFiles.configMaps |= map(select(.name != "lightspeed-stack-config"))')
  oc patch backstage "$CR" -n "$NS" --type=merge -p "{\"spec\":{\"application\":${spec}}}" >/dev/null && ok "Backstage CR unwired"
  oc delete cm app-config-lightspeed lightspeed-stack-config -n "$NS" --ignore-not-found >/dev/null
  oc delete secret lightspeed-secrets -n "$NS" --ignore-not-found >/dev/null
  oc delete -f "${LS_DIR}/maas/subscription.yaml" --ignore-not-found >/dev/null && ok "MaaS subscription + ServiceAccount removed (its API keys stop working)"
  info "The MCP plugins stay in dynamic-plugins-rhdh (harmless); ./deploy.sh rhdh regenerates that file."
}

# ----------------------------------------------------------------------------- main
CMD=${1:-help}; shift || true
ARGS=()
for a in "$@"; do
  case $a in
    --rotate) ROTATE=true ;;
    *) ARGS+=("$a") ;;
  esac
done
case $CMD in
  setup)   preflight; setup_llm; setup_mcp; setup_rhdh; test_all; urls ;;
  llm)     preflight; setup_llm; LS_FORCE_RESTART=true setup_rhdh ;;
  mcp)     preflight; setup_mcp ;;
  test)    test_all ;;
  ask)     preflight; [[ ${#ARGS[@]} -ge 1 ]] || die "usage: ./deploy.sh lightspeed ask \"<question>\" [model]"; ask "${ARGS[@]}" ;;
  status)  status ;;
  urls)    urls ;;
  destroy) destroy ;;
  -h|--help|help) awk '/^# =+$/ { if (++n == 2) exit; next } n == 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown command '${CMD}' (setup | llm | mcp | test | ask | status | urls | destroy)" ;;
esac
