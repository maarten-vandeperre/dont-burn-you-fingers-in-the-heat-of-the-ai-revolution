#!/usr/bin/env bash
# =============================================================================
# OpenShift 4.22 AI platform stack + Models-as-a-Service with the smallest Gemma and Qwen models
#   - google/gemma-3-270m-it   (gated on Hugging Face, needs HF_TOKEN)
#   - Qwen/Qwen3-0.6B
#
# Commands
#   stack       Fresh OpenShift 4.22 cluster, everything with oc: OpenShift AI 3.4 + MLflow +
#               Gen AI playground + MaaS (Gemma, Qwen) + tracing, Kafka + Debezium, Service Mesh
#               + Kiali, Developer Hub, Argo CD + Argo Rollouts, Tekton Pipelines
#   stack-argocd  Same stack, but installed and kept in sync by Argo CD (OpenShift GitOps)
#   cdc-demo    Insert a row in the demo database and show the Debezium event from Kafka
#   urls        Print the URLs of every UI in the stack
#   app <cmd>   Demo applications in app/ (RAG, mesh patterns, CDC): same as app/demo.sh <cmd>
#   tssc <cmd>  Trusted software supply chain: setup | run | verify | urls | destroy (stack/tssc/tssc.sh)
#   rhdh        Developer Hub: render the catalog, wire tokens, enable the plugins of the running version
#   sso         Install / update Keycloak (single sign-on) and GitLab on an existing stack
#   gitlab      Push this repository into GitLab (group ai-platform) and register it with Argo CD
#   rhdh-plugins [word...]  List the plugin packages this Developer Hub offers (filtered by words)
#   validate    End-to-end check of every layer through oc and the routes: PASS / WARN / FAIL
#               report in validate-<date>.txt (--quick: skip the checks that call the models)
#   debug       Collect Developer Hub + model diagnostics into one file (no secrets)
#   dashboards  (Re)create the data for the OpenShift AI observability dashboard (Perses datasource)
#   models      Re-apply the model deployments (e.g. after changing flags) and wait for them
#   configure   Detect cluster domain + TLS secret, write platform/30-gateway/cluster-params.env
#   oc          Deploy everything with the oc CLI (layer by layer, with readiness waits)
#   argocd      Bootstrap secrets, then hand the manifests to Argo CD (OpenShift GitOps)
#   test        Create a MaaS API key and send a chat completion to both models
#   usage       Token consumption per model / subscription (/ user) from Prometheus
#   wait        Re-check the models (with diagnostics) after fixing something
#   observability  Add only the dashboards/telemetry to an existing MaaS install
#   playground  Enable the Gen AI playground backend (opt-in on 3.5, see README)
#   hf-check    Check that the Hugging Face token can download Gemma, and how to fix it if not
#   switch-rhoai --to 3.4|3.5   Reinstall OpenShift AI on another minor version, then redeploy
#               (DESTRUCTIVE: OLM cannot downgrade, so OpenShift AI is uninstalled first)
#   status      Show the state of all MaaS resources
#   render      Print the rendered manifests (no cluster changes)
#   destroy     Remove models, governance, gateway and PoC database
#
# Options
#   --rhoai-version 3.4|3.5   Default: auto-detected from the installed operator
#   --accelerator cpu|gpu     Default: cpu (vLLM CPU). gpu = vLLM CUDA, 1 NVIDIA GPU per model
#   --with-operators          Also install Connectivity Link, LWS and cert-manager operators
#   --postgres-url URL        Use an external PostgreSQL instead of the PoC one in maas-db
#   --repo-url URL            (argocd) Git repo Argo CD pulls from. Default: git remote origin
#   --revision REV            (argocd) Branch/tag/commit. Default: current branch
#   --no-observability        Skip the telemetry / token consumption dashboards
#   --capture-user            Add the user id to token metrics (off by default, GDPR)
#   --model-timeout MIN       Max minutes to wait per model before diagnosing (default 30)
#   --window DURATION         (usage) Time window, Prometheus syntax. Default: 24h
#   --disable-maas            (destroy) Also set MaaS to Removed in the DataScienceCluster
#   --to 3.4|3.5              (switch-rhoai) Target OpenShift AI version
#   --yes                     (switch-rhoai) Do not ask for confirmation
#   --no-deploy               (switch-rhoai) Only reinstall OpenShift AI, do not redeploy MaaS
#   --vllm-tracing            Add --otlp-traces-endpoint to vLLM (only for images with OpenTelemetry)
#
# Environment
#   HF_TOKEN             Hugging Face token of an account that accepted the Gemma license
#   OPENAI_API_KEY       optional, used by the demo apps (alias "openai" and the fallback)
#   DEMO_ADMIN_USER      the one user for every UI (default admin): Keycloak realm "demo" and
#   DEMO_ADMIN_PASSWORD  master realm, Developer Hub, GitLab (as root) (default redhatdemo)
# =============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_FILE="${ROOT_DIR}/platform/30-gateway/cluster-params.env"
OBS_PARAMS_FILE="${ROOT_DIR}/observability/usage-logs/cluster-params.env"
RHDH_PARAMS_FILE="${ROOT_DIR}/stack/developer-hub/cluster-params.env"
PLAYGROUND_PARAMS_FILE="${ROOT_DIR}/platform/60-playground/cluster-params.env"
PLAYGROUND_NS="ai-tenants"
SSO_PARAMS_FILE="${ROOT_DIR}/stack/keycloak/cluster-params.env"
GITLAB_PARAMS_FILE="${ROOT_DIR}/stack/gitlab/cluster-params.env"
# one user for every UI (Keycloak realm "demo", GitLab root password, Developer Hub user entity)
DEMO_ADMIN_USER="${DEMO_ADMIN_USER:-admin}"
DEMO_ADMIN_PASSWORD="${DEMO_ADMIN_PASSWORD:-redhatdemo}"
GITLAB_GROUP="ai-platform"
GITLAB_PROJECT="platform"
MONITORING_NS="redhat-ods-monitoring"

MODELS_NS="maas-models"
DB_NS="maas-db"
RHOAI_APPS_NS="redhat-ods-applications"
GATEWAY_INFRA_NS_35="redhat-ai-gateway-infra"
MAAS_POLICY_NS="models-as-a-service"
GITOPS_NS="openshift-gitops"
MODELS=("gemma-3-270m-it" "qwen3-0-6b")

RHOAI_VERSION=""
ACCELERATOR="cpu"
WITH_OPERATORS=false
POSTGRES_URL=""
REPO_URL=""
REVISION=""
DISABLE_MAAS=false
WITH_OBSERVABILITY=true
CAPTURE_USER=false
MODEL_TIMEOUT_MIN=30
USAGE_WINDOW="24h"
RHOAI_FULL_VERSION=""
SWITCH_TO=""
ASSUME_YES=false
SWITCH_DEPLOY=true
STACK=false
VLLM_TRACING=false
STACK_ISSUES=""
REPO_PATH=""

# ----------------------------------------------------------------------------- logging
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; Y=""; R=""; N=""; fi
step() { echo "${B}==> $*${N}"; }
info() { echo "    $*"; }
ok()   { echo "    ${G}OK${N} $*"; }
warn() { echo "    ${Y}WARN${N} $*" >&2; }
die()  { echo "${R}ERROR${N} $*" >&2; exit 1; }
trap 'die "failed at line $LINENO: $BASH_COMMAND"' ERR

usage() { awk '/^# =+$/ { if (++n == 2) exit; next } n == 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}" || true; exit "${1:-0}"; }

# ----------------------------------------------------------------------------- helpers
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed"; }

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
  local timeout=$1 desc=$2; shift 2
  local start=$SECONDS last=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start >= timeout )) && { warn "timed out after ${timeout}s waiting for: ${desc}"; return 1; }
    if (( SECONDS - last >= 60 )); then   # heartbeat, so a long wait never looks like a hang
      info "... still waiting for: ${desc} ($(( (SECONDS - start) / 60 ))/$(( timeout / 60 )) min)"
      last=$SECONDS
    fi
    sleep 10
  done
  ok "$desc"
}

apply_k() {  # apply_k <kustomize-dir> [field-manager]; server-side apply (partial objects rely on SSA)
  oc apply --server-side --force-conflicts --field-manager="${2:-maas-deploy}" -k "$1"
}

ns_ensure() {
  oc get namespace "$1" >/dev/null 2>&1 || oc create namespace "$1" >/dev/null
}

crd_exists() { oc get crd "$1" >/dev/null 2>&1; }

# the stack adds OpenTelemetry tracing to the model servers
# vLLM tracing is opt-in (--vllm-tracing): the Red Hat vLLM CPU image ships without the
# OpenTelemetry Python packages and refuses to start with --otlp-traces-endpoint.
models_overlay() { if [[ "$VLLM_TRACING" == true ]]; then echo "${ACCELERATOR}-traced"; else echo "$ACCELERATOR"; fi; }

param() { grep -E "^$1=" "$PARAMS_FILE" | cut -d= -f2-; }

maas_api_ns() {
  local ns
  for ns in "$GATEWAY_INFRA_NS_35" "$RHOAI_APPS_NS"; do
    oc get deployment maas-api -n "$ns" >/dev/null 2>&1 && { echo "$ns"; return 0; }
  done
  return 1
}

# ----------------------------------------------------------------------------- preflight
preflight() {
  step "Preflight checks"
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin rights are required"
  ok "logged in as $(oc whoami) on $(oc whoami --show-server)"

  local csv version
  csv=$(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null | grep '^rhods-operator' | head -1 || true)
  [[ -n "$csv" ]] || die "Red Hat OpenShift AI operator not found in redhat-ods-operator"
  RHOAI_FULL_VERSION=$(awk '{print $2}' <<<"$csv")
  version=$(cut -d. -f1,2 <<<"$RHOAI_FULL_VERSION")
  ok "OpenShift AI ${version} installed"

  if [[ -z "$RHOAI_VERSION" ]]; then
    if printf '%s\n3.5\n' "$version" | sort -V | head -1 | grep -qx '3.5'; then RHOAI_VERSION="3.5"
    elif [[ "$version" == "3.4" ]]; then RHOAI_VERSION="3.4"
    else die "OpenShift AI ${version} is not supported: these manifests need 3.4+ (subscription based MaaS)"; fi
  fi
  [[ "$RHOAI_VERSION" == "3.4" || "$RHOAI_VERSION" == "3.5" ]] || die "--rhoai-version must be 3.4 or 3.5"
  info "using platform overlay rhoai-${RHOAI_VERSION}, accelerator ${ACCELERATOR}"

  oc get datasciencecluster default-dsc >/dev/null 2>&1 || die "DataScienceCluster 'default-dsc' not found"
  heal_known_ogx_issue

  if [[ "$WITH_OPERATORS" == false ]]; then
    local csvs; csvs=$(oc get csv -n openshift-operators -o name 2>/dev/null || true)
    grep -q rhcl-operator <<<"$csvs" || die "Red Hat Connectivity Link operator not found, install it or pass --with-operators"
    ok "Connectivity Link operator present"
  fi

  if [[ "$ACCELERATOR" == "gpu" ]]; then
    local gpus; gpus=$(oc get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')
    grep -q '[1-9]' <<<"$gpus" || warn "no allocatable nvidia.com/gpu found on any node, GPU pods will stay Pending"
  fi
}

# ----------------------------------------------------------------------------- configure
configure() {
  step "Detecting cluster specific values"
  local domain cert host
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  cert=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)
  cert=${cert:-router-certs-default}
  host="maas.${domain}"
  cat >"$PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
# Commit this file when you deploy with Argo CD.
MAAS_HOSTNAME=${host}
TLS_SECRET_NAME=${cert}
EOF
  ok "MAAS_HOSTNAME=${host}"
  ok "TLS_SECRET_NAME=${cert} (wildcard *.${domain} cert served by the gateway)"

  local sc
  sc=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)
  [[ -n "$sc" ]] || { sc=$(oc get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true); warn "no default StorageClass, using '${sc}'"; }
  cat >"$OBS_PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
# Commit this file when you deploy with Argo CD.
STORAGE_CLASS=${sc}
EOF
  ok "STORAGE_CLASS=${sc} (Loki usage logs)"

  cat >"$PLAYGROUND_PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
# (same keys as platform/30-gateway/cluster-params.env; kustomize cannot load ../)
# Commit this file when you deploy with Argo CD.
MAAS_HOSTNAME=${host}
TLS_SECRET_NAME=${cert}
PLAYGROUND_VLLM_URL_GEMMA=https://${host}/maas-models/gemma-3-270m-it/v1
PLAYGROUND_VLLM_URL_QWEN=https://${host}/maas-models/qwen3-0-6b/v1
EOF
  ok "PLAYGROUND_VLLM_URL_* (Gen AI playground model endpoints)"

  cat >"$RHDH_PARAMS_FILE" <<EOF
RHDH_HOST=backstage-developer-hub-rhdh.${domain}
KEYCLOAK_URL=https://platform-sso-keycloak.${domain}
GITLAB_HOST=gitlab-gitlab.${domain}
EOF
  cat >"$SSO_PARAMS_FILE" <<EOF
# Cluster specific values, generated by: ./deploy.sh configure
KEYCLOAK_HOST=platform-sso-keycloak.${domain}
KEYCLOAK_URL=https://platform-sso-keycloak.${domain}
RHDH_URL=https://backstage-developer-hub-rhdh.${domain}
RHDH_REDIRECT_URI=https://backstage-developer-hub-rhdh.${domain}/api/auth/oidc/handler/frame
GITLAB_URL=https://gitlab-gitlab.${domain}
GITLAB_REDIRECT_URI=https://gitlab-gitlab.${domain}/users/auth/openid_connect/callback
EOF
  cat >"$GITLAB_PARAMS_FILE" <<EOF
GITLAB_HOST=gitlab-gitlab.${domain}
GITLAB_EXTERNAL_URL=https://gitlab-gitlab.${domain}
KEYCLOAK_ISSUER=https://platform-sso-keycloak.${domain}/realms/demo
EOF
  ok "Keycloak https://platform-sso-keycloak.${domain}, GitLab https://gitlab-gitlab.${domain}"
  ok "RHDH_HOST=backstage-developer-hub-rhdh.${domain} (Developer Hub)"
}

# ----------------------------------------------------------------------------- operators
install_operators() {
  step "Installing prerequisite operators"
  oc apply -k "${ROOT_DIR}/operators"
  wait_until 900 "Connectivity Link operator ready" \
    bash -c "oc get csv -n openshift-operators -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{\"\n\"}{end}' | grep -q '^rhcl-operator.* Succeeded'"
  wait_until 900 "LeaderWorkerSet operator ready" \
    bash -c "oc get csv -n openshift-lws-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"
  wait_until 900 "cert-manager operator ready" \
    bash -c "oc get csv -n cert-manager-operator -o jsonpath='{.items[*].status.phase}' | grep -q Succeeded"
}

# ----------------------------------------------------------------------------- bootstrap
# Everything imperative lives here: secrets (never in git) and cluster wide config
# that must be merged rather than overwritten.
bootstrap() {
  step "Bootstrapping namespaces and secrets"
  ns_ensure "$MODELS_NS"
  oc label namespace "$MODELS_NS" maas.opendatahub.io/gateway-access=true opendatahub.io/dashboard=true --overwrite >/dev/null

  # Hugging Face token for the gated Gemma repo
  if [[ -n "${HF_TOKEN:-}" ]]; then
    oc create secret generic hf-token -n "$MODELS_NS" --from-literal=HF_TOKEN="$HF_TOKEN" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
    ok "secret ${MODELS_NS}/hf-token"
  elif oc get secret hf-token -n "$MODELS_NS" >/dev/null 2>&1; then
    ok "secret ${MODELS_NS}/hf-token already present (checking the token stored there)"
    HF_TOKEN=$(oc get secret hf-token -n "$MODELS_NS" -o jsonpath='{.data.HF_TOKEN}' | base64 -d)
  else
    die "HF_TOKEN is not set. google/gemma-3-270m-it is gated: accept the license on huggingface.co, then export HF_TOKEN=hf_..."
  fi

  hf_access_check || true

  # PostgreSQL for MaaS API keys
  local db_url
  if [[ -n "$POSTGRES_URL" ]]; then
    db_url="$POSTGRES_URL"
    info "using external PostgreSQL"
  else
    ns_ensure "$DB_NS"
    local pw
    if oc get secret postgres-creds -n "$DB_NS" >/dev/null 2>&1; then
      pw=$(oc get secret postgres-creds -n "$DB_NS" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
    else
      pw=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)
      oc create secret generic postgres-creds -n "$DB_NS" \
        --from-literal=POSTGRES_USER=maas --from-literal=POSTGRES_PASSWORD="$pw" --from-literal=POSTGRES_DB=maas >/dev/null
    fi
    ok "secret ${DB_NS}/postgres-creds"
    db_url="postgresql://maas:${pw}@postgres.${DB_NS}.svc.cluster.local:5432/maas?sslmode=disable"
  fi
  oc create secret generic maas-db-config -n "$RHOAI_APPS_NS" --from-literal=DB_CONNECTION_URL="$db_url" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "secret ${RHOAI_APPS_NS}/maas-db-config"

  # S3 credentials for the Loki usage-log store (RHOAI 3.5+ usage dashboards)
  if [[ "$WITH_OBSERVABILITY" == true && "$RHOAI_VERSION" == "3.5" ]]; then
    ns_ensure "$MONITORING_NS"
    if ! oc get secret minio-secret -n "$MONITORING_NS" >/dev/null 2>&1; then
      oc create secret generic minio-secret -n "$MONITORING_NS" \
        --from-literal=access_key_id=maas-loki \
        --from-literal=access_key_secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32)" \
        --from-literal=bucketnames=loki \
        --from-literal=endpoint="http://minio.${MONITORING_NS}.svc:9000" \
        --from-literal=region=us-east-1 >/dev/null
    fi
    ok "secret ${MONITORING_NS}/minio-secret"
  fi

  # User Workload Monitoring (MaaS reports Degraded without it). Merge, never overwrite.
  local cfg tmp
  cfg=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
  if grep -Eq '^enableUserWorkload:[[:space:]]*true' <<<"$cfg"; then
    ok "user workload monitoring already enabled"
  else
    tmp=$(mktemp)
    if grep -Eq '^enableUserWorkload:' <<<"$cfg"; then
      sed -E 's/^enableUserWorkload:.*/enableUserWorkload: true/' <<<"$cfg" >"$tmp"
    else
      { [[ -n "$cfg" ]] && printf '%s\n' "$cfg"; echo "enableUserWorkload: true"; } >"$tmp"
    fi
    if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
      oc set data configmap/cluster-monitoring-config -n openshift-monitoring --from-file=config.yaml="$tmp" >/dev/null
    else
      oc create configmap cluster-monitoring-config -n openshift-monitoring --from-file=config.yaml="$tmp" >/dev/null
    fi
    rm -f "$tmp"
    ok "user workload monitoring enabled"
  fi
}

