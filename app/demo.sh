#!/usr/bin/env bash
# =============================================================================
# AI platform demo apps (namespace ai-demo) on the OpenShift 4.22 stack
#
#   all                     setup + build + deploy + urls
#   setup                   namespace, secrets (MaaS API key, OpenAI key, DB), cluster params
#   build [service...]      build images in the cluster (binary Docker builds of this folder)
#   deploy [--rollouts]     apply app/deploy (with --rollouts: model-router as Argo Rollout)
#   pattern <name> [w]      rag-service traffic: reset | canary [weight] | ab | blue | green | mirror
#   menu <name> [n]         coffee-menu traffic + chaos: reset | canary [w] | blue | green | mirror |
#                           delay [percent] | abort [percent]
#   coffee                  coffee shop end to end: order via the model, status changes, audit trail
#   update                  existing install: setup + build the new/changed services + deploy
#   mlflow                  (re)create the MLflow experiment and the collector link for AI traces
#   traffic [n] [variant]   send n requests and show which rag version answered
#   probe                   "who can access who" from the frontend's mesh identity
#   mtls                    call the services from a pod outside the mesh (STRICT mTLS rejects it)
#   rollout                 start an Argo Rollouts canary of the model-router (needs --rollouts)
#   cdc                     create a customer + order and show the MongoDB projection
#   ask "<question>" [model] ask the RAG service (model: auto | qwen | gemma | openai)
#   pipeline <git-url> [rev] build all services with the Tekton pipeline instead
#   gitops <git-url> [rev]  let Argo CD manage app/deploy (sync status shows up in Developer Hub)
#   status | urls | destroy
#
# Environment: OPENAI_API_KEY (optional, enables alias "openai" and the fallback of "auto")
# =============================================================================
set -Eeuo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="ai-demo"
SERVICES=(frontend rag-service model-router orders-service projection-service coffee-shop coffee-menu)

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo "${B}==> $*${N}"; }
info() { echo "    $*"; }
ok()   { echo "    ${G}OK${N} $*"; }
warn() { echo "    ${Y}WARN${N} $*" >&2; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required"; }
usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

route_host() { oc get route ai-demo -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true; }
coffee_url() { local h; h=$(oc get route coffee -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true); [[ -n "$h" ]] || die "route coffee not found in namespace ${NS}: run './deploy.sh app update' (or setup, build coffee-shop coffee-menu projection-service, deploy)"; echo "https://${h}"; }
base_url() { local h; h=$(route_host); [[ -n "$h" ]] || die "route ai-demo not found, run './demo.sh deploy' first"; echo "https://${h}"; }
CURL=(curl -sk --max-time 300)

# ----------------------------------------------------------------------------- setup
prereqs() {
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  local missing=""
  oc get istio default >/dev/null 2>&1 || missing+=" service-mesh(istio/default)"
  oc get kafka platform -n kafka >/dev/null 2>&1 || missing+=" kafka(kafka/platform)"
  oc get secret inventory-db -n kafka >/dev/null 2>&1 || missing+=" inventory-db-secret"
  oc get deployment otel-collector -n tracing-system >/dev/null 2>&1 || missing+=" tracing(otel-collector)"
  oc get llminferenceservice -n maas-models >/dev/null 2>&1 || missing+=" maas-models"
  [[ -z "$missing" ]] || die "platform parts missing:${missing}. Install the stack first: ./deploy.sh stack"
  ok "platform stack present (mesh, kafka, tracing, MaaS)"
}

maas_api_key() {  # creates a long lived MaaS API key for the model-router
  local host="$1" sub key
  for sub in small-models-premium small-models-free; do
    key=$("${CURL[@]}" -X POST "https://${host}/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d "{\"name\":\"ai-demo-model-router\",\"subscription\":\"${sub}\",\"expiresIn\":\"720h\"}" \
      | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
    if [[ -n "$key" ]]; then info "MaaS API key created on subscription ${sub}" >&2; echo "$key"; return 0; fi
  done
  return 1
}

setup() {
  prereqs
  step "Namespace ${NS} (in the mesh)"
  oc apply -f "${APP_DIR}/deploy/base/namespace.yaml" >/dev/null && ok "namespace ${NS}"

  step "Cluster parameters"
  local domain maas
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  maas="maas.${domain}"
  mlflow_setup
  printf 'MAAS_URL=https://%s\nMAAS_TRUST_ALL=true\n' "$maas" > "${APP_DIR}/deploy/base/cluster-params.env"
  [[ -n "${MLFLOW_UI_URL:-}" ]] && printf 'MLFLOW_UI_URL=%s\n' "$MLFLOW_UI_URL" >> "${APP_DIR}/deploy/base/cluster-params.env"
  ok "MAAS_URL=https://${maas}"

  step "Secrets"
  local pw; pw=$(oc get secret inventory-db -n kafka -o jsonpath='{.data.admin-password}' | base64 -d)
  oc create secret generic inventory-db -n "$NS" --from-literal=admin-password="$pw" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null && ok "inventory-db (copied from namespace kafka)"

  # coffee schema in the CDC source + connector table list (idempotent; fresh stacks already have both)
  local db; db=$(oc get pod -n kafka -l app=inventory-db -o name 2>/dev/null | head -1)
  if [[ -n "$db" ]]; then
    oc exec -n kafka "$db" -- psql -q -d inventory -c "
      CREATE SCHEMA IF NOT EXISTS coffee;
      CREATE TABLE IF NOT EXISTS coffee.orders (id BIGSERIAL PRIMARY KEY, status TEXT NOT NULL, total_cents INT NOT NULL,
        cups INT NOT NULL, model_alias TEXT, menu_version TEXT, order_text VARCHAR(500),
        created_at TIMESTAMPTZ DEFAULT now(), updated_at TIMESTAMPTZ DEFAULT now());
      CREATE TABLE IF NOT EXISTS coffee.order_lines (id BIGSERIAL PRIMARY KEY,
        order_id BIGINT NOT NULL REFERENCES coffee.orders(id) ON DELETE CASCADE, drink TEXT NOT NULL, size TEXT NOT NULL,
        milk TEXT NOT NULL, decaf BOOLEAN NOT NULL, quantity INT NOT NULL, unit_cents INT NOT NULL, total_cents INT NOT NULL);
      ALTER TABLE coffee.orders REPLICA IDENTITY FULL; ALTER TABLE coffee.order_lines REPLICA IDENTITY FULL;" >/dev/null \
      && ok "coffee tables in inventory-db"
    oc patch kafkaconnector inventory-postgres -n kafka --type=merge \
      -p '{"spec":{"config":{"table.include.list":"inventory.customers,inventory.orders,coffee.orders,coffee.order_lines"}}}' >/dev/null \
      && ok "Debezium connector captures the coffee tables"
  fi

  local existing key openai
  existing=$(oc get secret model-router-secrets -n "$NS" -o jsonpath='{.data.MAAS_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    key="$existing"; ok "MaaS API key already present"
  else
    key=$(maas_api_key "$maas") || die "could not create a MaaS API key (is MaaS ready? ./deploy.sh test)"
  fi
  openai="${OPENAI_API_KEY:-$(oc get secret model-router-secrets -n "$NS" -o jsonpath='{.data.OPENAI_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)}"
  oc create secret generic model-router-secrets -n "$NS" \
    --from-literal=MAAS_API_KEY="$key" --from-literal=OPENAI_API_KEY="${openai}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "model-router-secrets (OpenAI: $([[ -n "$openai" ]] && echo configured || echo 'not set, aliases openai/fallback disabled'))"
}

# ----------------------------------------------------------------------------- build
# Build pods in the mesh namespace must not get an Istio sidecar: the binary source is streamed
# into the build pod, and with a proxy container in it the builder receives nothing. Older
# platform installs miss this setting (now in stack/servicemesh/istio.yaml): add it here.
builds_outside_mesh() {
  local current
  current=$(oc get istio default -o jsonpath='{.spec.values.sidecarInjectorWebhook.neverInjectSelector}' 2>/dev/null || true)
  [[ "$current" == *openshift.io/build.name* ]] && return 0
  if ! oc patch istio default --type merge -p \
      '{"spec":{"values":{"sidecarInjectorWebhook":{"neverInjectSelector":[{"matchExpressions":[{"key":"openshift.io/build.name","operator":"Exists"}]}]}}}}' >/dev/null 2>&1; then
    warn "could not update istio/default; builds in ${NS} get a sidecar and may fail"
    return 0
  fi
  ok "mesh: build pods get no sidecar from now on (Istio neverInjectSelector)"
  local i
  for i in $(seq 1 30); do   # the injector reads its config from a ConfigMap: wait until it has it
    oc get configmap istio-sidecar-injector -n istio-system -o yaml 2>/dev/null | grep -q 'openshift.io/build.name' && break
    sleep 2
  done
  sleep 5
}

build() {
  need oc
  builds_outside_mesh
  local targets=("$@"); [[ ${#targets[@]} -gt 0 ]] || targets=("${SERVICES[@]}")
  step "In-cluster image builds: ${targets[*]}"
  oc apply -f "${APP_DIR}/deploy/base/imagestreams.yaml" -n "$NS" >/dev/null
  oc apply -k "${APP_DIR}/deploy/builds" >/dev/null
  # A clean copy of only what the image builds need (the Gradle build and the seven services),
  # uploaded with --from-dir: oc writes the archive itself, the same on every OS. A local tar is
  # not used on purpose: macOS tar stores the files' extended attributes (com.apple.quarantine of a
  # downloaded zip) and "._" companions, and the builder cannot extract that ("unable to extract
  # binary build input"). Never in the copy: the standalone demos (their .env files hold API keys),
  # build output, node_modules.
  local stage p
  stage=$(mktemp -d "${TMPDIR:-/tmp}/ai-demo-src.XXXXXX")
  for p in Dockerfile .dockerignore build.gradle.kts settings.gradle.kts gradle.properties gradlew gradle "${SERVICES[@]}"; do
    [[ -e "${APP_DIR}/${p}" ]] && cp -R "${APP_DIR}/${p}" "${stage}/"
  done
  rm -rf "$stage"/*/build "$stage"/.gradle "$stage"/*/.gradle "$stage"/*/src/main/resources/META-INF/resources
  find "$stage" -name node_modules -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$stage" \( -name '._*' -o -name '.DS_Store' -o -name '.env' -o -name '*.env' \) -type f -delete 2>/dev/null || true
  info "source $(du -sh "$stage" | cut -f1) ($(find "$stage" -type f | wc -l | tr -d ' ') files), first build downloads Gradle + Maven dependencies (5-10 min)"
  local s pids=() failed=""
  for s in "${targets[@]}"; do
    oc start-build "$s" -n "$NS" --from-dir="$stage" --wait >"/tmp/ai-demo-build-${s}.log" 2>&1 &
    pids+=("$!")
  done
  local i=0
  for s in "${targets[@]}"; do
    if wait "${pids[$i]}"; then ok "$s"; else failed+=" $s"; warn "$s failed: oc logs -f bc/$s -n $NS (local log /tmp/ai-demo-build-${s}.log)"; fi
    i=$((i + 1))
  done
  rm -rf "$stage"
  if [[ -n "$failed" ]]; then
    # show the cause right away: the end of the first failed build's log
    local first=${failed# }; first=${first%% *}
    warn "last lines of the ${first} build:"
    { oc logs "bc/${first}" -n "$NS" -c docker-build 2>/dev/null || oc logs "bc/${first}" -n "$NS" 2>/dev/null \
      || cat "/tmp/ai-demo-build-${first}.log"; } | tail -25 | sed 's/^/      /'
    die "builds failed:${failed} (rebuild one: ./deploy.sh app build ${first})"
  fi
  oc rollout restart deployment -n "$NS" -l app.kubernetes.io/part-of=ai-demo >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------- deploy
deploy() {
  need oc
  local dir="${APP_DIR}/deploy"
  [[ "${1:-}" == "--rollouts" ]] && dir="${APP_DIR}/deploy/overlays/rollouts"
  grep -q CHANGE-ME "${APP_DIR}/deploy/base/cluster-params.env" && die "run './demo.sh setup' first"
  step "Deploying $(basename "$dir" | sed 's/^deploy$/ai-demo/')"
  oc apply -k "$dir"
  local is missing_images=""
  for is in "${SERVICES[@]}"; do
    oc get istag "${is}:latest" -n "$NS" >/dev/null 2>&1 || missing_images+="${is} "
  done
  [[ -z "$missing_images" ]] || warn "no image built yet for: ${missing_images}(run: ./deploy.sh app build ${missing_images})"
  step "Waiting for the pods (sidecars included)"
  local d
  for d in mongodb frontend rag-service-v1 rag-service-v2 orders-service projection-service coffee-shop coffee-menu-v1 coffee-menu-v2 ai-demo-gateway; do
    oc rollout status "deployment/$d" -n "$NS" --timeout=600s >/dev/null 2>&1 && ok "$d" || warn "$d not ready: oc get pods -n $NS -l app=${d%-v[12]}"
  done
  if oc get rollout model-router -n "$NS" >/dev/null 2>&1; then
    oc wait rollout/model-router -n "$NS" --for=condition=Available --timeout=600s >/dev/null 2>&1 && ok "model-router (Argo Rollout)" || warn "model-router rollout not available yet"
  else
    oc rollout status deployment/model-router -n "$NS" --timeout=600s >/dev/null 2>&1 && ok "model-router" || warn "model-router not ready"
  fi
  urls
}

# ----------------------------------------------------------------------------- mesh demos
pattern() {
  need oc
  local name="${1:-}" weight="${2:-10}"
  case "$name" in
    reset|ab|blue|green|mirror) oc apply -f "${APP_DIR}/deploy/patterns/${name}.yaml" >/dev/null ;;
    canary)
      [[ "$weight" =~ ^[0-9]+$ && "$weight" -le 100 ]] || die "weight must be 0-100"
      sed -e "s/weight: 90/weight: $((100 - weight))/" -e "s/weight: 10/weight: ${weight}/" \
        "${APP_DIR}/deploy/patterns/canary.yaml" | oc apply -f - >/dev/null
      name="canary (${weight}% v2)" ;;
    blue-green) oc apply -f "${APP_DIR}/deploy/patterns/blue.yaml" >/dev/null; name="blue (switch with: pattern green)" ;;
    *) die "pattern: reset | canary [weight] | ab | blue | green | mirror" ;;
  esac
  ok "rag-service traffic: ${name}"
  info "see it: ./demo.sh traffic 100   |   Kiali graph, namespace ${NS}, versioned app graph"
}

# MLflow (OpenShift AI 3.4, workspace = project ai-demo): experiment "coffee-shop" for the coffee
# shop's AI traces, and the collector pipeline that forwards them (stack/tracing/otel-collector.yaml).
MLFLOW_UI_URL=""
mlflow_setup() {
  local dash url token exp hdr
  dash=$(oc get consolelink rhodslink -o jsonpath='{.spec.href}' 2>/dev/null || true)
  if [[ -z "$dash" ]] || ! oc get mlflow mlflow >/dev/null 2>&1; then
    warn "MLflow not found (oc get mlflow mlflow); AI traces stay in Tempo only"; return 0
  fi
  url="${dash%/}/mlflow"; token=$(oc whoami -t)
  hdr=(-H "Authorization: Bearer ${token}" -H "X-MLFLOW-WORKSPACE: ${NS}" -H "Content-Type: application/json")
  exp=$("${CURL[@]}" "${hdr[@]}" "${url}/api/2.0/mlflow/experiments/get-by-name?experiment_name=coffee-shop" 2>/dev/null \
        | sed -n 's/.*"experiment_id": *"\([^"]*\)".*/\1/p' || true)
  [[ -n "$exp" ]] || exp=$("${CURL[@]}" "${hdr[@]}" -X POST -d '{"name":"coffee-shop"}' "${url}/api/2.0/mlflow/experiments/create" 2>/dev/null \
        | sed -n 's/.*"experiment_id": *"\([^"]*\)".*/\1/p' || true)
  if [[ -z "$exp" ]]; then
    warn "could not create MLflow experiment coffee-shop in workspace ${NS} (${url}); AI traces stay in Tempo only"; return 0
  fi
  oc create configmap mlflow-tracing -n tracing-system \
    --from-literal=MLFLOW_OTLP_TRACES_ENDPOINT="${url}/v1/traces" \
    --from-literal=MLFLOW_EXPERIMENT_ID="$exp" --from-literal=MLFLOW_WORKSPACE="$NS" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc rollout restart deployment/otel-collector -n tracing-system >/dev/null 2>&1 || true
  MLFLOW_UI_URL="${url}/#/experiments/${exp}/traces"
  ok "MLflow experiment coffee-shop (id ${exp}, workspace ${NS}) receives the coffee shop's AI traces"
}

menu() {
  need oc
  local name="${1:-}" n="${2:-}" f
  case "$name" in
    reset|blue|green|mirror) f="${APP_DIR}/deploy/patterns/menu-${name}.yaml"; oc apply -f "$f" >/dev/null ;;
    canary)
      n=${n:-20}; [[ "$n" =~ ^[0-9]+$ && "$n" -le 100 ]] || die "weight must be 0-100"
      sed -e "s/weight: 80/weight: $((100 - n))/" -e "s/weight: 20/weight: ${n}/" "${APP_DIR}/deploy/patterns/menu-canary.yaml" | oc apply -f - >/dev/null
      name="canary (${n}% v2)" ;;
    delay)
      n=${n:-50}; [[ "$n" =~ ^[0-9]+$ && "$n" -le 100 ]] || die "percent must be 0-100"
      sed "s/value: 50.0/value: ${n}.0/" "${APP_DIR}/deploy/patterns/menu-delay.yaml" | oc apply -f - >/dev/null
      name="delay 3 s on ${n}% of calls" ;;
    abort)
      n=${n:-30}; [[ "$n" =~ ^[0-9]+$ && "$n" -le 100 ]] || die "percent must be 0-100"
      sed "s/value: 30.0/value: ${n}.0/" "${APP_DIR}/deploy/patterns/menu-abort.yaml" | oc apply -f - >/dev/null
      name="HTTP 503 on ${n}% of calls" ;;
    *) die "menu: reset | canary [weight] | blue | green | mirror | delay [percent] | abort [percent]" ;;
  esac
  ok "coffee-menu: ${name}"
  local out; out=$("${CURL[@]}" "$(coffee_url)/api/menu/probe?n=40" || true)
  if command -v jq >/dev/null && [[ -n "$out" ]]; then
    info "probe (40 raw calls): $(jq -r '"versions \(.versions|tostring), errors \(.errors|tostring), p50 \(.p50Ms) ms, p95 \(.p95Ms) ms"' <<<"$out")"
  fi
  info "UI: $(coffee_url) > Menu & resilience > Probe"
}

coffee() {
  need curl; need jq
  local url quote id order
  url=$(coffee_url)
  step "1. interpret an order with the model (via model-router)"
  quote=$("${CURL[@]}" -X POST "${url}/api/interpret" -H 'Content-Type: application/json' \
    -d '{"text":"Two large oat lattes and a cappuccino, please."}')
  id=$(jq -r '.quote.id // empty' <<<"$quote")
  [[ -n "$id" ]] || die "no quote: $(jq -c . <<<"$quote" 2>/dev/null || echo "$quote")"
  ok "quote $(jq -r '"\(.quote.items|length) lines, total \(.quote.totalCents/100) EUR, menu \(.quote.menuVersion) (\(.quote.menuSource)), \(.elapsedMs) ms"' <<<"$quote")"
  step "2. place it (PostgreSQL) and move it through the lifecycle"
  order=$("${CURL[@]}" -X POST "${url}/api/orders" -H 'Content-Type: application/json' -d "{\"quoteId\":\"${id}\"}" | jq -r '.id')
  ok "order ${order} PLACED"
  "${CURL[@]}" -X POST "${url}/api/orders/${order}/advance" >/dev/null && ok "order ${order} BREWING"
  "${CURL[@]}" -X POST "${url}/api/orders/${order}/advance" >/dev/null && ok "order ${order} READY"
  step "3. audit trail, read from MongoDB (Debezium -> Kafka -> projection-service)"
  local i events
  for i in $(seq 1 15); do
    events=$("${CURL[@]}" "${url}/api/audit?orderId=${order}")
    if [[ "$(jq 'length' <<<"$events")" -ge 5 ]]; then
      jq -r 'reverse | .[] | "      \(.operation)\t\(.summary)"' <<<"$events"
      ok "audit complete after ~$((i * 2)) s"; return 0
    fi
    sleep 2
  done
  warn "audit incomplete: $(jq 'length' <<<"$events") events. Check: oc get kafkaconnector inventory-postgres -n kafka"
}

traffic() {
  need curl
  local n="${1:-100}" variant="${2:-}" out
  out=$("${CURL[@]}" "$(base_url)/api/traffic?n=${n}${variant:+&variant=${variant}}")
  if command -v jq >/dev/null; then jq -r '"requests: \(.requests), errors: \(.errors)", (.versions | to_entries[] | "  rag \(.key): \(.value)")' <<<"$out"
  else echo "$out"; fi
}

probe() {
  need curl
  local out; out=$("${CURL[@]}" "$(base_url)/api/mesh/probe")
  if command -v jq >/dev/null; then
    jq -r '.[] | "  \(if .allowed == .expectedAllowed then "OK  " else "??  " end) \(.target | . + "                    " | .[0:20]) expected=\(if .expectedAllowed then "allow" else "deny " end)  \(.outcome)"' <<<"$out"
  else echo "$out"; fi
}

mtls() {
  need oc
  step "Calling ai-demo services from a pod OUTSIDE the mesh (no sidecar, no client certificate)"
  oc get namespace ai-demo-outsider >/dev/null 2>&1 || oc create namespace ai-demo-outsider >/dev/null
  oc run mtls-check -n ai-demo-outsider --rm -i --restart=Never --quiet \
    --image=registry.access.redhat.com/ubi9/ubi-minimal:latest -- \
    sh -c 'for s in frontend rag-service model-router; do
             printf "  %-14s " "$s"; curl -s -o /dev/null -m 5 -w "HTTP %{http_code}\n" http://$s.ai-demo.svc.cluster.local:8080/q/health || echo "rejected (plaintext not allowed, STRICT mTLS)"
           done' || true
  info "Inside the mesh the same calls succeed with mTLS: ./demo.sh probe"
}

rollout() {
  need oc
  oc get rollout model-router -n "$NS" >/dev/null 2>&1 || die "model-router is not a Rollout: ./demo.sh deploy --rollouts"
  step "Argo Rollouts canary of the model-router (20% -> 50% -> 100%, driven by the mesh)"
  oc patch rollout model-router -n "$NS" --type=merge \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"demo/revision\":\"$(date +%s)\"}}}}}" >/dev/null
  local i phase weights
  for i in $(seq 1 40); do
    phase=$(oc get rollout model-router -n "$NS" -o jsonpath='{.status.phase} step {.status.currentStepIndex}' 2>/dev/null || true)
    weights=$(oc get virtualservice model-router -n "$NS" -o jsonpath='{range .spec.http[0].route[*]}{.destination.subset}={.weight} {end}' 2>/dev/null || true)
    info "$(date +%H:%M:%S)  ${phase}   ${weights}"
    [[ "$phase" == Healthy* ]] && [[ $i -gt 2 ]] && break
    sleep 10
  done
  ok "done. Abort a running canary with: oc patch rollout model-router -n $NS --type merge -p '{\"status\":{\"abort\":true}}'"
}

cdc() {
  need curl
  local url stamp; url=$(base_url); stamp=$(date +%H%M%S)
  step "1. write to PostgreSQL through orders-service"
  local cust id
  cust=$("${CURL[@]}" -X POST "${url}/api/customers" -H 'Content-Type: application/json' \
    -d "{\"firstName\":\"Demo\",\"lastName\":\"User ${stamp}\",\"email\":\"demo-${stamp}@example.com\"}")
  id=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"$cust")
  [[ -n "$id" ]] || die "customer not created: $cust"
  ok "customer ${id}"
  "${CURL[@]}" -X POST "${url}/api/orders" -H 'Content-Type: application/json' \
    -d "{\"customerId\":${id},\"product\":\"demo-${stamp}\",\"quantity\":2}" >/dev/null && ok "order demo-${stamp}"
  step "2. Debezium -> Kafka -> projection-service -> MongoDB"
  local i views
  for i in $(seq 1 15); do
    views=$("${CURL[@]}" "${url}/api/customer-views")
    if grep -q "demo-${stamp}" <<<"$views"; then
      ok "projected after ~$((i * 2)) s"
      if command -v jq >/dev/null; then jq ".[] | select(._id == ${id})" <<<"$views"; else echo "$views"; fi
      return 0
    fi
    sleep 2
  done
  warn "not projected yet: oc get kafkaconnector inventory-postgres -n kafka; oc logs deploy/projection-service -n $NS -c app"
}

ask() {
  need curl
  local q="${1:-How does the mesh decide who can access who?}" model="${2:-auto}"
  "${CURL[@]}" -X POST "$(base_url)/api/ask" -H 'Content-Type: application/json' \
    -d "{\"question\":$(printf '%s' "$q" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'),\"model\":\"${model}\"}" \
    | { if command -v jq >/dev/null; then jq '{answer, model, version, generationMs, sources: [.sources[].title]}'; else cat; fi; }
}

pipeline() {
  need oc
  local repo="${1:-}" rev="${2:-main}" s dockerfile
  [[ -n "$repo" ]] || die "usage: ./demo.sh pipeline <git-url> [revision]"
  oc apply -f "${APP_DIR}/deploy/base/imagestreams.yaml" -n "$NS" >/dev/null
  oc apply -k "${APP_DIR}/deploy/pipelines" >/dev/null
  step "Tekton PipelineRuns (OpenShift console > Pipelines, namespace ${NS})"
  for s in "${SERVICES[@]}"; do
    dockerfile="Dockerfile"; [[ "$s" == "frontend" || "$s" == "coffee-shop" ]] && dockerfile="${s}/Dockerfile"
    oc create -n "$NS" -f - >/dev/null <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: build-${s}-
  labels:
    backstage.io/kubernetes-id: ${s}   # Tekton tab of the component in Developer Hub
spec:
  pipelineRef:
    name: build-service
  params:
    - {name: git-url, value: "${repo}"}
    - {name: git-revision, value: "${rev}"}
    - {name: service, value: "${s}"}
    - {name: dockerfile, value: "${dockerfile}"}
    - {name: ssl-verify, value: "$([[ "$repo" == *gitlab-gitlab.* ]] && echo false || echo true)"}
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 2Gi
EOF
    ok "build-${s} started"
  done
}

gitops() {
  need oc
  local repo="${1:-}" rev="${2:-main}" prefix path
  [[ -n "$repo" ]] || die "usage: ./demo.sh gitops <git-url> [revision]  (the repository that contains this app/ folder)"
  grep -q CHANGE-ME "${APP_DIR}/deploy/base/cluster-params.env" && die "run './demo.sh setup' first and commit deploy/base/cluster-params.env"
  prefix=$(git -C "$APP_DIR" rev-parse --show-prefix 2>/dev/null || echo "app/")
  path="${prefix}deploy"
  sed -e "s#__REPO_URL__#${repo}#" -e "s#__REVISION__#${rev}#" -e "s#__PATH__#${path}#" \
    "${APP_DIR}/deploy/argocd-application.yaml" | oc apply -f -
  ok "Argo CD Application ai-demo -> ${repo} @ ${rev} : ${path}"
  info "images still come from './demo.sh build' or './demo.sh pipeline'; secrets from './demo.sh setup'"
}

status() {
  need oc
  oc get pods,rollout -n "$NS" 2>/dev/null || true
  oc get virtualservice,destinationrule,authorizationpolicy,peerauthentication -n "$NS" 2>/dev/null || true
}

urls() {
  step "URLs"
  local m; m=$(grep -E '^MLFLOW_UI_URL=' "${APP_DIR}/deploy/base/cluster-params.env" 2>/dev/null | cut -d= -f2- || true)
  [[ -n "$m" ]] && info "MLflow traces: ${m}   (workspace ${NS})"
  local r h
  for r in ai-demo:"Demo UI     " coffee:"Coffee shop "; do
    h=$(oc get route "${r%%:*}" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [[ -n "$h" ]]; then info "${r#*:} : https://${h}"
    else warn "${r#*:} : route '${r%%:*}' not in namespace ${NS} yet (./deploy.sh app deploy)"; fi
  done
  info "Kiali        : https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}' 2>/dev/null)   (namespace ${NS})"
  info "Traces       : OpenShift console > Observe > Traces (service frontend, rag-service, model-router)"
  info "Dashboard    : OpenShift console > Observe > Dashboards > 'AI demo: models, RAG, CDC and mesh'"
  info "Argo Rollouts: oc get rollout -n ${NS}   (after ./demo.sh deploy --rollouts)"
}

destroy() {
  need oc
  oc delete -k "${APP_DIR}/deploy/monitoring" --ignore-not-found >/dev/null 2>&1 || true
  oc delete namespace "$NS" ai-demo-outsider --ignore-not-found
}

# ----------------------------------------------------------------------------- main
[[ $# -ge 1 ]] || usage 1
cmd=$1; shift
case "$cmd" in
  all)      setup; build; deploy "$@" ;;
  setup)    setup ;;
  build)    build "$@" ;;
  deploy)   deploy "$@" ;;
  pattern)  pattern "$@" ;;
  menu)     menu "$@" ;;
  coffee)   coffee ;;
  update)   setup; build coffee-shop coffee-menu projection-service rag-service; deploy ;;
  mlflow)   need oc; need curl; mlflow_setup ;;
  traffic)  traffic "$@" ;;
  probe)    probe ;;
  mtls)     mtls ;;
  rollout)  rollout ;;
  cdc)      cdc ;;
  ask)      ask "$@" ;;
  pipeline) pipeline "$@" ;;
  gitops)   gitops "$@" ;;
  status)   status ;;
  urls)     urls ;;
  destroy)  destroy ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
