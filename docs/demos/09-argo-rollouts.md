# Demo 9: Argo Rollouts, four strategies

**The story:** four self-contained Rollouts, each demonstrating one release strategy on its own:
canary (automatic, weighted), blue-green (manual cutover), blue-green with **pre**-promotion
analysis (the cutover is gated by a smoke test) and canary with **post**-promotion analysis (every
weight step is gated). No service mesh, no MaaS, no Kafka — only the Argo Rollouts controller and
OpenShift Pipelines, so this demo works on any cluster that has the two operators installed. The
workload is the upstream [`argoproj/rollouts-demo`](https://hub.docker.com/r/argoproj/rollouts-demo)
image — a colored square on `/`, the same color as JSON on `/color` — the exact app the Argo
Rollouts project itself uses in its own "Getting started" guide.

**Duration:** 20 minutes (10 the four strategies, 3 Developer Hub, 3 Tekton, 4 IntelliJ). Each
part also works on its own.

```
app/deploy/rollouts-demo/ (namespace rollouts-demo, kustomize) ──> 4 Rollouts + Services + Routes
                                                                     + 1 shared AnalysisTemplate (Job)
                                                                     + 1 Tekton Pipeline

canary-demo             : setWeight 20/40/60/80/100, pause 20s, fully automatic
bluegreen-demo          : active + preview Service, autoPromotionEnabled: false, manual promote
bluegreen-analysis-demo : blue-green + prePromotionAnalysis (smoke test gates the cutover)
canary-analysis-demo    : canary + analysis after each step (smoke test gates the next weight)
```

Every step below has three parts: **Do** (what you type or click), **You see**, **Say**.

| Strategy | Real or mocked |
|---|---|
| All four Rollouts, their Services, Routes and traffic shifting | **real**: the Argo Rollouts controller on this cluster |
| The "smoke test" analysis (HTTP check against `/color`) | **real**: a Kubernetes Job, no Prometheus/Thanos needed |
| The release pipeline | **real**: a Tekton `PipelineRun`, `openshift-client` ClusterTask |
| Developer Hub catalog item, Kubernetes/CI/CD tabs | **real**: live data read from this cluster |
| Argo Rollouts dashboard (the Promote/Abort/Retry buttons) | **real**: the upstream `kubectl argo rollouts dashboard`, run as its own pod |

---

## Before you start

1. Once:
   ```bash
   ./deploy.sh app argorollouts deploy      # namespace, 4 Rollouts, Services, Routes, AnalysisTemplate, Pipeline
   ./deploy.sh app argorollouts urls        # the 10 Routes (one per Service)
   ```
2. Developer Hub needs its own render + apply once the `rollouts-demo` namespace exists, so the
   catalog's Kubernetes/CI/CD tabs resolve: `./deploy.sh rhdh`.
3. Browser tabs: the **Argo Rollouts dashboard** (first URL printed by `argorollouts urls`, e.g.
   `https://rollouts-dashboard-rollouts-demo.<apps-domain>/rollouts`) — this is the main tab for
   the whole demo, it shows all four Rollouts as live-updating cards; **Developer Hub** (catalog,
   filter **Kind: System**, item `argo-rollouts-demo`); **OpenShift console > Pipelines**.
   Optionally open two of the other Route URLs from `argorollouts urls` side by side (e.g. the
   blended `canary-demo` Route and `canary-demo-canary` / `canary-demo-stable`).
4. Start clean: `./deploy.sh app argorollouts reset` (all four back to `blue`, analyses disarmed,
   no pause/abort left over).
5. **IntelliJ** on the repository folder.

---

## Part A: canary — automatic, weighted (3 minutes)

* **Do:**
  ```bash
  ./deploy.sh app argorollouts canary yellow
  ./deploy.sh app argorollouts status
  ```
* **You see:** `phase=Progressing step=0`, then `step=2`, `step=4`... every 20 seconds, until
  `phase=Healthy`. Reload the `canary-demo` Route a few times while it progresses: the color
  flips between blue and yellow roughly in proportion to the current weight; `canary-demo-canary`
  is always the new color, `canary-demo-stable` always the old one.
* **Say:** "Argo Rollouts scales the stable and canary ReplicaSets so their *pod count*
  approximates the step weight — 20%, 40%, 60%, 80%, 100% — and the plain Kubernetes Service load
  balances across whatever pods exist. No mesh, no sidecars, just ReplicaSet math."

---

## Part B: blue-green — a deliberate cutover (3 minutes)

* **Do:**
  ```bash
  ./deploy.sh app argorollouts bluegreen yellow
  ```
* **You see:** `phase=Paused` almost immediately. Open the `bluegreen-demo-preview` Route: it is
  already yellow. Open `bluegreen-demo-active`: still blue. On the **Argo Rollouts dashboard**,
  the `bluegreen-demo` card shows a new revision with yellow checkmarks and an active **Promote**
  button (it was greyed out before — nothing to promote).
* **Say:** "Both versions are fully up right now. Nothing changes for real users until somebody
  looks at the preview and says go."
* **Do (click it in the UI — this is the moment to show):** on the dashboard, click **Promote** on
  the `bluegreen-demo` card. (CLI equivalent: `./deploy.sh app argorollouts promote bluegreen-demo`.)
* **You see:** the card's "Active" revision changes to the new one in real time, no reload needed;
  `bluegreen-demo-active` is now yellow too; `status` shows `phase=Healthy`.
* **Say:** "The cutover is one `status` patch — pauseConditions cleared — not a new rollout. Same
  button does Abort / Retry / Restart on every card: it is reversible before that point — Abort
  leaves `active` on blue forever and keeps the bad pods around to inspect."

---

## Part C: blue-green with **pre**-promotion analysis (4 minutes)

**C1. The happy path.**
* **Do:**
  ```bash
  ./deploy.sh app argorollouts bluegreen-analysis yellow
  oc get analysisrun -n rollouts-demo -w       # Ctrl-C once it says Successful
  ```
* **You see:** an `AnalysisRun` appears, `Successful` within a few seconds; `argorollouts status`
  then shows `bluegreen-analysis-demo` already `Healthy` — the active Service moved on its own.
* **Say:** "Nobody clicked promote. The smoke test — a Job that curls the preview Service's
  `/color` and checks for HTTP 200 — *is* the gate. `autoPromotionEnabled: true` only works because
  `prePromotionAnalysis` stands in front of it."

**C2. Break it.**
* **Do:**
  ```bash
  ./deploy.sh app argorollouts bluegreen-analysis red true
  oc get analysisrun -n rollouts-demo -w
  ```
* **You see:** the `AnalysisRun` goes `Failed`; `argorollouts status` shows the Rollout stuck
  `Paused`/`Degraded`, and the `-preview` Route is red while `-active` stayed yellow — the bad
  color never reached real traffic.
* **Say:** "`fail=true` is my presenter's switch — in a real setup this would be an error-rate
  query instead of a forced failure, same mechanism. Either way: a failing analysis blocks the
  cutover automatically, no human has to notice and react fast enough."
* **Do (clean up before Part D):** `./deploy.sh app argorollouts reset`.

---

## Part D: canary with **post**-promotion analysis (4 minutes)

**D1. The happy path.**
* **Do:**
  ```bash
  ./deploy.sh app argorollouts canary-analysis yellow
  oc get analysisrun -n rollouts-demo -w
  ```
* **You see:** two `AnalysisRun`s in turn (after `setWeight: 20` and after `setWeight: 60`), each
  `Successful`; `status` progresses `step=0` → `step=1` (analysis) → `step=3` → `step=4`
  (analysis) → `step=6`, ending `Healthy` at weight 100.
* **Say:** "Same idea as blue-green's pre-promotion gate, but inline, after every weight bump
  instead of once before a cutover — 'post' because it checks the version traffic was *just*
  shifted to, before letting the next bump happen."

**D2. Break it.**
* **Do:**
  ```bash
  ./deploy.sh app argorollouts canary-analysis red true
  oc get analysisrun -n rollouts-demo -w
  ```
* **You see:** the first `AnalysisRun` (at weight 20) goes `Failed`; `status` shows `phase=Degraded`
  and the canary ReplicaSet scaled back to 0 — `canary-analysis-demo-canary`'s Route goes back to
  serving nothing new, `-stable` never moved off the last good color.
* **Say:** "A failed analysis here doesn't just pause — it actively rolls the canary back to zero.
  The blast radius of the bad version was capped at 20% of pods, for about 20 seconds."
* **Do (clean up before Part E):** `./deploy.sh app argorollouts reset`.

---

## Part E: Developer Hub — the catalog item and day-2 actions (3 minutes)

**E1. The catalog item.**
* **Do:** Developer Hub > **Catalog**, filter **Kind: System**, open **argo-rollouts-demo**.
* **You see:** the System's diagram with its four Components (`rollouts-canary`,
  `rollouts-bluegreen`, `rollouts-bluegreen-analysis`, `rollouts-canary-analysis`) and two
  Resources (`rollouts-smoke-test` the AnalysisTemplate, `rollouts-release-pipeline` the Tekton
  Pipeline).