# Checks, from this machine, that the token can actually download the gated Gemma files.
# Only warns: the cluster may reach Hugging Face through a different path.
GEMMA_REPO="google/gemma-3-270m-it"
HF_FIX_URL_LICENSE="https://huggingface.co/${GEMMA_REPO}"
HF_FIX_URL_TOKENS="https://huggingface.co/settings/tokens"

# Checks, from this machine, that the token can actually download the gated Gemma files,
# and explains the exact fix for the account/token type. Returns 0 = OK, 1 = denied,
# 2 = could not verify. Only warns during a deploy: the cluster may use a different network path.
hf_access_check() {
  [[ -n "${HF_TOKEN:-}" ]] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  local who user role headers code hf_err
  who=$(curl -s --max-time 15 -H "Authorization: Bearer ${HF_TOKEN}" https://huggingface.co/api/whoami-v2 || true)
  user=$(grep -o '"name":"[^"]*"' <<<"$who" | head -1 | cut -d'"' -f4 || true)
  role=$(grep -o '"role":"[^"]*"' <<<"$who" | head -1 | cut -d'"' -f4 || true)
  # no -L: an authorized request answers 200 or a redirect to the CDN, a denied one 401/403.
  # Hugging Face tags its own denials with an X-Error-Code header (GatedRepo, ...), which tells
  # them apart from a 403 produced by a corporate proxy.
  headers=$(curl -s -I --max-time 15 -H "Authorization: Bearer ${HF_TOKEN}" \
    "https://huggingface.co/${GEMMA_REPO}/resolve/main/config.json" 2>/dev/null | tr -d '\r' || true)
  code=$(head -1 <<<"$headers" | awk '{print $2}')
  hf_err=$(grep -i '^x-error-code:' <<<"$headers" | head -1 | awk '{print $2}' || true)
  local id="account ${user:-?}, ${role:-unknown} token"
  case "${code}:${hf_err}" in
    2??:*|3??:*)
      ok "Hugging Face token (${id}) can download ${GEMMA_REPO}"; return 0 ;;
    401:?*)
      warn "Hugging Face token is invalid or expired (${hf_err}): Gemma will fail to download."
      warn "  Create a new one at ${HF_FIX_URL_TOKENS}, then: export HF_TOKEN=hf_...; ./deploy.sh oc"
      return 1 ;;
    403:?*)
      warn "Hugging Face token (${id}) is NOT allowed to download ${GEMMA_REPO} (${hf_err})."
      warn "  You can keep this token. Fix it on huggingface.co while logged in as '${user:-the token owner}':"
      warn "  1. Accept the Gemma license (skip if the page says you have been granted access):"
      warn "       ${HF_FIX_URL_LICENSE}"
      if [[ "$role" == "fineGrained" ]]; then
        warn "  2. This is a fine-grained token: edit it at ${HF_FIX_URL_TOKENS} and tick"
        warn "       'Read access to contents of all public gated repos you can access' (token value stays the same)"
      else
        warn "  2. If the license was accepted with ANOTHER account, use a token of that account instead"
      fi
      warn "  Then verify with: ./deploy.sh hf-check   and retry the model with: ./deploy.sh wait"
      return 1 ;;
    *)
      info "could not verify Hugging Face access from this machine (HTTP ${code:-none})"; return 2 ;;
  esac
}

# ./deploy.sh hf-check: test the token that is (or will be) used by the cluster
hf_check_cmd() {
  need curl
  step "Hugging Face access for ${GEMMA_REPO}"
  if [[ -n "${HF_TOKEN:-}" ]]; then
    info "testing HF_TOKEN from your shell"
  else
    need oc
    HF_TOKEN=$(oc get secret hf-token -n "$MODELS_NS" -o jsonpath='{.data.HF_TOKEN}' 2>/dev/null | base64 -d || true)
    [[ -n "$HF_TOKEN" ]] || die "no HF_TOKEN exported and no secret ${MODELS_NS}/hf-token in the cluster"
    info "testing the token stored in secret ${MODELS_NS}/hf-token"
  fi
  local rc=0; hf_access_check || rc=$?
  if [[ $rc -eq 0 ]] && command -v oc >/dev/null 2>&1; then
    local state; state=$(model_pod gemma-3-270m-it 2>/dev/null | awk '{print $2}')
    [[ "$state" == *CrashLoopBackOff* || "$state" == *Error* ]] && info "Gemma pod is ${state}: run ./deploy.sh wait to retry the download now"
  fi
  exit "$rc"   # exit, not return: a non-zero return would trip the ERR trap
}

# ----------------------------------------------------------------------------- glue
# Steps that touch operator owned objects or namespaces that only exist later.
authorino_tls_env() {
  wait_until 300 "Authorino deployment exists" oc get deployment authorino -n kuadrant-system
  if oc get deployment authorino -n kuadrant-system -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q SSL_CERT_FILE; then
    ok "Authorino trusts the service CA"
  else
    oc -n kuadrant-system set env deployment/authorino \
      SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
      REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt >/dev/null
    ok "Authorino configured to trust the service CA"
  fi
}

maas_api_glue() {
  wait_until 600 "MaaS CRDs installed" crd_exists maasmodelrefs.maas.opendatahub.io
  wait_until 600 "maas-api deployment created" maas_api_ns
  local ns; ns=$(maas_api_ns)
  info "maas-api runs in ${ns}"

  # 3.5+: maas-api moved to redhat-ai-gateway-infra and reads the DB secret there
  if [[ "$ns" == "$GATEWAY_INFRA_NS_35" ]] && ! oc get secret maas-db-config -n "$ns" >/dev/null 2>&1; then
    local url; url=$(oc get secret maas-db-config -n "$RHOAI_APPS_NS" -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d)
    oc create secret generic maas-db-config -n "$ns" --from-literal=DB_CONNECTION_URL="$url" >/dev/null
    oc rollout restart deployment/maas-api -n "$ns" >/dev/null
    ok "mirrored maas-db-config to ${ns}"
  fi
  # The MaaS HTTPRoutes must be admitted by the gateway. On 3.5 the dashboard's MaaS routes live in
  # redhat-ods-applications, maas-api in redhat-ai-gateway-infra: both need the label, otherwise
  # "Error loading API keys" / "Models as a Service could not be loaded" (RHOAIENG-83207)
  local lns
  for lns in "$ns" "$RHOAI_APPS_NS"; do
    oc label namespace "$lns" maas.opendatahub.io/gateway-access=true --overwrite >/dev/null
  done
  oc rollout status deployment/maas-api -n "$ns" --timeout=300s >/dev/null && ok "maas-api ready"
}

# Create / refresh the MaaS API key Secret the Llama Stack playground mounts.
# AuthPolicy on the MaaS gateway requires Bearer sk-oai-*; a placeholder key produces empty
# assistant turns in the playground (provider 401, the UI hides the error).
playground_maas_keys() {
  local host key secret=lsd-maas-api-keys
  oc get namespace "$PLAYGROUND_NS" >/dev/null 2>&1 || return 0
  if oc get secret "$secret" -n "$PLAYGROUND_NS" >/dev/null 2>&1; then
    ok "playground MaaS API key present (Secret ${PLAYGROUND_NS}/${secret})"; return 0
  fi
  host=$(param MAAS_HOSTNAME)
  key=$(curl -sk --max-time 60 -X POST "https://${host}/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"lsd-genai-playground","subscription":"small-models-free","expiresIn":"720h"}' \
      | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
  if [[ -z "$key" ]]; then
    warn "could not mint a MaaS API key for the playground (is maas-api healthy?); chats stay empty until Secret ${PLAYGROUND_NS}/${secret} exists"
    return 0
  fi
  oc create secret generic "$secret" -n "$PLAYGROUND_NS" \
    --from-literal=VLLM_API_TOKEN_1="$key" --from-literal=VLLM_API_TOKEN_2="$key" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "playground MaaS API key stored in Secret ${PLAYGROUND_NS}/${secret}"
  oc rollout restart deployment/lsd-genai-playground -n "$PLAYGROUND_NS" >/dev/null 2>&1 || true
}

# 3.4: a ready-made playground (LlamaStackDistribution) with both models, in project ai-tenants
# (created by the MaaS controller). 3.5 keeps the opt-in OGX flow below.
playground_instance() {
  [[ "$RHOAI_VERSION" == "3.4" ]] || return 0
  step "Gen AI playground: LlamaStackDistribution in ${PLAYGROUND_NS}"
  if ! wait_until 60 "namespace ${PLAYGROUND_NS} (created by the MaaS controller on some versions)" oc get namespace "$PLAYGROUND_NS"; then
    oc create namespace "$PLAYGROUND_NS" >/dev/null && ok "namespace ${PLAYGROUND_NS} created"
  fi
  # a project in the OpenShift AI dashboard (Gen AI studio > Playground > project picker)
  oc label namespace "$PLAYGROUND_NS" opendatahub.io/dashboard=true --overwrite >/dev/null
  playground_maas_keys
  wait_until 300 "Llama Stack CRD" crd_exists llamastackdistributions.llamastack.io || return 0
  apply_k "${ROOT_DIR}/platform/60-playground" >/dev/null && ok "playground lsd-genai-playground applied (Gen AI studio > Playground, project ${PLAYGROUND_NS})"
}

# The Gen AI playground needs the OGX (3.5) / Llama Stack (3.4) CRDs. The dashboard caches
# API discovery at startup, so if it started before those CRDs existed it shows
# "no matches for ogx.io/v1beta1" until it is restarted.
playground_group() { [[ "$RHOAI_VERSION" == "3.5" ]] && echo "ogx.io" || echo "llamastack.io"; }
playground_crd_time() {
  local g; g=$(playground_group)
  oc get crd -o jsonpath="{range .items[?(@.spec.group==\"${g}\")]}{.metadata.creationTimestamp}{\"\\n\"}{end}" 2>/dev/null | sort | tail -1
}
playground_crds_exist() { [[ -n "$(playground_crd_time)" ]]; }

playground_conditions() {  # OGX / Llama Stack related DSC conditions, one per line
  oc get datasciencecluster default-dsc \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'ogx|llama' || true
}

ogx_state() { oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.ogx.managementState}' 2>/dev/null || true; }
set_ogx() {
  oc patch datasciencecluster default-dsc --type=merge \
    -p "{\"spec\":{\"components\":{\"ogx\":{\"managementState\":\"$1\"}}}}" >/dev/null
}

# Self-heal at the start of every run: an earlier run (or a manual edit) may have left
# "ogx: Managed" on a 3.5.x build without the OGX module CRD, which pins the DSC at Ready=False.
heal_known_ogx_issue() {
  [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" == "Managed" ]] || return 0
  if grep -q 'no matches for kind "OGX"' <<<"$(playground_conditions)"; then
    set_ogx Removed
    warn "known RHOAI 3.5.x OGX issue found: set ogx back to Removed so default-dsc can become Ready"
    info "the playground stays off until an OpenShift AI update; retry then with ./deploy.sh playground"
  fi
}

# Explicit opt-in on 3.5 (./deploy.sh playground); always part of the deploy on 3.4.
enable_playground() {
  if [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" != "Managed" ]]; then
    set_ogx Managed
    ok "ogx set to Managed in default-dsc"
  fi
  PLAYGROUND_REQUESTED=true
  playground_glue
}

playground_glue() {
  step "Gen AI playground"
  if [[ "$RHOAI_VERSION" == "3.5" && "$(ogx_state)" != "Managed" && "${PLAYGROUND_REQUESTED:-false}" != true ]]; then
    info "skipped on 3.5 by default (known OGX module issue on some 3.5.x builds)"
    info "try it with: ./deploy.sh playground  (rolls back automatically if the issue is present)"
    return 0
  fi
  local g crd_t pods_t start=$SECONDS last=$SECONDS cond
  g=$(playground_group)
  until playground_crds_exist; do
    cond=$(playground_conditions)
    # Known RHOAI 3.5.x issue: the OGX module CRD is not shipped, the DSC stays NotReady forever
    if (( SECONDS - start >= 60 )) && grep -q 'no matches for kind "OGX"' <<<"$cond"; then
      warn "known RHOAI 3.5.x issue: the OGX module CRD (components.platform.opendatahub.io OGX) is not"
      warn "installed on this cluster, so the playground backend cannot be deployed."
      set_ogx Removed
      warn "rolled ogx back to Removed so default-dsc can become Ready again (MaaS is not affected)."
      info "retry after an OpenShift AI update: ./deploy.sh playground"
      return 0
    fi
    # Any other failing component status: show it instead of waiting 10 minutes
    if (( SECONDS - start >= 120 )) && grep -q '=False' <<<"$cond"; then
      warn "the ${g} API is not being installed, the operator reports:"
      sed 's/^/      /' <<<"$cond"
      info "operator log: oc logs -n redhat-ods-operator deploy/rhods-operator --since=15m | grep -iE 'ogx|llama'"
      return 0
    fi
    if (( SECONDS - start >= 600 )); then
      warn "${g} API still missing after 10 min. DSC conditions: ${cond:-none mention ogx/llama}"
      return 0
    fi
    if (( SECONDS - last >= 60 )); then
      info "... still waiting for the ${g} API ($(( (SECONDS - start) / 60 ))/10 min)"
      last=$SECONDS
    fi
    sleep 10
  done
  ok "${g} API installed (playground backend)"
  crd_t=$(playground_crd_time)
  pods_t=$(oc get pods -n "$RHOAI_APPS_NS" -l app=rhods-dashboard -o jsonpath='{range .items[*]}{.status.startTime}{"\n"}{end}' 2>/dev/null | sort | head -1)
  if [[ -z "$pods_t" || "$pods_t" < "$crd_t" ]]; then
    oc rollout restart deployment/rhods-dashboard -n "$RHOAI_APPS_NS" >/dev/null
    oc rollout status deployment/rhods-dashboard -n "$RHOAI_APPS_NS" --timeout=300s >/dev/null || true
    ok "dashboard restarted so it picks up the ${g} API"
  else
    ok "dashboard already knows the ${g} API"
  fi
}

# ----------------------------------------------------------------------------- waits
kuadrant_ready() { oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=10s; }

wait_kuadrant() {
  wait_until 240 "Kuadrant ready" kuadrant_ready && return 0
  # Known behaviour: Kuadrant stays on MissingDependency after the Gateway API provider
  # was installed underneath it. A restart of the operator pod makes it re-check.
  local pod
  pod=$(oc get pods -n openshift-operators -o name | grep kuadrant-operator-controller | head -1 || true)
  [[ -n "$pod" ]] && { warn "restarting ${pod}"; oc delete "$pod" -n openshift-operators >/dev/null; }
  wait_until 480 "Kuadrant ready" kuadrant_ready || die "Kuadrant not Ready: oc describe kuadrant kuadrant -n kuadrant-system"
}

wait_platform() {
  wait_kuadrant
  wait_until 300 "Gateway programmed" \
    oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=10s || true
  if [[ -z "$POSTGRES_URL" ]]; then
    wait_until 600 "PostgreSQL ready" oc rollout status deployment/postgres -n "$DB_NS" --timeout=10s
  fi
}

FAILED_MODELS=""   # plain string, empty arrays break "set -u" on macOS bash 3.2

model_pod() {        # "<pod> <status>" of the model's workload pod, empty if none yet
  oc get pods -n "$MODELS_NS" --no-headers 2>/dev/null | awk -v p="${1}-kserve-" 'index($1,p)==1 && $3!="Terminating" {print $1, $3; exit}'
}

diagnose_model() {
  local m=$1 pod
  pod=$(model_pod "$m" | awk '{print $1}')
  if [[ -z "$pod" ]]; then
    warn "${m}: no pod created, recent events:"
    oc get events -n "$MODELS_NS" --sort-by=.lastTimestamp 2>/dev/null | tail -8 | sed 's/^/      /'
    return 0
  fi
  warn "${m}: pod ${pod} is $(model_pod "$m" | awk '{print $2}')"
  info "storage-initializer env: $(oc get pod "$pod" -n "$MODELS_NS" -o jsonpath='{.spec.initContainers[0].env[*].name}' 2>/dev/null)"
  info "--- storage-initializer log (tail)"
  oc logs "$pod" -n "$MODELS_NS" -c storage-initializer --tail=15 2>&1 | sed 's/^/      /' || true
  if oc logs "$pod" -n "$MODELS_NS" -c storage-initializer --tail=50 2>/dev/null | grep -q 'gated repo'; then
    warn "${m}: the HF token reaches the pod, but its Hugging Face account is not allowed to download this gated model."
    info "  exact fix for this token: ./deploy.sh hf-check   (see also README, 'Hugging Face token for Gemma')"
  fi
  info "--- main log (tail)"
  oc logs "$pod" -n "$MODELS_NS" -c main --tail=15 2>&1 | sed 's/^/      /' || true
}

# KServe storage-initializer can hang on the Hugging Face Xet protocol; fall back to HTTP.
xet_workaround() {
  local dep="${1}-kserve"
  oc get deployment "$dep" -n "$MODELS_NS" >/dev/null 2>&1 || return 0
  warn "${1}: still in Init after 5 min, setting HF_HUB_DISABLE_XET=1 on the storage-initializer"
  oc set env "deployment/${dep}" -n "$MODELS_NS" -c storage-initializer HF_HUB_DISABLE_XET=1 >/dev/null 2>&1 || true
}

wait_models() {
  step "Waiting for models (image pull + download + load can take 5-15 min)"
  restart_failed_models
  local m state start last xet_done pending_told limit=$(( MODEL_TIMEOUT_MIN * 60 ))
  for m in "${MODELS[@]}"; do
    start=$SECONDS; last=0; xet_done=false; pending_told=false
    while ! oc wait "llminferenceservice/${m}" -n "$MODELS_NS" --for=condition=Ready --timeout=5s >/dev/null 2>&1; do
      state=$(model_pod "$m" | awk '{print $2}')
      case "$state" in
        *Error*|*CrashLoopBackOff*|*OOMKilled*|*ImagePullBackOff*|*ErrImagePull*)
          diagnose_model "$m"; FAILED_MODELS="${FAILED_MODELS} ${m}"; break ;;
        Init:0/1)
          if (( SECONDS - start > 300 )) && [[ "$xet_done" == false ]]; then xet_workaround "$m"; xet_done=true; fi ;;
        Pending)
          if (( SECONDS - start > 180 )) && [[ "$pending_told" == false ]]; then
            warn "${m}: Pending for 3 min: $(oc get events -n "$MODELS_NS" --field-selector reason=FailedScheduling -o jsonpath='{.items[-1:].message}' 2>/dev/null)"
            pending_told=true
          fi ;;
      esac
      if (( SECONDS - start > limit )); then
        diagnose_model "$m"; FAILED_MODELS="${FAILED_MODELS} ${m}"; break
      fi
      if (( SECONDS - last >= 60 )); then
        info "$(date +%H:%M:%S) ${m}: ${state:-no pod yet} ($(( (SECONDS - start) / 60 )) min)"; last=$SECONDS
      fi
      sleep 10
    done
    [[ " ${FAILED_MODELS} " == *" ${m} "* ]] || ok "${m} serving"
  done
}

