#!/usr/bin/env bash
# =============================================================================
# Agent sandboxes: Claude Code on a leash, on the laptop (Kaiden), in Dev Spaces and in
# OpenShell on OpenShift, always on the company LLM API (demo 15).
#
#   ./deploy.sh agent-sandboxes deploy        Claude Code images (sandbox + Dev Spaces UDI, with the
#                                             platform's managed settings), consumer key "sandbox",
#                                             the /anthropic endpoint of the LLM API (demo 15)
#   ./deploy.sh agent-sandboxes claude "<task>"
#                                             Claude Code, headless, in a throwaway pod (Part B)
#   ./deploy.sh agent-sandboxes kaiden        laptop: the settings Kaiden / a local Claude Code need
#
#   ./deploy.sh agent-sandboxes devspaces [user]
#                                             Part C: key, automounted Secret, EgressFirewall and a
#                                             Claude Code workspace in <user>-devspaces
#   ./deploy.sh agent-sandboxes devspaces-check       what the workspace can reach
#   ./deploy.sh agent-sandboxes devspaces-claude "<task>"   Claude Code inside the workspace
#   ./deploy.sh agent-sandboxes devspaces-fence on|off      the EgressFirewall
#
#   ./deploy.sh agent-sandboxes openshell-install     Part D, CLUSTER-ADMIN: Agent Sandbox controller
#                                                     (CRD) + OpenShell gateway (Helm, namespace openshell)
#   ./deploy.sh agent-sandboxes openshell-connect     register the gateway in the local openshell CLI
#                                                     (mTLS client certificate from the cluster)
#   ./deploy.sh agent-sandboxes openshell-sandbox     credential profile + provider, sandbox "claude-dev"
#   ./deploy.sh agent-sandboxes openshell-check       what the sandbox can reach, and as which binary
#   ./deploy.sh agent-sandboxes openshell-claude "<task>"   Claude Code inside the sandbox
#   ./deploy.sh agent-sandboxes openshell-pypi        live policy change: allow pip -> pypi.org
#   ./deploy.sh agent-sandboxes openshell-reset       sandbox back to policy.yaml
#   ./deploy.sh agent-sandboxes openshell-uninstall   remove OpenShell and the Agent Sandbox controller
#
#   ./deploy.sh agent-sandboxes test | status | destroy
#
# Needs: ./deploy.sh ai-gateways deploy (demo 15, the LLM API) with an OpenAI key, Dev Spaces
# (./deploy.sh stack). Part D: helm, and the openshell CLI 0.1.9 on the laptop.
# Demo guide: docs/demos/17-agent-sandboxes.md
# =============================================================================
set -Eeuo pipefail

AS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${AS_DIR}/../.." && pwd)"
GW_SH="${ROOT_DIR}/stack/ai-gateways/ai-gateways.sh"
GW_DIR="${ROOT_DIR}/stack/ai-gateways"
NS="agent-sandboxes"
OS_NS="openshell"
OS_VERSION="0.1.9"                 # OpenShell chart, gateway and CLI
AGENT_SANDBOX_VERSION="v1.0.3"     # what OpenShell 0.1.9's own e2e tests install
SANDBOX="claude-dev"
REGISTRY="image-registry.openshift-image-registry.svc:5000"
CLAUDE_BIN="/usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
# the default task, the same in every part: sample-project/ has a pricing bug and a failing test
TASK_DEFAULT="Run the unit tests with python3 -m unittest, find the bug in pricing.py, fix it, run the tests again and summarize the fix in two sentences."

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "    ${G}OK${N} $*"; }
info() { echo "    $*"; }
warn() { echo "    ${Y}WARN${N} $*"; }
fail() { echo "    ${R}FAIL${N} $*"; FAILED=1; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "'$1' is required${2:+: $2}"; }
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
host_of()  { oc get route "$1" -n "$2" -o jsonpath='{.spec.host}' 2>/dev/null; }
llm_host() { local h; h=$(host_of llm-gateway ai-gateways); [[ -n "$h" ]] || die "demo 15 LLM API not found: ./deploy.sh ai-gateways deploy"; echo "$h"; }
llm_base() { echo "https://$(llm_host)/anthropic"; }
apps_domain() { oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}'; }
key_of() {  # the LLM API key of a consumer (Secret llm-key-<name> in ai-gateways)
  oc get secret "llm-key-$1" -n ai-gateways -o jsonpath='{.data.api_key}' 2>/dev/null | base64 -d 2>/dev/null || true
}
ensure_key() {  # ensure_key <consumer>: a gold-tier key (gpt-4o-mini behind alias "cloud")
  [[ -n "$(key_of "$1")" ]] || "$GW_SH" key "$1" gold >/dev/null
  key_of "$1"
}
image() { echo "${REGISTRY}/${NS}/$1:latest"; }

