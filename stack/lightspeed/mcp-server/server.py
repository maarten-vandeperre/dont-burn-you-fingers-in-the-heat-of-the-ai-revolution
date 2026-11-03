"""
platform-mcp: a small MCP server (Streamable HTTP, stateless, Python standard library only)
that gives Developer Lightspeed live answers about this platform.

Tools
  list_deployed_models     models served by OpenShift AI (KServe LLMInferenceService /
                           InferenceService), their MaaS publication and token quotas
  get_catalog_overview     the Developer Hub software catalog: domains > systems > components,
                           APIs, resources, and who provides / consumes / depends on what
  get_component_details    one catalog entity with everything linked to it: relations,
                           CI (OpenShift Builds, Tekton PipelineRuns), CD (Argo CD), runtime
                           (Deployments, Argo Rollouts, model servers)

The answers are pre-digested Markdown on purpose: Lightspeed runs on Qwen3-0.6B (MaaS) by
default, and a small model answers well when the tool already did the joining and filtering.

Data sources
  Kubernetes API   with this pod's ServiceAccount (read-only ClusterRole, see rbac.yaml)
  Developer Hub    catalog REST API with the static MCP token (backend.auth.externalAccess)

Environment
  MCP_TOKEN       clients must send "Authorization: Bearer <MCP_TOKEN>" (also used to call
                  the Developer Hub catalog API)
  RHDH_URL        in-cluster Developer Hub URL (default http://backstage-developer-hub.rhdh.svc)
  RHDH_PUBLIC_URL public Developer Hub URL, used for links in the answers
  PORT            default 8080
"""

import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
MCP_TOKEN = os.environ.get("MCP_TOKEN", "")
RHDH_URL = os.environ.get("RHDH_URL", "http://backstage-developer-hub.rhdh.svc").rstrip("/")
RHDH_PUBLIC_URL = os.environ.get("RHDH_PUBLIC_URL", "").rstrip("/")
if RHDH_PUBLIC_URL and "://" not in RHDH_PUBLIC_URL:   # rhdh-cluster-params holds the bare host
    RHDH_PUBLIC_URL = "https://" + RHDH_PUBLIC_URL
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
SERVER_INFO = {"name": "platform-mcp", "version": "1.0.0"}
SUPPORTED_PROTOCOLS = ["2025-06-18", "2025-03-26", "2024-11-05"]


def log(msg):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {msg}", file=sys.stderr, flush=True)


# ----------------------------------------------------------------------------- HTTP clients
def _k8s_ctx():
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt") if os.path.exists(f"{SA_DIR}/ca.crt") \
        else ssl._create_unverified_context()
    return ctx


K8S_CTX = None


def k8s(path):
    """GET on the Kubernetes API, {} when the resource type or object does not exist."""
    global K8S_CTX
    if K8S_CTX is None:
        K8S_CTX = _k8s_ctx()
    with open(f"{SA_DIR}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(K8S + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, context=K8S_CTX, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):
            return {}
        raise


def k8s_items(path):
    return k8s(path).get("items", [])


_catalog = {"at": 0.0, "entities": []}
_catalog_lock = threading.Lock()


def catalog_entities():
    """All catalog entities (cached 30s)."""
    with _catalog_lock:
        if time.time() - _catalog["at"] < 30 and _catalog["entities"]:
            return _catalog["entities"]
        req = urllib.request.Request(f"{RHDH_URL}/api/catalog/entities",
                                     headers={"Authorization": f"Bearer {MCP_TOKEN}"})
        # Developer Hub answers 429 / 503 for a while after a (re)start or under a burst of
        # requests: retry with backoff (Retry-After when given), else serve the last good copy.
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=20) as r:
                    ents = json.load(r)
                break
            except urllib.error.HTTPError as e:
                if e.code not in (429, 502, 503, 504) or attempt == 4:
                    if _catalog["entities"]:
                        return _catalog["entities"]
                    raise
                try:
                    wait = min(float(e.headers.get("Retry-After") or 0), 10.0)
                except ValueError:
                    wait = 0.0
                time.sleep(wait or 2 ** attempt)
        # Package / Plugin = the RHDH extensions catalog (installable plugins), not the platform
        ents = [e for e in ents if e.get("kind") not in ("Location", "Template", "Package", "Plugin")]
        _catalog.update(at=time.time(), entities=ents)
        return ents