restart_failed_models() {  # skip the CrashLoopBackOff back-off after fixing something
  local m state restarted=false
  for m in "${MODELS[@]}"; do
    state=$(model_pod "$m" | awk '{print $2}')
    if [[ "$state" == *CrashLoopBackOff* || "$state" == *Error* ]]; then
      oc rollout restart "deployment/${m}-kserve" -n "$MODELS_NS" >/dev/null && info "restarted ${m} (was ${state}), fresh attempt"
      restarted=true
    fi
  done
  # let the old pod start terminating, so it is not mistaken for the new attempt
  [[ "$restarted" == true ]] && sleep 20
  true
}

wait_modelrefs() {
  local m
  for m in "${MODELS[@]}"; do
    if [[ " ${FAILED_MODELS} " == *" ${m} "* ]]; then
      warn "skipping MaaSModelRef ${m}: its model is not serving"; continue
    fi
    wait_until 600 "MaaSModelRef ${m} Ready (subscription + auth policy paired)" \
      oc wait "maasmodelref/${m}" -n "$MODELS_NS" --for=jsonpath='{.status.phase}'=Ready --timeout=10s || true
  done
}

# ----------------------------------------------------------------------------- observability
csv_succeeded() {  # csv_succeeded <namespace> <csv-name-prefix>
  local out; out=$(oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null || true)
  grep -Eq "^${2}.* Succeeded$" <<<"$out"
}

install_observability_operators() {
  apply_k "${ROOT_DIR}/observability/operators"
  [[ "$RHOAI_VERSION" == "3.5" ]] && apply_k "${ROOT_DIR}/observability/operators-loki"
  wait_until 600 "Cluster Observability operator ready" csv_ok_anywhere cluster-observability-operator || true
  wait_until 600 "Tempo operator ready" csv_ok_anywhere tempo-operator || true
  wait_until 600 "OpenTelemetry operator ready" csv_ok_anywhere opentelemetry-operator || true
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    wait_until 600 "Loki operator ready" csv_succeeded openshift-operators-redhat loki-operator || true
  fi
}

tenant_patch() {  # merge patch on the operator owned MaaS tenant config
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    oc patch maastenantconfigs.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS" --type=merge -p "$1" >/dev/null
  else
    oc patch tenants.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS" --type=merge -p "$1" >/dev/null
  fi
}
tenant_exists() {
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then oc get maastenantconfigs.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS"
  else oc get tenants.maas.opendatahub.io default-tenant -n "$MAAS_POLICY_NS"; fi
}
telemetry_ready() {
  [[ -n "$(oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress --no-headers 2>/dev/null)" ]]
}
lokistack_ready() {
  # Not "oc wait --for=jsonpath" with a filter: several oc versions never match it even when
  # Ready=True. Read the condition and compare instead.
  [[ "$(oc get lokistack usage -n "$MONITORING_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == *True* ]]
}

diagnose_lokistack() {
  warn "LokiStack 'usage' conditions:"
  oc get lokistack usage -n "$MONITORING_NS" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' 2>/dev/null | sed 's/^/      /'
  local bad
  bad=$(oc get pods -n "$MONITORING_NS" --no-headers 2>/dev/null | grep -E '^(usage-|minio)' | grep -vE 'Running|Completed' || true)
  [[ -n "$bad" ]] && { warn "Loki / MinIO pods not running:"; sed 's/^/      /' <<<"$bad"; }
  bad=$(oc get pvc -n "$MONITORING_NS" --no-headers 2>/dev/null | grep -v Bound || true)
  [[ -n "$bad" ]] && { warn "unbound PVCs:"; sed 's/^/      /' <<<"$bad"; }
  info "fix, then re-run: ./deploy.sh observability"
}

# Switches on what lives in operator owned objects: gateway telemetry (token metrics
# labelled per model/subscription) and, on 3.5, the logs based usage pipeline.
# Data for the OpenShift AI observability dashboard (Observe & monitor > Dashboard). COO 1.5 on
# OpenShift AI 3.4 needs a global Perses datasource plus a few workarounds (observability/dashboard-datasource).
dashboard_datasource() {
  [[ "$RHOAI_VERSION" == "3.4" ]] || return 0
  step "OpenShift AI dashboard: Perses datasource (Cluster / Models / Usage tabs)"
  wait_until 600 "Perses of the OpenShift AI monitoring stack" bash -c \
    'oc get crd persesglobaldatasources.perses.dev >/dev/null 2>&1 && oc get svc data-science-perses -n redhat-ods-monitoring >/dev/null 2>&1' \
    || { warn "no Perses in redhat-ods-monitoring yet (DSCI monitoring not ready?); re-run later: ./deploy.sh dashboards"; return 0; }
  apply_k "${ROOT_DIR}/observability/dashboard-datasource" >/dev/null && ok "global datasource, network policies, RBAC and auth fix applied"
  oc delete job perses-auth-fix-now -n "$MONITORING_NS" --ignore-not-found >/dev/null 2>&1
  oc create job perses-auth-fix-now --from=cronjob/perses-auth-fix -n "$MONITORING_NS" >/dev/null 2>&1 || true
  if oc wait job/perses-auth-fix-now -n "$MONITORING_NS" --for=condition=Complete --timeout=300s >/dev/null 2>&1; then
    ok "Perses reaches Thanos (dashboard datasource works); the CronJob keeps the token in place"
  else
    warn "datasource check did not pass yet: oc logs job/perses-auth-fix-now -n ${MONITORING_NS}"
  fi
}

observability_glue() {
  step "Observability: token metrics + usage dashboards"
  wait_until 600 "DSCI monitoring stack ready" \
    oc wait dsci/default-dsci --for=jsonpath='{.status.phase}'=Ready --timeout=10s || true
  dashboard_datasource

  if [[ "$RHOAI_VERSION" == "3.4" && -n "$RHOAI_FULL_VERSION" ]] \
     && [[ "$(printf '%s\n3.4.4\n' "$RHOAI_FULL_VERSION" | sort -V | head -1)" != "3.4.4" ]]; then
    warn "OpenShift AI ${RHOAI_FULL_VERSION} < 3.4.4: gateway telemetry can crash the Wasm shim (RHOAIENG-79318), not enabling it"
    return 0
  fi
  wait_until 300 "MaaS tenant config present" tenant_exists || { warn "cannot enable telemetry, tenant config missing"; return 0; }
  local capture=false; [[ "$CAPTURE_USER" == true ]] && capture=true
  tenant_patch "{\"spec\":{\"telemetry\":{\"enabled\":true,\"metrics\":{\"captureModelUsage\":true,\"captureUser\":${capture}}}}}"
  ok "gateway telemetry enabled (per model + subscription$([[ "$capture" == true ]] && echo " + user"))"
  wait_until 180 "TelemetryPolicy created by the MaaS controller" telemetry_ready || true

  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    info "LokiStack starts ~8 components with PVCs, this usually takes 3-8 min"
    wait_until 600 "LokiStack ready" lokistack_ready || { diagnose_lokistack; warn "usage logging NOT enabled yet, continuing"; return 0; }
    oc patch configs.maas.opendatahub.io default --type=merge -p '{"spec":{"usageLogging":true}}' >/dev/null \
      && ok "usage logging enabled (per-request tokens -> Loki)"
  fi
}

deploy_observability_oc() {
  step "Observability 1/3: operators (COO, Tempo, OpenTelemetry$([[ "$RHOAI_VERSION" == "3.5" ]] && echo ", Loki"))"
  install_observability_operators
  step "Observability 2/3: RHOAI monitoring stack"
  apply_k "${ROOT_DIR}/observability/monitoring"
  if [[ "$RHOAI_VERSION" == "3.5" ]]; then
    step "Observability 3/3: usage-log store (MinIO + LokiStack)"
    wait_until 300 "LokiStack CRD installed" crd_exists lokistacks.loki.grafana.com || true
    apply_k "${ROOT_DIR}/observability/usage-logs"
  fi
  observability_glue
}

# ----------------------------------------------------------------------------- switch OpenShift AI version
RHOAI_CRD_REGEX='\.(opendatahub\.io|kserve\.io|ogx\.io|llamastack\.io)$'

rhoai_installed_version() {
  oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null \
    | grep '^rhods-operator' | head -1 | awk '{print $2}' || true
}
ns_gone() { ! oc get namespace "$1" >/dev/null 2>&1; }
rhoai_crds() {
  { oc get crd -l operators.coreos.com/rhods-operator.redhat-ods-operator -o name 2>/dev/null || true
    oc get crd -o name 2>/dev/null | grep -E "$RHOAI_CRD_REGEX" || true; } | sort -u
}
rhoai_crds_gone() { [[ -z "$(rhoai_crds)" ]]; }
dsc_ready() { [[ "$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null)" == "Ready" ]]; }

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local answer
  read -r -p "    Type 'switch' to continue: " answer
  [[ "$answer" == "switch" ]] || die "aborted, nothing was changed"
}

# With the operator gone, finalizers on leftover custom resources keep their CRDs terminating forever
strip_leftover_finalizers() {
  local crd res ns name
  while read -r crd; do
    [[ -n "$crd" ]] || continue
    res=${crd#*/}
    while IFS='|' read -r ns name; do
      [[ -n "$name" ]] || continue
      if [[ -n "$ns" ]]; then
        oc patch "$res" "$name" -n "$ns" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      else
        oc patch "$res" "$name" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
      fi
    done < <(oc get "$res" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done <<<"$(rhoai_crds)"
}

uninstall_rhoai() {
  step "Uninstalling OpenShift AI $(rhoai_installed_version)"
  # our own resources first, while the controllers still run their finalizers
  oc delete -k "${ROOT_DIR}/governance" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc delete namespace "$MODELS_NS" "$DB_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  # created by the MaaS controller, recreated when telemetry is enabled again
  oc delete telemetrypolicies.extensions.kuadrant.io --all -n openshift-ingress --ignore-not-found >/dev/null 2>&1 || true

  # Documented CLI uninstall: the operator removes its components and namespaces itself
  oc create configmap delete-self-managed-odh -n redhat-ods-operator --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc label configmap delete-self-managed-odh -n redhat-ods-operator api.openshift.com/addon-managed-odh-delete=true --overwrite >/dev/null
  wait_until 1200 "OpenShift AI components removed (redhat-ods-applications gone)" ns_gone "$RHOAI_APPS_NS" \
    || warn "redhat-ods-applications still terminating, continuing"

  local csv
  csv=$(oc get subscription rhods-operator -n redhat-ods-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
  oc delete subscription rhods-operator -n redhat-ods-operator --ignore-not-found >/dev/null
  [[ -n "$csv" ]] && oc delete csv "$csv" -n redhat-ods-operator --ignore-not-found >/dev/null
  ok "operator subscription and CSV removed"

  # Leftover webhooks point at deleted services and would reject the finalizer patches below
  local wh
  wh=$(oc get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null \
    | grep -iE 'kserve|opendatahub|odh|rhods|llmisvc|maas|ogx|llamastack' || true)
  [[ -n "$wh" ]] && { xargs oc delete --ignore-not-found <<<"$wh" >/dev/null; ok "removed $(wc -l <<<"$wh" | tr -d ' ') leftover webhook configurations"; }

  # The CRDs must go too: 3.5 stores e.g. LLMInferenceService as v1alpha2, and OLM refuses to
  # install a 3.4 CRD that drops a stored version
  local crds; crds=$(rhoai_crds)
  if [[ -n "$crds" ]]; then
    info "deleting $(wc -l <<<"$crds" | tr -d ' ') OpenShift AI CRDs"
    xargs oc delete --ignore-not-found --wait=false <<<"$crds" >/dev/null 2>&1 || true
    sleep 30
    strip_leftover_finalizers
    wait_until 900 "OpenShift AI CRDs removed" rhoai_crds_gone \
      || warn "some CRDs still terminating, check: oc get crd | grep -E 'opendatahub|kserve|ogx|llamastack'"
  fi

  local ns
  for ns in redhat-ods-operator redhat-ods-monitoring redhat-ai-gateway-infra models-as-a-service rhods-notebooks; do
    oc delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  for ns in redhat-ods-operator redhat-ods-monitoring redhat-ai-gateway-infra models-as-a-service; do
    wait_until 600 "namespace ${ns} removed" ns_gone "$ns" || warn "${ns} still terminating"
  done
}

install_rhoai() {  # install_rhoai <channel> [nowait]
  step "Installing OpenShift AI from channel $1"
  if [[ -z "$(rhoai_installed_version)" ]]; then
    sed "s/__CHANNEL__/$1/" "${ROOT_DIR}/rhoai/operator.yaml" | oc apply -f -
    wait_until 1200 "OpenShift AI operator installed" csv_succeeded redhat-ods-operator rhods-operator \
      || die "operator not installed: oc get csv,installplan -n redhat-ods-operator"
  fi
  local full v; full=$(rhoai_installed_version); v=$(cut -d. -f1,2 <<<"$full")
  ok "OpenShift AI ${full}"
  [[ -f "${ROOT_DIR}/rhoai/datasciencecluster-${v}.yaml" ]] || die "no rhoai/datasciencecluster-${v}.yaml for this version"
  wait_until 600 "DSCInitialization default-dsci created" oc get dsci default-dsci || true
  if ! oc get datasciencecluster default-dsc >/dev/null 2>&1; then
    oc apply --server-side --field-manager=maas-rhoai-install -f "${ROOT_DIR}/rhoai/datasciencecluster-${v}.yaml"
  fi
  if [[ "${2:-}" == "nowait" ]]; then
    info "DataScienceCluster created; it reports Ready once the MaaS gateway and database exist (next steps)"
  else
    wait_until 1200 "DataScienceCluster Ready" dsc_ready || warn "default-dsc not Ready yet, continuing (MaaS deploy will wait for its parts)"
  fi
}

switch_rhoai() {
  need oc
  [[ "$SWITCH_TO" == "3.4" || "$SWITCH_TO" == "3.5" ]] || die "use: ./deploy.sh switch-rhoai --to 3.4|3.5"
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin rights are required"
  if oc get application.argoproj.io maas-platform -n "$GITOPS_NS" >/dev/null 2>&1; then
    die "this install is managed by Argo CD. Run './deploy.sh destroy' first, then switch, then './deploy.sh argocd'"
  fi
  if [[ "$SWITCH_DEPLOY" == true && -z "${HF_TOKEN:-}" ]]; then
    die "export HF_TOKEN first: the switch removes ${MODELS_NS} (with its hf-token secret) and redeploys afterwards"
  fi

  local current channel
  current=$(rhoai_installed_version)
  [[ "$SWITCH_TO" == "3.4" ]] && channel="stable-3.4" || channel="stable-3.x"
  step "Switch OpenShift AI ${current:-(not installed)} -> ${SWITCH_TO}"

  if [[ -n "$current" && "$(cut -d. -f1,2 <<<"$current")" != "$SWITCH_TO" ]]; then
    local models
    models=$(oc get inferenceservices.serving.kserve.io,llminferenceservices.serving.kserve.io -A --no-headers 2>/dev/null \
      | awk '{print $1 "/" $2}' || true)
    warn "OLM cannot move between these versions in place, so this UNINSTALLS OpenShift AI ${current} and installs ${SWITCH_TO}."
    warn "Removed: the DataScienceCluster, redhat-ods-* / redhat-ai-gateway-infra / models-as-a-service namespaces,"
    warn "  all OpenShift AI CRDs, ${MODELS_NS}, and the PoC database ${DB_NS} (MaaS API keys are lost)."
    warn "Model deployments that disappear with their CRDs (all namespaces):"
    sed 's/^/      /' <<<"${models:-none}"
    warn "Kept: user projects, Kuadrant, the MaaS gateway, observability operators, other operators."
    confirm
    uninstall_rhoai
  fi
  install_rhoai "$channel"

  RHOAI_VERSION=""   # let preflight detect the new version
  if [[ "$SWITCH_DEPLOY" == true ]]; then
    deploy_oc
  else
    info "next: ./deploy.sh oc"
  fi
}

# ----------------------------------------------------------------------------- OpenShift 4.22 platform stack
# namespace | CSV name prefix | label | Subscription (= package) name
STACK_CSVS="redhat-ods-operator|rhods-operator|OpenShift AI 3.4|rhods-operator
openshift-operators|rhcl-operator|Connectivity Link|rhcl-operator
openshift-lws-operator|leader-worker-set|LeaderWorkerSet|leader-worker-set
cert-manager-operator|cert-manager-operator|cert-manager|openshift-cert-manager-operator
openshift-gitops-operator|openshift-gitops-operator|OpenShift GitOps (Argo CD + Rollouts)|openshift-gitops-operator
openshift-operators|openshift-pipelines-operator-rh|OpenShift Pipelines (Tekton)|openshift-pipelines-operator-rh
openshift-operators|servicemeshoperator3|Service Mesh 3|servicemeshoperator3
openshift-operators|kiali-operator|Kiali|kiali-ossm
openshift-operators|amqstreams|Streams for Apache Kafka|amq-streams
rhdh-operator|rhdh-operator|Developer Hub|rhdh
keycloak|rhbk-operator|Keycloak (RHBK)|rhbk-operator
openshift-cluster-observability-operator|cluster-observability-operator|Cluster Observability|cluster-observability-operator
openshift-tempo-operator|tempo-operator|Tempo|tempo-product
openshift-opentelemetry-operator|opentelemetry-operator|OpenTelemetry|opentelemetry-product"

# namespace | OperatorGroup this repo creates there
OUR_OGS="redhat-ods-operator|redhat-ods-operator
openshift-lws-operator|leader-worker-set
cert-manager-operator|cert-manager-operator
openshift-gitops-operator|openshift-gitops-operator
rhdh-operator|rhdh-operator
keycloak|keycloak
openshift-cluster-observability-operator|openshift-cluster-observability-operator
openshift-tempo-operator|openshift-tempo-operator
openshift-opentelemetry-operator|openshift-opentelemetry-operator"

# Succeeded CSV with this prefix in ANY namespace: also accepts operators that were already
# installed on the cluster before this script ran (other namespace, other subscription name)
csv_ok_anywhere() {
  local out; out=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null || true)
  grep -Eq "^${1}.* Succeeded$" <<<"$out"
}

# Why OLM is not installing an operator: prints nothing while things look normal
operator_problems() {  # operator_problems <namespace> <subscription>
  local ns=$1 sub=$2 n
  n=$(oc get operatorgroups -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -gt 1 ]]; then
    echo "${n} OperatorGroups in ${ns}, OLM needs exactly one: $(oc get operatorgroups -n "$ns" -o name | tr '\n' ' ')"
  fi
  oc get operatorgroups -n "$ns" -o jsonpath='{range .items[*]}{range .status.conditions[*]}{.reason}: {.message}{"\n"}{end}{end}' 2>/dev/null \
    | grep -v '^: $' || true
  oc get subscription "$sub" -n "$ns" \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}: {.message}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(ResolutionFailed|CatalogSourcesUnhealthy|InstallPlanFailed)' || true
  oc get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.reason}: {.status.message}{"\n"}{end}' 2>/dev/null \
    | grep -E ' (Failed|Pending) ' || true
}

