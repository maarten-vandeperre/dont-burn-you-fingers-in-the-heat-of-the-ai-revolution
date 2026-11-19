#!/usr/bin/env bash
# =============================================================================
# AgentOps: tracing, monitoring, prompt management and a judge model for an AI agent
#
#   ./deploy.sh agentops deploy            namespace agentops: runtime image, PostgreSQL dataset,
#                                          budget API, MCP server (registered in the demo 15 MCP
#                                          gateway), the FinOps agent + UI, consumer keys agent and
#                                          judge, prompt v1/v2 in the MLflow prompt registry
#   ./deploy.sh agentops ask "<question>" [model] [prompt]
#                                          one question; prints answer, steps, trace id
#   ./deploy.sh agentops load [n]          n questions (default 8) as live traffic, for the judge
#   ./deploy.sh agentops prompts [show|register|promote <version>]
#                                          the MLflow prompt registry (finops-agent)
#   ./deploy.sh agentops eval [refs...]    offline evaluation, judge model, prompt v1 vs v2
#   ./deploy.sh agentops judge [n]         judge the n most recent live traces (assessments)
#   ./deploy.sh agentops metrics           agent metrics + Limitador counters for agent / judge
#   ./deploy.sh agentops test              the checks the demo relies on
#   ./deploy.sh agentops code              re-apply the code ConfigMap and restart (after an edit)
#   ./deploy.sh agentops status | urls | destroy
#
# Needs: ./deploy.sh stack (OpenShift AI 3.4 with MLflow, tracing), ./deploy.sh ai-gateways deploy
# and ./deploy.sh ai-gateways mcp (demo 15: the LLM API and the MCP gateway).
# Demo guide: docs/demos/16-agentops.md
# =============================================================================
set -Eeuo pipefail

AO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${AO_DIR}/../.." && pwd)"
GW_SH="${ROOT_DIR}/stack/ai-gateways/ai-gateways.sh"
NS="agentops"

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}OK${N} $*"; }
info() { echo "    $*"; }
warn() { echo "    ${Y}WARN${N} $*"; }
fail() { echo "    ${R}FAIL${N} $*"; FAILED=1; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "'$1' is required"; }
trap 'echo "${R}ERROR${N} failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR
FAILED=0

wait_until() {  # wait_until <seconds> <label> <command...>
  local timeout=$1 label=$2; shift 2
  local start; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then warn "timed out after ${timeout}s waiting for: ${label}"; return 1; fi
    sleep 5
  done
}
host_of() { oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null; }
agent_url() { echo "https://$(host_of finops-agent "$NS")"; }
in_agent() { oc exec -n "$NS" deploy/finops-agent -c agent -- /usr/bin/python3.12 -u "$@"; }

# ----------------------------------------------------------------------------- deploy
params() {
  local mlflow llm mcp console
  mlflow=$(oc get mlflow mlflow -o jsonpath='{.status.url}' 2>/dev/null) || true
  [[ -n "$mlflow" ]] || die "OpenShift AI MLflow not found (oc get mlflow mlflow): ./deploy.sh stack"
  llm=$(host_of llm-gateway ai-gateways); [[ -n "$llm" ]] || die "demo 15 LLM API not found: ./deploy.sh ai-gateways deploy"
  mcp=$(host_of mcp-gateway mcp-gateway); [[ -n "$mcp" ]] || die "demo 15 MCP gateway not found: ./deploy.sh ai-gateways mcp"
  console=$(oc whoami --show-console 2>/dev/null || true)
  cat > "${AO_DIR}/openshift/cluster-params.env" <<EOF
MLFLOW_TRACKING_URI=${mlflow}
MLFLOW_UI_URL=${mlflow}
MLFLOW_WORKSPACE=${NS}
MLFLOW_EXPERIMENT_NAME=finops-agent
MLFLOW_TRACE_ENABLE_OTLP_DUAL_EXPORT=true
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://otel-collector.tracing-system.svc.cluster.local:4318/v1/traces
OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
LLM_BASE_URL=https://${llm}/v2
MCP_URL=https://${mcp}/mcp
JUDGE_MODEL=openai:/cloud
AGENT_MODELS=cloud,smart,fast
CONSOLE_URL=${console}
EOF
}

keys() {
  # Two Connectivity Link consumers (demo 15): the agent itself, and the judge. Separate keys =
  # separate token quotas and separate rows in the gateway metrics ("who spent what").
  local agent judge
  agent=$("$GW_SH" key agent gold | tail -1); judge=$("$GW_SH" key judge gold | tail -1)
  oc create secret generic agentops-keys -n "$NS" --from-literal=agent="$agent" --from-literal=judge="$judge" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "consumer keys agent (gold) and judge (gold): Secret agentops-keys"
}

