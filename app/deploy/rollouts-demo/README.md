# Argo Rollouts: deployment strategies

Four self-contained Argo Rollouts, each demonstrating one strategy, independent of the rest of the
`ai-demo` stack (no service mesh, no MaaS, no Kafka -- only Argo Rollouts and OpenShift Pipelines).
Workload: the upstream [`argoproj/rollouts-demo`](https://hub.docker.com/r/argoproj/rollouts-demo)
image (a colored square on `/`, the color as JSON on `/color`), the same app the Argo Rollouts
project itself uses in its "Getting started" guide. Presenter guide with Do / You see / Say:
[docs/demos/09-argo-rollouts.md](../../../docs/demos/09-argo-rollouts.md).

| Demo | Rollout | What it shows |
|---|---|---|
| Canary | `canary-demo` | Weighted traffic shift in 20% steps, fully automatic (timed pauses) |
| Blue-green | `bluegreen-demo` | Two live Services (active + preview); the cutover is a deliberate, manual action |
| Blue-green + **pre**-promotion analysis | `bluegreen-analysis-demo` | A smoke test against the preview Service gates the cutover automatically |
| Canary + **post**-promotion analysis | `canary-analysis-demo` | A smoke test after each weight step gates the next one; a failure auto-aborts |

## Where the configuration lives

| What | File |
|---|---|
| Canary steps and Services | `canary.yaml` |
| Blue-green Services and `autoPromotionEnabled: false` | `bluegreen.yaml` |
| Blue-green `prePromotionAnalysis` | `bluegreen-analysis.yaml` |
| Canary per-step `analysis` | `canary-analysis.yaml` |
| The shared "smoke test" `AnalysisTemplate` (a Kubernetes Job, no Prometheus needed) | `analysis-template.yaml` |
| Namespace | `namespace.yaml` |
| Developer Hub template identity may `get`/`patch` these four Rollouts | `rbac.yaml` |
| The deployment pipeline (release a color, arm/disarm the smoke test, wait for the result) | `pipeline.yaml` |
| Argo CD Application (`app/demo.sh argorollouts gitops <url>`) | `argocd-application.yaml` |
| Developer Hub catalog entities (system, 4 components) | `../../../stack/developer-hub/catalog-templates/argo-rollouts-demo.yaml` |
| Developer Hub day-2 templates (release / promote / abort / retry) | `../../../stack/developer-hub/catalog-templates/template-rollouts-*.yaml` |
| The Argo Rollouts web dashboard (upstream `kubectl argo rollouts dashboard`, as a Deployment+Route) | `dashboard.yaml` |

`canary.yaml` and `canary-analysis.yaml` each define **three** Services (the blended one plus
`-canary` / `-stable`) purely so you can open all three Routes side by side and watch one version
at a time while the blended one shows the live mix -- the same technique the upstream Argo
Rollouts tutorial uses. `bluegreen*.yaml` define `-active` / `-preview`.

## Run it

```bash
./deploy.sh app argorollouts deploy                     # namespace, 4 Rollouts, Services, Routes, AnalysisTemplate, Pipeline

./deploy.sh app argorollouts canary [color]              # color: blue | yellow | green | red (default yellow)
./deploy.sh app argorollouts bluegreen [color]
./deploy.sh app argorollouts promote bluegreen-demo       # manual cutover
./deploy.sh app argorollouts bluegreen-analysis [color] [fail]   # fail: true | false (default false)
./deploy.sh app argorollouts canary-analysis [color] [fail]

./deploy.sh app argorollouts abort <rollout>              # back to stable/active, keep the bad pods around to look at
./deploy.sh app argorollouts retry <rollout>              # resume an aborted rollout
./deploy.sh app argorollouts reset                        # all four back to blue, analyses disarmed
./deploy.sh app argorollouts status                       # phase + step of all four, and the AnalysisRuns
./deploy.sh app argorollouts urls                         # every Route

./deploy.sh app argorollouts pipeline <rollout> [color] [fail]   # the same release, run as a Tekton PipelineRun
./deploy.sh app argorollouts gitops <git-url> [revision]  # let Argo CD manage this folder
```

`./deploy.sh app argorollouts urls` prints the **Argo Rollouts dashboard** URL first -- open it to watch
all four Rollouts progress as cards, with their own **Promote** / **Abort** / **Retry** / **Restart**
buttons (same effect as the `demo.sh` commands above, just clickable).

`<rollout>` is one of `canary-demo`, `bluegreen-demo`, `bluegreen-analysis-demo`,
`canary-analysis-demo`.

## Notes

* **Why native Services, not the mesh.** `app/deploy/overlays/rollouts/model-router-rollout.yaml`
  already shows an Argo Rollouts canary driven by Istio traffic weights. This tutorial is the other
  half of the picture: Argo Rollouts' own traffic management (pod-count ratios behind one Service,
  plus separate preview/active Services for blue-green), which needs nothing but the Rollout
  controller itself and works on a cluster without a service mesh.
* **The `fail` switch.** `bluegreen-analysis-demo` and `canary-analysis-demo` keep the smoke test's
  `fail` argument at a fixed array index (see the comments in the two YAML files) so the Tekton
  pipeline, `demo.sh` and the Developer Hub templates can all flip it with a precise JSON Patch
  without touching `service-url`.
* **Status is a real subresource.** Promote / abort / retry patch `.status`, which this CRD exposes
  as a separate subresource: local `oc patch` needs `--subresource=status`, the Developer Hub
  templates get there for free because they PATCH the literal `/rollouts/<name>/status` URL through
  the `/platform-actions` proxy.
* **Cleanup.** `./deploy.sh app argorollouts reset` does not delete anything; to remove the whole
  tutorial: `oc delete -k app/deploy/rollouts-demo` (or `oc delete namespace rollouts-demo`).
* **The dashboard is the official one, not a custom UI.** `dashboard.yaml` runs the exact
  `quay.io/argoproj/kubectl-argo-rollouts` CLI image's `dashboard` subcommand as a Deployment,
  version-pinned to match the installed controller (`v1.10.0`). Its own ServiceAccount/Role is
  scoped to `get`/`list`/`watch` plus the few `patch`es its Promote/Abort/Retry/Restart buttons
  need, in `rollouts-demo` only -- the same scoping pattern as `rbac.yaml`'s Developer Hub
  identity, just for this one extra pod.