# ----------------------------------------------------------------------------- deploy
llm_api() {
  step "The company LLM API, Anthropic endpoint (demo 15 + this demo's additions)"
  # Praxis listener api-anthropic + coding-egress, HTTPRoute llm-api-anthropic and the tool-error
  # shim live in demo 15's folders (they're part of the LLM API). Re-applying is idempotent.
  oc apply -k "${GW_DIR}/praxis" >/dev/null
  oc apply -k "${GW_DIR}/connectivity-link" >/dev/null 2>&1
  oc rollout status deploy/praxis-ai -n ai-gateways --timeout=180s >/dev/null
  local base code; base=$(llm_base)
  ensure_key sandbox >/dev/null
  wait_until 120 "the /anthropic endpoint" anthropic_ok sandbox || true
  code=$(curl -s -o /dev/null -w '%{http_code}' "${base}/v1/messages" -H 'content-type: application/json' -d '{}')
  [[ "$code" == 401 ]] && ok "${base}  (no key: 401)" || warn "${base} without a key: ${code} (expected 401)"
  anthropic_ok sandbox && ok "consumer 'sandbox' (gold) gets an answer from model 'cloud'" \
    || warn "no answer from model 'cloud': OpenAI key? ./deploy.sh ai-gateways openai-key"
}
anthropic_ok() {  # anthropic_ok <consumer>: one Anthropic Messages call with that consumer's key
  local r; r=$(curl -s -m 60 "$(llm_base)/v1/messages" -H "Authorization: Bearer $(key_of "$1")" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -d '{"model":"cloud","max_tokens":20,"messages":[{"role":"user","content":"Say OK"}]}' || true)
  grep -q '"type":"message"' <<<"$r"
}

images() {
  step "Claude Code images (namespace ${NS}): sandbox + Dev Spaces UDI, managed settings baked in"
  oc apply -k "${AS_DIR}/images" >/dev/null
  local is
  for is in claude-code-sandbox claude-code-udi; do
    if [[ -z "$(oc get istag "${is}:latest" -n "$NS" -o name 2>/dev/null)" || "${REBUILD:-}" == 1 ]]; then
      info "building ${is} (2-3 minutes) ..."
      oc start-build "$is" -n "$NS" --wait >/dev/null || die "build ${is} failed: oc logs bc/${is} -n ${NS}"
    fi
    ok "$(image "$is")"
  done
  oc create secret generic claude-code-llm-key -n "$NS" --from-literal=ANTHROPIC_AUTH_TOKEN="$(key_of sandbox)" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "Secret ${NS}/claude-code-llm-key (consumer 'sandbox', for the throwaway pods of 'claude')"
}

deploy() {
  need oc; need curl
  oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift"
  llm_api
  images
  step "Ready"
  info "Part B: ./deploy.sh agent-sandboxes claude \"Write fib.py, run it, tell me fib(20)\""
  info "Part C: ./deploy.sh agent-sandboxes devspaces"
  info "Part D: ./deploy.sh agent-sandboxes openshell-install (cluster-admin), then openshell-connect"
}