deploy() {
  need oc
  step "Cluster parameters (MLflow, demo 15 LLM API and MCP gateway)"
  params; sed 's/^/    /' "${AO_DIR}/openshift/cluster-params.env"
  step "Namespace, RBAC, runtime image"
  oc apply -f "${AO_DIR}/openshift/namespace.yaml" -f "${AO_DIR}/openshift/build.yaml" >/dev/null
  keys
  if ! oc get istag agentops-runtime:latest -n "$NS" >/dev/null 2>&1; then
    info "building agentops-runtime (OpenShift AI MLflow image + OTLP exporter, ~2 min)"
    oc start-build agentops-runtime -n "$NS" --wait >/dev/null || die "build failed: oc logs -n ${NS} bc/agentops-runtime"
  fi
  ok "image agentops-runtime:latest"
  step "Dataset, budget API, MCP server, agent"
  oc apply -k "$AO_DIR" >/dev/null
  for d in postgres budget-api mcp-finops finops-agent; do
    oc rollout status "deploy/${d}" -n "$NS" --timeout=300s >/dev/null && ok "$d"
  done
  step "MCP gateway registration (finops_ tools)"
  wait_until 180 "MCPServerRegistration finops Ready" \
    bash -c "oc get mcpserverregistration finops -n mcp-gateway -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
    && ok "MCPServerRegistration finops: Ready" || true
  step "Prompt registry"
  in_agent prompts.py register | sed 's/^/    /'
  urls
}

code() {
  oc apply -k "$AO_DIR" >/dev/null
  oc rollout restart deploy/finops-agent deploy/mcp-finops deploy/budget-api -n "$NS" >/dev/null
  for d in budget-api mcp-finops finops-agent; do oc rollout status "deploy/${d}" -n "$NS" --timeout=180s >/dev/null; done
  ok "code ConfigMap applied, services restarted"
}

# ----------------------------------------------------------------------------- demo commands
ask() {  # ask <question> [model] [prompt] [source]
  need jq
  local q=${1:?usage: ask "<question>" [model] [prompt]} m=${2:-cloud} p=${3:-production} s=${4:-ui}
  curl -sk --max-time 300 "$(agent_url)/api/ask" -H 'content-type: application/json' \
    -d "$(jq -cn --arg q "$q" --arg m "$m" --arg p "$p" --arg s "$s" '{question:$q, model:$m, prompt:$p, source:$s}')"
}
ask_cmd() {
  local out; out=$(ask "$@")
  echo "$out" | jq -r '"\n" + .answer + "\n",
    "    status \(.status) · prompt v\(.prompt_version) · model \(.model) · \(.tokens.prompt + .tokens.completion) tokens · \(.seconds) s",
    "    trace \(.trace_id)",
    (.steps[] | if .type == "llm" then "    LLM  \(.model) \(.ms) ms \(.tokens) tokens -> \(if (.tool_calls|length) > 0 then (.tool_calls|join(", ")) else "answer" end)"
                else "    TOOL \(.tool) \(.args|tostring) \(.ms) ms" end)'
}
load() {
  local n=${1:-8} i qs=(
    "Which team spent the most on LLMs in the last 7 days, and is it within its budget?"
    "Why did the support team's LLM cost go up?"
    "Is the payments team within its LLM budget?"
    "Which team used the most tokens in the last 30 days?"
    "What is the request throttle on our LLM API?"
    "How much did marketing spend on OpenAI models this month?")
  step "Live traffic: ${n} questions (source=load, prompt @production)"
  for i in $(seq 1 "$n"); do
    ask "${qs[$(( (i - 1) % ${#qs[@]} ))]}" cloud production load \
      | jq -r '"    \(.status)  v\(.prompt_version)  \(.tokens.prompt + .tokens.completion) tokens  \(.seconds) s  \(.trace_id)"'
  done
}
prompts() { in_agent prompts.py "${@:-show}"; }
evaluate() { in_agent evaluate.py "$@"; }
judge() { in_agent judge_traces.py "$@"; }

metrics() {
  step "Agent (/metrics): requests, tokens, tool calls per prompt version / model / tool"
  oc exec -n "$NS" deploy/finops-agent -c agent -- /usr/bin/python3.12 -c \
    "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/metrics/').read().decode())" \
    | grep -E '^agent_(requests_total|llm_tokens_total|tool_calls_total|request_seconds_(sum|count))' | sed 's/^/    /'
  step "Connectivity Link (Limitador): the agent and the judge as gateway consumers"
  local pod; pod=$(oc get pod -n kuadrant-system -l app=limitador -o name | head -1)
  oc exec -n kuadrant-system "$pod" -- sh -c 'curl -s localhost:8080/metrics 2>/dev/null || wget -qO- localhost:8080/metrics' 2>/dev/null \
    | grep -E '^(authorized_hits|authorized_calls|limited_calls)' | grep -E 'user="llm-key-(agent|judge)"' | sed 's/^/    /' \
    || info "(no Limitador metrics for agent / judge yet)"
}