* **Say:** "One System, four Components — exactly the four strategies we just ran — each wired to
  the live cluster through three tabs."

**E2. The SDLC tabs.**
* **Do:** open component **rollouts-canary** > **Kubernetes** tab.
* **You see:** the `canary-demo` Rollout, its three Services and three Routes, read straight from
  namespace `rollouts-demo` (annotation `backstage.io/kubernetes-id: rollouts-canary`).
* **Do:** the **CI** tab on the same component.
* **You see:** empty until a pipeline has run against this target (Part F fixes that) —
  `tekton.dev/cicd: "true"` is what turns the tab on.
* **Do:** the **CD** tab.
* **You see:** empty until `./deploy.sh app argorollouts gitops <url>` creates the Argo CD
  Application `rollouts-demo` (`argocd/app-name: rollouts-demo` on every one of the four
  Components points at the same Application). Once it exists and has synced, the tab shows a
  **Deployment lifecycle** card for `rollouts-demo` — status, commit, resource count. Click the
  card to open its side panel: a live resource table (every Service/Route/Rollout/AnalysisRun
  Argo CD manages for this Application) and, underneath it, a **Rollout > Revisions** widget —
  one card per revision, each showing the container image and the live traffic percentage, with
  the currently-stable revision marked. Watch it change in real time while a canary from Part A
  or a promote from Part B is in flight.
