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
# `head -c` exits as soon as it has read N bytes, which SIGPIPEs the still-writing `tr` upstream;
# under `pipefail` that makes the *pipeline* report a non-zero status (even though the N-char output
# is correct), which trips our `ERR` trap. The `|| true` absorbs that false failure; stdout/the
# generated string are unaffected either way.
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}" || true; }
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
  # Dev Spaces' Subscription lives in stack/operators (./deploy.sh stack installs it with every
  # other operator); applied here too so './deploy.sh tssc setup' works standalone on a cluster
  # that never ran './deploy.sh stack'.
  oc apply -f "${ROOT_DIR}/stack/operators/devspaces.yaml" >/dev/null
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
    # The chart's own default (modules.importer.resources.requests: 1 CPU / 8Gi memory) is sized
    # for a dedicated prod node, not a small demo cluster — and the importer Deployment has a
    # *required* pod affinity to co-locate with the "server" pod (same hostname), so it can only
    # ever land on whichever one node that happens to be; if that node is already busy, 8Gi simply
    # never fits no matter how much headroom the rest of the cluster has (verified live:
    # FailedScheduling "Insufficient memory" while other nodes sat mostly idle). Ask for less so it
    # can actually schedule on a modest cluster; the importer just runs its periodic (1d) sync
    # slower/with smaller batches under memory pressure, it doesn't need 8Gi to make progress.
    importer_flags+=(--set modules.importer.resources.requests.memory=1Gi
                      --set modules.importer.resources.requests.cpu=250m)
  fi
  # Chart bug workaround: with storage.type=filesystem (used here), the chart's migrate-db Job runs
  # as a Helm pre-install/pre-upgrade hook and mounts a PVC named "storage" — but that PVC template
  # has no helm.sh/hook annotation, so Helm only creates it as a normal resource *after* all
  # pre-install hooks have already succeeded. On a fresh install this is a deadlock: migrate-db's pod
  # can never schedule ("persistentvolumeclaim \"storage\" not found"), so `helm upgrade --install`
  # times out no matter how high --timeout is set (verified live: pod stuck Pending ~13min on
  # 0/6 nodes schedulable, FailedScheduling: persistentvolumeclaim "storage" not found). Pre-create
  # the PVC ourselves (idempotent) with the exact spec/labels the chart would render, plus the
  # meta.helm.sh/release-* annotations Helm needs to adopt a pre-existing resource into the release
  # instead of failing the subsequent apply with "invalid ownership metadata".
  if ! oc get pvc storage -n "$TPA_NS" >/dev/null 2>&1; then
    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: storage
  namespace: ${TPA_NS}
  labels:
    app.kubernetes.io/name: storage
    app.kubernetes.io/instance: redhat-trusted-profile-analyzer
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: trustify
  annotations:
    meta.helm.sh/release-name: redhat-trusted-profile-analyzer
    meta.helm.sh/release-namespace: ${TPA_NS}
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
EOF
  fi
  # Self-heal an existing, already-undersized PVC (e.g. from before this 20Gi default): ext4 (this
  # cluster's StorageClass) ties its *inode* budget to byte size at mkfs time, so growing the PVC
  # also grows available inodes -- confirmed live, 10Gi->20Gi doubled free inodes from 0 to 640K,
  # which is what actually fixes Trusted Profile Analyzer's "StorageFull"/inode-exhaustion caveat
  # (not a code workaround: `df -h` can look nearly empty while `df -i` is already at 100%). The
  # filesystem resize itself only completes once a pod remounts the volume, which the scale-down +
  # helm-driven scale-up cycle right below already does on every upgrade, so just patch the spec
  # here; no extra restart needed. Requires allowVolumeExpansion: true on the StorageClass (true on
  # this cluster's ocs-external-storagecluster-ceph-rbd).
  local cur_size; cur_size=$(oc get pvc storage -n "$TPA_NS" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)
  if [[ -n "$cur_size" && "$cur_size" != "20Gi" ]]; then
    info "existing storage PVC is ${cur_size}: growing it to 20Gi (fixes TPA's inode-exhaustion caveat, not just a workaround)"
    oc patch pvc storage -n "$TPA_NS" --type merge -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}' >/dev/null 2>&1 || true
  fi
  # Second chart bug, upgrade-only: migrate-db's pre-install,pre-upgrade hook mounts the same
  # ReadWriteOnce "storage" PVC as the long-running server/importer Deployments. On a fresh install
  # nothing else holds it yet, but on a re-run (helm upgrade) those Deployments are already up and
  # keep the volume attached on their node — migrate-db's pod then gets stuck Pending forever with
  # "FailedAttachVolume: Multi-Attach error ... already used by pod(s) server-..., importer-..."
  # (verified live). Scale them to 0 before the hook runs so it can attach the volume; helm's normal
  # (non-hook) apply phase that follows a successful pre-upgrade hook re-creates/scales them back up
  # to the chart's desired replica count, so no explicit scale-up afterwards is needed.
  if helm status redhat-trusted-profile-analyzer -n "$TPA_NS" >/dev/null 2>&1; then
    info "existing release: scaling down server/importer first (they hold the storage PVC that migrate-db's upgrade hook needs)"
    oc scale deployment/server deployment/importer -n "$TPA_NS" --replicas=0 >/dev/null 2>&1 || true
    wait_until 120 "server/importer scaled down" bash -c \
      "[[ \$(oc get pods -n ${TPA_NS} -l 'app.kubernetes.io/name in (server,importer)' --field-selector=status.phase=Running -o name | wc -l) -eq 0 ]]" || true
  fi
  helm repo add openshift-helm-charts https://charts.openshift.io/ >/dev/null 2>&1 || true
  helm repo update openshift-helm-charts >/dev/null
  # --timeout bounds the pre-/post-install hook Jobs (create-db, migrate-db, create-importers), not
  # the importer's actual CVE/OSV data ingestion (that keeps running in the DB-backed importer
  # service long after this returns — see the "vulnerability importers ON" note above). 15m is well
  # above observed hook-Job durations (seconds to low single-digit minutes once scheduling works).
  helm upgrade --install redhat-trusted-profile-analyzer openshift-helm-charts/redhat-trusted-profile-analyzer \
    -n "$TPA_NS" --values "$values" --values "${TSSC_DIR}/rhtpa/values-importers.yaml" \
    --set-string appDomain="-${TPA_NS}.${d}" "${importer_flags[@]}" --timeout 15m >/dev/null
  rm -f "$values"
  ok "helm release redhat-trusted-profile-analyzer"
  wait_until 900 "RHTPA server route" tpa_route || true
  local host; host=$(tpa_route || true)
  TPA_URL=${host:+https://${host}}
  [[ -n "$TPA_URL" ]] && ok "Trusted Profile Analyzer: ${TPA_URL} (sign in: admin / your demo password)" \
    || warn "no RHTPA route yet: oc get pods,routes -n ${TPA_NS}"
  [[ "$TPA_IMPORTERS" == true ]] && info "vulnerability importers scheduled (period: 1d); setup does not" \
    "wait for the first import to finish — that continues in the background for hours, by design"
}

