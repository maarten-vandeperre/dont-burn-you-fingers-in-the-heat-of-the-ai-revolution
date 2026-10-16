#!/usr/bin/env bash
# =============================================================================
# Connectivity: Red Hat Service Interconnect + Red Hat Connectivity Link
#
#   ./deploy.sh connectivity setup                 install Service Interconnect, enable the
#                                                   Connectivity Link Developer Portal component
#   ./deploy.sh connectivity legacy                 the "legacy" site: namespace, NetworkPolicies,
#                                                   PostgreSQL, seed data, Skupper Site + Connector
#   ./deploy.sh connectivity link                   the platform site, and the one-time link
#                                                   between the two (AccessGrant/AccessToken)
#   ./deploy.sh connectivity psql-check             proves it: query the legacy DB through Skupper,
#                                                   then prove direct access is still blocked
#   ./deploy.sh connectivity partner-api deploy     Gateway, HTTPRoute, mesh grant, AuthPolicy,
#                                                   PlanPolicy, APIProduct for orders-service
#   ./deploy.sh connectivity partner-api signup <trial|partner> [user] [email]
#                                                   self-service: a partner developer asks for a key
#   ./deploy.sh connectivity partner-api approve <APIKeyRequest name> [reviewer]
#   ./deploy.sh connectivity partner-api deny    <APIKeyRequest name> [reviewer]
#   ./deploy.sh connectivity partner-api test <api-key> [count]
#                                                   call the API count times with that key (no key:
#                                                   omit the argument) and print the HTTP status
#   ./deploy.sh connectivity partner-api reset      remove every signup/request/approval (not
#                                                   the policies)
#   ./deploy.sh connectivity status                 Sites, Link, Connector/Listener, AuthPolicy /
#                                                   APIProduct status in one place
#   ./deploy.sh connectivity urls                   the Partner Orders API URL
#   ./deploy.sh connectivity destroy                remove the two demo namespaces and the
#                                                   ai-demo additions (operators stay installed)
#
# Needs: the platform stack (./deploy.sh stack, for Connectivity Link/Kuadrant) and the demo app
# (./deploy.sh app deploy, for orders-service and the mesh) before `partner-api deploy`.
# Demo guide: docs/demos/10-connectivity.md
# =============================================================================
set -Eeuo pipefail