# ----------------------------------------------------------------------------- helpers
def ref(e):
    m = e["metadata"]
    return f"{e['kind'].lower()}:{m.get('namespace', 'default')}/{m['name']}"


def short(r):
    """component:default/frontend -> frontend (component)"""
    kind, rest = r.split(":", 1)
    name = rest.split("/", 1)[-1]
    return name if kind == "component" else f"{name} ({kind})"


def rels(e, rtype):
    return sorted({r["targetRef"] for r in e.get("relations", []) if r["type"] == rtype})


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def ago(ts):
    if not ts:
        return "-"
    try:
        t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return ts
    s = int((datetime.now(timezone.utc) - t).total_seconds())
    if s < 120:
        return f"{s}s ago"
    if s < 7200:
        return f"{s // 60}m ago"
    if s < 172800:
        return f"{s // 3600}h ago"
    return f"{s // 86400}d ago"


def cond(obj, ctype="Ready"):
    for c in obj.get("status", {}).get("conditions", []) or []:
        if c.get("type") == ctype:
            return c.get("status"), c.get("reason") or "", c.get("message") or ""
    return None, "", ""


def entity_url(e):
    if not RHDH_PUBLIC_URL:
        return ""
    m = e["metadata"]
    return f"{RHDH_PUBLIC_URL}/catalog/{m.get('namespace', 'default')}/{e['kind'].lower()}/{m['name']}"


# ----------------------------------------------------------------------------- tool: models
def tool_list_deployed_models(_args):
    out = ["# Models deployed in OpenShift AI", ""]
    llmisvcs = k8s_items("/apis/serving.kserve.io/v1alpha1/llminferenceservices")
    isvcs = k8s_items("/apis/serving.kserve.io/v1beta1/inferenceservices")
    refs = k8s_items("/apis/maas.opendatahub.io/v1alpha1/maasmodelrefs")
    subs = k8s_items("/apis/maas.opendatahub.io/v1alpha1/maassubscriptions")
    externals = k8s_items("/apis/maas.opendatahub.io/v1alpha1/externalmodels")

    maas = {(r["metadata"]["namespace"], r["spec"].get("modelRef", {}).get("name", r["metadata"]["name"])): r for r in refs}
    quotas = {}
    for s in subs:
        for mr in s.get("spec", {}).get("modelRefs", []) or []:
            lim = ", ".join(f"{l['limit']} tokens/{l['window']}" for l in mr.get("tokenRateLimits", []) or [])
            quotas.setdefault((mr.get("namespace"), mr["name"]), []).append(f"{s['metadata']['name']} ({lim})")

    rows = []
    for m in llmisvcs:
        md, spec = m["metadata"], m.get("spec", {})
        ready, reason, _ = cond(m)
        args = " ".join((spec.get("template", {}).get("containers") or [{}])[0].get("args", []) or [])
        image = (spec.get("template", {}).get("containers") or [{}])[0].get("image", "")
        rows.append({
            "name": md["name"], "ns": md["namespace"], "kind": "LLMInferenceService (llm-d / vLLM)",
            "display": md.get("annotations", {}).get("openshift.io/display-name", md["name"]),
            "uri": spec.get("model", {}).get("uri", "-"), "replicas": spec.get("replicas", 1),
            "ready": "Ready" if ready == "True" else f"NOT ready ({reason or 'unknown'})",
            "url": m.get("status", {}).get("url", "-"),
            "runtime": ("vLLM CPU" if "cpu" in image else "vLLM GPU" if image else "-"),
            "tools": "yes" if "--enable-auto-tool-choice" in args else "no",
        })
    for m in isvcs:
        md, spec = m["metadata"], m.get("spec", {})
        ready, reason, _ = cond(m)
        pred = spec.get("predictor", {}).get("model", {})
        rows.append({
            "name": md["name"], "ns": md["namespace"], "kind": "InferenceService (KServe)",
            "display": md.get("annotations", {}).get("openshift.io/display-name", md["name"]),
            "uri": pred.get("storageUri", "-"), "replicas": spec.get("predictor", {}).get("minReplicas", 1),
            "ready": "Ready" if ready == "True" else f"NOT ready ({reason or 'unknown'})",
            "url": m.get("status", {}).get("url", "-"),
            "runtime": pred.get("runtime", pred.get("modelFormat", {}).get("name", "-")), "tools": "-",
        })

    if not rows:
        out.append("No model servers (LLMInferenceService / InferenceService) found.")
    out.append("| Model | Namespace | Status | Served by | Source | Replicas | Tool calling |")
    out.append("|---|---|---|---|---|---|---|")
    for r in rows:
        out.append(f"| {r['display']} (`{r['name']}`) | {r['ns']} | {r['ready']} | {r['kind']}, {r['runtime']} | {r['uri']} | {r['replicas']} | {r['tools']} |")
    out.append("")
    out.append("## Published through Models-as-a-Service (MaaS)")
    for r in rows:
        ref_ = maas.get((r["ns"], r["name"]))
        if ref_:
            phase = ref_.get("status", {}).get("phase", "-")
            ep = ref_.get("status", {}).get("endpoint", "-")
            q = "; ".join(quotas.get((r["ns"], ref_["metadata"]["name"]), [])) or "no subscription"
            out.append(f"- **{r['name']}**: MaaSModelRef {phase}, endpoint `{ep}/v1`; subscriptions: {q}")
        else:
            out.append(f"- **{r['name']}**: not published through MaaS (internal URL {r['url']})")
    for x in externals:
        out.append(f"- **{x['metadata']['name']}** (external model, {x.get('spec', {}).get('provider', '?')})")
    out.append("")
    out.append("Call a model: create an API key in OpenShift AI > Gen AI studio > API keys, then use any "
               "OpenAI client with base_url = the endpoint above.")
    return "\n".join(out)


# ----------------------------------------------------------------------------- tool: catalog
def tool_get_catalog_overview(_args):
    ents = catalog_entities()
    by_ref = {ref(e): e for e in ents}
    kinds = {}
    for e in ents:
        kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
    out = ["# Software catalog overview (Developer Hub)", "",
           "Entities: " + ", ".join(f"{n} {k}" for k, n in sorted(kinds.items())), ""]

    systems = sorted([e for e in ents if e["kind"] == "System"], key=lambda e: e["metadata"]["name"])
    domains = {}
    for s in systems:
        domains.setdefault(s.get("spec", {}).get("domain", "(no domain)"), []).append(s)
    for dom, syss in sorted(domains.items()):
        out.append(f"## Domain {dom}")
        for s in syss:
            parts = rels(s, "hasPart")
            comps = [short(p) for p in parts if p.startswith("component:")]
            apis = [short(p).replace(" (api)", "") for p in parts if p.startswith("api:")]
            res = [short(p).replace(" (resource)", "") for p in parts if p.startswith("resource:")]
            owner = short(rels(s, "ownedBy")[0]) if rels(s, "ownedBy") else "-"
            out.append(f"- **System {s['metadata']['name']}** (owner {owner}): {s['metadata'].get('description', '')}".rstrip(": "))
            if comps:
                out.append(f"  - components: {', '.join(comps)}")
            if apis:
                out.append(f"  - APIs: {', '.join(apis)}")
            if res:
                out.append(f"  - resources: {', '.join(res)}")
        out.append("")

    out.append("## How the components are wired (one line per relation)")
    for e in sorted([e for e in ents if e["kind"] == "Component"], key=lambda e: e["metadata"]["name"]):
        me = e["metadata"]["name"]
        for a in rels(e, "consumesApi"):
            providers = [short(p) for p in rels(by_ref.get(a, {"relations": []}), "apiProvidedBy")]
            api = short(a).replace(" (api)", "")
            out.append(f"- {me} calls the API {api}" + (f" of {', '.join(providers)}" if providers else ""))
        for d in rels(e, "dependsOn"):
            out.append(f"- {me} depends on {short(d)}")
    out.append("")
    # Small models sometimes pick this tool for "which items ... and their pipeline status": say what to do next
    out.append("This overview has NO pipeline / CI status. If the user asked about pipelines, CI or builds, "
               "call get_ci_status now without a name and answer with its table.")
    return "\n".join(out)