# ----------------------------------------------------------------------------- Part B: headless
claude_pod() {  # claude_pod [task]: Claude Code in a throwaway pod, same image as the sandboxes
  local task=${1:-$TASK_DEFAULT} pod="claude-run-$(date +%s)"
  oc get secret claude-code-llm-key -n "$NS" >/dev/null 2>&1 || die "run ./deploy.sh agent-sandboxes deploy first"
  info "pod ${NS}/${pod}, image claude-code-sandbox, model 'cloud' via $(llm_base)"
  # the sample project as a ConfigMap (copied to a writable folder), the task as an environment
  # variable: no shell quoting of the prompt
  oc create configmap sample-project -n "$NS" --from-file="${AS_DIR}/sample-project" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f - >/dev/null <<EOF2
apiVersion: v1
kind: Pod
metadata: {name: ${pod}, namespace: ${NS}, labels: {app.kubernetes.io/part-of: agent-sandboxes-demo}}
spec:
  restartPolicy: Never
  containers:
    - name: claude
      image: $(image claude-code-sandbox)
      env:
        - {name: ANTHROPIC_BASE_URL, value: "$(llm_base)"}
        - {name: HOME, value: /tmp/home}
        - {name: TASK, value: $(printf '%s' "$task" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}
      envFrom: [{secretRef: {name: claude-code-llm-key}}]
      volumeMounts: [{name: project, mountPath: /project}]
      command: [sh, -c]
      args:
        - |
          mkdir -p /tmp/home /tmp/work && cp /project/*.py /tmp/work/ && cd /tmp/work
          echo '{"hasCompletedOnboarding":true}' > /tmp/home/.claude.json
          claude -p "\$TASK" --allowedTools Write Edit Read "Bash(python3:*)" "Bash(ls:*)" "Bash(cat:*)" 2>&1 | grep -v unrecognized_model
          echo "--- tests now:"; python3 -m unittest 2>&1 | tail -1
  volumes: [{name: project, configMap: {name: sample-project}}]
EOF2
  wait_until 300 "pod ${pod}" pod_done "$NS" "$pod" || true
  oc logs "$pod" -n "$NS"
  oc delete pod "$pod" -n "$NS" --wait=false >/dev/null
}
pod_done() { local p; p=$(oc get pod "$2" -n "$1" -o jsonpath='{.status.phase}'); [[ "$p" == Succeeded || "$p" == Failed ]]; }

kaiden() {
  step "Laptop: Kaiden (or Claude Code itself) on the company LLM API"
  local k; k=$(ensure_key laptop)
  info "Consumer 'laptop' (gold). Kaiden: Models > LLM Providers > Claude, custom base URL:"
  echo
  echo "    Base URL : $(llm_base)"
  echo "    API key  : ${k:0:12}...   (full key: oc get secret llm-key-laptop -n ai-gateways -o jsonpath='{.data.api_key}' | base64 -d)"
  echo "    Model    : cloud           (alias of gpt-4o-mini; 'smart' = in-cluster Qwen)"
  echo
  info "Claude Code directly, in a terminal (the same settings the images bake in):"
  echo "    export ANTHROPIC_BASE_URL=$(llm_base) ANTHROPIC_AUTH_TOKEN=<key> ANTHROPIC_MODEL=cloud \\"
  echo "      ANTHROPIC_DEFAULT_HAIKU_MODEL=cloud ANTHROPIC_DEFAULT_SONNET_MODEL=cloud ANTHROPIC_DEFAULT_OPUS_MODEL=cloud \\"
  echo "      CLAUDE_CODE_MAX_CONTEXT_TOKENS=128000 CLAUDE_CODE_MAX_OUTPUT_TOKENS=16000 DISABLE_PROMPT_CACHING=1"
  info "Kaiden: open folder stack/agent-sandboxes/sample-project (network policy in .kaiden/workspace.json)"
}

# ----------------------------------------------------------------------------- Part C: Dev Spaces
ds_user() { echo "${1:-$(oc whoami)}"; }
ds_ns()   { echo "$(ds_user "${1:-}")-devspaces"; }
ws_pod()  { oc get pod -n "$1" -l controller.devfile.io/devworkspace_name=claude-code-sandbox -o name 2>/dev/null | head -1; }
ws_exec() {  # ws_exec <ns> <command>
  local p; p=$(ws_pod "$1"); [[ -n "$p" ]] || die "workspace claude-code-sandbox not running in $1: ./deploy.sh agent-sandboxes devspaces"
  oc exec -n "$1" "$p" -c tools -- bash -lc "$2"
}
render() { sed -e "s#__NS__#$1#g" -e "s#__LLM_HOST__#$(llm_host)#g" -e "s#__LLM_BASE__#$(llm_base)#g" -e "s#__IMAGE__#$(image claude-code-udi)#g" "$2"; }

devspaces() {
  local user ns k; user=$(ds_user "${1:-}"); ns=$(ds_ns "$user")
  step "Dev Spaces: Claude Code workspace for ${user} (namespace ${ns})"
  oc get ns "$ns" >/dev/null 2>&1 || die "namespace ${ns} not found: open Dev Spaces once as ${user} (it creates it)"
  k=$(ensure_key "devspaces-${user}")
  # Automount: every workspace in this namespace gets ANTHROPIC_AUTH_TOKEN as an environment
  # variable, without it ever being in a devfile or a git repository.
  oc create secret generic claude-code-llm-key -n "$ns" --from-literal=ANTHROPIC_AUTH_TOKEN="$k" --dry-run=client -o yaml \
    | oc label --local -f - -o yaml controller.devfile.io/mount-to-devworkspace=true controller.devfile.io/watch-secret=true \
        app.kubernetes.io/part-of=agent-sandboxes-demo \
    | oc annotate --local -f - -o yaml controller.devfile.io/mount-as=env \
    | oc apply -f - >/dev/null
  ok "Secret ${ns}/claude-code-llm-key, automounted as env (consumer devspaces-${user}, gold)"
  render "$ns" "${AS_DIR}/devspaces/egress-firewall.yaml" | oc apply -f - >/dev/null
  ok "EgressFirewall ${ns}/default: LLM API, npm registry, github.com; everything else denied"
  editor_template "$ns"
  render "$ns" "${AS_DIR}/devspaces/devworkspace.yaml" | oc apply -f - >/dev/null
  oc patch devworkspace claude-code-sandbox -n "$ns" --type merge -p '{"spec":{"started":true}}' >/dev/null
  info "starting the workspace (first start pulls the image, 1-3 minutes) ..."
  wait_until 420 "workspace running" ws_running "$ns" && ok "workspace claude-code-sandbox is Running"
  info "open: $(oc get devworkspace claude-code-sandbox -n "$ns" -o jsonpath='{.status.mainUrl}')"
  info "or the dashboard: https://$(host_of devspaces openshift-devspaces)/dashboard/"
}
editor_template() {  # editor_template <ns>: the che-code editor as a DevWorkspaceTemplate
  # The dashboard does this when you create a workspace there: it copies the editor definition
  # (ConfigMap editors-definitions, che-code.yaml) into the user's namespace. Created directly
  # with oc, the DevWorkspace needs it to exist first.
  oc get cm editors-definitions -n openshift-devspaces -o jsonpath='{.data.che-code\.yaml}' | python3 -c '
import sys, yaml, json
d = yaml.safe_load(sys.stdin)
spec = {k: d[k] for k in ("commands", "components", "events") if k in d}
print(json.dumps({"apiVersion": "workspace.devfile.io/v1alpha2", "kind": "DevWorkspaceTemplate",
  "metadata": {"name": "che-code-claude-code-sandbox", "namespace": sys.argv[1],
               "labels": {"app.kubernetes.io/part-of": "agent-sandboxes-demo"}}, "spec": spec}))' "$1" \
    | oc apply -f - >/dev/null
}
ws_running() { [[ "$(oc get devworkspace claude-code-sandbox -n "$1" -o jsonpath='{.status.phase}')" == Running ]]; }

devspaces_check() {
  local ns; ns=$(ds_ns "${1:-}")
  step "What can workspace claude-code-sandbox (${ns}) reach?"
  ws_exec "$ns" "$(cat "${AS_DIR}/devspaces/check-fence.sh")"
  info "key in the environment: $(ws_exec "$ns" 'echo ${ANTHROPIC_AUTH_TOKEN:0:12}...')"
}
devspaces_claude() {  # Claude Code in the workspace, on the sample project (copied in if missing)
  local task=${1:-$TASK_DEFAULT} ns p; ns=$(ds_ns "${2:-}")
  p=$(ws_pod "$ns"); [[ -n "$p" ]] || die "workspace not running: ./deploy.sh agent-sandboxes devspaces"
  step "Claude Code in workspace claude-code-sandbox (${ns}), /projects/sample-project"
  tar -C "$AS_DIR" -cf - sample-project | oc exec -i -n "$ns" "$p" -c tools -- tar -C /projects -xf -
  ws_exec "$ns" "cd /projects/sample-project && claude -p $(printf '%q' "$task") --allowedTools Write Edit Read 'Bash(python3:*)' 'Bash(ls:*)' 2>&1 | grep -v unrecognized_model; echo '--- tests now:'; python3 -m unittest 2>&1 | tail -1"
}
devspaces_fence() {
  local ns; ns=$(ds_ns "${2:-}")
  case "${1:-}" in
    on)  render "$ns" "${AS_DIR}/devspaces/egress-firewall.yaml" | oc apply -f - >/dev/null; ok "EgressFirewall on (${ns})" ;;
    off) oc delete egressfirewall default -n "$ns" --ignore-not-found >/dev/null; ok "EgressFirewall removed (${ns})" ;;
    *)   die "usage: devspaces-fence on|off" ;;
  esac
}

# ----------------------------------------------------------------------------- Part D: OpenShell
os_config_dir() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/openshell"; }
os_route() { echo "openshell.$(apps_domain)"; }
openshell_cli() {
  command -v openshell >/dev/null || die "the openshell CLI is not installed. Install ${OS_VERSION} yourself, e.g.
      brew install ai-openshell/tap/openshell   or the release archive from
      https://github.com/ai-openshell/openshell/releases/tag/v${OS_VERSION} (openshell-aarch64-apple-darwin.tar.gz)"
}

openshell_install() {
  need helm
  step "Agent Sandbox controller ${AGENT_SANDBOX_VERSION} (cluster-scoped: CRD sandboxes.agents.x-k8s.io)"
  oc apply -f "${AS_DIR}/openshell/agent-sandbox-${AGENT_SANDBOX_VERSION}.yaml" >/dev/null
  wait_until 120 "Sandbox CRD" oc get crd sandboxes.agents.x-k8s.io
  oc -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=300s >/dev/null
  ok "agent-sandbox-controller running (namespace agent-sandbox-system)"
  step "OpenShell ${OS_VERSION} gateway (Helm, namespace ${OS_NS})"
  oc get ns "$OS_NS" >/dev/null 2>&1 || oc create ns "$OS_NS" >/dev/null
  oc label ns "$OS_NS" app.kubernetes.io/part-of=agent-sandboxes-demo --overwrite >/dev/null
  local host; host=$(os_route)
  helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart --version "$OS_VERSION" \
    --namespace "$OS_NS" -f "${AS_DIR}/openshell/values-openshift.yaml" \
    --set "openshiftRoute.host=${host}" --set "pkiInitJob.serverDnsNames[0]=${host}" \
    --wait --timeout 10m >/dev/null
  oc -n "$OS_NS" rollout status statefulset/openshell --timeout=300s >/dev/null
  ok "gateway running, Route https://${host} (passthrough, mTLS)"
  info "next: ./deploy.sh agent-sandboxes openshell-connect"
}

openshell_connect() {
  openshell_cli
  step "Register the OpenShift gateway in the local openshell CLI"
  local dir host; dir="$(os_config_dir)/gateways/openshift"; host=$(os_route)
  mkdir -p "${dir}/mtls"; chmod 700 "${dir}/mtls"
  # The client certificate the chart generated (pre-install hook). Whoever holds it is a user of
  # this gateway: keep it like a kubeconfig. Production: OIDC per user instead.
  oc get secret openshell-client-tls -n "$OS_NS" -o jsonpath='{.data.ca\.crt}'  | base64 -d > "${dir}/mtls/ca.crt"
  oc get secret openshell-client-tls -n "$OS_NS" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${dir}/mtls/tls.crt"
  oc get secret openshell-client-tls -n "$OS_NS" -o jsonpath='{.data.tls\.key}' | base64 -d > "${dir}/mtls/tls.key"
  chmod 600 "${dir}/mtls/"*
  cat > "${dir}/metadata.json" <<EOF
{
  "name": "openshift",
  "gateway_endpoint": "https://${host}",
  "is_remote": false,
  "gateway_port": 443
}
EOF
  openshell gateway select openshift >/dev/null 2>&1 || printf '%s' openshift > "$(os_config_dir)/active_gateway"
  ok "gateway 'openshift' -> https://${host} (client certificate in ${dir}/mtls)"
  local code; code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://${host}/" || true)
  info "without the client certificate: curl -> ${code:-000} (000 = refused in the TLS handshake)"
  openshell status
}

openshell_sandbox() {
  openshell_cli
  step "Credential profile 'company-llm' + provider (the LLM API key, as a placeholder)"
  local tmp; tmp=$(mktemp -d)
  sed "s#__LLM_HOST__#$(llm_host)#g" "${AS_DIR}/openshell/profile-company-llm.yaml" > "${tmp}/company-llm.yaml"
  openshell profile import -f "${tmp}/company-llm.yaml" --global >/dev/null 2>&1 \
    || openshell profile update -f "${tmp}/company-llm.yaml" --global >/dev/null
  ok "profile company-llm: Authorization on $(llm_host):443/anthropic/** for ${CLAUDE_BIN##*/} only"
  if ! openshell provider get company-llm >/dev/null 2>&1; then
    ANTHROPIC_AUTH_TOKEN="$(ensure_key sandbox)" openshell provider create --name company-llm --type company-llm \
      --credential ANTHROPIC_AUTH_TOKEN >/dev/null
  fi
  ok "provider company-llm (consumer 'sandbox'): the key is stored in the gateway, not in the sandbox"
  rm -rf "$tmp"
  step "Sandbox ${SANDBOX} (image claude-code-sandbox, policy openshell/policy.yaml)"
  if openshell sandbox get "$SANDBOX" >/dev/null 2>&1; then
    ok "sandbox ${SANDBOX} exists"
  else
    openshell sandbox create --name "$SANDBOX" --from "$(image claude-code-sandbox)" \
      --policy "${AS_DIR}/openshell/policy.yaml" --provider company-llm \
      --env "ANTHROPIC_BASE_URL=$(llm_base)" --upload "${AS_DIR}/sample-project:/sandbox/sample-project" \
      --detach >/dev/null
    wait_until 300 "sandbox ${SANDBOX} Ready" sandbox_ready && ok "sandbox ${SANDBOX} Ready"
  fi
  oc get pods -n "$OS_NS" -o wide | sed 's/^/    /'
}
sandbox_ready() { local j; j=$(openshell sandbox get "$SANDBOX" -o json 2>/dev/null || true); grep -qiE '"phase" *: *"(Ready|SANDBOX_PHASE_READY)"' <<<"$j"; }
in_sandbox() { openshell sandbox exec -n "$SANDBOX" --no-tty -- bash -lc "$1"; }

