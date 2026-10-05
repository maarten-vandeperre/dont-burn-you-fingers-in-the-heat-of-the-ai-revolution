#!/usr/bin/env bash
# =============================================================================
# Trusted software supply chain on the AI platform
#
#   ./deploy.sh tssc setup [--tpa-importers] [--skip-tpa] [--skip-devspaces] [--rebuild-tools]
#   ./deploy.sh tssc run [--revision REV] [--service NAME] [--allow-unsigned] [--gate fail]
#   ./deploy.sh tssc verify      verify the released image: signature, SBOM attestation, Rekor
#   ./deploy.sh tssc urls        RHTAS, RHTPA, Dev Spaces, pipeline and GitLab links
#   ./deploy.sh tssc destroy     remove the CI namespace, RHTPA and the RHTAS instance
#
# setup installs (each step is repeatable):
#   1. operators: Trusted Artifact Signer, Dev Spaces (Pipelines, GitOps, Keycloak: platform stack)
#   2. Keycloak realm demo: client trusted-artifact-signer (keyless signing), RHTPA clients,
#      scopes and roles
#   3. Trusted Artifact Signer (Securesign: Fulcio, Rekor, TUF, CT log)
#   4. Trusted Profile Analyzer 2 (Helm chart, needs helm 3.17+ on this machine)
#   5. Dev Spaces (CheCluster, a GitLab token for your workspaces)
#   6. CI namespace tssc-ci: tools image, cosign key, pipeline, GitLab push webhook
#   7. stack/tssc/generated/signing.env (used in Dev Spaces), pushed to GitLab
#
# Needs: the platform stack (./deploy.sh stack) and the demo apps (./deploy.sh app all).
# Advanced Cluster Security is optional: Secret acs-central (endpoint, token) in tssc-ci
# turns the simulated ACS checks into real roxctl checks.
# =============================================================================
set -Eeuo pipefail