def find_entity(name):
    ents = catalog_entities()
    q = name.strip()
    if ":" in q:   # kind:namespace/name or kind:name
        q = q.split(":", 1)[1]
    q = q.split("/")[-1]
    exact = [e for e in ents if e["metadata"]["name"].lower() == q.lower()]
    if not exact:
        exact = [e for e in ents if norm(e["metadata"]["name"]) == norm(q)
                 or norm(e["metadata"].get("title", "")) == norm(q)]
    if exact:
        order = {"Component": 0, "Resource": 1, "API": 2, "System": 3}
        return sorted(exact, key=lambda e: order.get(e["kind"], 9))[0], []
    near = [e for e in ents if norm(q) and (norm(q) in norm(e["metadata"]["name"]) or norm(e["metadata"]["name"]) in norm(q))]
    if len({e["metadata"]["name"] for e in near}) == 1:   # "model router project" -> model-router
        order = {"Component": 0, "Resource": 1, "API": 2, "System": 3}
        return sorted(near, key=lambda e: order.get(e["kind"], 9))[0], []
    return None, [e["metadata"]["name"] for e in near]


def ci_section(kid, ns, e):
    out = ["## CI (builds and pipelines)"]
    found = False
    sel = urllib.parse.quote(f"backstage.io/kubernetes-id={kid}")
    # OpenShift Builds: BuildConfig with the component's name
    for nsx in [ns] if ns else []:
        bc = k8s(f"/apis/build.openshift.io/v1/namespaces/{nsx}/buildconfigs/{kid}")
        if bc:
            found = True
            builds = k8s_items(f"/apis/build.openshift.io/v1/namespaces/{nsx}/builds?labelSelector=" +
                               urllib.parse.quote(f"buildconfig={kid}"))
            builds.sort(key=lambda b: b.get("metadata", {}).get("creationTimestamp", ""), reverse=True)
            strat = bc.get("spec", {}).get("strategy", {}).get("type", "?")
            src = bc.get("spec", {}).get("source", {}).get("type", "?")
            if builds:
                last = builds[0]
                st = last.get("status", {})
                out.append(f"- OpenShift BuildConfig `{kid}` ({strat}, source {src}): last build **{last['metadata']['name']} {st.get('phase', '?')}** "
                           f"{ago(st.get('completionTimestamp') or st.get('startTimestamp'))}; "
                           f"history: " + ", ".join(f"{b['metadata']['name']}={b.get('status', {}).get('phase', '?')}" for b in builds[:5]))
            else:
                out.append(f"- OpenShift BuildConfig `{kid}` ({strat}): no builds yet")
    # Tekton PipelineRuns labelled with the component id (any namespace)
    prs = k8s_items(f"/apis/tekton.dev/v1/pipelineruns?labelSelector={sel}")
    if prs:
        found = True
        prs.sort(key=lambda p: p.get("status", {}).get("startTime") or p["metadata"].get("creationTimestamp", ""), reverse=True)
        ok = sum(1 for p in prs if cond(p, "Succeeded")[0] == "True")
        failed = sum(1 for p in prs if cond(p, "Succeeded")[0] == "False")
        last = prs[0]
        st, reason, msg = cond(last, "Succeeded")
        state = "Succeeded" if st == "True" else ("Running" if st == "Unknown" else f"Failed ({reason})")
        pipe = last["metadata"].get("labels", {}).get("tekton.dev/pipeline", "?")
        out.append(f"- Tekton pipeline `{pipe}` (namespace {last['metadata']['namespace']}): last run **{last['metadata']['name']} {state}** "
                   f"{ago(last.get('status', {}).get('startTime'))}; {len(prs)} runs total, {ok} succeeded, {failed} failed")
        if st == "False" and msg:
            out.append(f"  - failure: {msg[:240]}")
        for p in prs[1:5]:
            s2, r2, _ = cond(p, "Succeeded")
            out.append(f"  - {p['metadata']['name']}: {'Succeeded' if s2 == 'True' else 'Running' if s2 == 'Unknown' else 'Failed'} {ago(p.get('status', {}).get('startTime'))}")
    if not found:
        if e["metadata"].get("annotations", {}).get("tekton.dev/cicd") == "true":
            out.append("- CI is enabled for this component (tekton.dev/cicd) but no builds or PipelineRuns exist yet.")
        else:
            out.append("- No CI configured (no BuildConfig, no Tekton PipelineRuns labelled with this component).")
    return out


def cd_section(e):
    app = e["metadata"].get("annotations", {}).get("argocd/app-name")
    if not app:
        return []
    out = ["## CD (Argo CD)"]
    a = k8s(f"/apis/argoproj.io/v1alpha1/namespaces/openshift-gitops/applications/{app}")
    if a:
        st = a.get("status", {})
        out.append(f"- Argo CD application `{app}`: sync **{st.get('sync', {}).get('status', '?')}**, health **{st.get('health', {}).get('status', '?')}**, "
                   f"revision {str(st.get('sync', {}).get('revision', '-'))[:8]}, last sync {ago(st.get('operationState', {}).get('finishedAt'))}")
    else:
        out.append(f"- Argo CD application `{app}` is referenced but does not exist (the workload is deployed with oc / deploy.sh, not by Argo CD).")
    return out


def runtime_section(kid, ns):
    out = ["## Runtime (OpenShift)"]
    sel = urllib.parse.quote(f"backstage.io/kubernetes-id={kid}")
    scope = f"/namespaces/{ns}" if ns else ""
    found = False
    for d in k8s_items(f"/apis/apps/v1{scope}/deployments?labelSelector={sel}"):
        found = True
        st, sp = d.get("status", {}), d.get("spec", {})
        img = (sp.get("template", {}).get("spec", {}).get("containers") or [{}])[0].get("image", "")
        out.append(f"- Deployment `{d['metadata']['name']}` ({d['metadata']['namespace']}): {st.get('readyReplicas', 0)}/{sp.get('replicas', 0)} ready, image `{img.split('/')[-1][:70]}`")
    for r in k8s_items(f"/apis/argoproj.io/v1alpha1{scope}/rollouts?labelSelector={sel}"):
        found = True
        st = r.get("status", {})
        out.append(f"- Argo Rollout `{r['metadata']['name']}`: phase {st.get('phase', '?')}, {st.get('readyReplicas', 0)}/{st.get('replicas', 0)} ready, step {st.get('currentStepIndex', '-')}")
    for m in k8s_items(f"/apis/serving.kserve.io/v1alpha1{scope}/llminferenceservices?labelSelector={sel}"):
        found = True
        ready, reason, _ = cond(m)
        out.append(f"- Model server LLMInferenceService `{m['metadata']['name']}`: {'Ready' if ready == 'True' else 'NOT ready ' + reason}, URL {m.get('status', {}).get('url', '-')}")
    if not found:
        out.append("- No workloads labelled with this component on the cluster.")
    return out


def tool_get_component_details(args):
    name = str(args.get("name") or args.get("component") or "").strip()
    if not name:
        return "Please give the name of a catalog entity, e.g. coffee-shop."
    e, near = find_entity(name)
    if not e:
        hint = f" Did you mean: {', '.join(sorted(set(near))[:8])}?" if near else " Use get_catalog_overview to list the names."
        return f"No catalog entity named '{name}'.{hint}"
    ents = catalog_entities()
    by_ref = {ref(x): x for x in ents}
    md, spec = e["metadata"], e.get("spec", {})
    owner = ", ".join(short(r) for r in rels(e, "ownedBy")) or "-"
    system = ", ".join(short(r).replace(" (system)", "") for r in rels(e, "partOf")) or "-"
    out = [f"# {e['kind']} {md['name']}" + (f" - {md['title']}" if md.get("title") and md["title"] != md["name"] else ""), "",
           f"- type: {spec.get('type', '-')}, lifecycle: {spec.get('lifecycle', '-')}, owner: {owner}, system: {system}"]
    if md.get("description"):
        out.append(f"- {md['description']}")
    if entity_url(e):
        out.append(f"- Developer Hub: {entity_url(e)}")

    # One sentence per relation, subject repeated: small models misattribute compact lists
    out += ["", "## Linked catalog entities"]
    me = md["name"]
    lines = []

    def nm(r):
        return r.split(":", 1)[1].split("/", 1)[-1]

    def kind(r):
        return r.split(":", 1)[0]

    for t in rels(e, "providesApi"):
        cons = [nm(c) for c in rels(by_ref.get(t, {"relations": []}), "apiConsumedBy")]
        lines.append(f"- {me} PROVIDES the API {nm(t)}" + (f"; the API {nm(t)} is called by {', '.join(cons)}." if cons else "; no catalog component calls it."))
    for t in rels(e, "consumesApi"):
        prov = [nm(p) for p in rels(by_ref.get(t, {"relations": []}), "apiProvidedBy")]
        lines.append(f"- {me} CALLS the API {nm(t)}" + (f", which is provided by {', '.join(prov)}." if prov else "."))
    for t in rels(e, "dependsOn"):
        lines.append(f"- {me} DEPENDS ON the {kind(t)} {nm(t)}.")
    for t in rels(e, "dependencyOf"):
        lines.append(f"- the {kind(t)} {nm(t)} DEPENDS ON {me}.")
    for t in rels(e, "apiProvidedBy"):
        lines.append(f"- the API {me} is PROVIDED BY the {kind(t)} {nm(t)}.")
    for t in rels(e, "apiConsumedBy"):
        lines.append(f"- the API {me} is CALLED BY the {kind(t)} {nm(t)}.")
    for t in rels(e, "hasPart"):
        lines.append(f"- {me} CONTAINS the {kind(t)} {nm(t)}.")
    out += lines or ["- none"]
    for l in md.get("links", []) or []:
        out.append(f"- link: [{l.get('title', l.get('url'))}]({l.get('url')})")

    ann = md.get("annotations", {})
    kid = ann.get("backstage.io/kubernetes-id")
    ns = ann.get("backstage.io/kubernetes-namespace")
    if kid and e["kind"] in ("Component", "Resource"):
        out.append("")
        out += ci_section(kid, ns, e)
        cd = cd_section(e)
        if cd:
            out.append("")
            out += cd
        out.append("")
        out += runtime_section(kid, ns)
    return "\n".join(out)