openshell_check() {
  openshell_cli
  step "What can sandbox ${SANDBOX} reach? (curl = a binary with no network rule)"
  in_sandbox "export ANTHROPIC_BASE_URL=$(llm_base); $(cat "${AS_DIR}/devspaces/check-fence.sh")" || true
  step "The key, as the sandbox sees it"
  in_sandbox 'echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}"' || true
  step "Filesystem (Landlock): write outside /sandbox and /tmp?"
  in_sandbox 'touch /etc/x 2>&1 | head -1; touch /opt/x 2>&1 | head -1; touch /sandbox/ok && echo "/sandbox: writable"' || true
}
openshell_claude() {
  local task=${1:-$TASK_DEFAULT}
  openshell_cli
  step "Claude Code in sandbox ${SANDBOX}, /sandbox/sample-project"
  in_sandbox "cd /sandbox/sample-project && [ -f ~/.claude.json ] || echo '{\"hasCompletedOnboarding\":true}' > ~/.claude.json; claude -p $(printf '%q' "$task") --allowedTools Write Edit Read 'Bash(python3:*)' 'Bash(ls:*)' 'Bash(pip:*)' 2>&1 | grep -v unrecognized_model"
}
openshell_pypi() {
  openshell_cli
  step "Live policy change: python3 (pip) may read pypi.org + files.pythonhosted.org"
  openshell policy update "$SANDBOX" --rule-name pypi --binary /usr/bin/python3.9 \
    --add-endpoint pypi.org:443:read-only:rest:enforce \
    --add-endpoint files.pythonhosted.org:443:read-only:rest:enforce --wait
  ok "applied to the running sandbox, no restart"
}
openshell_reset() {
  openshell_cli
  openshell policy set "$SANDBOX" --policy "${AS_DIR}/openshell/policy.yaml" --wait
  ok "sandbox ${SANDBOX} back on policy.yaml"
}
openshell_uninstall() {
  step "Remove OpenShell and the Agent Sandbox controller"
  command -v openshell >/dev/null && openshell sandbox delete "$SANDBOX" >/dev/null 2>&1 || true
  helm uninstall openshell -n "$OS_NS" >/dev/null 2>&1 || true
  oc delete ns "$OS_NS" --ignore-not-found --wait=false >/dev/null
  oc delete -f "${AS_DIR}/openshell/agent-sandbox-${AGENT_SANDBOX_VERSION}.yaml" --ignore-not-found >/dev/null 2>&1 || true
  ok "removed"
}

