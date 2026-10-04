# Test checklist

Fastest: `./deploy.sh validate` runs all of the checks below (and a few more) in one go and
writes a PASS / WARN / FAIL report to `validate-<date>.txt`. The sections below explain each
layer and are useful when a check fails.

Run top to bottom after an install or before a demo. Each check says what to run and what
"good" looks like. The first failing layer is usually the cause of everything below it.

## 1. Platform

```bash
./deploy.sh status
```
Good: the Kuadrant instance, `maas-default-gateway` (Programmed True), both LLMInferenceServices
READY True, both MaaSModelRefs Ready, `istio/default` Healthy, `kafka/platform` Ready, the
Backstage instance present.

```bash
oc get csv -n openshift-operators | grep -v Succeeded
```
Good: only the header line. Any other line is an operator that did not install.

## 2. Models through MaaS

```bash
./deploy.sh test
```
Good:
```
OK API key created (subscription small-models-free, expires in 1h)
models visible to this key: ..., gemma-3-270m-it, ..., qwen3-0-6b
OK gemma-3-270m-it: <some answer>
OK qwen3-0-6b: <some answer>
```
If a model is missing: `./deploy.sh models` (re-applies and waits with diagnostics). Gemma with
403 in its logs: `./deploy.sh hf-check`.

```bash
./deploy.sh usage --window 1h
```
Good: lines `tokens  qwen3-0-6b  small-models-free ...` with a value above 0 after the test.

## 3. Demo applications

```bash
./deploy.sh app status
```
Good: every pod `2/2 Running` (application + sidecar), `mongodb` included.

```bash
./deploy.sh app ask "How does the mesh decide who can access who?" qwen
```
Good: JSON with a non-empty `answer`, `"model": "qwen"`, `"version": "v1"` and source titles such
as "Service mesh, mTLS and authorization".

In the UI: the demo UI loads, Ask with `qwen` returns an answer with badges and retrieved
passages.

## 4. Mesh

```bash
./deploy.sh app probe
```
Good, five lines all starting with OK:
```
OK   rag-service          expected=allow  HTTP 200
OK   orders-service       expected=allow  HTTP 200
OK   projection-service   expected=allow  HTTP 200
OK   model-router         expected=deny   403 RBAC: access denied
OK   mongodb              expected=deny   closed by the mesh (RBAC denied)
```

```bash
./deploy.sh app mtls
```
Good: frontend, rag-service and model-router each `rejected (plaintext not allowed, STRICT mTLS)`.

```bash
./deploy.sh app pattern canary 50 && ./deploy.sh app traffic 200 && ./deploy.sh app pattern reset
```
Good: `rag v1` and `rag v2` both around 100.

## 5. CDC

```bash
./deploy.sh cdc-demo
```
Good: `OK inserted order 'demo-...'` followed by `OK Debezium captured it:` and the event with
`"op":"c"`.

```bash
./deploy.sh app cdc
```
Good: `OK customer <id>`, `OK order demo-...`, `OK projected after ~2 s` and the MongoDB
document with `fullName`, `orders`, `totals` and `lastChange`.

## 5b. Coffee shop

```bash
./deploy.sh app coffee
```
Good: a quote, PLACED > BREWING > READY, and five audit events from MongoDB ending with
`OK audit complete`.

```bash
./deploy.sh app menu delay 100 && ./deploy.sh app coffee && ./deploy.sh app menu reset
```
Good: the probe shows ~3000 ms latency, yet the order completes with `menu v1 (cache)`.

## 6. Observability

In the UI: console > Observe > Traces, service `frontend`: a trace from the last `app ask` with
spans of frontend, rag-service and model-router. Console > Observe > Dashboards > "AI demo":
the token and request panels show data.

```bash
oc get servicemonitor,podmonitor,prometheusrule -n ai-demo
```

OpenShift AI dashboard data (Observe & monitor > Dashboard shows charts, no "No datasource found"):
```bash
oc get persesglobaldatasource thanos-querier-global-datasource
oc logs -n redhat-ods-monitoring job/perses-auth-fix-now | tail -1
```
Good: the datasource exists and the job printed `OK: Perses proxy to Thanos works`. Fix:
`./deploy.sh dashboards`.

MLflow tracing: place a coffee order, then OpenShift AI > Applications > MLflow UI, workspace
`ai-demo`, experiment `coffee-shop`, Traces. Fix: `./deploy.sh app mlflow`.
Good: the `istio-proxies-monitor` PodMonitor and the `ai-demo-alerts` PrometheusRule exist.

## 7. Single sign-on and GitLab

```bash
oc get keycloak platform-sso -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo
oc get keycloakrealmimport demo-realm -n keycloak -o jsonpath='{.status.conditions[?(@.type=="Done")].status}'; echo
oc rollout status deploy/gitlab -n gitlab --timeout=10s
```
Good: `True`, `True`, `successfully rolled out`.

In the UI: Developer Hub shows a Keycloak sign-in; `admin` / `redhatdemo` lands in the catalog.
GitLab > Sign in with Keycloak works too, and `ai-platform/platform` contains the source. If the
project is missing: `./deploy.sh gitlab`.

## 8. Developer Hub

```bash
./deploy.sh rhdh-plugins tekton argo topology kubernetes http-request
```
Good: every word lists at least one package.

In the UI: Catalog shows the `ai-demo`, `openshift-platform` and `models-as-a-service` systems;
component `rag-service` has Topology and Kubernetes tabs with live pods; Create lists four
platform templates.

## When a check fails

`./deploy.sh debug` collects versions, plugin install logs, model logs and events into one file
without secrets.