# ----------------------------------------------------------------------------- tool: CI of the catalog
def run_state(p):
    st, reason, _ = cond(p, "Succeeded")
    return "Succeeded" if st == "True" else ("Running" if st in ("Unknown", None) else f"Failed ({reason})" if reason else "Failed")


def tool_get_catalog_ci_status(_args):
    """One row per component/resource: what the CI tab (Tekton plugin) of Developer Hub shows.

    The Tekton CI tab is shown for entities annotated tekton.dev/cicd: "true" and lists the
    PipelineRuns labelled backstage.io/kubernetes-id=<id> (or matching the
    backstage.io/kubernetes-label-selector annotation). OpenShift Builds are not on that tab;
    they are listed in a separate column so a missing pipeline is not mistaken for 'never built'.
    """
    ents = [e for e in catalog_entities() if e["kind"] in ("Component", "Resource")]
    # Two cluster-wide lists instead of one query per entity
    prs = k8s_items("/apis/tekton.dev/v1/pipelineruns")
    builds = k8s_items("/apis/build.openshift.io/v1/builds")

    def matches(labels, ann):
        kid = ann.get("backstage.io/kubernetes-id")
        if kid:
            return labels.get("backstage.io/kubernetes-id") == kid
        return False

    rows, with_pipeline, idle = [], 0, {}
    order = {"Component": 0, "Resource": 1}
    for e in sorted(ents, key=lambda x: (order[x["kind"]], x["metadata"]["name"])):
        md = e["metadata"]
        ann = md.get("annotations", {}) or {}
        kid = ann.get("backstage.io/kubernetes-id")
        ns = ann.get("backstage.io/kubernetes-namespace")

        pipeline = "N/A"
        mine = [p for p in prs if matches(p["metadata"].get("labels", {}) or {}, ann)] if kid else []
        if mine:
            with_pipeline += 1
            mine.sort(key=lambda p: p.get("status", {}).get("startTime") or p["metadata"].get("creationTimestamp", ""), reverse=True)
            last = mine[0]
            ok = sum(1 for p in mine if cond(p, "Succeeded")[0] == "True")
            pipeline = f"{run_state(last)} ({last['metadata']['name']}, {ago(last.get('status', {}).get('startTime'))}, {ok}/{len(mine)} ok)"

        build = "-"
        if kid and ns:
            bs = [b for b in builds if b["metadata"]["namespace"] == ns
                  and (b["metadata"].get("labels", {}) or {}).get("buildconfig") == kid]
            if bs:
                bs.sort(key=lambda b: b["metadata"].get("creationTimestamp", ""), reverse=True)
                st = bs[0].get("status", {})
                build = f"{st.get('phase', '?')} ({bs[0]['metadata']['name']}, {ago(st.get('completionTimestamp') or st.get('startTimestamp'))})"
        if pipeline == "N/A" and build == "-":
            idle.setdefault(e["kind"], []).append(md["name"])
        else:
            rows.append(f"| {md['name']} | {e['kind']} | {pipeline} | {build} |")

    # The instruction travels with the data: a 0.6B model follows it better than the system prompt
    built = sum(1 for r in rows if not r.endswith("| - |"))
    total = len(rows) + sum(len(v) for v in idle.values())
    for kind, names in sorted(idle.items()):
        rows.append(f"| {', '.join(names)} | {kind} | N/A | - |")
    # The instruction travels with the data: a 0.6B model follows it better than the system prompt.
    # The table is kept small (items without pipeline and build share one row): Qwen3's 8k context
    # also has to hold its reasoning, and a long table got cut off.
    out = [f"Copy the table and the last line below as your answer, verbatim, all {len(rows)} rows. /no_think", "",
           "| Item | Kind | Pipeline (CI tab) | Last build |",
           "|---|---|---|---|"] + rows + ["",
           f"**{total} items: {with_pipeline} with a pipeline on their CI tab (N/A = no pipeline), "
           f"{built} with an OpenShift build.** Ask for one item to get its links."]
    return "\n".join(out)


def tool_get_ci_status(args):
    """CI status of ONE catalog item, with the links to its catalog page and its CI tab."""
    name = str(args.get("name") or args.get("component") or "").strip()
    # No name, or a word meaning "everything" (small models fill in something): all items
    if norm(name) in ("", "all", "allitems", "catalog", "everything", "my", "mine", "myitems", "mycomponents",
                      "components", "items", "projects", "myprojects", "none", "null", "any"):
        return tool_get_catalog_ci_status({})
    e, near = find_entity(name)
    if not e:
        if near:
            return f"No catalog item named '{name}'. Did you mean: {', '.join(sorted(set(near))[:8])}?"
        return f"No catalog item named '{name}', so here is the CI status of all items.\n\n" + tool_get_catalog_ci_status({})
    md = e["metadata"]
    ann = md.get("annotations", {}) or {}
    kid, ns = ann.get("backstage.io/kubernetes-id"), ann.get("backstage.io/kubernetes-namespace")
    url = entity_url(e)
    out = [f"Answer with the status and BOTH links below, keep the links exactly. /no_think", "",
           f"# CI status of {md['name']} ({e['kind']})"]
    if kid and e["kind"] in ("Component", "Resource"):
        ci = ci_section(kid, ns, e)[1:]
        if not any("Tekton pipeline" in l for l in ci):
            ci.insert(0, "- Pipeline (CI tab): **N/A** (no Tekton pipeline runs for this item)")
        out += ci
    else:
        out.append("- N/A: no CI (no kubernetes-id, so no builds or pipeline runs are linked to it).")
    if url:
        out += ["", f"- Catalog page: {url}"]
        if ann.get("tekton.dev/cicd") == "true":
            out.append(f"- CI tab (pipeline runs): {url}/ci")
        else:
            out.append(f"- CI tab: none (the item has no tekton.dev/cicd annotation); overview: {url}")
    return "\n".join(out)