TSSC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TSSC_DIR}/../.." && pwd)"
CI_NS="tssc-ci"
TAS_NS="trusted-artifact-signer"
TPA_NS="trusted-profile-analyzer"
DS_NS="openshift-devspaces"
REALM="demo"
SIGNER="admin@demo.example.com"
GITLAB_PARAMS_FILE="${ROOT_DIR}/stack/gitlab/cluster-params.env"
GITLAB_PROJECT_PATH="ai-platform/platform"
SIGNING_ENV="${TSSC_DIR}/generated/signing.env"
TOOLS_IMAGE="image-registry.openshift-image-registry.svc:5000/${CI_NS}/tssc-tools:latest"

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
  local start detail; start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - start > timeout )); then warn "timed out after ${timeout}s waiting for: ${label}"; return 1; fi
    detail=""
    if declare -F wait_detail >/dev/null; then detail=$(wait_detail 2>/dev/null || true); detail=${detail:+ — ${detail}}; fi
    info "... waiting for: ${label} ($(( ($(date +%s) - start) / 60 ))/$(( timeout / 60 )) min)${detail}"
    sleep 20
  done
}
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"; }
domain() { oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'; }
csv_ok() { oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep -q "^$2.* Succeeded"; }

# ----------------------------------------------------------------------------- Keycloak admin API
KC_HOST="" KC_TOKEN=""
kc_login() {
  KC_HOST=$(oc get route platform-sso -n keycloak -o jsonpath='{.spec.host}' 2>/dev/null) \
    || die "Keycloak route keycloak/platform-sso not found: run ./deploy.sh stack (or ./deploy.sh sso) first"
  local user pass
  user=$(oc get secret keycloak-sso-bootstrap-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d)
  pass=$(oc get secret keycloak-sso-bootstrap-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
  KC_TOKEN=$(curl -sk --max-time 30 -d grant_type=password -d client_id=admin-cli \
    --data-urlencode "username=${user}" --data-urlencode "password=${pass}" \
    "https://${KC_HOST}/realms/master/protocol/openid-connect/token" | jq -r '.access_token // empty')
  [[ -n "$KC_TOKEN" ]] || die "could not log in to Keycloak as the bootstrap admin"
}
kc() {  # kc <method> <path under /admin/realms/demo> [json]
  local args=(-sk --max-time 30 -X "$1" -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(-d "$3")
  curl "${args[@]}" "https://${KC_HOST}/admin/realms/${REALM}$2"
}
kc_client_id() { kc GET "/clients?clientId=$1" | jq -r '.[0].id // empty'; }
kc_client_upsert() {  # kc_client_upsert <json>  (prints the internal id)
  local cid id; cid=$(jq -r .clientId <<<"$1"); id=$(kc_client_id "$cid")
  if [[ -n "$id" ]]; then kc PUT "/clients/${id}" "$(jq --arg id "$id" '. + {id: $id}' <<<"$1")" >/dev/null
  else kc POST /clients "$1" >/dev/null; id=$(kc_client_id "$cid"); fi
  [[ -n "$id" ]] || die "could not create Keycloak client ${cid}"
  echo "$id"
}
kc_role() { kc GET "/roles/$1"; }
kc_scope_id() { kc GET /client-scopes | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }

keycloak_setup() {
  step "Keycloak realm ${REALM}: signing identity and Trusted Profile Analyzer access"
  kc_login
  local d; d=$(domain)

  # keyless signing (gitsign, cosign): public client, PKCE; urn:...:oob is the copy-the-code flow
  # used in Dev Spaces, localhost for laptops
  kc_client_upsert '{"clientId":"trusted-artifact-signer","name":"Trusted Artifact Signer","enabled":true,
    "publicClient":true,"standardFlowEnabled":true,"directAccessGrantsEnabled":false,
    "redirectUris":["urn:ietf:wg:oauth:2.0:oob","http://localhost/*","http://127.0.0.1/*"],
    "webOrigins":["+"],"attributes":{"pkce.code.challenge.method":"S256"}}' >/dev/null
  ok "client trusted-artifact-signer (signer identity: ${SIGNER})"

  # Trusted Profile Analyzer: roles, document scopes (write scopes only for trustify-manager)
  local r s sid
  for r in trustify-user trustify-manager trustify-admin; do kc POST /roles "{\"name\":\"${r}\"}" >/dev/null; done
  kc POST "/roles/default-roles-${REALM}/composites" "[$(kc_role trustify-user)]" >/dev/null
  for s in read:document create:document update:document delete:document; do
    [[ -n "$(kc_scope_id "$s")" ]] || kc POST /client-scopes \
      "{\"name\":\"${s}\",\"protocol\":\"openid-connect\",\"attributes\":{\"include.in.token.scope\":\"true\"}}" >/dev/null
    if [[ "$s" != read:document ]]; then
      kc POST "/client-scopes/$(kc_scope_id "$s")/scope-mappings/realm" "[$(kc_role trustify-manager)]" >/dev/null
    fi
  done
  local aud='"protocolMappers":[{"name":"rhtpa-audience","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.client.audience":"CLIENT","access.token.claim":"true","id.token.claim":"false"}}]'
  local fe cli
  fe=$(kc_client_upsert "{\"clientId\":\"rhtpa-frontend\",\"name\":\"Trusted Profile Analyzer UI\",\"enabled\":true,
    \"publicClient\":true,\"standardFlowEnabled\":true,\"implicitFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
    \"redirectUris\":[\"https://server-${TPA_NS}.${d}/*\"],\"webOrigins\":[\"*\"],${aud//CLIENT/rhtpa-frontend}}")
  cli=$(kc_client_upsert "{\"clientId\":\"rhtpa-cli\",\"name\":\"Trusted Profile Analyzer API (pipelines)\",\"enabled\":true,
    \"publicClient\":false,\"serviceAccountsEnabled\":true,\"standardFlowEnabled\":false,\"directAccessGrantsEnabled\":false,
    ${aud//CLIENT/rhtpa-cli}}")
  for s in read:document create:document update:document delete:document; do
    sid=$(kc_scope_id "$s")
    kc PUT "/clients/${fe}/default-client-scopes/${sid}" >/dev/null
    kc PUT "/clients/${cli}/default-client-scopes/${sid}" >/dev/null
  done
  local sa admin
  sa=$(kc GET "/clients/${cli}/service-account-user" | jq -r .id)
  kc POST "/users/${sa}/role-mappings/realm" "[$(kc_role trustify-manager)]" >/dev/null
  admin=$(kc GET "/users?email=${SIGNER}&exact=true" | jq -r '.[0].id // empty')
  [[ -n "$admin" ]] && kc POST "/users/${admin}/role-mappings/realm" "[$(kc_role trustify-manager),$(kc_role trustify-admin)]" >/dev/null
  TPA_CLIENT_SECRET=$(kc GET "/clients/${cli}/client-secret" | jq -r .value)
  ok "clients rhtpa-frontend and rhtpa-cli, scopes *:document, roles trustify-* (${SIGNER}: manager)"
}

# ----------------------------------------------------------------------------- 1. operators
operators() {
  step "Operators: Trusted Artifact Signer, Dev Spaces"
  oc apply -k "${TSSC_DIR}/operators" >/dev/null
  wait_until 900 "Trusted Artifact Signer operator" csv_ok openshift-operators rhtas-operator && ok "Trusted Artifact Signer operator"
  wait_until 900 "Dev Spaces operator" csv_ok openshift-operators devspacesoperator && ok "Dev Spaces operator"
}

# ----------------------------------------------------------------------------- 3. RHTAS
TUF_URL="" FULCIO_URL="" REKOR_URL="" CLI_SERVER="" OIDC_ISSUER=""
rhtas_urls() {
  TUF_URL=$(oc get tuf -n "$TAS_NS" -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)
  FULCIO_URL=$(oc get fulcio -n "$TAS_NS" -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)
  REKOR_URL=$(oc get rekor -n "$TAS_NS" -o jsonpath='{.items[0].status.url}' 2>/dev/null || true)
  local host
  host=$(oc get routes -A -o jsonpath='{range .items[*]}{.metadata.name} {.spec.host}{"\n"}{end}' 2>/dev/null \
    | awk '$1 ~ /cli-server/ {print $2; exit}')
  CLI_SERVER=${host:+https://${host}}
  OIDC_ISSUER="https://$(oc get route platform-sso -n keycloak -o jsonpath='{.spec.host}')/realms/${REALM}"
}
rhtas_ready() { [[ "$(oc get securesign rhtas -n "$TAS_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]; }
rhtas() {
  step "Trusted Artifact Signer (Fulcio, Rekor, TUF)"
  wait_until 300 "Securesign API" oc get crd securesigns.rhtas.redhat.com || die "Securesign CRD missing"
  local versions template issuer
  versions=$(oc get crd securesigns.rhtas.redhat.com -o jsonpath='{.spec.versions[?(@.served==true)].name}')
  if [[ " $versions " == *" v1 "* ]]; then template=securesign-v1.yaml; else template=securesign-v1alpha1.yaml; fi
  oc get namespace "$TAS_NS" >/dev/null 2>&1 || oc create namespace "$TAS_NS" >/dev/null
  issuer="https://$(oc get route platform-sso -n keycloak -o jsonpath='{.spec.host}')/realms/${REALM}"
  sed "s#__ISSUER__#${issuer}#g" "${TSSC_DIR}/rhtas/${template}" | oc apply -f - >/dev/null
  ok "Securesign rhtas (${template%.yaml}, OIDC issuer ${issuer})"
  wait_detail() {
    oc get securesign rhtas -n "$TAS_NS" -o jsonpath='{range .status.conditions[?(@.status!="True")]}{.type}={.reason} {end}'
  }
  wait_until 1200 "Fulcio, Rekor, TUF, CT log ready" rhtas_ready && ok "Trusted Artifact Signer ready" || {
    warn "not Ready yet: oc get securesign rhtas -n ${TAS_NS} -o yaml"
    oc get securesign rhtas -n "$TAS_NS" -o jsonpath='{range .status.conditions[?(@.status!="True")]}{"    "}{.type}={.status} {.reason} {.message}{"\n"}{end}' || true
  }
  unset -f wait_detail
  rhtas_urls
  info "TUF ${TUF_URL:-?} | Fulcio ${FULCIO_URL:-?} | Rekor ${REKOR_URL:-?} | CLI ${CLI_SERVER:-?}"
}

# ----------------------------------------------------------------------------- 4. RHTPA
TPA_URL="" TPA_CLIENT_SECRET=""
tpa_route() { oc get route -n "$TPA_NS" --selector app.kubernetes.io/name=server -o jsonpath='{.items[0].spec.host}' 2>/dev/null; }
rhtpa() {
  step "Trusted Profile Analyzer 2 (Helm)"
  if ! command -v helm >/dev/null; then
    warn "helm not found: Trusted Profile Analyzer skipped, the pipeline simulates that step (brew install helm, then rerun)"
    return 0
  fi
  local d; d=$(domain)
  oc get namespace "$TPA_NS" >/dev/null 2>&1 || oc create namespace "$TPA_NS" >/dev/null
  if ! oc get secret rhtpa-db -n "$TPA_NS" >/dev/null 2>&1; then
    oc create secret generic rhtpa-db -n "$TPA_NS" --from-literal=username=trustify \
      --from-literal=password="$(rand)" --from-literal=admin-password="$(rand)" >/dev/null
  fi
  local pw apw
  pw=$(oc get secret rhtpa-db -n "$TPA_NS" -o jsonpath='{.data.password}' | base64 -d)
  apw=$(oc get secret rhtpa-db -n "$TPA_NS" -o jsonpath='{.data.admin-password}' | base64 -d)
  oc create secret generic postgresql-credentials -n "$TPA_NS" --from-literal=db.host="rhtpa-db.${TPA_NS}.svc" \
    --from-literal=db.port=5432 --from-literal=db.name=trustify --from-literal=db.user=trustify \
    --from-literal=db.password="$pw" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc create secret generic postgresql-admin-credentials -n "$TPA_NS" --from-literal=db.host="rhtpa-db.${TPA_NS}.svc" \
    --from-literal=db.port=5432 --from-literal=db.name=postgres --from-literal=db.user=postgres \
    --from-literal=db.password="$apw" --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc create secret generic oidc-cli -n "$TPA_NS" --from-literal=client-secret="$TPA_CLIENT_SECRET" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc apply -f "${TSSC_DIR}/rhtpa/postgres.yaml" >/dev/null
  wait_until 300 "RHTPA database" oc rollout status deploy/rhtpa-db -n "$TPA_NS" --timeout=10s && ok "PostgreSQL rhtpa-db"

  local values importer_flags=()
  values=$(mktemp); sed "s#__ISSUER__#${OIDC_ISSUER}#g" "${TSSC_DIR}/rhtpa/values-rhtpa.yaml" > "$values"
  if [[ "$TPA_IMPORTERS" == true ]]; then
    importer_flags=(--set modules.createImporters.importers.osv-github.osv.disabled=false
                    --set modules.createImporters.importers.cve.cve.disabled=false)
    info "vulnerability importers ON (CVE list + GitHub advisories: several GB, first import takes hours)"
  fi
  helm repo add openshift-helm-charts https://charts.openshift.io/ >/dev/null 2>&1 || true
  helm repo update openshift-helm-charts >/dev/null
  helm upgrade --install redhat-trusted-profile-analyzer openshift-helm-charts/redhat-trusted-profile-analyzer \
    -n "$TPA_NS" --values "$values" --values "${TSSC_DIR}/rhtpa/values-importers.yaml" \
    --set-string appDomain="-${TPA_NS}.${d}" "${importer_flags[@]}" >/dev/null
  rm -f "$values"
  ok "helm release redhat-trusted-profile-analyzer"
  wait_until 900 "RHTPA server route" tpa_route || true
  local host; host=$(tpa_route || true)
  TPA_URL=${host:+https://${host}}
  [[ -n "$TPA_URL" ]] && ok "Trusted Profile Analyzer: ${TPA_URL} (sign in: admin / your demo password)" \
    || warn "no RHTPA route yet: oc get pods,routes -n ${TPA_NS}"
}

# ----------------------------------------------------------------------------- 5. Dev Spaces
devspaces() {
  step "Dev Spaces"
  wait_until 300 "CheCluster API" oc get crd checlusters.org.eclipse.che || { warn "Dev Spaces API missing"; return 0; }
  oc get namespace "$DS_NS" >/dev/null 2>&1 || oc create namespace "$DS_NS" >/dev/null
  oc apply -f "${TSSC_DIR}/devspaces/checluster.yaml" >/dev/null
  wait_until 1200 "Dev Spaces URL" bash -c "oc get checluster devspaces -n ${DS_NS} -o jsonpath='{.status.cheURL}' | grep -q https" || true
  local url; url=$(oc get checluster devspaces -n "$DS_NS" -o jsonpath='{.status.cheURL}' 2>/dev/null || true)
  ok "Dev Spaces: ${url:-starting}"

  # A GitLab token for the current OpenShift user's workspaces (clone + push without prompts)
  local user uid ns token host
  user=$(oc whoami); uid=$(oc get user "$user" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  token=$(oc get secret gitlab-automation-token -n gitlab -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  host=$(grep -E '^GITLAB_HOST=' "$GITLAB_PARAMS_FILE" 2>/dev/null | cut -d= -f2- || true)
  if [[ -z "$uid" || -z "$token" || -z "$host" ]]; then
    warn "no GitLab token for Dev Spaces (GitLab not set up?): add one in Dev Spaces > User Preferences > Personal Access Tokens"
    return 0
  fi
  ns="${user}-devspaces"
  oc get namespace "$ns" >/dev/null 2>&1 || oc create namespace "$ns" >/dev/null
  oc label namespace "$ns" app.kubernetes.io/part-of=che.eclipse.org app.kubernetes.io/component=workspaces-namespace --overwrite >/dev/null
  oc annotate namespace "$ns" "che.eclipse.org/username=${user}" --overwrite >/dev/null
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: personal-access-token-gitlab
  namespace: ${ns}
  labels:
    app.kubernetes.io/component: scm-personal-access-token
    app.kubernetes.io/part-of: che.eclipse.org
  annotations:
    che.eclipse.org/che-userid: ${uid}
    che.eclipse.org/scm-personal-access-token-name: gitlab
    che.eclipse.org/scm-url: https://${host}
stringData:
  token: ${token}
EOF
  ok "GitLab token for the workspaces of ${user} (namespace ${ns})"
}

# ----------------------------------------------------------------------------- 6. CI
gitlab_api() {
  local token host; token=$(oc get secret gitlab-automation-token -n gitlab -o jsonpath='{.data.token}' | base64 -d)
  host=$(grep -E '^GITLAB_HOST=' "$GITLAB_PARAMS_FILE" | cut -d= -f2-)
  local args=(-sk --max-time 60 -X "$1" -H "PRIVATE-TOKEN: ${token}" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(-d "$3")
  curl "${args[@]}" "https://${host}/api/v4$2"
}
ci() {
  step "CI namespace ${CI_NS}: tools image, signing key, pipeline, webhook"
  oc get namespace ai-demo >/dev/null 2>&1 || die "namespace ai-demo not found: deploy the demo apps first (./deploy.sh app all)"
  oc apply -k "${TSSC_DIR}/ci" >/dev/null
  ok "pipeline trusted-supply-chain, trigger gitlab-push, RBAC"

  local d; d=$(domain)
  oc create configmap tssc-config -n "$CI_NS" \
    --from-literal=TUF_URL="$TUF_URL" --from-literal=FULCIO_URL="$FULCIO_URL" --from-literal=REKOR_URL="$REKOR_URL" \
    --from-literal=OIDC_ISSUER="$OIDC_ISSUER" --from-literal=TPA_URL="$TPA_URL" \
    --from-literal=KEYCLOAK_TOKEN_URL="${OIDC_ISSUER}/protocol/openid-connect/token" \
    --from-literal=ARGOCD_APP=ai-demo --from-literal=ARGOCD_NAMESPACE=openshift-gitops \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  local webhook
  webhook=$(oc get secret tssc-secrets -n "$CI_NS" -o jsonpath='{.data.gitlab-webhook-token}' 2>/dev/null | base64 -d 2>/dev/null || true)
  webhook=${webhook:-$(rand 32)}
  oc create secret generic tssc-secrets -n "$CI_NS" --from-literal=tpa-client-secret="${TPA_CLIENT_SECRET}" \
    --from-literal=gitlab-webhook-token="$webhook" --dry-run=client -o yaml | oc apply -f - >/dev/null
  ok "ConfigMap tssc-config, Secret tssc-secrets"

  # tools image: Sigstore clients from this cluster's CLI server
  if [[ -z "$CLI_SERVER" ]]; then die "RHTAS CLI server route not found (Trusted Artifact Signer not ready?)"; fi
  oc patch bc tssc-tools -n "$CI_NS" --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/strategy/dockerStrategy/buildArgs/0/value\",\"value\":\"${CLI_SERVER}\"}]" >/dev/null
  if [[ "$REBUILD_TOOLS" == true ]] || ! oc get istag tssc-tools:latest -n "$CI_NS" >/dev/null 2>&1; then
    info "building the tools image (cosign, gitsign, rekor-cli, syft, oc; ~3 min)"
    oc start-build tssc-tools -n "$CI_NS" --wait >/dev/null || die "tools image build failed: oc logs -f bc/tssc-tools -n ${CI_NS}"
  fi
  ok "tools image ${TOOLS_IMAGE}"

  # cosign key pair, generated in the cluster straight into a Secret (never on this machine)
  if ! oc get secret cosign-signing -n "$CI_NS" >/dev/null 2>&1; then
    oc delete job cosign-keygen -n "$CI_NS" --ignore-not-found >/dev/null
    oc apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cosign-keygen
  namespace: ${CI_NS}
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: 300
  template:
    spec:
      serviceAccountName: pipeline
      restartPolicy: Never
      containers:
        - name: keygen
          image: ${TOOLS_IMAGE}
          env:
            - {name: COSIGN_PASSWORD, value: "$(rand 32)"}
          command: ["sh", "-c", "cosign generate-key-pair k8s://${CI_NS}/cosign-signing"]
EOF
    oc wait job/cosign-keygen -n "$CI_NS" --for=condition=Complete --timeout=300s >/dev/null \
      || die "cosign key generation failed: oc logs job/cosign-keygen -n ${CI_NS}"
  fi
  ok "cosign key pair in Secret ${CI_NS}/cosign-signing (public key: oc get secret cosign-signing -n ${CI_NS} -o jsonpath='{.data.cosign\\.pub}' | base64 -d)"

  # GitLab push webhook -> EventListener
  local el pid hooks
  el=$(oc get route gitlab-push -n "$CI_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -z "$el" ]] || ! oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1; then
    warn "no GitLab webhook (GitLab or the EventListener route missing): start runs with ./deploy.sh tssc run"
    return 0
  fi
  gitlab_api PUT /application/settings '{"allow_local_requests_from_web_hooks_and_services":true}' >/dev/null
  pid=$(gitlab_api GET "/projects/${GITLAB_PROJECT_PATH//\//%2F}" | jq -r '.id // empty')
  [[ -n "$pid" ]] || { warn "GitLab project ${GITLAB_PROJECT_PATH} not found: ./deploy.sh gitlab, then rerun"; return 0; }
  hooks=$(gitlab_api GET "/projects/${pid}/hooks" | jq -r '.[].url')
  if ! grep -qx "https://${el}" <<<"$hooks"; then
    gitlab_api POST "/projects/${pid}/hooks" "{\"url\":\"https://${el}\",\"token\":\"${webhook}\",\"push_events\":true,\"enable_ssl_verification\":false}" >/dev/null
  fi
  ok "GitLab webhook: pushes to ${GITLAB_PROJECT_PATH} (main, app/coffee-menu/) start the pipeline"
}

signing_env() {
  step "Signing settings for Dev Spaces (stack/tssc/generated/signing.env)"
  mkdir -p "$(dirname "$SIGNING_ENV")"
  cat > "$SIGNING_ENV" <<EOF
# Written by stack/tssc/tssc.sh setup: the Trusted Artifact Signer endpoints of this cluster.
# Used by stack/tssc/devspaces/sign-setup.sh in Dev Spaces (devfile command "1. Set up commit signing").
TUF_URL=${TUF_URL}
FULCIO_URL=${FULCIO_URL}
REKOR_URL=${REKOR_URL}
OIDC_ISSUER=${OIDC_ISSUER}
OIDC_CLIENT_ID=trusted-artifact-signer
CLI_SERVER=${CLI_SERVER}
SIGNER_IDENTITY=${SIGNER}
EOF
  ok "written"
  if oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1; then
    info "pushing the repository (incl. devfile.yaml and signing.env) to GitLab"
    "${ROOT_DIR}/deploy.sh" gitlab | grep -E 'OK|WARN|ERROR' || true
  fi
}

# ----------------------------------------------------------------------------- commands
setup() {
  need oc; need curl; need jq
  oc whoami >/dev/null 2>&1 || die "not logged in: oc login"
  operators
  keycloak_setup
  rhtas
  [[ "$SKIP_TPA" == true ]] && info "Trusted Profile Analyzer skipped (--skip-tpa)" || rhtpa
  [[ "$SKIP_DEVSPACES" == true ]] && info "Dev Spaces skipped (--skip-devspaces)" || devspaces
  ci
  signing_env
  urls
  echo
  echo "${B}Next:${N} sign a commit in Dev Spaces and push it, or start a run now: ./deploy.sh tssc run"
  echo "      Demo guide: docs/demos/08-trusted-software-supply-chain.md"
}

run() {
  need oc
  local revision=main service=coffee-menu require=true gate=warn git_url host name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --revision) revision=$2; shift 2 ;;
      --service) service=$2; shift 2 ;;
      --allow-unsigned) require=false; shift ;;
      --gate) gate=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
  host=$(grep -E '^GITLAB_HOST=' "$GITLAB_PARAMS_FILE" 2>/dev/null | cut -d= -f2- || true)
  [[ -n "$host" ]] || die "no GitLab host in ${GITLAB_PARAMS_FILE}: ./deploy.sh configure"
  git_url="https://${host}/${GITLAB_PROJECT_PATH}.git"
  name=$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: ${service}-manual-
  namespace: ${CI_NS}
  labels:
    app.kubernetes.io/part-of: trusted-software-supply-chain
spec:
  pipelineRef:
    name: trusted-supply-chain
  params:
    - {name: git-url, value: "${git_url}"}
    - {name: git-revision, value: "${revision}"}
    - {name: service, value: "${service}"}
    - {name: require-signed-commit, value: "${require}"}
    - {name: vulnerability-gate, value: "${gate}"}
  taskRunTemplate:
    serviceAccountName: pipeline
  workspaces:
    - name: source
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 5Gi
    - name: cosign
      secret:
        secretName: cosign-signing
EOF
)
  step "PipelineRun ${name} (${service} @ ${revision}, signed commit required: ${require}, gate: ${gate})"
  local console; console=$(oc whoami --show-console 2>/dev/null || true)
  info "console: ${console}/k8s/ns/${CI_NS}/tekton.dev~v1~PipelineRun/${name}"
  if command -v tkn >/dev/null; then tkn pipelinerun logs -f "$name" -n "$CI_NS"; return; fi
  local seen="" status
  while true; do
    status=$(oc get pipelinerun "$name" -n "$CI_NS" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null || true)
    local line
    line=$(oc get taskruns -n "$CI_NS" -l "tekton.dev/pipelineRun=${name}" \
      -o jsonpath='{range .items[*]}{.metadata.labels.tekton\.dev/pipelineTask}={.status.conditions[0].reason} {end}' 2>/dev/null || true)
    [[ "$line" != "$seen" ]] && { info "$line"; seen=$line; }
    case "$status" in Succeeded|Completed) ok "pipeline succeeded"; return 0 ;;
      Failed|PipelineRunTimeout|Cancelled) die "pipeline ${status}: oc logs -n ${CI_NS} -l tekton.dev/pipelineRun=${name} --all-containers --tail=30" ;; esac
    sleep 10
  done
}

verify() {
  need oc
  local service=${1:-coffee-menu} pod
  pod="tssc-verify-$(rand 5 | tr '[:upper:]' '[:lower:]')"
  step "Verify ai-demo/${service}:release (signature, SBOM attestation, transparency log)"
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${CI_NS}
spec:
  serviceAccountName: pipeline
  restartPolicy: Never
  containers:
    - name: verify
      image: ${TOOLS_IMAGE}
      envFrom: [{configMapRef: {name: tssc-config}}]
      env: [{name: IMAGE, value: "image-registry.openshift-image-registry.svc:5000/ai-demo/${service}:release"}]
      volumeMounts: [{name: keys, mountPath: /keys}]
      command:
        - bash
        - -c
        - |
          set -uo pipefail
          token=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
          mkdir -p \$HOME/.docker
          printf '{"auths":{"image-registry.openshift-image-registry.svc:5000":{"auth":"%s"}}}' "\$(printf 'pipeline:%s' "\$token" | base64 -w0)" > \$HOME/.docker/config.json
          cosign initialize --mirror "\$TUF_URL" --root "\$TUF_URL/root.json" >/dev/null
          echo "== signature"
          cosign verify --key /keys/cosign.pub --rekor-url "\$REKOR_URL" --allow-insecure-registry "\$IMAGE" \
            | jq -r '.[] | "digest \(.critical.image["docker-manifest-digest"])  Rekor log index \(.optional.Bundle.Payload.logIndex // "?")"'
          echo "== SBOM attestation (CycloneDX)"
          cosign verify-attestation --key /keys/cosign.pub --type cyclonedx --rekor-url "\$REKOR_URL" --allow-insecure-registry "\$IMAGE" \
            | jq -r '.payload' | head -1 | base64 -d | jq -r '"components in the SBOM: \(.predicate.components | length)"'
  volumes:
    - name: keys
      secret:
        secretName: cosign-signing
        items: [{key: cosign.pub, path: cosign.pub}]
EOF
  oc wait pod/"$pod" -n "$CI_NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s >/dev/null 2>&1 || true
  oc logs "$pod" -n "$CI_NS" 2>/dev/null | sed 's/^/    /'
  oc delete pod "$pod" -n "$CI_NS" --wait=false >/dev/null 2>&1 || true
}

urls() {
  step "Trusted software supply chain: URLs"
  rhtas_urls
  local tpa ds gl el console
  tpa=$(tpa_route || true); ds=$(oc get checluster devspaces -n "$DS_NS" -o jsonpath='{.status.cheURL}' 2>/dev/null || true)
  gl=$(grep -E '^GITLAB_HOST=' "$GITLAB_PARAMS_FILE" 2>/dev/null | cut -d= -f2- || true)
  el=$(oc get route gitlab-push -n "$CI_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  console=$(oc whoami --show-console 2>/dev/null || true)
  info "Dev Spaces workspace : ${ds:+${ds}/#https://${gl}/${GITLAB_PROJECT_PATH}.git}"
  info "GitLab repository    : ${gl:+https://${gl}/${GITLAB_PROJECT_PATH}}"
  info "Pipeline runs        : ${console}/pipelines/ns/${CI_NS}"
  info "Trusted Profile Analyzer : ${tpa:+https://${tpa}}"
  info "Rekor (transparency log) : ${REKOR_URL}"
  info "TUF (trust root)         : ${TUF_URL}"
  info "Fulcio (certificates)    : ${FULCIO_URL}"
  info "CLI downloads            : ${CLI_SERVER}"
  info "Keycloak signer identity : ${SIGNER} (issuer ${OIDC_ISSUER})"
  info "Webhook (EventListener)  : ${el:+https://${el}}"
}

destroy() {
  step "Removing the CI namespace, Trusted Profile Analyzer and the Trusted Artifact Signer instance"
  oc delete namespace "$CI_NS" --ignore-not-found --wait=false
  command -v helm >/dev/null && helm uninstall redhat-trusted-profile-analyzer -n "$TPA_NS" 2>/dev/null || true
  oc delete namespace "$TPA_NS" --ignore-not-found --wait=false
  oc delete securesign rhtas -n "$TAS_NS" --ignore-not-found
  oc delete clusterrolebinding tssc-triggers --ignore-not-found
  info "operators and Dev Spaces stay installed"
}

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

TPA_IMPORTERS=false SKIP_TPA=false SKIP_DEVSPACES=false REBUILD_TOOLS=false
cmd=${1:-}; [[ $# -gt 0 ]] && shift
case "$cmd" in
  setup)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tpa-importers) TPA_IMPORTERS=true ;;
        --skip-tpa) SKIP_TPA=true ;;
        --skip-devspaces) SKIP_DEVSPACES=true ;;
        --rebuild-tools) REBUILD_TOOLS=true ;;
        *) die "unknown option $1" ;;
      esac
      shift
    done
    setup ;;
  run) run "$@" ;;
  verify) verify "$@" ;;
  urls) urls ;;
  destroy) destroy ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac
