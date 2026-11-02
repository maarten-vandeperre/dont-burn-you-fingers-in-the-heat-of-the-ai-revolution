# Trusted software supply chain (TSSC)

From a signed commit to a signed, checked, deployed image, on the same cluster as the AI platform.
A dedicated Developer Hub catalog item (`coffee-menu-tssc`) links the code, the Dev Spaces
workspace and the live Tekton pipeline, and shows its PipelineRuns in the CI tab.

```
Dev Spaces ──git commit -S (gitsign, Keycloak login)──> GitLab ──webhook──> Tekton (tssc-ci)
                    │                                                          │
                    └─ certificate from Fulcio, entry in Rekor                 │
                                                                               ▼
                                     ,-> static-analysis (MOCK) ->,
     clone -> verify-commit --------+-> unit-tests       (MOCK) -+-> build-image -> sign-image -> sbom
                                     `-> integration-tests(MOCK) ->'      (podman)   (cosign+Rekor)  (syft+attest)
           -> tpa-check -> acs-checks -> push-release -> argocd-sync
             (RHTPA, CVEs)  (ACS, or MOCK)  (:release tag)  (MOCK unless an Argo CD app exists)
```

| Component | Role | Installed by |
|---|---|---|
| Red Hat Trusted Artifact Signer | Sigstore: Fulcio (certificates for Keycloak identities), Rekor (transparency log), TUF (trust root); CLI server if the installed edition ships one (not present on RHTAS 1.5.0 — see "Design choices") | `tssc setup` (operator + `Securesign`) |
| Red Hat Trusted Profile Analyzer 2 | SBOM store and vulnerability analysis | `tssc setup` (Helm chart, needs `helm` 3.17+) |
| OpenShift Dev Spaces | browser IDE; commits signed with gitsign | `tssc setup` (operator + `CheCluster`) |
| OpenShift Pipelines | the pipeline and the GitLab trigger | platform stack |
| Red Hat build of Keycloak | identities: realm `demo`, user `admin@demo.example.com` | platform stack (`tssc setup` adds clients) |
| podman (in-pipeline) | builds and pushes the container image | task `build-image` (`registry.redhat.io/rhel9/podman`) |
| Advanced Cluster Security | image and deployment checks | optional, bonus step: Secret `acs-central` in `tssc-ci`, otherwise MOCK from real facts |
| OpenShift GitOps | deploys the signed digest | platform stack (`./deploy.sh app gitops <url>` for the app; otherwise MOCK) |
| Red Hat Developer Hub | catalog item `coffee-menu-tssc`: links + live CI tab | `./deploy.sh rhdh` (rerun after `tssc setup` so links resolve) |

### Which steps are mocked, and why

`static-analysis`, `unit-tests` and `integration-tests` are **always mocked** — they are stand-ins
for whatever real tool a team actually uses (SonarQube, Gradle, Testcontainers, ...) and are not
the focus of this demo; swap their single script step for a real one without touching the rest of
the pipeline. They run in parallel (same `runAfter: [verify-commit]`, no dependency between them).

`tpa-check`, `acs-checks` and `argocd-sync` are **conditionally mocked**: each becomes real the
moment the corresponding optional piece exists (RHTPA installed, Secret `acs-central`, Argo CD app
`ai-demo`). Every mocked or simulated task prints `MOCK` or `SIMULATED` as the first word of its
log, so a demo audience can always tell a real result from a stand-in.


## Commands

```bash
./deploy.sh tssc setup              # everything (repeatable); --tpa-importers, --skip-tpa, --skip-devspaces
./deploy.sh tssc run                # start the pipeline on main; --allow-unsigned, --gate fail, --revision
./deploy.sh tssc verify             # verify ai-demo/coffee-menu:release: signature, SBOM attestation, Rekor
./deploy.sh tssc urls               # all links
./deploy.sh tssc destroy            # CI namespace, RHTPA, RHTAS instance (operators stay)
```

Prerequisites: the platform (`./deploy.sh stack`), the demo apps (`./deploy.sh app all`), GitLab
(`./deploy.sh gitlab`), and `helm` 3.17+ on your machine for Trusted Profile Analyzer.

## Design choices

* **Commits are signed keyless by a person** (gitsign, Keycloak login). The signature certificate
  names the user's verified email and is recorded in Rekor; the pipeline checks identity and issuer.
* **In Dev Spaces, gitsign uses the copy-the-code login**: the browser login cannot call back into a
  workspace, so `sign-setup.sh` makes the browser openers fail and gitsign prints a link and asks
  for the code Keycloak shows (redirect URI `urn:ietf:wg:oauth:2.0:oob`). Works with every gitsign.
* **The image is signed by the pipeline with a cosign key** kept in Secret `tssc-ci/cosign-signing`
  (generated in the cluster) and still recorded in RHTAS Rekor. Keyless signing for the pipeline
  itself would need extra Keycloak audience mappings.
* **The tools image** is built in the cluster. It *prefers* the cosign, gitsign, rekor-cli and ec
  clients from this cluster's RHTAS CLI server (so client and server versions always match), but
  that component genuinely does not exist on every RHTAS edition — confirmed absent on the
  installed RHTAS 1.5.0 (`oc explain securesign.spec` has no `cliServer` field; no
  Deployment/Service/Route labelled `app.kubernetes.io/component=client-server` anywhere in
  `trusted-artifact-signer`). When there is no CLI server, `tools-build.yaml` falls back to the
  upstream sigstore GitHub releases instead, with two version choices that matter and are pinned
  deliberately, not left on "latest":
  - **cosign is pinned to the latest 2.x release** (`COSIGN_VERSION`, currently 2.6.5), not 3.x.
    cosign v3 always pushes signatures/attestations as an OCI 1.1 "referrers" image index with a
    `subject` field; OpenShift's internal registry's `ImageStreamMapping` validation unconditionally
    requires `architecture`/`os` on every image index, which a signature-only index does not have,
    so every v3 `cosign sign`/`attest` push against this registry fails with
    `dockerImageManifests[0].architecture: Required value` (confirmed directly against this
    cluster; neither `--registry-referrers-mode=legacy` nor `COSIGN_DOCKER_MEDIA_TYPES=1` change
    the unconditional index wrapper). cosign 2.x still pushes the older, flat manifest the
    `--rekor-url`/`--tlog-upload` flags in `pipeline.yaml` expect, and works end to end.
  - **gitsign is built from source**, not downloaded prebuilt. Every current upstream prebuilt
    gitsign release (including the latest, v0.17.1) embeds a permanently stale TUF bootstrap root
    for Rekor's public key (a *different*, legacy `sigstore/sigstore` TUF client than the one
    `gitsign initialize --mirror` configures — used unconditionally by `cosign.GetRekorPubs()`
    inside gitsign's own Rekor-client construction). That embedded root's `expires` field is
    already in the past upstream, so `gitsign sign`/`verify-commit` fails outright with
    `tuf: ... expired` before it ever touches the network, no matter which mirror gitsign was
    initialized against or whether `GITSIGN_ENABLE_SIGSTORE_GO` is set. The fix: at image-build
    time, `tools-build.yaml` clones gitsign, patches its vendored `sigstore/sigstore` copy's
    embedded `root.json` to be *this cluster's own* current RHTAS root (fetched live from
    `TUF_URL`, not the public sigstore.dev one — that keeps everything air-gapped and matches
    this demo's "nothing leaves the company" design, and was confirmed to be the only approach
    that works: embedding a fresh *public* root still fails differently, "valid signatures did
    not meet threshold", because `TUF_URL`'s metadata is signed with this cluster's own distinct
    RHTAS keys), then builds gitsign from source with `go.mod replace`.
* **Trusted Profile Analyzer API**: `/api/v3` with fallback to `/api/v2`. Vulnerability data comes from
  importers that are off by default (several GB); `--tpa-importers` turns on the CVE list and GitHub
  advisories. Without them the SBOM is stored and browsable, with no advisories yet.
* **The pipeline runs in `tssc-ci`, outside the service mesh** (no sidecars in pipeline pods) and
  pushes to the `ai-demo` image streams.
* **The repo's root `.gitignore` has a `!**/gradle/wrapper/gradle-wrapper.jar` exception** to its
  blanket `*.jar` rule. Without it, `gradle-wrapper.jar` is silently dropped from every commit —
  including the GitLab "Platform snapshot" re-push `./deploy.sh gitlab` does (`rsync` copies the
  working tree into a scratch directory, then runs a *fresh* `git init && git add -A`, which
  re-applies whatever `.gitignore` got copied along with it) — which breaks `build-image` for
  every Gradle-based service with `Unable to access jarfile .../gradle-wrapper.jar`, even though
  the jar is present and already tracked in this repo's own history. If `build-image` ever
  regresses with that exact error, check `git check-ignore -v app/gradle/wrapper/gradle-wrapper.jar`
  first.
* **The image is built with podman** (`registry.redhat.io/rhel9/podman`, `--storage-driver=vfs
  --isolation=chroot`), the same rootless-compatible pattern OpenShift Pipelines documents for
  Buildah: no privileged SCC, just the `SETFCAP` capability on the step. `--isolation=chroot` is
  required here — without it `RUN` steps fail with `mount proc to proc: Permission denied` under
  this cluster's default SCC (podman's other isolation modes want to mount a fresh `/proc`, chroot
  does not); verified end-to-end on a live OpenShift 4.22 cluster while building this demo.
* **Static analysis, unit tests and integration tests are three separate, always-mocked Tekton
  tasks**, not one combined "CI" step: they all `runAfter: [verify-commit]` with no dependency on
  each other, so Tekton schedules them in parallel, and `build-image` waits on all three. Each one
  is a single, obvious script step to swap for a real tool.
* **The Developer Hub catalog item (`coffee-menu-tssc`) is separate from the `coffee-menu`
  component**: the pipeline's resources live in `tssc-ci`, a different namespace from the app's
  `ai-demo`, and Backstage's Kubernetes plugin scopes every lookup to the single namespace named
  in `backstage.io/kubernetes-namespace`. A second Component with its own namespace annotation,
  linked back with `subcomponentOf: component:coffee-menu`, is simpler and more correct than
  stretching one Component's annotations across two namespaces.
* **The PipelineRun needs the label `backstage.io/kubernetes-id: coffee-menu-tssc`** (set in
  `ci/triggers.yaml` and in `tssc.sh run`) for Developer Hub's Tekton plugin to find it; Tekton
  propagates that label to the TaskRuns it creates, so nothing else needs to be labelled by hand.

## Files

| Path | Contains |
|---|---|
| `tssc.sh` | setup, run, verify, urls, destroy |
| `operators/` | subscriptions: `rhtas-operator`, `devspaces` |
| `rhtas/securesign-v1.yaml`, `-v1alpha1.yaml` | the RHTAS instance; the script picks the version the operator serves |
| `rhtpa/` | PostgreSQL, Helm values, importers |
| `devspaces/` | `CheCluster`; `sign-setup.sh`, `sign-commit.sh`, `verify-commit.sh` (devfile commands) |
| `ci/` | namespace, RBAC, tools image build, the pipeline (`pipeline.yaml`), the GitLab trigger (`triggers.yaml`) |
| `generated/signing.env` | the RHTAS endpoints of this cluster, written by `tssc setup` |
| `../../devfile.yaml` | the Dev Spaces workspace definition with the three signing commands |
| `../developer-hub/catalog-templates/ai-demo.yaml` | the `coffee-menu-tssc` Component (links, `subcomponentOf`, `dependsOn`) |
| `../developer-hub/catalog-templates/platform.yaml` | the `trusted-artifact-signer`, `trusted-profile-analyzer`, `dev-spaces` Resources it depends on |

Demo guide: [docs/demos/08-trusted-software-supply-chain.md](../../docs/demos/08-trusted-software-supply-chain.md).