TOOLS = [
    {
        "name": "get_ci_status",
        "description": "Pipeline / CI / build status of ALL catalog items (Developer Hub CI tab), as one table "
                       "with N/A for items without a pipeline. Call it with NO arguments for the catalog, all "
                       "items or 'my' statuses. Only for one named item pass its name: then it also gives the "
                       "links to its catalog page and CI tab. Use for every CI, pipeline or build question.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string",
                                    "description": "Optional: one catalog item name, e.g. coffee-shop. Omit it for all items."}},
        },
        "fn": tool_get_ci_status,
    },
    {
        "name": "list_deployed_models",
        "description": "List the AI models deployed in OpenShift AI (model servers, status, runtime, "
                       "MaaS endpoint and token quotas). Use for any question about deployed, served or available models.",
        "inputSchema": {"type": "object", "properties": {}},
        "fn": tool_list_deployed_models,
    },
    {
        "name": "get_catalog_overview",
        "description": "Overview of the Developer Hub software catalog: domains, systems, components, APIs, "
                       "resources and how they depend on each other. Use for questions about the architecture, "
                       "the catalog, or relations between components. Not for pipeline, CI or build status "
                       "(use get_ci_status).",
        "inputSchema": {"type": "object", "properties": {}},
        "fn": tool_get_catalog_overview,
    },
    {
        "name": "get_component_details",
        "description": "Details of ONE catalog entity (component, resource, API or system) and everything linked to it: "
                       "related components and APIs, CI status (builds, Tekton pipeline runs), CD status (Argo CD) "
                       "and runtime status (deployments, rollouts, model servers).",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Catalog entity name, e.g. coffee-shop"}},
            "required": ["name"],
        },
        "fn": tool_get_component_details,
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ----------------------------------------------------------------------------- MCP (JSON-RPC)
def handle_rpc(msg):
    """Returns the JSON-RPC response for one message, None for notifications."""
    mid, method, params = msg.get("id"), msg.get("method", ""), msg.get("params") or {}
    if mid is None:   # notification (notifications/initialized, cancelled, ...)
        return None

    def result(r):
        return {"jsonrpc": "2.0", "id": mid, "result": r}

    def error(code, text):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": text}}

    if method == "initialize":
        asked = params.get("protocolVersion", SUPPORTED_PROTOCOLS[0])
        return result({
            "protocolVersion": asked if asked in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": SERVER_INFO,
            "instructions": "Live data about this OpenShift AI platform: deployed models, the Developer Hub catalog, "
                            "and CI/CD/runtime status per catalog component.",
        })
    if method == "ping":
        return result({})
    if method == "tools/list":
        return result({"tools": [{k: v for k, v in t.items() if k != "fn"} for t in TOOLS]})
    if method == "tools/call":
        name = params.get("name")
        tool = TOOLS_BY_NAME.get(name)
        if not tool:
            return error(-32602, f"unknown tool {name}")
        t0 = time.time()
        try:
            text = tool["fn"](params.get("arguments") or {})
            log(f"tool {name} {json.dumps(params.get('arguments') or {})} -> {len(text)} chars in {time.time() - t0:.1f}s")
            return result({"content": [{"type": "text", "text": text}], "isError": False})
        except Exception as ex:  # report tool failures to the model instead of breaking the session
            log(f"tool {name} failed: {ex!r}")
            return result({"content": [{"type": "text", "text": f"Tool {name} failed: {ex}"}], "isError": True})
    if method in ("resources/list", "prompts/list"):
        return result({method.split("/")[0]: []})
    return error(-32601, f"method not found: {method}")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quiet default access log
        pass

    def _send(self, code, body=None, ctype="application/json"):
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        if data:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _authorized(self):
        if not MCP_TOKEN:
            return True
        h = self.headers.get("Authorization", "")
        tok = h[7:].strip() if h.lower().startswith("bearer ") else h.strip()
        return tok == MCP_TOKEN

    def do_GET(self):
        if self.path in ("/healthz", "/readyz"):
            return self._send(200, b"ok", "text/plain")
        # no server-initiated SSE stream: stateless server (allowed by the Streamable HTTP spec)
        return self._send(405, {"error": "use POST /mcp"})

    def do_DELETE(self):
        return self._send(405)

    def do_POST(self):
        if not self.path.split("?")[0].rstrip("/").endswith("/mcp"):
            return self._send(404, {"error": "not found"})
        if not self._authorized():
            log(f"401 from {self.client_address[0]}")
            return self._send(401, {"error": "missing or wrong bearer token"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0") or 0)) or b"null")
        except json.JSONDecodeError:
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        if isinstance(body, list):
            replies = [r for r in (handle_rpc(m) for m in body) if r is not None]
            return self._send(200, replies) if replies else self._send(202)
        if not isinstance(body, dict):
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "invalid request"}})
        reply = handle_rpc(body)
        if body.get("method") and reply is None:
            return self._send(202)
        return self._send(200, reply)


def main():
    if "--call" in sys.argv:   # local debugging: python server.py --call <tool> [json-args]
        i = sys.argv.index("--call")
        print(TOOLS_BY_NAME[sys.argv[i + 1]]["fn"](json.loads(sys.argv[i + 2]) if len(sys.argv) > i + 2 else {}))
        return
    log(f"platform-mcp listening on :{PORT} (/mcp), catalog {RHDH_URL}, auth {'on' if MCP_TOKEN else 'OFF'}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