# ----------------------------------------------------------------------------- test / status
test_all() {
  step "LLM API, Anthropic endpoint"
  local base; base=$(llm_base)
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "${base}/v1/messages" -d '{}')" == 401 ]] && ok "no key: 401" || fail "no key: not 401"
  anthropic_ok sandbox && ok "consumer sandbox: model 'cloud' answers" || fail "consumer sandbox: no answer"
  # a failed tool call (is_error) must not break the session (the Lua shim on the llm-gateway)
  local r; r=$(curl -s -m 60 "${base}/v1/messages" -H "Authorization: Bearer $(key_of sandbox)" -H 'content-type: application/json' \
    -d '{"model":"cloud","max_tokens":30,"tools":[{"name":"Bash","description":"run","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}}],"messages":[{"role":"user","content":"run ls"},{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Exit code 2","is_error":true}]}]}')
  grep -q '"type":"message"' <<<"$r" && ok "tool error (is_error) accepted" || fail "tool error rejected: ${r:0:160}"
  step "Images"
  local is; for is in claude-code-sandbox claude-code-udi; do
    oc get istag "${is}:latest" -n "$NS" >/dev/null 2>&1 && ok "$is" || fail "$is missing: ./deploy.sh agent-sandboxes deploy"
  done
  step "Dev Spaces ($(ds_ns))"
  local ns; ns=$(ds_ns)
  if ws_running "$ns" 2>/dev/null; then
    local out; out=$(ws_exec "$ns" "$(cat "${AS_DIR}/devspaces/check-fence.sh")" 2>&1 || true)
    grep -q "LLM API.* 401" <<<"$out" && ok "LLM API reachable" || fail "LLM API not reachable"
    if oc get egressfirewall default -n "$ns" >/dev/null 2>&1; then
      grep -q "Anthropic API directly.*BLOCKED" <<<"$out" && ok "api.anthropic.com blocked" || fail "api.anthropic.com not blocked"
      grep -q "anything else.*BLOCKED" <<<"$out" && ok "example.com blocked" || fail "example.com not blocked"
    else warn "EgressFirewall off"; fi
    ws_exec "$ns" 'test -n "$ANTHROPIC_AUTH_TOKEN"' && ok "key automounted as env" || fail "no ANTHROPIC_AUTH_TOKEN in the workspace"
  else warn "workspace not running: ./deploy.sh agent-sandboxes devspaces"; fi
  step "OpenShell"
  if oc get statefulset openshell -n "$OS_NS" >/dev/null 2>&1; then
    ok "gateway installed (namespace ${OS_NS})"
    if command -v openshell >/dev/null && sandbox_ready; then
      local o; o=$(in_sandbox "export ANTHROPIC_BASE_URL=${base}; $(cat "${AS_DIR}/devspaces/check-fence.sh")" 2>&1 || true)
      grep -q "anything else.*BLOCKED\|anything else.*403" <<<"$o" && ok "example.com blocked in the sandbox" || fail "example.com not blocked: ${o}"
    else warn "no CLI or sandbox ${SANDBOX}: openshell-connect, openshell-sandbox"; fi
  else warn "not installed: ./deploy.sh agent-sandboxes openshell-install"; fi
  echo; [[ $FAILED == 0 ]] && echo "${G}All checks passed${N}" || { echo "${R}Some checks failed${N}"; exit 1; }
}