# ----------------------------------------------------------------------------- GitLab prerequisite
# GitLab (namespace "gitlab") must exist with a working automation token *before* devspaces() (it
# provisions a per-user GitLab PAT for each workspace) and signing_env() (it pushes signing.env
# there) run — and before ci() (its pipeline/trigger reference the same repo). Auto-provision it
# if missing/incomplete rather than making the user run a separate command first: './deploy.sh sso'
# deploys GitLab's k8s resources (and Keycloak if that's also missing) — idempotent, safe to call
# even when already up; './deploy.sh gitlab' (gitlab_seed) then creates the root API token, the
# ai-platform group / platform project, and pushes a full repo snapshot.
#
# That snapshot push is NOT safe to repeat once the project already has that snapshot: it is a
# full-repo force-push of a brand-new orphan commit ("Platform snapshot <date>"), which discards
# *any* history added since — including commits signed in Dev Spaces. Confirmed to have actually
# happened: a user ran `tssc setup` a second time on an already-working cluster, this call fired
# again unconditionally, and it silently reset `main` to that fresh snapshot, wiping their signed
# commit (and, because their workspace also happened to be recreated at the same time, its local
# `.git/config` signing settings too — see devfile.yaml's postStart fix). `tssc setup` must be
# safe to re-run at any time without resetting anything that already works, so only do this the
# first time: once the project exists on GitLab (and the force-push already happened at least
# once), running `./deploy.sh gitlab` again is left to whoever explicitly wants a fresh snapshot
# (e.g. after editing the demo's source locally), not to every `tssc setup`.
ensure_gitlab() {
  step "GitLab (repo for Dev Spaces + commit signing)"
  if oc get namespace gitlab >/dev/null 2>&1 && oc get route gitlab -n gitlab >/dev/null 2>&1 \
      && oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1; then
    ok "GitLab already deployed (namespace, route, automation token present)"
  else
    info "GitLab not found/incomplete: deploying it now with ./deploy.sh sso (idempotent; also installs Keycloak if that's missing too)"
    "${ROOT_DIR}/deploy.sh" sso 2>&1 | grep -E 'OK|WARN|ERROR' || true
    wait_until 1500 "GitLab ready" oc rollout status deployment/gitlab -n gitlab --timeout=10s \
      || { warn "GitLab did not become ready in time: oc get pods -n gitlab"; return 1; }
  fi
  if oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1 \
      && gitlab_api GET "/projects/${GITLAB_PROJECT_PATH//\//%2F}/repository/branches/main" 2>/dev/null | grep -q '"name"'; then
    ok "GitLab project ${GITLAB_PROJECT_PATH} already seeded (main branch exists): not re-pushing" \
       "(a repeat snapshot push would discard any commits made since, signed or not — use" \
       "./deploy.sh gitlab yourself if you deliberately want a fresh snapshot)"
    return 0
  fi
  info "seeding GitLab for the first time: automation token, group/project ${GITLAB_PROJECT_PATH}, repo push"
  "${ROOT_DIR}/deploy.sh" gitlab 2>&1 | grep -E 'OK|WARN|ERROR' || true
  oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1 \
    || { warn "GitLab seeding did not produce an automation token: oc get pods -n gitlab, then ./deploy.sh gitlab"; return 1; }
}