# Before applying: an operator may already be installed through another Subscription in
# another namespace (common on sandbox/demo clusters). A second Subscription for the same
# package would never install, so drop ours and use the existing one.
drop_duplicate_subscriptions() {
  local all ns prefix label sub other
  all=$(oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}|{.spec.name}{"\n"}{end}' 2>/dev/null || true)
  while IFS='|' read -r ns prefix label sub; do
    other=$(grep -E "\|${sub}$" <<<"$all" | grep -v "^${ns}|" | head -1 | cut -d'|' -f1 || true)
    if [[ -n "$other" ]] && oc get subscription "$sub" -n "$ns" >/dev/null 2>&1; then
      oc delete subscription "$sub" -n "$ns" >/dev/null 2>&1 || true
      oc delete csv -n "$ns" -l "operators.coreos.com/${sub}.${ns}" >/dev/null 2>&1 || true
      warn "${label}: already subscribed in namespace ${other}, using that one (removed the duplicate in ${ns})"
    fi
  done <<<"$STACK_CSVS"
}

# A namespace that already had an OperatorGroup now has two (ours + theirs): OLM refuses to
# install anything there. Keep the pre-existing one, delete ours.
drop_duplicate_operatorgroups() {
  local ns og n
  while IFS='|' read -r ns og; do
    n=$(oc get operatorgroups -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$n" -gt 1 ]] && oc get operatorgroup "$og" -n "$ns" >/dev/null 2>&1; then
      oc delete operatorgroup "$og" -n "$ns" >/dev/null 2>&1 || true
      warn "namespace ${ns} already had an OperatorGroup, removed the duplicate '${og}' this script added"
    fi
  done <<<"$OUR_OGS"
}

# wait_operator <ns> <csv-prefix> <label> <subscription>: returns 1 early when OLM reports a problem
wait_operator() {
  local ns=$1 prefix=$2 label=$3 sub=$4 start=$SECONDS last=$SECONDS problems
  until csv_ok_anywhere "$prefix"; do
    if (( SECONDS - start >= 120 )); then
      problems=$(operator_problems "$ns" "$sub")
      if [[ -n "$problems" ]]; then
        warn "${label}: OLM reports a problem, not waiting any longer:"
        sed 's/^/      /' <<<"$problems"
        info "  inspect: oc get subscription,installplan,csv,operatorgroup -n ${ns}"
        return 1
      fi
    fi
    if (( SECONDS - start >= 1200 )); then
      warn "${label}: not installed after 20 min. oc get subscription,installplan,csv,operatorgroup -n ${ns}"
      return 1
    fi
    if (( SECONDS - last >= 60 )); then
      info "... still waiting for: ${label} ($(( (SECONDS - start) / 60 ))/20 min)"
      last=$SECONDS
    fi
    sleep 10
  done
  ok "$label"
}

rand_hex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 32; }
rollouts_ready() { [[ "$(oc get pods -n argo-rollouts --no-headers 2>/dev/null | grep -c Running || true)" -gt 0 ]]; }

stack_issue() { STACK_ISSUES="${STACK_ISSUES} $1"; warn "$1 not ready yet, continuing"; }

stack_preflight() {
  step "Preflight: OpenShift platform stack"
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "cluster-admin rights are required"
  local ocp; ocp=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
  if [[ "$ocp" == 4.22.* ]]; then ok "OpenShift ${ocp}"
  else warn "OpenShift ${ocp:-unknown}: this stack is written and pinned for 4.22 (OpenShift AI 3.4 supports 4.19.9+ to 4.22)"; fi
  local current; current=$(rhoai_installed_version)
  if [[ -n "$current" && "$(cut -d. -f1,2 <<<"$current")" != "3.4" ]]; then
    die "OpenShift AI ${current} is installed, the stack pins 3.4. Run './deploy.sh switch-rhoai --to 3.4 --no-deploy' first"
  fi
  [[ -n "${HF_TOKEN:-}" ]] || oc get secret hf-token -n "$MODELS_NS" >/dev/null 2>&1 \
    || die "export HF_TOKEN first (Gemma is gated, see README 'Hugging Face token for Gemma')"
  RHOAI_VERSION="3.4"
  WITH_OBSERVABILITY=true   # the tracing layer needs the Tempo + OpenTelemetry operators
}

install_stack_operators() {
  step "Operators (all subscriptions at once, then wait)"
  apply_k "${ROOT_DIR}/stack/operators" maas-stack
  apply_k "${ROOT_DIR}/observability/operators" maas-stack
  drop_duplicate_subscriptions
  drop_duplicate_operatorgroups
  local ns prefix label sub
  while IFS='|' read -r ns prefix label sub; do
    if [[ "$prefix" == "rhods-operator" || "$prefix" == "rhcl-operator" ]]; then
      wait_operator "$ns" "$prefix" "$label" "$sub" || die "${label} is required for the rest of the stack"
    else
      wait_operator "$ns" "$prefix" "$label" "$sub" || stack_issue "operator:${label// /_}"
    fi
  done <<<"$STACK_CSVS"
  install_observability_operators
}