status() {
  oc get bc,istag -n "$NS" 2>/dev/null || true
  oc get devworkspace -A -l app.kubernetes.io/part-of=agent-sandboxes-demo 2>/dev/null || true
  oc get egressfirewall -A 2>/dev/null || true
  oc get pods -n "$OS_NS" 2>/dev/null || true
}

destroy() {
  step "Remove the demo (keeps demo 15's LLM API additions)"
  local ns; ns=$(ds_ns)
  oc delete devworkspace claude-code-sandbox -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  oc delete devworkspacetemplate che-code-claude-code-sandbox -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  oc delete egressfirewall default -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  oc delete secret claude-code-llm-key -n "$ns" --ignore-not-found >/dev/null 2>&1 || true
  oc delete ns "$NS" --ignore-not-found --wait=false >/dev/null
  ok "Dev Spaces workspace, fence, key secret and namespace ${NS} removed"
  info "OpenShell: ./deploy.sh agent-sandboxes openshell-uninstall"
}

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd=${1:-help}; shift || true
case "$cmd" in
  deploy)               deploy ;;
  claude)               claude_pod "$@" ;;
  kaiden)               kaiden ;;
  devspaces)            devspaces "$@" ;;
  devspaces-check)      devspaces_check "$@" ;;
  devspaces-claude)     devspaces_claude "$@" ;;
  devspaces-fence)      devspaces_fence "$@" ;;
  openshell-install)    openshell_install ;;
  openshell-connect)    openshell_connect ;;
  openshell-sandbox)    openshell_sandbox ;;
  openshell-check)      openshell_check ;;
  openshell-claude)     openshell_claude "$@" ;;
  openshell-pypi)       openshell_pypi ;;
  openshell-reset)      openshell_reset ;;
  openshell-uninstall)  openshell_uninstall ;;
  test)                 test_all ;;
  status)               status ;;
  destroy)              destroy ;;
  help|-h|--help)       usage 0 ;;
  *)                    usage 1 ;;
esac