test_all() {
  need jq
  step "Pods"
  for d in postgres budget-api mcp-finops finops-agent; do
    [[ "$(oc get deploy "$d" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == 1 ]] && ok "$d ready" || fail "$d not ready"
  done
  step "Prompt registry"
  local cfg; cfg=$(curl -sk "$(agent_url)/api/config")
  [[ "$(echo "$cfg" | jq '.versions|length')" -ge 2 ]] && ok "finops-agent: $(echo "$cfg" | jq -c '.aliases')" || fail "prompt versions missing: ./deploy.sh agentops prompts register"
  step "One question, end to end (LLM API + MCP gateway + PostgreSQL + budget-api)"
  local out; out=$(ask "Is the payments team within its LLM budget?" cloud production ui)
  [[ "$(echo "$out" | jq -r .status)" == ok ]] && ok "answer: $(echo "$out" | jq -r .answer | head -c 120 | tr '\n' ' ')" || fail "$(echo "$out" | head -c 300)"
  local tools; tools=$(echo "$out" | jq -r '[.steps[] | select(.type=="tool") | .tool] | join(",")')
  [[ "$tools" == *finops_team_budget* ]] && ok "tools used: ${tools}" || fail "expected finops_team_budget, got '${tools}'"
  local tid; tid=$(echo "$out" | jq -r .trace_id)
  step "The trace in MLflow (spans from agent, mcp-finops and budget-api)"
  sleep 5
  in_agent -c "
import sys; from common import setup_mlflow
mlflow, _ = setup_mlflow()
t = mlflow.get_trace('${tid}')
names = [s.name for s in t.data.spans]
svc = {'agent': any(n == 'finops-agent' for n in names), 'mcp-finops': any(n.startswith('mcp-finops') for n in names),
       'postgres': any(n == 'postgres query' for n in names), 'budget-api': any(n.startswith('budget-api') for n in names)}
print('    spans:', len(names), svc, 'prompt', t.info.tags.get('prompt.version'))
sys.exit(0 if all(svc.values()) else 1)" && ok "trace ${tid} has all four hops" || fail "trace ${tid} is missing hops (see above)"
  step "The trace in Tempo"
  if oc get svc tempo-platform -n tracing-system >/dev/null 2>&1; then
    local hex; hex=${tid#tr-}
    oc run tempo-check -n "$NS" --rm -i --restart=Never --quiet --image=registry.access.redhat.com/ubi9/ubi-minimal \
      --command -- curl -s -o /dev/null -w '%{http_code}' "http://tempo-platform.tracing-system.svc.cluster.local:3200/api/traces/${hex}" 2>/dev/null \
      | grep -q 200 && ok "Tempo has trace ${hex}" || warn "Tempo has no trace ${hex} yet (flush interval); check Observe > Traces"
  fi
  (( FAILED == 0 )) && echo && ok "all checks passed" || { echo; die "some checks failed"; }
}

# ----------------------------------------------------------------------------- status / urls / destroy
status() {
  oc get deploy,route -n "$NS" 2>/dev/null || warn "not deployed: ./deploy.sh agentops deploy"
  oc get mcpserverregistration finops -n mcp-gateway 2>/dev/null || true
}
urls() {
  step "URLs"
  info "FinOps agent UI : $(agent_url)"
  info "MLflow          : $(oc get mlflow mlflow -o jsonpath='{.status.url}' 2>/dev/null)  (workspace ${NS}, experiment finops-agent)"
  info "Traces (Tempo)  : $(oc whoami --show-console 2>/dev/null)/observe/traces  (service finops-agent)"
}
destroy() {
  step "Removing the AgentOps demo"
  oc delete httproute mcp-finops -n mcp-gateway --ignore-not-found >/dev/null
  oc delete mcpserverregistration finops -n mcp-gateway --ignore-not-found >/dev/null
  oc delete secret llm-key-agent llm-key-judge -n ai-gateways --ignore-not-found >/dev/null
  oc delete namespace "$NS" --ignore-not-found --wait=false
  info "MLflow keeps the workspace's experiments and prompts in its database (the workspace disappears with the namespace)"
}

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd=${1:-}; [[ $# -gt 0 ]] && shift
case "$cmd" in
  deploy)   deploy ;;
  code)     code ;;
  ask)      ask_cmd "$@" ;;
  load)     load "$@" ;;
  prompts)  prompts "$@" ;;
  eval)     evaluate "$@" ;;
  judge)    judge "$@" ;;
  metrics)  metrics ;;
  test)     test_all ;;
  status)   status ;;
  urls)     urls ;;
  destroy)  destroy ;;
  ""|-h|--help|help) usage 0 ;;
  *) echo "unknown command: $cmd" >&2; usage 1 ;;
esac