# ----------------------------------------------------------------------------- 5. Dev Spaces
devspaces() {
  step "Dev Spaces"
  wait_until 300 "CheCluster API" oc get crd checlusters.org.eclipse.che || { warn "Dev Spaces API missing"; return 0; }
  # Namespace + CheCluster CR: shared with the main stack (stack/devspaces, apply_layer in
  # deploy_stack_oc()) so there is one source of truth; applying it again here is idempotent and
  # keeps './deploy.sh tssc setup' self-sufficient even without './deploy.sh stack'.
  oc apply -k "${ROOT_DIR}/stack/devspaces" >/dev/null
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
# ci()'s pipeline/RBAC/image-stream pushes target namespace ai-demo, but the actual runtime
# dependency is lightweight (RBAC + image-stream pushes + a few tolerant environment checks + a
# self-documented "MOCK without app" Argo CD sync step) — it doesn't need the full app running.
# Auto-provision the namespace (idempotent) rather than hard-dying, per the same "prefer
# auto-provisioning over a better error message" preference as ensure_gitlab() above.
ensure_ai_demo() {
  oc get namespace ai-demo >/dev/null 2>&1 && return 0
  info "namespace ai-demo not found: deploying the demo apps now with ./deploy.sh app all (idempotent; this can take a while)"
  "${ROOT_DIR}/deploy.sh" app all 2>&1 | grep -E 'OK|WARN|ERROR' || true
  oc get namespace ai-demo >/dev/null 2>&1 \
    || die "namespace ai-demo still not found after ./deploy.sh app all: oc get events -n ai-demo"
}

ci() {
  step "CI namespace ${CI_NS}: tools image, signing key, pipeline, webhook"
  ensure_ai_demo
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

  # tools image: Sigstore clients, ideally from this cluster's CLI server so they match the RHTAS
  # server version. Some RHTAS operator versions (confirmed: 1.5.0 — `oc explain securesign.spec`
  # has no cliServer field, and there is no cli-server Deployment/Service/Route in
  # trusted-artifact-signer) don't ship this component at all, so CLI_SERVER can legitimately stay
  # empty even once RHTAS itself is fully Ready — tools-build.yaml's Dockerfile falls back to
  # fetching cosign/gitsign/rekor-cli from their upstream sigstore GitHub releases in that case, so
  # the build still happens either way (warn, don't skip, so the pipeline's trusted-supply-chain
  # run and Dev Spaces commit signing still get a working tools image).
  # Patch buildArgs unconditionally (even to "") -- the BuildConfig's default placeholder value
  # ("https://cli-server.CHANGE-ME") is non-empty, so leaving it unpatched when CLI_SERVER is
  # empty would make the Dockerfile's `[ -n "${CLI_SERVER}" ]` check true and send it curling
  # against that fake host instead of taking the GitHub-releases fallback path.
  oc patch bc tssc-tools -n "$CI_NS" --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/strategy/dockerStrategy/buildArgs/0/value\",\"value\":\"${CLI_SERVER}\"}]" >/dev/null
  if [[ -z "$CLI_SERVER" ]]; then
    warn "no RHTAS CLI server route (removed in some operator versions, e.g. 1.5.0): building the tools image " \
      "from upstream sigstore GitHub releases instead (see stack/tssc/ci/tools-build.yaml)"
  fi
  # TUF_URL lets the Dockerfile build gitsign from source with this cluster's own (non-expired,
  # correctly-keyed) root.json embedded in place of upstream's permanently-stale default -- see
  # the long comment at the top of tools-build.yaml for why this is necessary.
  oc patch bc tssc-tools -n "$CI_NS" --type json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/strategy/dockerStrategy/buildArgs/1/value\",\"value\":\"${TUF_URL}\"}]" >/dev/null
  if [[ "$REBUILD_TOOLS" == true ]] || ! oc get istag tssc-tools:latest -n "$CI_NS" >/dev/null 2>&1; then
    info "building the tools image (cosign, gitsign, rekor-cli, syft, oc; ~3 min)"
    oc start-build tssc-tools -n "$CI_NS" --wait >/dev/null || die "tools image build failed: oc logs -f bc/tssc-tools -n ${CI_NS}"
  fi
  ok "tools image ${TOOLS_IMAGE}"

  # cosign key pair, generated in the cluster straight into a Secret (never on this machine).
  # Needs the tools image (cosign binary) built above — skip gracefully if that was skipped too.
  if ! oc get istag tssc-tools:latest -n "$CI_NS" >/dev/null 2>&1; then
    warn "no tools image: skipping cosign key pair generation (see the CLI server warning above)"
  elif ! oc get secret cosign-signing -n "$CI_NS" >/dev/null 2>&1; then
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
  oc get secret cosign-signing -n "$CI_NS" >/dev/null 2>&1 \
    && ok "cosign key pair in Secret ${CI_NS}/cosign-signing (public key: oc get secret cosign-signing -n ${CI_NS} -o jsonpath='{.data.cosign\\.pub}' | base64 -d)"

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

# Pushes just these files to GitLab as one small additive commit on top of whatever is already on
# main -- NOT the full-repo-reseed-and-force-push './deploy.sh gitlab' does -- so this is safe to
# call on every `tssc setup` run without discarding any commits (signed or not) made since the
# project was first seeded. Skips entirely (no commit at all) if GitLab already has identical
# content for every path given. Used to propagate the handful of files Dev Spaces actually
# depends on even on a cluster where ensure_gitlab() has (correctly) stopped doing the full
# snapshot push because the project already exists.
gitlab_push_files() {  # gitlab_push_files <commit-message> <repo-relative-path>...
  local msg=$1; shift
  oc get secret gitlab-automation-token -n gitlab >/dev/null 2>&1 \
    || { warn "no GitLab automation token: skipping push of $* (run ./deploy.sh tssc setup to auto-provision GitLab)"; return 1; }
  local pid; pid=$(gitlab_api GET "/projects/${GITLAB_PROJECT_PATH//\//%2F}" | jq -r '.id // empty')
  [[ -n "$pid" ]] || { warn "GitLab project ${GITLAB_PROJECT_PATH} not found: ./deploy.sh gitlab, then rerun"; return 1; }
  local path local_content remote_content action actions_json="[]"
  for path in "$@"; do
    local_content=$(cat "${ROOT_DIR}/${path}")
    remote_content=$(gitlab_api GET "/projects/${pid}/repository/files/${path//\//%2F}/raw?ref=main" 2>/dev/null || true)
    [[ "$local_content" == "$remote_content" ]] && continue
    [[ -n "$remote_content" ]] && action=update || action=create
    actions_json=$(jq --arg action "$action" --arg path "$path" --arg content "$local_content" \
      '. += [{action: $action, file_path: $path, content: $content}]' <<<"$actions_json")
  done
  if [[ "$(jq 'length' <<<"$actions_json")" == 0 ]]; then
    ok "GitLab already has the current content for: $*"
    return 0
  fi
  local payload; payload=$(jq -n --arg branch main --arg msg "$msg" --argjson actions "$actions_json" \
    '{branch: $branch, commit_message: $msg, actions: $actions}')
  gitlab_api POST "/projects/${pid}/repository/commits" "$payload" | jq -e '.id' >/dev/null \
    && ok "pushed to GitLab (${msg}): $*" \
    || warn "could not push $* to GitLab: check ./deploy.sh gitlab"
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
  info "pushing the Dev Spaces files (devfile.yaml, signing scripts, signing.env) to GitLab -- a small additive commit, not a full reseed"
  gitlab_push_files "tssc setup: update Dev Spaces signing config" \
    devfile.yaml \
    stack/tssc/devspaces/sign-setup.sh \
    stack/tssc/devspaces/sign-commit.sh \
    stack/tssc/devspaces/verify-commit.sh \
    stack/tssc/generated/signing.env
}

# ----------------------------------------------------------------------------- commands
setup() {
  need oc; need curl; need jq
  oc whoami >/dev/null 2>&1 || die "not logged in: oc login"
  operators
  keycloak_setup
  rhtas
  ensure_gitlab
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
    backstage.io/kubernetes-id: ${service}-tssc   # Tekton tab of the catalog item in Developer Hub
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