* **Say:** "Kubernetes, CI and CD are three different read-only views of the same namespace, on
  every one of the four components — not just a link out, actual cluster state. The Rollout
  widget specifically comes from the Argo CD plugin reading the `Rollout`/`AnalysisRun` custom
  resources it's been told about — nothing here is a bespoke plugin we wrote."

**E3. A day-2 action without leaving the browser.**
* **Do:** Developer Hub > **Create** > **Argo Rollouts: canary release** > Action **Release a new
  color**, Color **yellow** > **Create**.
* **You see:** the task succeeds; `oc get rollout canary-demo -n rollouts-demo -w` (or
  `argorollouts status`) shows it progressing exactly like Part A, just triggered from Developer
  Hub.
* **Say:** "This PATCHes the Rollout through the `/platform-actions` proxy with the
  `rhdh-platform-actions` identity — the same scoped RBAC Developer Hub already uses elsewhere,
  reused here for `get`/`patch` on these four Rollouts only (`rbac.yaml`). There are matching
  templates for blue-green (with a **Promote** action), and for both analysis variants (with a
  **Simulate a failure** checkbox that arms the smoke test before releasing)."

---

## Part F: the Tekton pipeline (3 minutes)

* **Do:**
  ```bash
  ./deploy.sh app argorollouts pipeline canary-demo yellow
  ```
* **You see:** `info` prints the PipelineRun name; OpenShift console > **Pipelines** > project
  **rollouts-demo** shows it running two tasks, **release** then **wait-for-rollout**; open it to
  see the graph and both logs.
* **Say:** "Same release as Part A, but as a CI/CD step: `release` does the exact `oc patch` the
  `demo.sh` helper does, `wait-for-rollout` polls `.status.phase` until `Healthy` (or `Degraded`,
  exit 1) so the PipelineRun's own status reflects whether Argo Rollouts' own analysis passed."
* **Do (make it fail on purpose):**
  ```bash
  ./deploy.sh app argorollouts pipeline canary-analysis-demo red true
  ```
* **You see:** the PipelineRun's **release** task first arms the smoke test's `fail` args via a
  second `oc patch`, then releases red; **wait-for-rollout** exits 1 once it sees `Degraded`, and
  the PipelineRun itself shows **Failed** in the console.
* **Say:** "This is the teaching point: a CD gate — Argo Rollouts' own analysis — visibly fails the
  CI pipeline. Nothing downstream of this PipelineRun would ever see the bad release." Then:
  `./deploy.sh app argorollouts reset`.

---

## Part G: how it is built (IntelliJ, 4 minutes)

* [`app/deploy/rollouts-demo/canary.yaml`](../../app/deploy/rollouts-demo/canary.yaml) and
  [`canary-analysis.yaml`](../../app/deploy/rollouts-demo/canary-analysis.yaml) side by side
  (Split Right): point at the identical `steps` shape, then the extra `analysis` blocks in the
  second file and the header comment's exact JSON Patch paths
  (`/spec/strategy/canary/steps/1/analysis/args/1/value`, `.../steps/4/analysis/args/1/value`)
  that every automation (pipeline, `demo.sh`, Developer Hub template) uses to flip `fail` without
  touching `args[0]` (`service-url`).
* [`bluegreen.yaml`](../../app/deploy/rollouts-demo/bluegreen.yaml) vs
  [`bluegreen-analysis.yaml`](../../app/deploy/rollouts-demo/bluegreen-analysis.yaml):
  `autoPromotionEnabled: false` vs `true` + `prePromotionAnalysis`, and the same fixed-index
  comment (`/spec/strategy/blueGreen/prePromotionAnalysis/args/1/value`).
* [`analysis-template.yaml`](../../app/deploy/rollouts-demo/analysis-template.yaml): the one
  shared `AnalysisTemplate` — point at the `job.spec` Kubernetes Job (no Prometheus provider),
  the `{{args.service-url}}`/`{{args.fail}}` templating, and `ttlSecondsAfterFinished: 300` so the
  Job pods don't pile up after a demo.
* [`dashboard.yaml`](../../app/deploy/rollouts-demo/dashboard.yaml): the Argo Rollouts dashboard
  Deployment — point at its own scoped `ServiceAccount`/`Role` (same pattern as `rbac.yaml`, one
  more read-mostly identity) and the image tag pinned to match the installed controller version.
* [`rbac.yaml`](../../app/deploy/rollouts-demo/rbac.yaml): the Role/RoleBinding that lets the
  *existing* `rhdh-platform-actions` ServiceAccount (namespace `rhdh`) `get`/`patch` `rollouts`
  and `rollouts/status`, scoped to `rollouts-demo` only — no new identity needed for the
  Developer Hub templates in Part E.
* [`pipeline.yaml`](../../app/deploy/rollouts-demo/pipeline.yaml): the two tasks, the `case`
  statement in **release** that arms the right Rollout's fail-args for the two analysis targets,
  and **wait-for-rollout**'s poll loop.
* [`stack/developer-hub/catalog-templates/argo-rollouts-demo.yaml`](../../stack/developer-hub/catalog-templates/argo-rollouts-demo.yaml):
  the System, the four Components — point at `backstage.io/kubernetes-id`,
  `backstage.io/kubernetes-namespace: rollouts-demo`, `tekton.dev/cicd: "true"` and
  `argocd/app-name: rollouts-demo` — and the two Resources.
* [`template-rollouts-canary.yaml`](../../stack/developer-hub/catalog-templates/template-rollouts-canary.yaml)
  (and the three sibling `template-rollouts-*.yaml` files): the `http:backstage:request` action
  against `/proxy/platform-actions/...`, `application/json-patch+json` for the release (a
  specific array index) vs `application/merge-patch+json` for abort/retry's `status` subresource.
* [`stack/developer-hub/kustomization.yaml`](../../stack/developer-hub/kustomization.yaml): the
  `rhdh-catalog` ConfigMap generator's explicit file list — every new catalog/template file has to
  be added here too, or it never gets mounted into the Developer Hub pod even though
  `catalog-info.yaml`'s own `targets:` already references it by name (this bit the first build of
  this very demo; see "If something goes wrong").
* **The CD tab's Rollout widget, end to end** — four pieces, all already in this repo:
  1. Each Rollout carries `app.kubernetes.io/instance: rollouts-demo` (see e.g.
     [`canary.yaml`](../../app/deploy/rollouts-demo/canary.yaml) `metadata.labels`) — this is how
     the Argo CD plugin maps a `Rollout` object to the GitOps Application named in the Component's
     `argocd/app-name` annotation. It is a *different* label from
     `app.kubernetes.io/part-of: rollouts-demo` (used elsewhere for grouping); both are needed.
  2. [`stack/developer-hub/app-config.yaml`](../../stack/developer-hub/app-config.yaml)'s
     `kubernetes.customResources` lists both `rollouts` and `analysisruns`
     (`group: argoproj.io, apiVersion: v1alpha1`) — without `analysisruns` the widget renders but
     never shows analysis-gated progress.
  3. [`stack/developer-hub/rbac.yaml`](../../stack/developer-hub/rbac.yaml)'s ClusterRole grants
     `get`/`list`/`watch` on `rollouts`, `analysisruns` and `applications` (`argoproj.io`) to the
     Kubernetes-plugin ServiceAccount.
  4. [`stack/developer-hub/dynamic-plugins.yaml`](../../stack/developer-hub/dynamic-plugins.yaml)'s
     `backstage-community-plugin-argocd` entry needs an explicit `pluginConfig` mounting
     `ArgocdDeploymentSummary` on `entity.page.overview/cards` and `ArgocdDeploymentLifecycle` on
     `entity.page.cd/cards` (condition `isArgocdConfigured`). The plugin ships its own bundled
     default config, but `install-dynamic-plugins` only auto-merges that default for plugins that
     are part of RHDH's base image (Tekton, Kubernetes, Topology, ...); an added-on OCI plugin like
     this one needs the override repeated in our own `dynamic-plugins.yaml`, or neither the
     Overview summary card nor the CD tab appear at all, with no error anywhere. The plugin's own
     bundled default also uses an `importName: ArgocdPage` that does not exist in this plugin
     version (2.8.1) and silently renders nothing — use the exact `ArgocdDeploymentSummary`/
     `ArgocdDeploymentLifecycle` names from [the RHDH 1.10 docs](https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.10/html/configuring_dynamic_plugins/install-and-configure-argo-cd_configuring-dynamic-plugins)
     instead.

  Nothing here is a custom plugin — it is the already-installed `@backstage-community/plugin-argocd`
  (its Argo Rollouts support shipped in
  [backstage/community-plugins#1153](https://github.com/backstage/community-plugins/pull/1153)),
  wired up with configuration only.
* [`app/demo.sh`](../../app/demo.sh) (search for `argorollouts`): the `argorollouts` function and
  its `rollouts_*` helpers — point at `rollouts_release`'s `--type=json` patches and
  `rollouts_promote`/`abort`/`retry`'s `--subresource=status` (the Rollout CRD declares `status`
  as a real subresource, so a plain
  `oc patch -p '{"status":...}'` silently no-ops without that flag).

---

## Part H: configuration reference — change it yourself

Every knob below is a few lines of YAML, applied with a plain `oc apply -f` (the object name
never changes, so this is a live edit of the running Rollout, not a new one). Each example edits
one file in [`app/deploy/rollouts-demo/`](../../app/deploy/rollouts-demo/) and reminds you how to
put it back.

**Make the canary slower or faster** —
[`canary.yaml`](../../app/deploy/rollouts-demo/canary.yaml#L29-L38), `spec.strategy.canary.steps`:

```yaml
steps:
  - setWeight: 20
  - pause: {duration: 20s}      # <- change to 5s for a snappier demo, or 2m for a slow one
  - setWeight: 40
  - pause: {duration: 20s}
  - setWeight: 60
  - pause: {duration: 20s}
  - setWeight: 80
  - pause: {duration: 20s}
  - setWeight: 100
```

Edit the four `duration` values (or add/remove `setWeight` steps entirely — e.g. a single
`setWeight: 50` step for a two-stage canary), then:
```bash
oc apply -f app/deploy/rollouts-demo/canary.yaml
./deploy.sh app argorollouts canary yellow   # new revision picks up the new step timing
```
`canary-analysis.yaml` has the same `steps` shape with two `analysis` blocks mixed in — the
timing knobs (`pause.duration`) are edited the same way; just leave the `analysis` entries where
they are.

**Switch blue-green to auto-promote without analysis** —
[`bluegreen.yaml`](../../app/deploy/rollouts-demo/bluegreen.yaml#L25-L29), one field:
```yaml
strategy:
  blueGreen:
    activeService: bluegreen-demo-active
    previewService: bluegreen-demo-preview
    autoPromotionEnabled: false     # <- true: cuts over right away, no manual promote step
```

**Change what the smoke test checks, or how many times it runs** —
[`analysis-template.yaml`](../../app/deploy/rollouts-demo/analysis-template.yaml#L20-L44):
```yaml
metrics:
  - name: smoke-test
    count: 1              # <- run the check N times before deciding (e.g. 3 for less flakiness)
    failureLimit: 0       # <- how many of those N are allowed to fail
    provider:
      job:
        spec:
          template:
            spec:
              containers:
                - name: smoke-test
                  command: ["/bin/bash", "-c"]
                  args:
                    - |
                      # <- replace this whole script with a real check: hit a /healthz endpoint,
                      # run a query against a metrics backend, call a test suite — anything that
                      # exits 0 for healthy / non-zero for unhealthy. {{args.service-url}} and
                      # {{args.fail}} are the two args every caller (pipeline, demo.sh, Developer
                      # Hub template) already knows how to set.
```
This one `AnalysisTemplate` is shared by both `bluegreen-analysis-demo` and
`canary-analysis-demo` — a change here affects both demos' gate at once.

**Change the pipeline's defaults** —
[`pipeline.yaml`](../../app/deploy/rollouts-demo/pipeline.yaml#L14-L24), `spec.params`:
```yaml
params:
  - name: color
    type: string
    default: yellow        # <- the color a bare `./deploy.sh app argorollouts pipeline <target>` releases
  - name: simulate-failure
    type: string
    default: "false"
```

**After any edit above:** `oc apply -k app/deploy/rollouts-demo` re-applies every file in this
folder at once (safe to run any time); `./deploy.sh app argorollouts reset` puts the *data* (image
colors, armed/disarmed fail-flags) back to baseline, but does not revert a YAML edit you made —
`git checkout app/deploy/rollouts-demo/<file>.yaml` does that.

---

## Prove it from the terminal

```bash
./deploy.sh app argorollouts deploy
./deploy.sh app argorollouts canary yellow   && sleep 90  && ./deploy.sh app argorollouts status   # Healthy
./deploy.sh app argorollouts bluegreen yellow && ./deploy.sh app argorollouts promote bluegreen-demo
./deploy.sh app argorollouts bluegreen-analysis red true  && sleep 10 && oc get analysisrun -n rollouts-demo   # Failed
./deploy.sh app argorollouts canary-analysis red true     && sleep 10 && oc get analysisrun -n rollouts-demo   # Failed
./deploy.sh app argorollouts reset
```

## Reset

```bash
./deploy.sh app argorollouts reset      # all four back to blue, analyses disarmed, nothing aborted/paused
```

To remove the whole tutorial: `oc delete -k app/deploy/rollouts-demo` (or
`oc delete namespace rollouts-demo`).

## If something goes wrong

* **A Rollout never leaves `Progressing`/`Paused` after `promote`/`abort`/`retry`, with no error:**
  the Rollout CRD declares `status` as a real Kubernetes subresource
  (`oc get crd rollouts.argoproj.io -o jsonpath='{.spec.versions[?(@.name=="v1alpha1")].subresources}'`
  shows `status: {}`). A plain `oc patch -p '{"status":...}'` reports "patched (no change)" and
  does nothing; it needs `--subresource=status`. `demo.sh`'s `rollouts_promote`/`abort`/`retry`
  already do this; a hand-written `oc patch` command needs the flag added explicitly.
* **The Developer Hub release/abort/retry templates work, but a direct `oc patch` by hand on the
  same field does not:** not a contradiction — the templates PATCH the literal
  `/rollouts/<name>/status` URL path over HTTP through the `/platform-actions` proxy, a different
  (and here, correct-by-default) mechanism from the `oc patch` CLI's subresource routing.
* **A new System/Component never shows up in Developer Hub's catalog after `./deploy.sh rhdh`,
  with zero errors in the backend log:** check that the file is actually mounted:
  `oc exec -n rhdh deploy/backstage-developer-hub -c backstage-backend -- ls
  /opt/app-root/src/catalog/`. `catalog-info.yaml`'s own `targets:` list is not enough — the file
  also has to be listed explicitly in `stack/developer-hub/kustomization.yaml`'s `rhdh-catalog`
  `configMapGenerator`, or it never reaches the pod at all (this is exactly what happened the
  first time this demo's catalog files were added; fixed by adding them to that list and
  `oc rollout restart deployment/backstage-developer-hub -n rhdh`).
* **Catalog file is mounted, but the entity still doesn't appear:** give it 15-30 seconds after the
  new pod is `Running` — ingestion (`refresh_state`) and stitching (`stitch_queue` →
  `final_entities`) are asynchronous. If it never appears, check for a policy-check warning
  (invalid `metadata.name`, bad kind) in the backend log.
* **`AnalysisRun` stuck `Running` forever:** the Job's pod likely can't resolve or reach the target
  Service — confirm `service-url` matches the Rollout's actual Service name
  (`<rollout>-canary`/`-preview`) and that `oc get job -n rollouts-demo` shows the pod actually
  started (image pull of `ubi9/ubi-minimal` failing would show here first).
* **Leftover `Job`/`AnalysisRun`/`PipelineRun` objects accumulating after repeated testing:** the
  AnalysisTemplate's Job already self-cleans after 5 minutes (`ttlSecondsAfterFinished: 300`); for
  everything else: `oc delete analysisrun,pipelinerun,job -n rollouts-demo --all`.
* **The CD tab never appears on any catalog entity (not just this demo's), even with
  `argocd/app-name` set and the Argo CD backend otherwise working:** check
  `oc logs -n rhdh deploy/backstage-developer-hub -c install-dynamic-plugins | grep -A3
  plugin-argocd` — if the line `Merging plugin-specific configuration` is missing right after it,
  the frontend plugin's own bundled mount-point config was not picked up. Add the `pluginConfig`
  override shown in Part G's "CD tab's Rollout widget" bullet to
  `stack/developer-hub/dynamic-plugins.yaml`, re-apply (`oc apply -k stack/developer-hub`) and
  restart (`oc rollout restart deployment/backstage-developer-hub -n rhdh`); confirm with
  `curl -sk https://<rhdh-route>/ | grep -A20 '"backstage-community.plugin-argocd"'` that
  `entity.page.cd/cards` now shows up in the page's embedded config.
* **The Rollout widget shows a different revision history than expected, or only appears for one
  of the four `rollouts-*` components:** all four Rollouts in this demo share a single Argo CD
  Application (`rollouts-demo`), so the CD tab's "Deployment lifecycle" card is the same for every
  one of the four catalog Components — it is an Application-level view, not scoped to the specific
  Rollout a given Component's annotations point at. This is expected with one shared GitOps
  Application per demo; a production setup with one Application per service would not have this
  ambiguity.
* **`docker.io/argoproj/rollouts-demo:blue` image pull fails from `quay.io` instead:** this
  tutorial intentionally pins `docker.io/argoproj/rollouts-demo`, not the `quay.io` mirror some
  older Argo Rollouts docs reference — the `quay.io` copy returned `unauthorized` when this was
  last checked.