stack_bootstrap() {
  step "Stack secrets (never stored in git)"
  ns_ensure rhdh; ns_ensure kafka
  # placeholders until './deploy.sh rhdh' wires the real tokens (the proxy config needs the keys)
  oc get secret rhdh-secrets -n rhdh >/dev/null 2>&1 \
    || oc create secret generic rhdh-secrets -n rhdh --from-literal=BACKEND_SECRET="$(rand_hex)" \
         --from-literal=K8S_CLUSTER_NAME=openshift --from-literal=K8S_CLUSTER_URL=https://kubernetes.default.svc \
         --from-literal=K8S_CLUSTER_TOKEN=pending --from-literal=K8S_ACTIONS_TOKEN=pending \
         --from-literal=ARGOCD_PASSWORD=pending --from-literal=DEVHUB_CLIENT_SECRET=pending \
         --from-literal=GITLAB_TOKEN=pending >/dev/null
  ok "secret rhdh/rhdh-secrets"
  oc get secret inventory-db -n kafka >/dev/null 2>&1 \
    || oc create secret generic inventory-db -n kafka \
         --from-literal=user-password="$(rand_hex)" --from-literal=admin-password="$(rand_hex)" >/dev/null
  ok "secret kafka/inventory-db"

  # single sign-on: Keycloak DB, master realm admin, demo realm user + OIDC client secrets
  ns_ensure keycloak; ns_ensure gitlab
  oc get secret keycloak-sso-db -n keycloak >/dev/null 2>&1 \
    || oc create secret generic keycloak-sso-db -n keycloak --from-literal=username=keycloak --from-literal=password="$(rand_hex)" >/dev/null
  oc create secret generic keycloak-sso-bootstrap-admin -n keycloak \
    --from-literal=username="$DEMO_ADMIN_USER" --from-literal=password="$DEMO_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  local devhub gitlab
  devhub=$(oc get secret keycloak-sso-demo -n keycloak -o jsonpath='{.data.DEVHUB_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
  gitlab=$(oc get secret keycloak-sso-demo -n keycloak -o jsonpath='{.data.GITLAB_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || true)
  devhub=${devhub:-$(rand_hex)}; gitlab=${gitlab:-$(rand_hex)}
  oc create secret generic keycloak-sso-demo -n keycloak \
    --from-literal=DEMO_ADMIN_USER="$DEMO_ADMIN_USER" --from-literal=DEMO_ADMIN_PASSWORD="$DEMO_ADMIN_PASSWORD" \
    --from-literal=DEVHUB_CLIENT_SECRET="$devhub" --from-literal=GITLAB_CLIENT_SECRET="$gitlab" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc create secret generic gitlab-secrets -n gitlab \
    --from-literal=root-password="$DEMO_ADMIN_PASSWORD" --from-literal=oidc-client-secret="$gitlab" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "Keycloak and GitLab secrets (user ${DEMO_ADMIN_USER})"
}

# apply_layer <dir> <label> <crd>...: wait for the CRDs the layer needs, then apply it
apply_layer() {
  local dir=$1 label=$2 crd; shift 2
  step "Stack: ${label}"
  for crd in "$@"; do
    wait_until 900 "CRD ${crd}" crd_exists "$crd" || { stack_issue "crd:${crd}"; return 0; }
  done
  if [[ "$dir" == "stack/developer-hub" ]]; then
    rhdh_align_api_version || { stack_issue developer-hub; return 0; }
  fi
  apply_k "${ROOT_DIR}/${dir}" maas-stack
}

deployment_ready() { oc rollout status "deployment/$2" -n "$1" --timeout=10s; }
cr_ready() { oc wait "$2" -n "$1" --for=condition=Ready --timeout=10s; }

wait_stack_services() {
  step "Waiting for the stack services"
  wait_until 600 "Tempo ready" cr_ready tracing-system tempomonolithic/platform || stack_issue tempo
  wait_until 300 "OpenTelemetry collector ready" deployment_ready tracing-system otel-collector || stack_issue otel-collector
  wait_until 600 "Istio control plane ready" bash -c 'oc wait istio/default --for=condition=Ready --timeout=10s' || stack_issue istio
  wait_until 600 "Istio CNI ready" bash -c 'oc wait istiocni/default --for=condition=Ready --timeout=10s' || stack_issue istio-cni
  wait_until 600 "Kiali ready" deployment_ready istio-system kiali || stack_issue kiali
  wait_until 600 "Bookinfo demo ready (with sidecars)" deployment_ready mesh-demo productpage-v1 || stack_issue bookinfo
  wait_until 900 "Kafka cluster ready" cr_ready kafka kafka/platform || stack_issue kafka
  info "Kafka Connect builds its image with the Debezium plugin first (~3-8 min)"
  wait_until 1200 "Kafka Connect (Debezium) ready" cr_ready kafka kafkaconnect/debezium || stack_issue kafka-connect
  wait_until 600 "Debezium connector running" cr_ready kafka kafkaconnector/inventory-postgres || stack_issue debezium-connector
  wait_until 900 "Keycloak ready" cr_ready keycloak keycloak/platform-sso || stack_issue keycloak
  wait_until 600 "Keycloak realm demo imported" bash -c 'oc wait keycloakrealmimport/demo-realm -n keycloak --for=condition=Done --timeout=10s' || stack_issue keycloak-realm
  info "GitLab initialises its database on first start (~5-15 min)"
  wait_until 1500 "GitLab ready" deployment_ready gitlab gitlab || stack_issue gitlab
  info "Developer Hub installs its dynamic plugins on first start (~3-6 min)"
  wait_until 1200 "Developer Hub ready" deployment_ready rhdh backstage-developer-hub || stack_issue developer-hub
  wait_until 600 "Argo Rollouts ready" rollouts_ready || stack_issue argo-rollouts
  wait_until 600 "MLflow instance present" bash -c 'oc get mlflow mlflow' || stack_issue mlflow
}

route_url() { local h; h=$(oc get route "$2" -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null || true); [[ -n "$h" ]] && echo "https://${h}" || echo "(route ${1}/${2} not found)"; }

stack_urls() {
  need oc
  step "URLs"
  local dash; dash=$(oc get consolelink rhodslink -o jsonpath='{.spec.href}' 2>/dev/null || true)
  info "OpenShift console    : $(oc whoami --show-console 2>/dev/null)"
  info "OpenShift AI         : ${dash:-console app launcher > Red Hat OpenShift AI}"
  info "  Gen AI playground  : OpenShift AI > Gen AI studio > Playground (project ${PLAYGROUND_NS})"
  info "  MLflow             : OpenShift AI > Applications > MLflow UI"
  info "MaaS endpoint        : https://$(param MAAS_HOSTNAME)/v1   (./deploy.sh test)"
  info "Traces               : console > Observe > Traces, or $(route_url tracing-system tempo-platform-jaegerui)"
  info "Kiali                : $(route_url istio-system kiali)"
  info "Developer Hub        : https://$(grep -E '^RHDH_HOST=' "$RHDH_PARAMS_FILE" | cut -d= -f2-)   (catalog of everything + platform templates)"
  info "Argo CD              : $(route_url "$GITOPS_NS" openshift-gitops-server)"
  info "Keycloak             : $(route_url keycloak platform-sso)/admin   (realm demo, user ${DEMO_ADMIN_USER})"
  info "GitLab               : $(route_url gitlab gitlab)   (root / DEMO_ADMIN_PASSWORD, or Keycloak sign-in)"
  info "Coffee shop          : $(route_url ai-demo coffee)"
  info "Tekton Pipelines     : console > Pipelines"
  info "Kafka + Debezium CDC : ./deploy.sh cdc-demo"
}

stack_finish() {
  stack_urls
  if [[ -n "$STACK_ISSUES" ]]; then
    warn "not ready (yet):${STACK_ISSUES}"
    info "re-check later with './deploy.sh status'; models: './deploy.sh wait'"
    exit 1
  fi
  ok "platform stack complete"
}

deploy_stack_oc() {
  STACK=true
  stack_preflight
  install_stack_operators
  install_rhoai "stable-3.4" nowait
  configure
  stack_bootstrap
  apply_layer stack/tracing "tracing (Tempo + OpenTelemetry collector)" \
    tempomonolithics.tempo.grafana.com opentelemetrycollectors.opentelemetry.io uiplugins.observability.openshift.io
  apply_layer stack/servicemesh "Service Mesh 3 + Kiali + Bookinfo demo" \
    istios.sailoperator.io istiocnis.sailoperator.io telemetries.telemetry.istio.io kialis.kiali.io
  apply_layer stack/kafka "Kafka (KRaft) + Debezium CDC" \
    kafkas.kafka.strimzi.io kafkanodepools.kafka.strimzi.io kafkaconnects.kafka.strimzi.io kafkaconnectors.kafka.strimzi.io
  apply_layer stack/keycloak "Keycloak (single sign-on)" keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org
  apply_layer stack/gitlab "GitLab"
  apply_layer stack/developer-hub "Developer Hub" backstages.rhdh.redhat.com
  apply_layer stack/gitops "Argo Rollouts" rolloutmanagers.argoproj.io
  # MaaS, models (with tracing), playground, MLflow component, observability
  deploy_oc
  apply_layer stack/rhoai "MLflow tracking server" mlflows.mlflow.opendatahub.io
  wait_stack_services
  gitlab_seed || stack_issue gitlab-seed
  configure_rhdh || stack_issue developer-hub-plugins
  stack_finish
}

deploy_stack_argocd() {
  STACK=true
  stack_preflight
  step "OpenShift GitOps (Argo CD itself is installed with oc, everything else by Argo CD)"
  oc apply --server-side --force-conflicts --field-manager=maas-stack -f "${ROOT_DIR}/stack/operators/gitops.yaml"
  wait_until 1200 "OpenShift GitOps operator" csv_succeeded openshift-gitops-operator openshift-gitops-operator \
    || die "OpenShift GitOps did not install"
  wait_until 600 "Argo CD instance openshift-gitops" deployment_ready "$GITOPS_NS" openshift-gitops-server || die "Argo CD not ready"
  git_context
  oc apply -f "${ROOT_DIR}/argocd/rbac.yaml" >/dev/null && ok "Argo CD may manage cluster resources"
  stack_bootstrap
  step "Creating stack Applications"
  render_apps "${ROOT_DIR}/argocd/stack-applications.yaml" | oc apply -f -
  # Operators come from Argo CD now; the DataScienceCluster is bootstrapped once with oc
  local ns prefix label sub
  while IFS='|' read -r ns prefix label sub; do
    wait_operator "$ns" "$prefix" "$label" "$sub" || stack_issue "operator:${label// /_}"
  done <<<"$STACK_CSVS"
  install_rhoai "stable-3.4" nowait
  deploy_argocd          # MaaS + observability Applications and their glue
  wait_stack_services
  gitlab_seed || stack_issue gitlab-seed
  configure_rhdh || stack_issue developer-hub-plugins
  stack_finish
}

# ----------------------------------------------------------------------------- GitLab
gitlab_host() { grep -E '^GITLAB_HOST=' "$GITLAB_PARAMS_FILE" | cut -d= -f2-; }
gitlab_token() { oc get secret gitlab-automation-token -n gitlab -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true; }
gitlab_api() {  # gitlab_api <method> <path> [json]
  local args=(-sk --max-time 60 -X "$1" -H "PRIVATE-TOKEN: $(gitlab_token)" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(-d "$3")
  curl "${args[@]}" "https://$(gitlab_host)/api/v4$2"
}

# Pushes this repository into GitLab (group ai-platform, project platform, public), so Developer
# Hub can link every component to its source, Argo CD can sync from it and Tekton can build it.
gitlab_seed() {
  need oc; need curl; need git
  step "GitLab: automation token, group, project and the platform source"
  deployment_ready gitlab gitlab || { warn "GitLab is not ready yet: oc get pods -n gitlab"; return 1; }
  if [[ -z "$(gitlab_token)" || "$(gitlab_api GET /user | grep -c '"username"' || true)" == "0" ]]; then
    local token pod
    token="glpat-$(rand_hex | head -c 20)"
    pod=$(oc get pod -n gitlab -l app=gitlab -o name | head -1)
    info "creating a root API token with gitlab-rails (about a minute)"
    oc exec -n gitlab "$pod" -- gitlab-rails runner "
      u = User.find_by_username('root')
      u.personal_access_tokens.where(name: 'platform-automation').each(&:revoke!)
      t = u.personal_access_tokens.create!(name: 'platform-automation', scopes: ['api', 'read_repository', 'write_repository'], expires_at: 300.days.from_now)
      t.set_token('${token}')
      t.save!" >/dev/null || { warn "could not create the GitLab token"; return 1; }
    oc create secret generic gitlab-automation-token -n gitlab --from-literal=token="$token" \
      --dry-run=client -o yaml | oc apply -f - >/dev/null
  fi
  ok "GitLab API token (Secret gitlab/gitlab-automation-token)"

  local gid
  gid=$(gitlab_api GET "/groups/${GITLAB_GROUP}" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
  if [[ -z "$gid" ]]; then
    gid=$(gitlab_api POST /groups "{\"name\":\"AI platform\",\"path\":\"${GITLAB_GROUP}\",\"visibility\":\"public\"}" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
  fi
  [[ -n "$gid" ]] || { warn "could not create GitLab group ${GITLAB_GROUP}"; return 1; }
  gitlab_api GET "/projects/${GITLAB_GROUP}%2F${GITLAB_PROJECT}" | grep -q '"id"' \
    || gitlab_api POST /projects "{\"name\":\"${GITLAB_PROJECT}\",\"namespace_id\":${gid},\"visibility\":\"public\",\"description\":\"OpenShift 4.22 AI platform: manifests, demo apps (Quarkus, React, LangChain4j, Camel), docs\"}" >/dev/null
  ok "project ${GITLAB_GROUP}/${GITLAB_PROJECT}"

  # push a clean snapshot of this folder (no build output, no node_modules, no local reports)
  local tmp proj; tmp=$(mktemp -d)
  if command -v rsync >/dev/null; then
    rsync -a --exclude='.git' --exclude='node_modules' --exclude='build' --exclude='.gradle' \
      --exclude='META-INF/resources' --exclude='debug-*.txt' --exclude='validate-*.txt' \
      --exclude='.env' --exclude='llm.env' --exclude='._*' --exclude='.DS_Store' "$ROOT_DIR"/ "$tmp"/
  else
    cp -R "$ROOT_DIR"/. "$tmp"/
    find "$tmp" \( -name .git -o -name node_modules -o -name build -o -name .gradle \) -prune -exec rm -rf {} + 2>/dev/null || true
    rm -f "$tmp"/debug-*.txt "$tmp"/validate-*.txt
    find "$tmp" \( -name '.env' -o -name 'llm.env' -o -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
  fi
  # software templates in GitLab carry this cluster's GitLab host and apps domain
  local domain; domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  find "$tmp/app/software-templates" -type f \( -name '*.yaml' -o -name '*.md' \) -print0 2>/dev/null \
    | xargs -0 -r sed -i.bak -e "s/__GITLAB_HOST__/$(gitlab_host)/g" -e "s/__APPS_DOMAIN__/${domain}/g"
  find "$tmp/app/software-templates" -name '*.bak' -delete 2>/dev/null || true
  # a re-run replaces main: lift the default branch protection for the push, restore it afterwards
  proj="${GITLAB_GROUP}%2F${GITLAB_PROJECT}"
  gitlab_api DELETE "/projects/${proj}/protected_branches/main" >/dev/null 2>&1 || true
  (
    cd "$tmp" && git init -q && git checkout -q -b main 2>/dev/null; git add -A \
      && git -c user.name="Platform demo" -c user.email="${DEMO_ADMIN_USER}@demo.example.com" commit -qm "Platform snapshot $(date +%Y-%m-%d)" \
      && git -c http.sslVerify=false push -q --force "https://root:$(gitlab_token)@$(gitlab_host)/${GITLAB_GROUP}/${GITLAB_PROJECT}.git" main
  ) || { rm -rf "$tmp"; warn "git push to GitLab failed"; return 1; }
  gitlab_api POST "/projects/${proj}/protected_branches?name=main&push_access_level=40&merge_access_level=40&allow_force_push=true" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  ok "source pushed: https://$(gitlab_host)/${GITLAB_GROUP}/${GITLAB_PROJECT}"

  # Argo CD may read the (public) repo despite the self-signed route certificate
  if oc get namespace "$GITOPS_NS" >/dev/null 2>&1; then
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-gitlab-platform
  namespace: ${GITOPS_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://$(gitlab_host)/${GITLAB_GROUP}/${GITLAB_PROJECT}.git
  insecure: "true"
EOF
    ok "Argo CD knows the GitLab repository (./deploy.sh app gitops https://$(gitlab_host)/${GITLAB_GROUP}/${GITLAB_PROJECT}.git)"
  fi
}

# ----------------------------------------------------------------------------- Developer Hub
# name | extended regex on the package reference (local path or OCI) in dynamic-plugins.default.yaml
# name | extended regex on the package reference; several regexes separated by ";;" are tried in order
RHDH_PLUGINS="Kubernetes backend|backstage-plugin-kubernetes-backend
Kubernetes|/backstage-plugin-kubernetes(-dynamic)?([:@!]|$)
Topology|plugin-topology(-dynamic)?([:@!]|$)
Tekton|plugin-tekton(-dynamic)?([:@!]|$)
Argo CD backend|(argo-?cd-backend|argocd-backend)
Argo CD|plugin-(redhat-)?argocd(-dynamic)?([:@!]|$);;roadiehq-backstage-plugin-argo-cd(-dynamic)?([:@!]|$)
Scaffolder HTTP request|scaffolder-backend-module-http-request
Scaffolder Kubernetes|scaffolder-backend-module-kubernetes
Scaffolder GitLab|plugin-scaffolder-backend-module-gitlab(-dynamic)?([:@!]|$)"

RHDH_DIR() { echo "${ROOT_DIR}/stack/developer-hub"; }

# The Backstage CRD moves forward between Developer Hub releases (v1alpha3, v1alpha4, v1alpha5,
# ...); older versions stop being served. Use the newest served version, the fields used in
# backstage.yaml are the same in all of them. Rewrites the file (commit it for Argo CD).
rhdh_align_api_version() {
  local served latest current file
  file="$(RHDH_DIR)/backstage.yaml"
  if ! oc get crd backstages.rhdh.redhat.com >/dev/null 2>&1; then
    warn "the Backstage CRD does not exist: the Developer Hub operator is not installed (yet)"
    oc get subscription rhdh -n rhdh-operator -o jsonpath='{range .status.conditions[*]}      {.type}={.status} {.message}{"\n"}{end}' 2>/dev/null || true
    oc get csv -n rhdh-operator 2>/dev/null | sed 's/^/      /' || true
    return 1
  fi
  served=$(oc get crd backstages.rhdh.redhat.com -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{"\n"}{end}')
  latest=$(sort -V <<<"$served" | tail -1)
  current=$(sed -n 's#^apiVersion: rhdh.redhat.com/##p' "$file")
  if [[ -z "$latest" ]]; then
    warn "Backstage CRD serves no version"; return 1
  fi
  if [[ "$current" != "$latest" ]]; then
    sed -i.bak "s#^apiVersion: rhdh.redhat.com/.*#apiVersion: rhdh.redhat.com/${latest}#" "$file" && rm -f "${file}.bak"
    ok "Backstage CR uses rhdh.redhat.com/${latest} (operator serves: $(tr '\n' ' ' <<<"$served"))"
  fi
}

rhdh_render_catalog() {  # catalog-templates/ -> catalog/ with the cluster's apps domain
  local domain=$1 f
  mkdir -p "$(RHDH_DIR)/catalog"
  for f in "$(RHDH_DIR)"/catalog-templates/*.yaml; do
    sed -e "s/__APPS_DOMAIN__/${domain}/g" -e "s/__GITLAB_HOST__/gitlab-gitlab.${domain}/g" \
        -e "s/__DEMO_ADMIN_USER__/${DEMO_ADMIN_USER}/g" "$f" > "$(RHDH_DIR)/catalog/$(basename "$f")"
  done
  ok "catalog rendered for ${domain} ($(grep -h '^kind:' "$(RHDH_DIR)"/catalog/*.yaml | wc -l | tr -d ' ') entities)"
}

sa_token() { oc get secret "$1" -n rhdh -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null; }
sa_token_ready() { [[ -n "$(sa_token "$1")" ]]; }

# Package references differ per Developer Hub release (bundled paths up to 1.9, OCI artifacts
# later), so take them from the dynamic-plugins.default.yaml of the instance that is running.
# Pods of the Developer Hub deployment: the newest one, and the newest one that is Ready.
rhdh_pods_newest_first() {
  oc get pods -n rhdh -l rhdh.redhat.com/app=backstage-developer-hub \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tac 2>/dev/null || \
  oc get pods -n rhdh -l rhdh.redhat.com/app=backstage-developer-hub \
    --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -r 2>/dev/null
}
rhdh_ready_pod() {
  local p
  for p in $(rhdh_pods_newest_first); do
    [[ "$(oc get "$p" -n rhdh -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "True" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# Package references of the default plugin list, as logged by the install-dynamic-plugins init
# container of a running pod: "Skipping disabled dynamic plugin <pkg>", "Installing dynamic plugin
# <pkg>", "Disabling OCI plugin oci://..." (catalog index, 1.9+). These carry a pinned version.
rhdh_default_packages() {
  local pod out
  pod=$(rhdh_ready_pod || true)
  [[ -n "$pod" ]] || return 0
  out=$(oc logs -n rhdh "$pod" -c install-dynamic-plugins 2>/dev/null \
        | grep -E '(Skipping disabled dynamic plugin|Installing dynamic plugin|Disabling OCI plugin|configuration for) ' \
        | grep -oE '(\./dynamic-plugins/dist/[^[:space:]]+|oci://[^[:space:]]+)' || true)
  if [[ -z "$out" ]]; then   # old versions: the file in the running container
    out=$(oc exec -n rhdh "$pod" -c backstage-backend -- sh -c '
            for f in $(find / -name dynamic-plugins.default.yaml -not -path "/proc/*" 2>/dev/null); do cat "$f"; done' 2>/dev/null \
          | grep -E '^[[:space:]]*-?[[:space:]]*package:' \
          | sed -E "s/^[[:space:]]*-?[[:space:]]*package:[[:space:]]*//; s/^[\"']//; s/[\"'][[:space:]]*$//" || true)
  fi
  printf '%s\n' "$out" | awk 'NF && !seen[$0]++'
}

# Plugins of the extensions catalog (Package entities, spec.dynamicArtifact): more than the defaults,
# but their OCI references often have no version (they inherit one from the defaults).
rhdh_extension_packages() {
  local pod; pod=$(rhdh_ready_pod || true)
  [[ -n "$pod" ]] || return 0
  oc exec -n rhdh "$pod" -c backstage-backend -- sh -c \
      'grep -rhoE "dynamicArtifact:[[:space:]]*[^[:space:]]+" /extensions 2>/dev/null' 2>/dev/null \
    | sed -E 's/^dynamicArtifact:[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//' | awk 'NF && !seen[$0]++' || true
}

# Bundled plugin directories present in the running image (a catalog entry may name one that was
# removed in this release).
rhdh_bundled() {
  local pod; pod=$(rhdh_ready_pod || true); [[ -n "$pod" ]] || return 0
  oc exec -n rhdh "$pod" -c backstage-backend -- sh -c 'ls /opt/app-root/src/dynamic-plugins/dist 2>/dev/null' 2>/dev/null || true
}

pkg_is_pinned() {  # local path, digest, or a non-empty tag that is not a placeholder
  [[ "$1" == ./* || "$1" == *@sha256:* ]] && return 0
  local ref=${1#oci://}; ref=${ref%%!*}
  [[ "$ref" =~ :([^/:]+)$ ]] && [[ "${BASH_REMATCH[1]}" != *"{{"* ]]
}
pkg_image() { local r=${1#oci://}; r=${r%%!*}; r=${r%%@*}; [[ "$r" =~ ^(.*/[^/:]+):[^/]*$ ]] && r=${BASH_REMATCH[1]}; echo "$r"; }
pkg_path() { [[ "$1" == *"!"* ]] && echo "${1##*!}" || basename "$(pkg_image "$1")"; }

# An extension reference without a version: pin it as bs_<backstage version>__<plugin version>,
# the tag scheme of the RHDH overlay images. Prints nothing when that cannot be determined.
rhdh_pin_extension() {
  local pkg=$1 pod image bs ver
  pod=$(rhdh_ready_pod || true); [[ -n "$pod" ]] || return 0
  image=$(pkg_image "$pkg")
  bs=$(oc exec -n rhdh "$pod" -c backstage-backend -- sh -c 'cat /opt/app-root/src/backstage.json 2>/dev/null' 2>/dev/null \
       | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  ver=$(oc exec -n rhdh "$pod" -c backstage-backend -- sh -c \
        "f=\$(grep -rl '$(basename "$image")' /extensions 2>/dev/null | head -1); [ -n \"\$f\" ] && cat \"\$f\"" 2>/dev/null \
       | grep -E '^[[:space:]]+version:' | head -1 | sed -E "s/.*version:[[:space:]]*//; s/[\"']//g")
  [[ -n "$bs" && -n "$ver" ]] || return 0
  echo "oci://${image}:bs_${bs}__${ver}!$(pkg_path "$pkg")"
}

rhdh_generate_plugins() {
  local defaults extensions name pkg out ext pinned regexes
  defaults=$(rhdh_default_packages)
  extensions=$(rhdh_extension_packages)
  if [[ -z "$defaults" && -z "$extensions" ]]; then
    warn "could not read the plugin list of Developer Hub (no running pod?); these show what it has:"
    info "  oc logs -n rhdh $(rhdh_ready_pod || echo deploy/backstage-developer-hub) -c install-dynamic-plugins | head -40"
    return 1
  fi
  info "$(grep -c . <<<"$defaults" || true) default and $(grep -c . <<<"$extensions" || true) extension plugin packages known to this Developer Hub"
  out="# Generated by ./deploy.sh rhdh from the plugin lists of the running Developer Hub
# (Developer Hub $(oc get csv -n rhdh-operator -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep '^rhdh-operator' | head -1 | sed 's/^rhdh-operator\.v//' || echo "unknown version")).
# Every package is pinned (digest, tag or bundled path), so nothing depends on version inheritance.
# Commit this file when you deploy with Argo CD.
includes:
  - dynamic-plugins.default.yaml
plugins:"
  local bundled source r alts
  bundled=$(rhdh_bundled)
  while IFS='|' read -r name alts; do
    if [[ "$name" == Argo* && "$(sa_secret_value ARGOCD_PASSWORD)" == "pending" ]]; then
      warn "Argo CD not installed, skipping plugin '${name}'"; continue
    fi
    pkg=""; source=""
    IFS=';' read -r -a regexes <<<"${alts//;;/;}"
    for r in "${regexes[@]}"; do
      [[ -n "$r" ]] || continue
      # 1. the default list: pinned by Red Hat for this release
      pkg=$(grep -E "$r" <<<"$defaults" | while read -r c; do pkg_is_pinned "$c" && { echo "$c"; break; }; done || true)
      [[ -n "$pkg" ]] && break
      # 2. the extensions catalog: bundled paths only if present in this image; OCI pinned as is or by us
      while read -r ext; do
        [[ -n "$ext" ]] || continue
        if [[ "$ext" == ./* ]]; then
          grep -qx "$(basename "$ext")" <<<"$bundled" && { pkg=$ext; source=extensions; break; }
        elif pkg_is_pinned "$ext"; then pkg=$ext; source=extensions; break
        else
          pinned=$(rhdh_pin_extension "$ext")
          [[ -n "$pinned" ]] && { pkg=$pinned; source=extensions; break; }
        fi
      done < <(grep -E "$r" <<<"$extensions" || true)
      [[ -n "$pkg" ]] && break
    done
    if [[ -z "$pkg" ]]; then
      warn "Developer Hub plugin '${name}' is not offered by this Developer Hub version, skipped"
      continue
    fi
    # plugins taken from the extensions catalog are marked: the self-heal drops them first
    out+="
  - package: '${pkg}'${source:+  # ${source}}
    disabled: false"
    ok "plugin ${name}: ${pkg}${source:+ (extensions catalog)}"
  done <<<"$RHDH_PLUGINS"
  printf '%s\n' "$out" > "$(RHDH_DIR)/dynamic-plugins.yaml"
}

# Remove one plugin (by image or path name) from the generated file.
rhdh_drop_plugin() {
  local key=$1 file; file="$(RHDH_DIR)/dynamic-plugins.yaml"
  grep -q -- "$key" "$file" || return 1
  awk -v k="$key" '
    /^  - package:/ { skip = index($0, k) > 0 }
    !skip { print }
    /^    disabled:/ && skip { skip = 0 }' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
}

# Wait for the new Developer Hub pod. When its plugin installer crashes, read why, drop the
# failing plugin and try again (max 3 times), so Developer Hub always ends up running.
rhdh_rollout_with_heal() {
  local attempt pod reason log failing key i
  for attempt in 1 2 3; do
    oc rollout restart deployment/backstage-developer-hub -n rhdh >/dev/null
    info "Developer Hub restarts and installs the plugins (~2-5 min, attempt ${attempt})"
    sleep 20
    for i in $(seq 1 60); do   # up to 15 min
      if oc rollout status deployment/backstage-developer-hub -n rhdh --timeout=5s >/dev/null 2>&1; then
        ok "Developer Hub ready with plugins"; return 0
      fi
      pod=$(rhdh_pods_newest_first | head -1)
      reason=$(oc get "$pod" -n rhdh -o jsonpath='{.status.initContainerStatuses[?(@.name=="install-dynamic-plugins")].state.waiting.reason}{" "}{.status.initContainerStatuses[?(@.name=="install-dynamic-plugins")].lastState.terminated.exitCode}' 2>/dev/null || true)
      if [[ "$reason" == *CrashLoopBackOff* || "$reason" =~ \ [1-9][0-9]*$ ]]; then
        log=$(oc logs -n rhdh "$pod" -c install-dynamic-plugins --previous 2>/dev/null || oc logs -n rhdh "$pod" -c install-dynamic-plugins 2>/dev/null || true)
        failing=$(grep -E '^======= Installing dynamic plugin ' <<<"$log" | tail -1 | sed 's/^======= Installing dynamic plugin //' || true)
        if [[ -z "$failing" ]]; then   # failed before installing: look for one of our packages in the error lines
          local ours
          for ours in $(sed -n "s/^  - package: '\([^']*\)'.*/\1/p" "$(RHDH_DIR)/dynamic-plugins.yaml"); do
            grep -iE 'error|exception|fail|not found|unknown' <<<"$log" | grep -qF "$(pkg_path "$ours")" && { failing=$ours; break; }
          done
        fi
        warn "the plugin installer failed${failing:+ on ${failing}}:"
        grep -iE 'error|exception|failed|not found|denied|unknown' <<<"$log" | tail -4 | sed 's/^/      /' || true
        key=$(pkg_path "${failing:-unknown}")
        if [[ -n "$failing" ]] && rhdh_drop_plugin "$key"; then
          warn "removed ${key} from dynamic-plugins.yaml, retrying without it"
          apply_k "$(RHDH_DIR)" maas-stack >/dev/null
          continue 2
        fi
        if grep -q '  # extensions$' "$(RHDH_DIR)/dynamic-plugins.yaml"; then
          warn "cause not identifiable; retrying without the plugins taken from the extensions catalog"
          awk '/^  - package:/ { skip = /  # extensions$/ } !skip { print } /^    disabled:/ && skip { skip = 0 }' \
            "$(RHDH_DIR)/dynamic-plugins.yaml" > "$(RHDH_DIR)/dynamic-plugins.yaml.tmp" \
            && mv "$(RHDH_DIR)/dynamic-plugins.yaml.tmp" "$(RHDH_DIR)/dynamic-plugins.yaml"
          apply_k "$(RHDH_DIR)" maas-stack >/dev/null
          continue 2
        fi
        warn "cannot tell which plugin to remove; full log: oc logs -n rhdh ${pod} -c install-dynamic-plugins --previous"
        return 1
      fi
      (( i % 4 == 0 )) && info "... still waiting for: Developer Hub with plugins ($((i / 4))/15 min)"
      sleep 15
    done
    warn "Developer Hub not ready after 15 min: oc get pods -n rhdh; oc logs -n rhdh $(rhdh_pods_newest_first | head -1) -c backstage-backend"
    return 1
  done
  return 1
}

# ./deploy.sh rhdh-plugins [keyword...]: what this Developer Hub offers (all, or matching keywords)
rhdh_list_plugins() {
  need oc
  local packages k
  packages=$(rhdh_default_packages)
  [[ -n "$packages" ]] || die "no plugin list found (see: oc logs -n rhdh deploy/backstage-developer-hub -c install-dynamic-plugins)"
  if [[ $# -eq 0 ]]; then
    printf '%s\n' "$packages"
  else
    for k in "$@"; do
      echo "--- ${k}"
      grep -i -- "$k" <<<"$packages" || echo "    (none)"
    done
  fi
}

sa_secret_value() { oc get secret rhdh-secrets -n rhdh -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d 2>/dev/null || true; }

configure_rhdh() {
  need oc
  step "Developer Hub: catalog, credentials and plugins"
  local domain backend argo
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  configure >/dev/null
  rhdh_render_catalog "$domain"
  wait_until 600 "Developer Hub operator (Backstage CRD)" crd_exists backstages.rhdh.redhat.com || true
  rhdh_align_api_version || die "install the Developer Hub operator first: ./deploy.sh stack (or check the subscription above)"
  apply_k "$(RHDH_DIR)" maas-stack >/dev/null && ok "Developer Hub resources applied"

  wait_until 120 "service account tokens issued" bash -c "[[ -n \"\$(oc get secret rhdh-kubernetes-token -n rhdh -o jsonpath='{.data.token}')\" && -n \"\$(oc get secret rhdh-platform-actions-token -n rhdh -o jsonpath='{.data.token}')\" ]]" \
    || die "tokens for rhdh-kubernetes / rhdh-platform-actions were not issued"
  backend=$(sa_secret_value BACKEND_SECRET); [[ -n "$backend" ]] || backend=$(rand_hex)
  argo=$(oc get secret openshift-gitops-cluster -n "$GITOPS_NS" -o jsonpath='{.data.admin\.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  oc create secret generic rhdh-secrets -n rhdh \
    --from-literal=BACKEND_SECRET="$backend" \
    --from-literal=K8S_CLUSTER_NAME=openshift \
    --from-literal=K8S_CLUSTER_URL=https://kubernetes.default.svc \
    --from-literal=K8S_CLUSTER_TOKEN="$(sa_token rhdh-kubernetes-token)" \
    --from-literal=K8S_ACTIONS_TOKEN="$(sa_token rhdh-platform-actions-token)" \
    --from-literal=ARGOCD_PASSWORD="${argo:-pending}" \
    --from-literal=DEVHUB_CLIENT_SECRET="$(oc get secret keycloak-sso-demo -n keycloak -o jsonpath='{.data.DEVHUB_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo pending)" \
    --from-literal=GITLAB_TOKEN="$(gitlab_token || true)" \
    --dry-run=client -o yaml | oc apply --server-side --force-conflicts --field-manager=maas-stack -f - >/dev/null
  ok "rhdh-secrets: Kubernetes read token, template action token, Argo CD $([[ -n "$argo" ]] && echo password || echo 'not installed')"

  wait_until 900 "a running Developer Hub pod (needed to read its plugin catalog)" rhdh_ready_pod \
    || die "Developer Hub is not running: oc get pods -n rhdh"
  rhdh_generate_plugins || die "cannot enable plugins"
  apply_k "$(RHDH_DIR)" maas-stack >/dev/null
  rhdh_rollout_with_heal || warn "Developer Hub is not ready with the new plugins (the previous pod keeps serving)"
  info "Open https://$(grep -E '^RHDH_HOST=' "$RHDH_PARAMS_FILE" | cut -d= -f2-) > Catalog (system ai-demo) and > Create (platform templates)"
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && ! git -C "$ROOT_DIR" diff --quiet -- "$(RHDH_DIR)/catalog" "$(RHDH_DIR)/dynamic-plugins.yaml" 2>/dev/null; then
    info "With Argo CD: commit and push stack/developer-hub/catalog and dynamic-plugins.yaml"
  fi
}

# ----------------------------------------------------------------------------- validate
# End-to-end validation through oc and the routes: every layer, PASS / WARN / FAIL with detail.
# Writes validate-<date>.txt (no secret values). --quick skips the checks that call the models.
V_PASS=0; V_WARN=0; V_FAIL=0; V_OUT=""; V_QUICK=false

v_record() {  # v_record <PASS|WARN|FAIL> <area> <check> <detail>
  local color line
  case "$1" in PASS) color=$G; V_PASS=$((V_PASS + 1)) ;; WARN) color=$Y; V_WARN=$((V_WARN + 1)) ;; *) color=$R; V_FAIL=$((V_FAIL + 1)) ;; esac
  line=$(printf '%-4s  %-14s %-46s %s' "$1" "$2" "$3" "$4")
  echo "${color}${line:0:4}${N}${line:4}"
  printf '%s\n' "$line" >> "$V_OUT"
}

# v_check <area> <check> <command...>: the command prints the detail; exit 0 = PASS, 2 = WARN, else FAIL
v_check() {
  local area=$1 name=$2 out rc; shift 2
  out=$("$@" 2>&1) && rc=0 || rc=$?
  out=$(tr '\n' ' ' <<<"$out" | sed 's/  */ /g' | cut -c1-160)
  case $rc in 0) v_record PASS "$area" "$name" "$out" ;; 2) v_record WARN "$area" "$name" "$out" ;; *) v_record FAIL "$area" "$name" "$out" ;; esac
}

# --- predicates (print a short detail; return 0 ok, 2 warn, 1 fail)
p_ocp() { local v; v=$(oc get clusterversion version -o jsonpath='{.status.desired.version}'); echo "$v"; [[ "$v" == 4.22.* ]] || return 2; }
p_csv() { csv_ok_anywhere "$1" && { echo "Succeeded"; return 0; }; echo "no Succeeded CSV '$1*' (oc get csv -A | grep $1)"; return 1; }
p_cond() {  # p_cond <ns|-> <kind/name> <condition>
  local nsarg=() st
  [[ "$1" != "-" ]] && nsarg=(-n "$1")
  st=$(oc get "$2" ${nsarg[@]+"${nsarg[@]}"} -o jsonpath="{.status.conditions[?(@.type==\"$3\")].status}" 2>/dev/null || true)
  echo "$3=${st:-missing}"; [[ "$st" == "True" ]]
}
p_phase() { local nsarg=() ph; [[ "$1" != "-" ]] && nsarg=(-n "$1"); ph=$(oc get "$2" ${nsarg[@]+"${nsarg[@]}"} -o jsonpath='{.status.phase}' 2>/dev/null || true); echo "phase=${ph:-missing}"; [[ "$ph" == "$3" ]]; }
p_deploy() {  # p_deploy <ns> <deployment>
  local r; r=$(oc get deploy "$2" -n "$1" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null || true)
  echo "ready ${r:-missing}"; [[ -n "$r" && "${r%%/*}" == "${r##*/}" && "${r%%/*}" != "0" && "${r%%/*}" != "" ]]
}
p_exists() { oc get "$2" -n "$1" >/dev/null 2>&1 && { echo "present"; return 0; }; echo "missing: oc get $2 -n $1"; return 1; }
p_http() {  # p_http <url> [expected codes regex]
  local code; code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "$1" || true)
  echo "HTTP ${code} ${1}"; [[ "$code" =~ ^(${2:-200})$ ]]
}
p_connector_tables() {
  local t; t=$(oc get kafkaconnector inventory-postgres -n kafka -o jsonpath='{.spec.config.table\.include\.list}' 2>/dev/null || true)
  echo "$t"; [[ "$t" == *coffee.orders* ]] || return 2
}
p_rhdh_plugins() {
  local cfg found="" missing="" k
  cfg=$(oc get configmap dynamic-plugins-rhdh -n rhdh -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || true)
  for k in kubernetes-backend topology tekton argo-cd-backend argocd http-request; do
    if grep -q -- "$k" <<<"$cfg"; then found+="$k "; else missing+="$k "; fi
  done
  echo "enabled: ${found:-none}${missing:+ | missing: $missing}"
  [[ -z "$missing" ]] && return 0; [[ -n "$found" ]] && return 2; return 1
}
p_rhdh_installed() {  # plugins actually installed by the init container
  local log n
  log=$(oc logs -n rhdh "$(rhdh_pods_newest_first | head -1)" -c install-dynamic-plugins 2>/dev/null || true)
  n=$(grep -c "Successfully installed dynamic plugin" <<<"$log" || true)
  echo "${n} plugins installed; $(grep -oE 'Successfully installed dynamic plugin [^ ]*(tekton|argo|http-request|topology)[^ ]*' <<<"$log" | sed 's#.*/##; s#@sha256:[0-9a-f]*##' | tr '\n' ' ')"
  [[ "$n" -gt 0 ]]
}
p_rhdh_auth() {
  local cfg; cfg=$(oc get configmap app-config-rhdh -n rhdh -o jsonpath='{.data.app-config\.yaml}' 2>/dev/null || true)
  grep -q "signInPage: oidc" <<<"$cfg" && grep -q "realms/demo" <<<"$cfg" && { echo "oidc via Keycloak realm demo"; return 0; }
  echo "app-config has no Keycloak sign-in (./deploy.sh rhdh)"; return 1
}
p_secret_keys() {  # p_secret_keys <ns> <secret> <key...>: present and not "pending"
  local ns=$1 sec=$2 k v bad=""; shift 2
  oc get secret "$sec" -n "$ns" >/dev/null 2>&1 || { echo "secret $ns/$sec missing"; return 1; }
  for k in "$@"; do
    v=$(oc get secret "$sec" -n "$ns" -o jsonpath="{.data.$k}" 2>/dev/null | base64 -d 2>/dev/null || true)
    [[ -z "$v" || "$v" == "pending" ]] && bad+="$k "
  done
  [[ -z "$bad" ]] && { echo "keys set: $*"; return 0; }; echo "not set: $bad"; return 2
}
p_maas_call() {
  local host key code
  host=$(param MAAS_HOSTNAME)
  key=$(curl -sk --max-time 60 -X POST "https://${host}/maas-api/v1/api-keys" -H "Authorization: Bearer $(oc whoami -t)" \
        -H "Content-Type: application/json" -d '{"name":"validate","subscription":"small-models-free","expiresIn":"1h"}' \
        | sed -n 's/.*"key":"\([^"]*\)".*/\1/p')
  [[ -n "$key" ]] || { echo "could not create a MaaS API key"; return 1; }
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 180 "https://${host}/maas-models/$1/v1/chat/completions" \
        -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" \
        -d "{\"model\":\"$1\",\"max_tokens\":5,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" || true)
  echo "chat completion HTTP ${code}"; [[ "$code" == "200" ]]
}
p_probe() {
  local out bad
  out=$(curl -sk --max-time 60 "$1/api/mesh/probe" || true)
  [[ "$out" == \[* ]] || { echo "no probe result: ${out:0:80}"; return 1; }
  if command -v jq >/dev/null; then
    bad=$(jq -r '[.[] | select(.allowed != .expectedAllowed) | .target] | join(",")' <<<"$out")
    echo "$(jq -r 'map("\(.target)=\(if .allowed then "allow" else "deny" end)") | join(" ")' <<<"$out")"
    [[ -z "$bad" ]] || { echo "unexpected: $bad"; return 1; }
  else
    echo "probe returned (install jq for details)"; return 2
  fi
}
p_dashboard_ds() {
  oc get persesglobaldatasource thanos-querier-global-datasource >/dev/null 2>&1 || { echo "no PersesGlobalDatasource (./deploy.sh dashboards)"; return 1; }
  local last; last=$(oc get jobs -n "$MONITORING_NS" --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name}={.status.succeeded}{"\n"}{end}' 2>/dev/null | grep perses-auth-fix | tail -1)
  [[ "$last" == *=1 ]] && { echo "datasource present, last auth fix ${last%%=*} succeeded"; return 0; }
  echo "datasource present, auth fix not succeeded yet (${last:-no job}): oc logs -n ${MONITORING_NS} job/perses-auth-fix-now"; return 2
}
p_mlflow_tracing() {
  local exp; exp=$(oc get configmap mlflow-tracing -n tracing-system -o jsonpath='{.data.MLFLOW_EXPERIMENT_ID}' 2>/dev/null || true)
  [[ -n "$exp" ]] || { echo "not configured (./deploy.sh app mlflow)"; return 2; }
  echo "experiment ${exp}, workspace $(oc get configmap mlflow-tracing -n tracing-system -o jsonpath='{.data.MLFLOW_WORKSPACE}')"
}
# What Developer Hub's Kubernetes / Topology tabs see: its own token, the component's label selector.
p_rhdh_sees() {  # p_rhdh_sees <namespace> <component>
  local token n
  token=$(sa_token rhdh-kubernetes-token)
  [[ -n "$token" ]] || { echo "no rhdh-kubernetes token (./deploy.sh rhdh)"; return 1; }
  n=$(oc --token="$token" get deploy -n "$1" -l "backstage.io/kubernetes-id=$2" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$n" -gt 0 ]]; then echo "${n} deployment(s) visible to Developer Hub"; return 0; fi
  if oc get deploy -n "$1" -l "backstage.io/kubernetes-id=$2" --no-headers 2>/dev/null | grep -q .; then
    echo "workloads exist but Developer Hub's token cannot list them (./deploy.sh rhdh)"; return 1
  fi
  echo "no workloads labelled backstage.io/kubernetes-id=$2 in $1 (not deployed: ./deploy.sh app all)"; return 1
}

p_tssc() {  # p_tssc <what>
  case "$1" in
    rhtas) [[ "$(oc get securesign rhtas -n trusted-artifact-signer -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]] \
             && echo "Securesign rhtas Ready" || { echo "not Ready: oc get securesign rhtas -n trusted-artifact-signer -o yaml"; return 1; } ;;
    tpa)   local h; h=$(oc get route -n trusted-profile-analyzer --selector app.kubernetes.io/name=server -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
           [[ -n "$h" ]] && echo "https://${h}" || { echo "not installed (needs helm): pipeline simulates the TPA step"; return 2; } ;;
    ci)    oc get pipeline trusted-supply-chain -n tssc-ci >/dev/null 2>&1 && oc get secret cosign-signing -n tssc-ci >/dev/null 2>&1 \
             && oc get istag tssc-tools:latest -n tssc-ci >/dev/null 2>&1 && echo "pipeline, tools image, cosign key" \
             || { echo "incomplete: ./deploy.sh tssc setup"; return 1; } ;;
    last)  local r; r=$(oc get pipelinerun -n tssc-ci --sort-by=.metadata.creationTimestamp -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[0].reason}{"\n"}{end}' 2>/dev/null | tail -1)
           [[ -z "$r" ]] && { echo "no run yet: ./deploy.sh tssc run"; return 2; }
           [[ "$r" == *Succeeded* || "$r" == *Completed* ]] && echo "$r" || { echo "$r"; return 2; } ;;
  esac
}

p_coffee_menu() {
  local out; out=$(curl -sk --max-time 30 "$1/api/menu" || true)
  grep -q '"source":"live"' <<<"$out" && { echo "menu $(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' <<<"$out") live"; return 0; }
  echo "menu not live: ${out:0:100}"; return 2
}
p_rag_ask() {
  local out; out=$(curl -sk --max-time 240 -X POST "$1/api/ask" -H 'Content-Type: application/json' \
    -d '{"question":"What does the model router do?","model":"qwen"}' || true)
  grep -q '"answer":"[^"]' <<<"$out" && { echo "answer received ($(sed -n 's/.*"generationMs":\([0-9]*\).*/\1/p' <<<"$out") ms)"; return 0; }
  echo "no answer: ${out:0:120}"; return 1
}
p_coffee_order() {
  local q id o
  q=$(curl -sk --max-time 240 -X POST "$1/api/interpret" -H 'Content-Type: application/json' -d '{"text":"One cappuccino, please."}' || true)
  id=$(sed -n 's/.*"quote":{"id":"\([^"]*\)".*/\1/p' <<<"$q")
  [[ -n "$id" ]] || { echo "no quote: ${q:0:120}"; return 1; }
  o=$(curl -sk --max-time 30 -X POST "$1/api/orders" -H 'Content-Type: application/json' -d "{\"quoteId\":\"${id}\"}" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
  [[ -n "$o" ]] || { echo "order not placed"; return 1; }
  sleep 8
  local n; n=$(curl -sk --max-time 30 "$1/api/audit?orderId=${o}" | grep -o '"operation"' | wc -l | tr -d ' ')
  echo "order ${o} placed, ${n} audit events in MongoDB"; [[ "$n" -ge 2 ]] || return 2
}

validate() {
  need oc; need curl
  oc whoami >/dev/null 2>&1 || die "not logged in, run 'oc login' first"
  V_OUT="validate-$(date +%Y%m%d-%H%M%S).txt"
  : > "$V_OUT"
  local domain demo coffee
  domain=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
  demo="https://ai-demo-ai-demo.${domain}"; coffee="https://coffee-ai-demo.${domain}"
  [[ -n "$RHOAI_VERSION" ]] || RHOAI_VERSION=$(oc get csv -n redhat-ods-operator -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null \
    | grep '^rhods-operator' | head -1 | awk '{print $2}' | cut -d. -f1,2 || true)
  step "Validating the platform on $(oc whoami --show-server) as $(oc whoami)"
  printf '%-4s  %-14s %-46s %s\n' STAT AREA CHECK DETAIL | tee -a "$V_OUT"

  v_check cluster   "OpenShift version"                        p_ocp
  local ns prefix label sub
  while IFS='|' read -r ns prefix label sub; do v_check operators "$label" p_csv "$prefix"; done <<<"$STACK_CSVS"

  v_check rhoai     "DataScienceCluster Ready"                 p_phase - datasciencecluster/default-dsc Ready
  v_check rhoai     "DSCInitialization Ready"                  p_phase - dscinitialization/default-dsci Ready
  v_check rhoai     "MLflow instance"                          p_exists redhat-ods-applications mlflow/mlflow
  [[ "$RHOAI_VERSION" == "3.4" ]] && v_check rhoai "observability dashboard datasource"  p_dashboard_ds
  v_check maas      "Gateway programmed"                       p_cond openshift-ingress gateway/maas-default-gateway Programmed
  v_check maas      "maas-api"                                 p_deploy "$(maas_api_ns 2>/dev/null || echo redhat-ods-applications)" maas-api
  v_check models    "gemma-3-270m-it Ready"                    p_cond "$MODELS_NS" llminferenceservice/gemma-3-270m-it Ready
  v_check models    "qwen3-0-6b Ready"                         p_cond "$MODELS_NS" llminferenceservice/qwen3-0-6b Ready
  v_check models    "MaaSModelRef gemma"                       p_phase "$MODELS_NS" maasmodelref/gemma-3-270m-it Ready
  v_check models    "MaaSModelRef qwen"                        p_phase "$MODELS_NS" maasmodelref/qwen3-0-6b Ready
  if [[ "$V_QUICK" != true ]]; then
    v_check models  "qwen answers through MaaS"                p_maas_call qwen3-0-6b
    v_check models  "gemma answers through MaaS"               p_maas_call gemma-3-270m-it
  fi
  v_check playground "LlamaStackDistribution ai-tenants"      p_phase "$PLAYGROUND_NS" llamastackdistribution/lsd-genai-playground Ready
  v_check playground "MaaS key for the playground"            p_secret_keys "$PLAYGROUND_NS" lsd-maas-api-keys VLLM_API_TOKEN_1 VLLM_API_TOKEN_2

  v_check tracing   "Tempo"                                    p_cond tracing-system tempomonolithic/platform Ready
  v_check tracing   "OpenTelemetry collector"                  p_deploy tracing-system otel-collector
  v_check tracing   "Console traces plugin"                    p_exists default uiplugin/distributed-tracing
  v_check tracing   "AI traces to MLflow (coffee shop)"        p_mlflow_tracing
  v_check mesh      "Istio control plane"                      p_cond - istio/default Ready
  v_check mesh      "Istio CNI"                                p_cond - istiocni/default Ready
  v_check mesh      "Kiali"                                    p_deploy istio-system kiali
  v_check mesh      "Bookinfo demo"                            p_deploy mesh-demo productpage-v1
  v_check kafka     "Kafka cluster"                            p_cond kafka kafka/platform Ready
  v_check kafka     "Kafka Connect (Debezium)"                 p_cond kafka kafkaconnect/debezium Ready
  v_check kafka     "Debezium connector"                       p_cond kafka kafkaconnector/inventory-postgres Ready
  v_check kafka     "connector captures coffee tables"         p_connector_tables
  v_check gitops    "Argo CD"                                  p_deploy "$GITOPS_NS" openshift-gitops-server
  v_check gitops    "Argo Rollouts"                            rollouts_ready
  v_check gitops    "Tekton (TektonConfig)"                    p_cond - tektonconfig/config Ready

  v_check sso       "Keycloak platform-sso"                    p_cond keycloak keycloak/platform-sso Ready
  v_check sso       "realm demo imported"                      p_cond keycloak keycloakrealmimport/demo-realm Done
  v_check sso       "realm demo reachable (OIDC discovery)"    p_http "https://platform-sso-keycloak.${domain}/realms/demo/.well-known/openid-configuration"
  v_check gitlab    "GitLab"                                   p_deploy gitlab gitlab
  v_check gitlab    "sign-in page"                             p_http "https://gitlab-gitlab.${domain}/users/sign_in"
  v_check gitlab    "project ai-platform/platform"             p_http "https://gitlab-gitlab.${domain}/api/v4/projects/ai-platform%2Fplatform"
  v_check rhdh      "Developer Hub"                            p_deploy rhdh backstage-developer-hub
  v_check rhdh      "health"                                   p_http "https://backstage-developer-hub-rhdh.${domain}/.backstage/health/v1/readiness"
  v_check rhdh      "Keycloak sign-in configured"              p_rhdh_auth
  v_check rhdh      "secrets wired (OIDC, GitLab, tokens)"     p_secret_keys rhdh rhdh-secrets DEVHUB_CLIENT_SECRET GITLAB_TOKEN K8S_CLUSTER_TOKEN K8S_ACTIONS_TOKEN ARGOCD_PASSWORD
  v_check rhdh      "plugins configured"                       p_rhdh_plugins
  v_check rhdh      "plugins installed"                        p_rhdh_installed
  local comp
  for comp in frontend rag-service model-router coffee-shop coffee-menu; do
    v_check rhdh    "Topology data: ${comp}"                   p_rhdh_sees ai-demo "$comp"
  done
  if oc get namespace tssc-ci >/dev/null 2>&1; then   # only once ./deploy.sh tssc setup ran
    v_check tssc    "Trusted Artifact Signer"                  p_tssc rhtas
    v_check tssc    "Trusted Profile Analyzer"                 p_tssc tpa
    v_check tssc    "pipeline trusted-supply-chain"            p_tssc ci
    v_check tssc    "last supply chain run"                    p_tssc last
  fi

  local d
  for d in frontend rag-service-v1 rag-service-v2 model-router orders-service projection-service mongodb coffee-shop coffee-menu-v1 coffee-menu-v2 ai-demo-gateway; do
    v_check apps    "$d"                                       p_deploy ai-demo "$d"
  done
  v_check apps      "demo UI"                                  p_http "$demo/"
  v_check apps      "coffee shop UI"                           p_http "$coffee/"
  v_check mesh      "who-can-access-who probe"                 p_probe "$demo"
  v_check mesh      "plaintext rejected (STRICT mTLS)"         p_exists ai-demo peerauthentication/default
  v_check coffee    "menu through the mesh"                    p_coffee_menu "$coffee"
  if [[ "$V_QUICK" != true ]]; then
    v_check apps    "RAG answer (qwen)"                        p_rag_ask "$demo"
    v_check coffee  "order + audit trail (CDC)"                p_coffee_order "$coffee"
  fi

  echo
  printf 'PASS %d   WARN %d   FAIL %d\n' "$V_PASS" "$V_WARN" "$V_FAIL" | tee -a "$V_OUT"
  ok "report written to ${V_OUT} (no secret values); share it when something fails"
  [[ "$V_FAIL" -eq 0 ]]
}

# ----------------------------------------------------------------------------- debug bundle
# One file with everything needed to diagnose Developer Hub plugins and the models.
# No Secret contents are collected.
collect_debug() {
  need oc
  local out pod
  out="debug-$(date +%Y%m%d-%H%M%S).txt"
  sec() { printf '\n\n######## %s\n' "$*"; }
  run() { printf '$ %s\n' "$*"; "$@" 2>&1 || true; }
  step "Collecting diagnostics into ${out} (1-2 min)"
  {
    sec "versions"
    run oc version
    run oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
    run oc get csv -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase
    sec "nodes and capacity"
    run oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,GPU:.status.allocatable.nvidia\.com/gpu
    run oc adm top nodes

    sec "developer hub: deployment and pods"
    run oc get backstage,deploy,pods -n rhdh -o wide
    run oc get deploy backstage-developer-hub -n rhdh -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name} image={.image}{"\n"}{range .env[*]}  {.name}={.value}{"\n"}{end}{end}'
    sec "developer hub: our dynamic plugins ConfigMap"
    run oc get configmap dynamic-plugins-rhdh -n rhdh -o jsonpath='{.data.dynamic-plugins\.yaml}'
    local p
    for p in $(rhdh_pods_newest_first | head -2); do
      sec "developer hub: install-dynamic-plugins log of ${p}"
      oc logs -n rhdh "$p" -c install-dynamic-plugins 2>&1 | grep -iE 'plugin|catalog|index|error|warn|fail|denied|not found' | head -300 || true
      sec "developer hub: previous (crashed) install-dynamic-plugins log of ${p}"
      oc logs -n rhdh "$p" -c install-dynamic-plugins --previous 2>&1 | tail -60 || true
    done
    sec "developer hub: files in the pod"
    pod=$(rhdh_ready_pod || true)
    [[ -n "$pod" ]] && run oc exec -n rhdh "$pod" -c backstage-backend -- sh -c 'ls /opt/app-root/src/dynamic-plugins-root | head -100; echo "---"; find / \( -name "dynamic-plugins*.yaml" -o -iname "*catalog-index*" -o -name "index.json" \) -not -path "/proc/*" 2>/dev/null | head -30'
    sec "developer hub: backend errors (last 40)"
    oc logs -n rhdh deploy/backstage-developer-hub -c backstage-backend --tail=400 2>&1 | grep -iE 'error|fail|plugin' | tail -40 || true

    sec "models: resources"
    run oc get llminferenceservice,maasmodelref -n maas-models -o wide
    run oc get llminferenceservice -n maas-models -o jsonpath='{range .items[*]}{.metadata.name}:{"\n"}{range .status.conditions[*]}  {.type}={.status} {.reason} {.message}{"\n"}{end}{end}'
    run oc get pods,deploy -n maas-models -o wide
    sec "models: pod details"
    for pod in $(oc get pods -n maas-models -o name 2>/dev/null); do
      run oc get "$pod" -n maas-models -o jsonpath='{.metadata.name}{"\n"}{range .status.initContainerStatuses[*]}  init {.name}: ready={.ready} restarts={.restartCount} state={.state}{"\n"}{end}{range .status.containerStatuses[*]}  {.name}: ready={.ready} restarts={.restartCount} state={.state}{"\n"}{end}'
      echo "-- storage-initializer log"; oc logs -n maas-models "$pod" -c storage-initializer --tail=15 2>&1 || true
      echo "-- main log"; oc logs -n maas-models "$pod" -c main --tail=30 2>&1 || true
    done
    sec "models: events"
    run oc get events -n maas-models --sort-by=.lastTimestamp
    sec "maas: gateway and api"
    run oc get gateway -A
    run oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
  } > "$out" 2>&1
  ok "written ${out} ($(wc -l < "$out" | tr -d ' ') lines). It contains no secret values; upload it in the chat."
}

# ----------------------------------------------------------------------------- cdc demo
cdc_demo() {
  need oc
  step "Debezium CDC demo"
  local db product
  db=$(oc get pod -n kafka -l app=inventory-db -o name 2>/dev/null | head -1)
  [[ -n "$db" ]] || die "inventory-db not found in namespace kafka"
  product="demo-$(date +%H%M%S)"
  oc exec -n kafka "$db" -- psql -q -d inventory \
    -c "INSERT INTO inventory.orders (customer_id, product, quantity) VALUES (1, '${product}', 1);" >/dev/null
  ok "inserted order '${product}' into inventory.orders"
  info "reading topic inventory.inventory.orders (10s)..."
  local events
  events=$(oc exec -n kafka platform-dual-role-0 -c kafka -- /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server localhost:9092 --topic inventory.inventory.orders --from-beginning --timeout-ms 10000 2>/dev/null || true)
  if grep -q "$product" <<<"$events"; then
    ok "Debezium captured it:"
    grep "$product" <<<"$events" | tail -1 | { if command -v jq >/dev/null; then jq -c '{op: .payload.op, after: .payload.after}'; else cat; fi; } | sed 's/^/      /'
  else
    warn "event not seen yet: oc get kafkaconnector inventory-postgres -n kafka -o yaml"
  fi
}

# ----------------------------------------------------------------------------- oc mode
deploy_oc() {
  preflight
  [[ "$WITH_OPERATORS" == true ]] && install_operators
  configure
  bootstrap

  step "Platform 1/5: Kuadrant + Authorino TLS"
  apply_k "${ROOT_DIR}/platform/10-kuadrant"
  apply_k "${ROOT_DIR}/platform/20-authorino-tls"
  # Creating the GatewayClass makes OpenShift install its Gateway API provider,
  # which Kuadrant needs before it reports Ready
  oc apply --server-side --force-conflicts --field-manager=maas-deploy -f "${ROOT_DIR}/platform/30-gateway/gatewayclass.yaml"
  wait_kuadrant

  step "Platform 2/5: Authorino trusts the service CA"
  wait_until 300 "Authorino serving cert issued" oc get secret authorino-server-cert -n kuadrant-system
  authorino_tls_env

  step "Platform 3/5: MaaS gateway"
  apply_k "${ROOT_DIR}/platform/30-gateway"
  wait_until 300 "Gateway programmed" \
    oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=10s || true

  if [[ -z "$POSTGRES_URL" ]]; then
    step "Platform 4/5: PostgreSQL (PoC)"
    apply_k "${ROOT_DIR}/platform/40-postgres"
    wait_until 600 "PostgreSQL ready" oc rollout status deployment/postgres -n "$DB_NS" --timeout=10s
  else
    step "Platform 4/5: PostgreSQL skipped (external database)"
  fi

  step "Platform 5/5: enable MaaS in OpenShift AI ${RHOAI_VERSION}"
  apply_k "${ROOT_DIR}/platform/50-rhoai/rhoai-${RHOAI_VERSION}"
  maas_api_glue
  playground_glue
  playground_instance
  sleep 10  # the dashboard operator sometimes resets flags right after enablement
  [[ "$(oc get odhdashboardconfig odh-dashboard-config -n "$RHOAI_APPS_NS" -o jsonpath='{.spec.dashboardConfig.modelAsService}')" == "true" ]] \
    || apply_k "${ROOT_DIR}/platform/50-rhoai/rhoai-${RHOAI_VERSION}"

  step "Models: Gemma 3 270M + Qwen3 0.6B (${ACCELERATOR})"
  apply_k "${ROOT_DIR}/models/overlays/$(models_overlay)"

  step "Governance: auth policy + free/premium subscriptions"
  apply_k "${ROOT_DIR}/governance"

  # runs while the models download
  [[ "$WITH_OBSERVABILITY" == true ]] && deploy_observability_oc

  wait_models
  wait_modelrefs
  done_banner
  if [[ -n "$FAILED_MODELS" ]]; then
    [[ "$STACK" == true ]] || die "not serving:${FAILED_MODELS} (details above). Fix, then re-run: ./deploy.sh wait"
    STACK_ISSUES="${STACK_ISSUES} models(${FAILED_MODELS# })"
  fi
}

# ----------------------------------------------------------------------------- argocd mode
# Repo coordinates for Argo CD + check that the cluster specific files are committed and pushed
git_context() {
  need git
  git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "${ROOT_DIR} must be inside a git repository that Argo CD can reach"
  REPO_URL=${REPO_URL:-$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || true)}
  REVISION=${REVISION:-$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD)}
  REPO_PATH=$(git -C "$ROOT_DIR" rev-parse --show-prefix)
  [[ -n "$REPO_URL" ]] || die "no git remote 'origin', pass --repo-url"
  local files=("$PARAMS_FILE" "$OBS_PARAMS_FILE" "$RHDH_PARAMS_FILE" "$PLAYGROUND_PARAMS_FILE" "$SSO_PARAMS_FILE" "$GITLAB_PARAMS_FILE") before
  before=$(cat "${files[@]}")
  configure
  if [[ "$before" != "$(cat "${files[@]}")" ]] || ! git -C "$ROOT_DIR" diff --quiet HEAD -- "${files[@]}"; then
    die "cluster-params.env files were updated for this cluster. Commit and push them, then re-run"
  fi
  if git -C "$ROOT_DIR" rev-parse '@{u}' >/dev/null 2>&1 && [[ "$(git -C "$ROOT_DIR" rev-list '@{u}..HEAD' --count)" != "0" ]]; then
    die "local commits are not pushed yet, Argo CD would not see them. Run 'git push' first"
  fi
  info "repo ${REPO_URL} @ ${REVISION} path '${REPO_PATH:-/}'"
}

render_apps() {
  sed -e "s#__REPO_URL__#${REPO_URL}#g" -e "s#__REVISION__#${REVISION}#g" -e "s#__REPO_PATH__#${REPO_PATH}#g" \
      -e "s#__RHOAI_VERSION__#${RHOAI_VERSION}#g" -e "s#__ACCELERATOR__#$(models_overlay)#g" "$1"
}

deploy_argocd() {
  preflight
  need git
  oc get namespace "$GITOPS_NS" >/dev/null 2>&1 || die "namespace ${GITOPS_NS} not found: install the Red Hat OpenShift GitOps operator first"

  git_context
  bootstrap

  step "Granting Argo CD permissions"
  oc apply -f "${ROOT_DIR}/argocd/rbac.yaml" >/dev/null && ok "ClusterRoleBinding openshift-gitops-maas-cluster-admin"

  step "Creating Argo CD Applications"
  if [[ "$WITH_OPERATORS" == true ]]; then
    render_apps "${ROOT_DIR}/argocd/operators-application.yaml" | oc apply -f -
  fi
  render_apps "${ROOT_DIR}/argocd/applications.yaml" | oc apply -f -
  [[ "$WITH_OBSERVABILITY" == true ]] && render_apps "${ROOT_DIR}/argocd/observability-application.yaml" | oc apply -f -

  step "Post-sync glue (operator owned objects)"
  wait_platform
  authorino_tls_env
  maas_api_glue
  playground_glue
  playground_maas_keys   # the LlamaStackDistribution itself comes from the platform Application
  [[ "$WITH_OBSERVABILITY" == true ]] && observability_glue
  wait_models
  wait_modelrefs
  [[ -z "$FAILED_MODELS" ]] || warn "not serving:${FAILED_MODELS} (details above). Fix, then re-run: ./deploy.sh wait"
  info "Argo CD console: https://$(oc get route openshift-gitops-server -n "$GITOPS_NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
  done_banner
}

# ----------------------------------------------------------------------------- test
test_models() {
  need oc; need curl; need jq
  local host key models body code m id url
  host=$(param MAAS_HOSTNAME)
  [[ "$host" == *CHANGE-ME* ]] && die "run './deploy.sh configure' first"
  step "Testing MaaS at https://${host}"
  # -k: lab clusters often use the self-signed default ingress cert
  local CURL=(curl -sk --max-time 120)

  key=$("${CURL[@]}" -X POST "https://${host}/maas-api/v1/api-keys" \
      -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
      -d '{"name":"deploy-sh-test","subscription":"small-models-free","expiresIn":"1h"}' | jq -r '.key // empty')
  [[ -n "$key" ]] || die "could not create an API key (check: oc get maassubscription -n ${MAAS_POLICY_NS})"
  ok "API key created (subscription small-models-free, expires in 1h)"

  models=$("${CURL[@]}" "https://${host}/v1/models" -H "Authorization: Bearer ${key}")
  info "models visible to this key: $(jq -r '[.data[].id] | join(", ")' <<<"$models" 2>/dev/null || echo "$models")"

  for m in "${MODELS[@]}"; do
    id=$(jq -r --arg m "$m" '[.data[]?.id | select(endswith($m))][0] // empty' <<<"$models" 2>/dev/null || true)
    id=${id:-$m}
    body=$(jq -n --arg id "$id" '{model:$id, max_tokens:60, messages:[{role:"user", content:"In one sentence: what is OpenShift AI?"}]}')
    url="https://${host}/v1/chat/completions"                         # body based routing
    code=$("${CURL[@]}" -o /tmp/maas-resp.json -w '%{http_code}' "$url" \
      -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "$body")
    if [[ "$code" == "404" ]]; then                                    # path based routing
      url="https://${host}/${MODELS_NS}/${m}/v1/chat/completions"
      body=$(jq --arg m "$m" '.model=$m' <<<"$body")
      code=$("${CURL[@]}" -o /tmp/maas-resp.json -w '%{http_code}' "$url" \
        -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "$body")
    fi
    if [[ "$code" == "200" ]]; then
      ok "${m}: $(jq -r '.choices[0].message.content' /tmp/maas-resp.json | tr '\n' ' ' | cut -c1-160)"
      info "tokens used: $(jq -c '.usage' /tmp/maas-resp.json)"
    else
      warn "${m}: HTTP ${code} from ${url}: $(head -c 300 /tmp/maas-resp.json)"
    fi
  done
  echo
  info "Use it from any OpenAI client:"
  info "  base_url = https://${host}/v1   api_key = <MaaS API key, sk-oai-...>"
}

# ----------------------------------------------------------------------------- usage
# Token consumption straight from the Limitador counters that enforce the subscriptions
# (authorized_hits = tokens, authorized_calls = requests, limited_calls = HTTP 429s),
# labelled by the MaaS TelemetryPolicy.
usage_report() {
  need oc; need curl; need jq
  local host token q
  host=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}')
  token=$(oc whoami -t)
  step "MaaS usage over the last ${USAGE_WINDOW}"
  prom() {
    curl -sk -G "https://${host}/api/v1/query" -H "Authorization: Bearer ${token}" --data-urlencode "query=$1" \
      | jq -r '.data.result[]? | [(.metric.model // "-"), (.metric.subscription // "-"), (.metric.user // "-"), (.value[1] | tonumber | floor)] | @tsv'
  }
  local by="model, subscription, user"
  {
    printf 'METRIC\tMODEL\tSUBSCRIPTION\tUSER\tVALUE\n'
    for q in authorized_hits:tokens authorized_calls:requests limited_calls:rate-limited; do
      prom "sum by (${by}) (increase(${q%%:*}[${USAGE_WINDOW}]))" | sed "s/^/${q##*:}\t/"
    done
  } | column -t -s $'\t'
  info "Empty? Send some traffic first (./deploy.sh test) and allow ~1 min for scraping."
  info "Dashboards: RHOAI dashboard > Observe & monitor (3.5) / Models as a service > Observability (3.4)"
}

# ----------------------------------------------------------------------------- status / render / destroy
status() {
  need oc
  step "MaaS status"
  oc get datasciencecluster default-dsc -o jsonpath='{"kserve.modelsAsService: "}{.spec.components.kserve.modelsAsService.managementState}{"\naigateway.modelsAsAService: "}{.spec.components.aigateway.modelsAsAService.managementState}{"\n"}' || true
  oc get kuadrant -n kuadrant-system 2>/dev/null || true
  oc get gateway maas-default-gateway -n openshift-ingress 2>/dev/null || true
  oc get tenants.maas.opendatahub.io -n "$MAAS_POLICY_NS" 2>/dev/null || true
  oc get llminferenceservice,maasmodelref -n "$MODELS_NS" -o wide 2>/dev/null || true
  oc get maassubscription,maasauthpolicy -n "$MAAS_POLICY_NS" 2>/dev/null || true
  oc get pods -n "$MODELS_NS" 2>/dev/null || true
  oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress 2>/dev/null || true
  oc get lokistack -n "$MONITORING_NS" 2>/dev/null || true
  oc get persesdashboard -n "$MONITORING_NS" 2>/dev/null || true
  oc get tempomonolithic -n tracing-system 2>/dev/null || true
  oc get istio,istiocni 2>/dev/null || true
  oc get kiali -n istio-system 2>/dev/null || true
  oc get kafka,kafkaconnect,kafkaconnector -n kafka 2>/dev/null || true
  oc get backstage -n rhdh 2>/dev/null || true
  oc get rolloutmanager -A 2>/dev/null || true
  oc get mlflow 2>/dev/null || true
  oc get applications.argoproj.io -n "$GITOPS_NS" 2>/dev/null | grep -E 'NAME|maas-|stack-' || true
}

render() {
  local k; k=$(command -v kustomize >/dev/null && echo "kustomize build" || echo "oc kustomize")
  local v=${RHOAI_VERSION:-3.4}
  for d in "platform/overlays/rhoai-${v}" "models/overlays/$(models_overlay)" governance "observability/overlays/rhoai-${v}"; do
    echo "# ---------------- ${d}"; $k "${ROOT_DIR}/${d}"
  done
}

destroy() {
  need oc
  step "Removing MaaS small models setup"
  if oc get application.argoproj.io maas-platform -n "$GITOPS_NS" >/dev/null 2>&1; then
    oc delete application.argoproj.io maas-observability maas-governance maas-models maas-platform -n "$GITOPS_NS" --ignore-not-found --wait=true
    oc delete application.argoproj.io maas-operators -n "$GITOPS_NS" --ignore-not-found
    oc delete -f "${ROOT_DIR}/argocd/rbac.yaml" --ignore-not-found
  else
    oc delete -k "${ROOT_DIR}/governance" --ignore-not-found
    oc delete -k "${ROOT_DIR}/models/overlays/$(models_overlay)" --ignore-not-found --wait=true
    oc delete route maas-default-gateway-https -n openshift-ingress --ignore-not-found
    oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found
    oc delete configmap maas-gateway-options -n openshift-ingress --ignore-not-found
    oc delete namespace "$DB_NS" --ignore-not-found
    oc delete lokistack usage -n "$MONITORING_NS" --ignore-not-found
    oc delete deployment/minio service/minio job/minio-create-bucket pvc/minio-data -n "$MONITORING_NS" --ignore-not-found
  fi
  oc delete secret minio-secret -n "$MONITORING_NS" --ignore-not-found
  oc delete secret maas-db-config -n "$RHOAI_APPS_NS" --ignore-not-found
  oc delete namespace "$MODELS_NS" --ignore-not-found
  if [[ "$DISABLE_MAAS" == true ]]; then
    preflight
    if [[ "$RHOAI_VERSION" == "3.4" ]]; then
      oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"kserve":{"modelsAsService":{"managementState":"Removed"}}}}}'
    else
      oc patch datasciencecluster default-dsc --type=merge -p '{"spec":{"components":{"aigateway":{"modelsAsAService":{"managementState":"Removed"}}}}}'
    fi
    ok "MaaS set to Removed in default-dsc"
  fi
  info "Kept on purpose (possibly shared): Kuadrant instance, GatewayClass openshift-default, Authorino TLS"
  info "settings, observability operators and the DSCI monitoring stack"
}

done_banner() {
  echo
  step "Done"
  info "Endpoint : https://$(param MAAS_HOSTNAME)/v1"
  info "Test     : ./deploy.sh test"
  info "API keys : RHOAI dashboard > Gen AI studio > API keys, or POST /maas-api/v1/api-keys"
  info "Premium  : oc adm groups add-users maas-premium-users <user>"
  info "Playground: RHOAI dashboard > Gen AI studio > Playground, project ${PLAYGROUND_NS} (ready-made, both models)"
  [[ "$WITH_OBSERVABILITY" == true ]] && info "Usage    : ./deploy.sh usage   (dashboards: RHOAI dashboard > Observe & monitor)"
  true
}

# ----------------------------------------------------------------------------- main
[[ $# -ge 1 ]] || usage 1
CMD=$1; shift
# the demo apps have their own CLI: hand over all remaining arguments untouched
[[ "$CMD" == "app" ]] && exec "${ROOT_DIR}/app/demo.sh" "$@"
[[ "$CMD" == "tssc" ]] && exec "${ROOT_DIR}/stack/tssc/tssc.sh" "$@"
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --rhoai-version) RHOAI_VERSION=$2; shift 2 ;;
    --accelerator)   ACCELERATOR=$2; shift 2 ;;
    --with-operators) WITH_OPERATORS=true; shift ;;
    --postgres-url)  POSTGRES_URL=$2; shift 2 ;;
    --repo-url)      REPO_URL=$2; shift 2 ;;
    --revision)      REVISION=$2; shift 2 ;;
    --disable-maas)  DISABLE_MAAS=true; shift ;;
    --no-observability) WITH_OBSERVABILITY=false; shift ;;
    --capture-user)  CAPTURE_USER=true; shift ;;
    --model-timeout) MODEL_TIMEOUT_MIN=$2; shift 2 ;;
    --window)        USAGE_WINDOW=$2; shift 2 ;;
    --to)            SWITCH_TO=$2; shift 2 ;;
    --yes)           ASSUME_YES=true; shift ;;
    --no-deploy)     SWITCH_DEPLOY=false; shift ;;
    --vllm-tracing)  VLLM_TRACING=true; shift ;;
    --quick)         V_QUICK=true; shift ;;
    -h|--help)       usage 0 ;;
    -*) die "unknown option: $1" ;;
    *)  POSITIONAL+=("$1"); shift ;;
  esac