CONN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${CONN_DIR}/../.." && pwd)"
LEGACY_NS="legacy-datacenter"
PLATFORM_NS="connectivity-demo"
PG_IMAGE="registry.redhat.io/rhel9/postgresql-16@sha256:3943bfa5de044d8f033df148c0409ed826171b779f3cf3ddf537a1914960ab57"

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
csv_ok() { oc get csv -n "$1" -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' | grep -q "^$2.* Succeeded"; }

# ----------------------------------------------------------------------------- setup
setup() {
  need oc
  oc whoami >/dev/null 2>&1 || die "not logged in: oc login"
  step "Operator: Red Hat Service Interconnect"
  oc apply -f "${ROOT_DIR}/operators/service-interconnect.yaml" >/dev/null
  wait_until 600 "Service Interconnect operator" csv_ok openshift-operators skupper-operator && ok "Service Interconnect operator"
  step "Connectivity Link: Developer Portal component"
  if oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1; then
    oc patch kuadrant kuadrant -n kuadrant-system --type=merge -p '{"spec":{"components":{"developerPortal":{"enabled":true}}}}' >/dev/null
    ok "developerPortal enabled on kuadrant-system/kuadrant"
  else
    warn "no Kuadrant instance found: ./deploy.sh stack (or ./deploy.sh oc) first, then re-run './deploy.sh connectivity setup'"
  fi
}

# ----------------------------------------------------------------------------- legacy site
legacy() {
  step "Legacy site: namespace, NetworkPolicies, PostgreSQL, Skupper Site + Connector"
  oc apply -k "${CONN_DIR}/legacy-site" >/dev/null
  wait_until 180 "legacy-inventory-db ready" oc rollout status deploy/legacy-inventory-db -n "$LEGACY_NS" --timeout=10s \
    && ok "PostgreSQL legacy-inventory-db"
  oc delete job legacy-inventory-seed -n "$LEGACY_NS" --ignore-not-found >/dev/null 2>&1
  oc apply -f "${CONN_DIR}/legacy-site/seed-job.yaml" >/dev/null
  wait_until 120 "seed data" oc wait job/legacy-inventory-seed -n "$LEGACY_NS" --for=condition=complete --timeout=5s \
    && ok "seed data (table 'parts')" || warn "seed job not finished: oc logs job/legacy-inventory-seed -n ${LEGACY_NS}"
  wait_until 120 "legacy-datacenter Skupper site ready" bash -c \
    "[[ \$(oc get site legacy-datacenter -n ${LEGACY_NS} -o jsonpath='{.status.status}' 2>/dev/null) == Ready ]]" \
    && ok "Skupper site legacy-datacenter"
}

# ----------------------------------------------------------------------------- link the two sites
link() {
  step "Platform site, and linking it to the legacy site"
  oc apply -k "${CONN_DIR}/platform-site" >/dev/null
  wait_until 120 "${PLATFORM_NS} Skupper site ready" bash -c \
    "[[ \$(oc get site connectivity-demo -n ${PLATFORM_NS} -o jsonpath='{.status.status}' 2>/dev/null) == Ready ]]" \
    && ok "Skupper site connectivity-demo"

  if oc get link legacy-datacenter-link -n "$PLATFORM_NS" >/dev/null 2>&1; then
    ok "already linked to ${LEGACY_NS}"
  else
    oc get accessgrant connectivity-demo-link -n "$LEGACY_NS" >/dev/null 2>&1 || oc apply -f - >/dev/null <<EOF
apiVersion: skupper.io/v2alpha1
kind: AccessGrant
metadata:
  name: connectivity-demo-link
  namespace: ${LEGACY_NS}
spec:
  redemptionsAllowed: 5
  expirationWindow: 1h
EOF
    wait_until 60 "AccessGrant ready" bash -c \
      "[[ \$(oc get accessgrant connectivity-demo-link -n ${LEGACY_NS} -o jsonpath='{.status.status}' 2>/dev/null) == Ready ]]"
    local ca code url
    ca=$(oc get accessgrant connectivity-demo-link -n "$LEGACY_NS" -o jsonpath='{.status.ca}')
    code=$(oc get accessgrant connectivity-demo-link -n "$LEGACY_NS" -o jsonpath='{.status.code}')
    url=$(oc get accessgrant connectivity-demo-link -n "$LEGACY_NS" -o jsonpath='{.status.url}')
    [[ -n "$url" ]] || die "AccessGrant has no status.url yet: oc get accessgrant connectivity-demo-link -n ${LEGACY_NS} -o yaml"
    oc apply -f - >/dev/null <<EOF
apiVersion: skupper.io/v2alpha1
kind: AccessToken
metadata:
  name: legacy-datacenter-link
  namespace: ${PLATFORM_NS}
spec:
  url: "${url}"
  code: "${code}"
  ca: |
$(sed 's/^/    /' <<<"$ca")
EOF
    ok "AccessToken redeemed"
  fi
  wait_until 180 "link connected" bash -c \
    "[[ \$(oc get link legacy-datacenter-link -n ${PLATFORM_NS} -o jsonpath='{.status.status}' 2>/dev/null) == Ready ]]" \
    && ok "site ${PLATFORM_NS} linked to ${LEGACY_NS} (2 sites in network: oc get site -n ${PLATFORM_NS})"
}

# ----------------------------------------------------------------------------- prove it
psql_check() {
  step "Querying the legacy database through the Skupper virtual network (no VPN, no public endpoint)"
  oc delete pod psql-check -n "$PLATFORM_NS" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: psql-check
  namespace: ${PLATFORM_NS}
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: ${PG_IMAGE}
      env: [{name: PGPASSWORD, value: change-me-legacy}, {name: PGCONNECT_TIMEOUT, value: "5"}]
      command: ["psql", "-h", "legacy-inventory-db", "-U", "legacy_app", "-d", "legacy_inventory", "-c", "SELECT * FROM parts;"]
EOF
  if oc wait pod/psql-check -n "$PLATFORM_NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s >/dev/null 2>&1; then
    ok "query succeeded, from a namespace that cannot reach the database directly (see below)"
  else
    warn "query did not finish: oc logs pod/psql-check -n ${PLATFORM_NS}"
  fi
  oc logs pod/psql-check -n "$PLATFORM_NS" 2>/dev/null | sed 's/^/    /'
  oc delete pod psql-check -n "$PLATFORM_NS" --wait=false >/dev/null 2>&1 || true

  step "Proving the database is NOT reachable directly, bypassing Skupper"
  local ip; ip=$(oc get pod -n "$LEGACY_NS" -l app=legacy-inventory-db -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
  [[ -n "$ip" ]] || { warn "no legacy-inventory-db pod yet: ./deploy.sh connectivity legacy"; return 0; }
  oc delete pod psql-direct -n "$PLATFORM_NS" --ignore-not-found --wait=true --force --grace-period=0 >/dev/null 2>&1 || true
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: psql-direct
  namespace: ${PLATFORM_NS}
spec:
  restartPolicy: Never
  containers:
    - name: psql
      image: ${PG_IMAGE}
      env: [{name: PGPASSWORD, value: change-me-legacy}, {name: PGCONNECT_TIMEOUT, value: "5"}]
      command: ["psql", "-h", "${ip}", "-U", "legacy_app", "-d", "legacy_inventory", "-c", "SELECT 1;"]
EOF
  if oc wait pod/psql-direct -n "$PLATFORM_NS" --for=jsonpath='{.status.phase}'=Succeeded --timeout=12s >/dev/null 2>&1; then
    warn "direct access to ${ip}:5432 worked -- the NetworkPolicies in legacy-site/network-policies.yaml are missing or were changed"
  else
    ok "direct access to ${ip}:5432 timed out, as expected: only the Skupper router may reach this pod"
  fi
  oc delete pod psql-direct -n "$PLATFORM_NS" --wait=false --force --grace-period=0 >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------- partner API
partner_api_deploy() {
  need oc
  oc get svc orders-service -n ai-demo >/dev/null 2>&1 || die "orders-service not found in namespace ai-demo: ./deploy.sh app deploy first"
  local host; host="partner-api.$(domain)"
  step "Partner Orders API: ${host}"
  cat > "${CONN_DIR}/partner-api/cluster-params.env" <<EOF
# Cluster specific value, generated by: ./deploy.sh connectivity partner-api deploy
# Commit this file when you deploy with Argo CD.
PARTNER_API_HOSTNAME=${host}
EOF
  oc apply -k "${CONN_DIR}/partner-api" >/dev/null
  wait_until 120 "partner-gateway programmed" bash -c \
    "[[ \$(oc get gateway partner-gateway -n ai-demo -o jsonpath='{.status.conditions[?(@.type==\"Programmed\")].status}' 2>/dev/null) == True ]]" \
    && ok "Gateway partner-gateway programmed"
  info "AuthPolicy / PlanPolicy / APIProduct can take a minute or two to reach Enforced/Ready -- check: ./deploy.sh connectivity status"
  # A brand new partner-gateway Envoy pod sometimes loses the race fetching the Kuadrant wasm
  # plugin binary from kuadrant-operator-wasm right at startup ("Plugin kuadrant-wasm-shim failed
  # to load" in its logs) and serves 503 for every request after that, forever -- it does not
  # retry on its own. One pod restart (a fresh fetch) clears it. See
  # docs/demos/10-connectivity.md, "If something goes wrong".
  need curl
  if wait_until 30 "partner-gateway answering (not the wasm-fetch-race 503)" bash -c \
      "code=\$(curl -sk -o /dev/null -w '%{http_code}' https://${host}/api/orders); [[ \$code == 401 || \$code == 200 ]]"; then
    ok "https://${host}/api/orders"
  else
    warn "partner-gateway still 503 after 30s: restarting its pod once (known wasm-fetch race)"
    oc delete pod -n ai-demo -l gateway.networking.k8s.io/gateway-name=partner-gateway --ignore-not-found >/dev/null
    wait_until 60 "partner-gateway answering after restart" bash -c \
      "code=\$(curl -sk -o /dev/null -w '%{http_code}' https://${host}/api/orders); [[ \$code == 401 || \$code == 200 ]]" \
      && ok "https://${host}/api/orders" \
      || warn "still not answering: oc logs -n ai-demo -l gateway.networking.k8s.io/gateway-name=partner-gateway"
  fi
}

partner_api_signup() {  # signup <trial|partner> [user] [email]
  local tier=${1:?usage: partner-api signup <trial|partner> [user] [email]} \
        user=${2:-partner-dev} email=${3:-${2:-partner-dev}@example.com}
  [[ "$tier" == trial || "$tier" == partner ]] || die "tier must be 'trial' or 'partner'"
  local id; id=$(rand 6)
  local key="sk-partner-${id}"
  step "Self-service signup: ${user} asks for '${tier}' access"
  # authorino.kuadrant.io/managed-by=authorino is required even before this key is approved: it is
  # Authorino's own "watch me individually" label (its --secret-label-selector bootstrap flag,
  # default authorino.kuadrant.io/managed-by=authorino). Without it, Authorino only ever sees this
  # Secret's *current* state the next time its AuthConfig itself is reconciled (which won't happen
  # again on its own) -- so the kuadrant.io/apikeys-by label added later at approval time would be
  # invisible to Authorino until something else nudged the AuthConfig. See
  # docs/demos/10-connectivity.md, "If something goes wrong".
  oc create secret generic "partner-key-${id}" -n ai-demo --from-literal=api_key="${key}" \
    --dry-run=client -o yaml \
    | oc label -f - app.kubernetes.io/part-of=partner-api-signup authorino.kuadrant.io/managed-by=authorino --local -o yaml \
    | oc apply -f - >/dev/null
  oc apply -f - >/dev/null <<EOF
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKey
metadata:
  name: partner-key-${id}
  namespace: ai-demo
  labels: {app.kubernetes.io/part-of: partner-api-signup}
spec:
  apiProductRef: {name: partner-orders-api, namespace: ai-demo}
  planTier: ${tier}
  requestedBy: {userId: "${user}", email: "${email}"}
  secretRef: {name: "partner-key-${id}"}
EOF
  oc apply -f - >/dev/null <<EOF
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKeyRequest
metadata:
  name: partner-request-${id}
  namespace: ai-demo
  labels: {app.kubernetes.io/part-of: partner-api-signup}
spec:
  apiProductRef: {name: partner-orders-api}
  apiKeyRef: {name: "partner-key-${id}", namespace: ai-demo}
  planTier: ${tier}
  requestedBy: {userId: "${user}", email: "${email}"}
  useCase: "${user} / ${tier} tier read access to order history"
EOF
  ok "request submitted: APIKeyRequest/partner-request-${id} (status: Pending until approved)"
  info "api key value (not usable yet)     : ${key}"
  info "platform-team/approver runs next   : ./deploy.sh connectivity partner-api approve partner-request-${id}"
}

partner_api_approve() {  # approve <request-name> [reviewer]
  local req=${1:?usage: partner-api approve <APIKeyRequest name> [reviewer]} reviewer=${2:-platform-team}
  oc get apikeyrequest "$req" -n ai-demo >/dev/null 2>&1 || die "APIKeyRequest/${req} not found in ai-demo"
  step "Approving ${req} as '${reviewer}'"
  oc apply -f - >/dev/null <<EOF
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKeyApproval
metadata:
  name: ${req}-approval
  namespace: ai-demo
  labels: {app.kubernetes.io/part-of: partner-api-signup}
spec:
  apiKeyRequestRef: {name: ${req}}
  approved: true
  reviewedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reviewedBy: "${reviewer}"
  reason: "tier matches the partner agreement"
EOF
  local secret tier
  secret=$(oc get apikeyrequest "$req" -n ai-demo -o jsonpath='{.spec.apiKeyRef.name}')
  tier=$(oc get apikeyrequest "$req" -n ai-demo -o jsonpath='{.spec.planTier}')
  # The devportal controller is designed to label/annotate this Secret once the approval lands
  # (the APIKey CRD's own field doc: "Controller reads API key from this secret on approval").
  # Fall back to doing it ourselves if that hasn't happened after a short wait, so the demo does
  # not depend on the controller's own restart cadence -- see docs/demos/10-connectivity.md,
  # "If something goes wrong".
  if wait_until 30 "Secret ${secret} labelled by the devportal controller" bash -c \
      "[[ -n \$(oc get secret ${secret} -n ai-demo -o jsonpath='{.metadata.labels.kuadrant\.io/apikeys-by}' 2>/dev/null) ]]"; then
    ok "Secret ${secret} is now a valid APIKEY credential (tier ${tier}, labelled by the controller)"
  else
    warn "devportal controller hasn't labelled ${secret} yet: applying the label/annotation directly"
    oc label secret "$secret" -n ai-demo kuadrant.io/apikeys-by=partner-orders-api-auth --overwrite >/dev/null
    oc annotate secret "$secret" -n ai-demo secret.kuadrant.io/plan-id="${tier}" --overwrite >/dev/null
    ok "Secret ${secret} is now a valid APIKEY credential (tier ${tier}, applied directly)"
  fi
  local key; key=$(oc get secret "$secret" -n ai-demo -o jsonpath='{.data.api_key}' | base64 -d)
  info "test it: ./deploy.sh connectivity partner-api test ${key}"
}

partner_api_deny() {  # deny <request-name> [reviewer]
  local req=${1:?usage: partner-api deny <APIKeyRequest name> [reviewer]} reviewer=${2:-platform-team}
  step "Declining ${req} as '${reviewer}'"
  oc apply -f - >/dev/null <<EOF
apiVersion: devportal.kuadrant.io/v1alpha1
kind: APIKeyApproval
metadata:
  name: ${req}-approval
  namespace: ai-demo
  labels: {app.kubernetes.io/part-of: partner-api-signup}
spec:
  apiKeyRequestRef: {name: ${req}}
  approved: false
  reviewedAt: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  reviewedBy: "${reviewer}"
  reason: "declined"
EOF
  ok "declined ${req}: its key stays a 401 forever"
}

partner_api_test() {  # test [api-key] [count]
  need curl
  local key=${1:-} n=${2:-1} host code i
  host=$(oc get route partner-api -n ai-demo -o jsonpath='{.spec.host}' 2>/dev/null)
  [[ -n "$host" ]] || die "no Route ai-demo/partner-api: ./deploy.sh connectivity partner-api deploy"
  step "GET https://${host}/api/orders x${n}${key:+ (Authorization: APIKEY ${key})}"
  for ((i = 1; i <= n; i++)); do
    if [[ -n "$key" ]]; then
      code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: APIKEY ${key}" "https://${host}/api/orders")
    else
      code=$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/api/orders")
    fi
    info "request $(printf '%3d' "$i"): HTTP ${code}"
  done
}

partner_api_reset() {
  step "Removing every signup/request/approval (the Gateway/HTTPRoute/AuthPolicy/PlanPolicy/APIProduct stay)"
  for kind in apikeyapproval apikeyrequest apikey secret; do
    oc get "$kind" -n ai-demo -l app.kubernetes.io/part-of=partner-api-signup -o name 2>/dev/null | xargs -r oc delete -n ai-demo >/dev/null
  done
  ok "removed"
}

# ----------------------------------------------------------------------------- status / urls / destroy
status() {
  step "Service Interconnect"
  oc get site -n "$LEGACY_NS" -o wide 2>/dev/null || warn "not deployed: ./deploy.sh connectivity legacy"
  oc get site -n "$PLATFORM_NS" -o wide 2>/dev/null || warn "not deployed: ./deploy.sh connectivity link"
  oc get link -n "$PLATFORM_NS" -o wide 2>/dev/null
  oc get connector -n "$LEGACY_NS" 2>/dev/null
  oc get listener -n "$PLATFORM_NS" 2>/dev/null

  step "Connectivity Link: Partner Orders API"
  oc get gateway partner-gateway -n ai-demo 2>/dev/null || warn "not deployed: ./deploy.sh connectivity partner-api deploy"
  oc get httproute partner-orders-api -n ai-demo 2>/dev/null
  echo "    AuthPolicy  : $(oc get authpolicy partner-orders-api-auth -n ai-demo -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status} {.status.conditions[?(@.type=="Enforced")].message}' 2>/dev/null)"
  echo "    APIProduct  : $(oc get apiproduct partner-orders-api -n ai-demo -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)"
  oc get apikeyrequest -n ai-demo -l app.kubernetes.io/part-of=partner-api-signup 2>/dev/null
}

urls() {
  local host; host=$(oc get route partner-api -n ai-demo -o jsonpath='{.spec.host}' 2>/dev/null)
  info "Partner Orders API : ${host:+https://${host}/api/orders}"
  info "OpenShift console  : look for the Kuadrant plugin's policy view on this HTTPRoute/Gateway"
}

destroy() {
  step "Removing the connectivity demo (operators stay installed)"
  oc delete -k "${CONN_DIR}/partner-api" --ignore-not-found >/dev/null 2>&1 || true
  oc delete authorizationpolicy partner-gateway-from-router orders-service-from-partner-gateway -n ai-demo --ignore-not-found >/dev/null 2>&1 || true
  oc delete route partner-api -n ai-demo --ignore-not-found >/dev/null 2>&1 || true
  for kind in apikeyapproval apikeyrequest apikey secret; do
    oc get "$kind" -n ai-demo -l app.kubernetes.io/part-of=partner-api-signup -o name 2>/dev/null | xargs -r oc delete -n ai-demo >/dev/null
  done
  oc delete namespace "$PLATFORM_NS" "$LEGACY_NS" --ignore-not-found --wait=false
  info "operators (Service Interconnect, Connectivity Link) stay installed"
}

usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

cmd=${1:-}; [[ $# -gt 0 ]] && shift
case "$cmd" in
  setup) setup ;;
  legacy) legacy ;;
  link) link ;;
  psql-check) psql_check ;;
  partner-api)
    sub=${1:-}; [[ $# -gt 0 ]] && shift
    case "$sub" in
      deploy) partner_api_deploy ;;
      signup) partner_api_signup "$@" ;;
      approve) partner_api_approve "$@" ;;
      deny) partner_api_deny "$@" ;;
      test) partner_api_test "$@" ;;
      reset) partner_api_reset ;;
      *) usage 1 ;;
    esac ;;
  status) status ;;
  urls) urls ;;
  destroy) destroy ;;
  -h|--help|help|"") usage 0 ;;
  *) usage 1 ;;
esac