done
[[ "$ACCELERATOR" == "cpu" || "$ACCELERATOR" == "gpu" ]] || die "--accelerator must be cpu or gpu"

case $CMD in
  configure) need oc; configure ;;
  oc)        deploy_oc ;;
  argocd)    deploy_argocd ;;
  test)      test_models ;;
  wait)      need oc; wait_models; wait_modelrefs; [[ -z "$FAILED_MODELS" ]] || exit 1 ;;
  usage)     usage_report ;;
  observability) preflight; configure; bootstrap; deploy_observability_oc ;;
  playground) preflight; enable_playground; playground_instance ;;
  hf-check)  hf_check_cmd ;;
  switch-rhoai) switch_rhoai ;;
  stack)     deploy_stack_oc ;;
  stack-argocd) deploy_stack_argocd ;;
  cdc-demo)  cdc_demo ;;
  rhdh)      configure_rhdh ;;
  gitlab)    gitlab_seed ;;
  sso)       need oc; STACK=true; configure >/dev/null; stack_bootstrap; apply_layer stack/keycloak "Keycloak (single sign-on)" keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org; apply_layer stack/gitlab "GitLab"
             info "next: ./deploy.sh gitlab (once GitLab is up, ~10 min), then ./deploy.sh rhdh" ;;
  debug)     collect_debug ;;
  dashboards) need oc; preflight; dashboard_datasource ;;
  validate)  for a in ${POSITIONAL[@]+"${POSITIONAL[@]}"}; do [[ "$a" == "quick" ]] && V_QUICK=true; done
             validate || exit 1 ;;
  models)    need oc; preflight; apply_k "${ROOT_DIR}/models/overlays/$(models_overlay)"; wait_models; wait_modelrefs; [[ -z "$FAILED_MODELS" ]] || exit 1 ;;
  rhdh-plugins) rhdh_list_plugins ${POSITIONAL[@]+"${POSITIONAL[@]}"} ;;
  urls)      STACK=true; stack_urls ;;
  status)    status ;;
  render)    render ;;
  destroy)   destroy ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
