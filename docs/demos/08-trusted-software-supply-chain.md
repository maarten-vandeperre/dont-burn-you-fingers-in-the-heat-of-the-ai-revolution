# Demo 8: Trusted software supply chain

**The story:** every step from a developer's commit to a running container is signed, checked and
recorded. The commit is signed with the developer's company identity, the pipeline refuses commits
it cannot trust, three CI checks run in parallel, the image is built with podman, signed and gets a
bill of materials, that SBOM is checked for known vulnerabilities, security policies are enforced,
and only the verified digest is deployed. The whole thing is one catalog item in Developer Hub,
linked to the code, the Dev Spaces workspace and the live Tekton pipeline.

**Duration:** 25 minutes (5 Dev Spaces, 10 pipeline, 5 Developer Hub, 5 proof). Parts C to G also
work on their own with `./deploy.sh tssc run`.

```
Dev Spaces: git commit (signed, Keycloak login) ─> GitLab ─> webhook ─> pipeline in tssc-ci:

                      ,-> static-analysis (MOCK) ->,
  clone -> verify-commit -> unit-tests       (MOCK) -+-> build-image (podman) -> sign-image -> sbom
                      `-> integration-tests(MOCK) ->'
        -> tpa-check (CVEs) -> acs-checks -> push-release -> argocd-sync (MOCK unless an Argo CD app exists)
```

Every step below has three parts: **Do** (what you click, type or open), **You see**, **Say**.

| Step | Real or mocked |
|---|---|
| Commit signing (gitsign) and verification | **real**: Trusted Artifact Signer on this cluster |
| Clone, verify commit signature (blocks unknown identities) | **real** |
| Static analysis, unit tests, integration tests (run in parallel) | **MOCK**: always simulated, see "Why these three are mocked" below |
| Image build (podman), push | **real** |
| Image signature, SBOM, SBOM attestation | **real**: cosign, syft, Rekor |
| Trusted Profile Analyzer check and CVE report | **real** when RHTPA is installed (needs `helm`), otherwise **SIMULATED** |
| Advanced Cluster Security checks | **SIMULATED** from real facts, unless Secret `acs-central` exists (then real `roxctl`) — a bonus step, not asked for by name but useful to show policy-as-code |
| Argo CD sync | **MOCK** by default; becomes real once the Argo CD app `ai-demo` exists (`./deploy.sh app gitops <url>`) |
| Developer Hub catalog item, CI tab | **real**: live PipelineRuns from this cluster |

**Why static analysis / unit tests / integration tests are mocked:** this demo is about the trusted
supply chain (signing, provenance, SBOM, vulnerability and policy checks), not about a specific
test stack. The three tasks are deliberately simple stand-ins — swap them for `sonar-scanner`,
`./gradlew test` and your real integration suite without touching anything else in the pipeline.
As it happens, `coffee-menu` itself has no test sources yet, so "mock" also reflects reality, not
just a demo shortcut. Every mocked task prints `MOCK` as the first word of its log, and every
step that is mocked *only because an optional component is not installed* prints `SIMULATED`, so a
demo audience can always tell a real cryptographic/security result apart from a stand-in.

---

## Before you start

1. Once (about 30 minutes):
   ```bash
   ./deploy.sh tssc setup          # add --tpa-importers for vulnerability data (hours to import)
   ```
   It installs Trusted Artifact Signer, Trusted Profile Analyzer, Dev Spaces, the pipeline and the
   GitLab webhook, writes `stack/tssc/generated/signing.env` and pushes the repository to GitLab.
2. Developer Hub needs its own render + apply after `tssc setup` has created the `tssc-ci`
   namespace and the Dev Spaces workspace, so the catalog's links resolve: `./deploy.sh rhdh`.
3. Check: `./deploy.sh validate --quick` (the `tssc` and `rhdh` lines) and `./deploy.sh tssc urls`.
4. Optional, for a real Argo CD sync instead of the mocked one: `./deploy.sh app gitops
   https://<gitlab-host>/ai-platform/platform.git`.
5. Browser tabs: **Developer Hub** (catalog item `coffee-menu: trusted software supply chain`),
   **Dev Spaces workspace** (URL "Dev Spaces workspace" from `tssc urls`; the first start takes a
   few minutes), **OpenShift console > Pipelines** (project `tssc-ci`), **Trusted Profile
   Analyzer**, **GitLab**.
6. In the workspace, run once: **Terminal > Run Task > devfile > 1. Set up commit signing**.
   **You see:** `OK: every commit in this repository is now signed with gitsign`.

Do not run `./deploy.sh gitlab` between the demo and your signed commit: it force-pushes `main`
and replaces the history, including signed commits.

---

## Part A: the trust services (2 minutes)

* **Do:** OpenShift console > **Installed Operators**, project `trusted-artifact-signer`: Red Hat
  Trusted Artifact Signer > **Securesign** `rhtas`.
* **You see:** status Ready; Fulcio, Rekor, TUF, CT log as separate resources.
* **Say:** "This is Sigstore, run by us: Fulcio issues short-lived signing certificates for our own
  Keycloak identities, Rekor is the tamper-evident log of every signature, TUF distributes the trust
  root. Nothing leaves the company."

---

## Part B: sign a commit in Dev Spaces (5 minutes)

**B1. Open the workspace from Developer Hub (optional, shows the catalog link).**
* **Do:** Developer Hub > **Catalog** > component **coffee-menu: trusted software supply chain**
  > **Open in Dev Spaces** (in the Links card).
* **You see:** the Dev Spaces workspace opens on this repository, cloned from GitLab.
* **Say:** "A developer never needs to know a cluster URL by heart: the catalog item is the
  starting point for the code, the IDE and the pipeline."

**B2. Sign.**
* **Do:** in the workspace: **Terminal > Run Task > devfile > 2. Sign a commit and push**.
* **You see:** `Go to the following link in a browser:` with a Keycloak URL, then
  `Enter verification code:`.
* **Do:** open the link, log in (`admin` / your demo password), copy the code Keycloak shows, paste
  it in the terminal, Enter.
* **You see:** the commit (`coffee-menu: release notes (signed in Dev Spaces)`), the start of its
  `gpgsig` signature block, and the push to GitLab.
* **Say:** "No GPG key to manage, nothing on my laptop. My company login proves who I am; Fulcio gave
  me a certificate valid for ten minutes, the signature is in the transparency log forever."

**B3. Verify it yourself.**
* **Do:** **Run Task > devfile > 3. Verify the last commit**.
* **You see:** `Validated Git signature: true`, `Validated Rekor entry: true`, the certificate identity
  `admin@demo.example.com` and issuer (the Keycloak realm).

---

## Part C: the pipeline runs (10 minutes)

* **Do:** OpenShift console > **Pipelines** > project **tssc-ci** > **PipelineRuns**: the new run
  `coffee-menu-...` (started by the GitLab webhook — see "If something goes wrong" for exactly
  which pushes trigger it; Part B2's signed commit qualifies). Open it; the graph shows **clone**,
  **verify-commit**, the three parallel checks, then **build-image** through **argocd-sync** in a
  single chain.

Walk through the tasks while they run; click a task to see its log.

| Task | You see in the log | Say |
|---|---|---|
| **clone** | the commit, author, message | "The pipeline fetches exactly the commit the webhook named, nothing cached." |
| **verify-commit** | `OK: commit signed by admin@demo.example.com, certificate from Trusted Artifact Signer, recorded in Rekor` (or `STOP: ...` for an unknown identity) | "The pipeline trusts no commit it cannot attribute to a known person — this is the gate the rest of the chain depends on." |
| **static-analysis** *(MOCK, parallel)* | `MOCK: static code analysis ...`, a real file count, `MOCK OK: ... passed` | "Stands in for SonarQube or Checkstyle; swap the script, keep the pipeline." |
| **unit-tests** *(MOCK, parallel)* | `MOCK: unit tests ...`, `MOCK result: Tests run: 38, Failures: 0` | "Stands in for `./gradlew test`. coffee-menu has no real tests yet, so this is honestly mocked, not just for the demo." |
| **integration-tests** *(MOCK, parallel)* | `MOCK: integration tests ...`, `MOCK result: 6 scenarios passed` | "Stands in for Testcontainers or a staging run. All three ran at the same time — look at the start times in the graph." |
| **build-image** | base images (UBI), `building with podman (storage driver vfs, chroot isolation...)`, `OK: pushed .../ai-demo/coffee-menu:<commit> = sha256:... (built with podman)` | "A real podman build, no Docker daemon anywhere on this cluster. From here on we only speak in digests, never tags." |
| **sign-image** | `tlog entry created with index: N`, the verify output, a Rekor URL | "Signed and logged. Anyone can verify it, and tampering would be visible." |
| **sbom** | `SBOM (CycloneDX): N components`, the Java libraries, `SBOM attached ... as a signed attestation` | "The image carries its own signed ingredient list." |
| **tpa-check** | `SBOM stored in Trusted Profile Analyzer`, a link, `affected vulnerabilities: ...` | "Every SBOM lands in one place, where security can see which images contain a vulnerable library — and the CVEs are reported right here in the log." |
| **acs-checks** | image, deployment and environment checks with PASS/WARN (first line says `SIMULATED` unless `acs-central` is configured) | "Policy as code: trusted base image, pinned digest, limits, no privilege, mTLS in the target namespace. A bonus step beyond the core ask, useful to show policy enforcement." |
| **push-release** | `:release now points to the signed, checked digest` | "Promotion moves a pointer; the signature stays valid because the digest does not change." |
| **argocd-sync** | `SIMULATED: no Argo CD application ...` (default, the mocked step) or `sync of ai-demo started ...` / `Argo CD synced` if `./deploy.sh app gitops` was run | "GitOps deploys exactly the digest we verified — mocked here unless we wired a real Argo CD app." |

Mocked and simulated steps say `MOCK` or `SIMULATED` on their first log line, with what they would
do instead; say so openly when you point at them.

---

## Part D: find it in Developer Hub (5 minutes)

**D1. The catalog item.**
* **Do:** Developer Hub > **Catalog**, filter **Kind: Component**, open **coffee-menu: trusted
  software supply chain** (or reach it from component **coffee-menu** > **Diagram**: it shows up
  as a subcomponent).
* **You see:** description, tags (`tekton`, `cosign`, `gitsign`, `sigstore`, `sbom`, ...), and a
  **Links** card with **Source code (GitLab)**, **Open in Dev Spaces**, **Tekton pipeline
  (OpenShift console)** and **PipelineRuns (OpenShift console)**.
* **Say:** "One catalog item, three ways in: the code, the IDE that signs commits, and the running
  pipeline. A developer or an auditor does not need to know three different URLs by heart."

**D2. The CI tab (live Tekton data).**
* **Do:** open the **CI** tab on the same component.
* **You see:** the PipelineRuns in namespace `tssc-ci`, most recent first, with status; open the
  latest one to see the same task graph as in Part C, rendered inside Developer Hub.
* **Say:** "This is not a link out — Developer Hub reads the PipelineRuns straight from the
  cluster. A security reviewer can see the state of every supply-chain run without an OpenShift
  login."

**D3. The dependency graph.**
* **Do:** on the component, open **Diagram** (or **Dependencies**).
* **You see:** `coffee-menu-tssc` depends on three Resources: **Red Hat Trusted Artifact Signer**,
  **Red Hat Trusted Profile Analyzer** and **OpenShift Dev Spaces** (System `openshift-platform`),
  and is a subcomponent of **coffee-menu** (System `ai-demo`).
* **Say:** "The catalog does not just list the pipeline, it shows what it depends on: the signing
  service, the SBOM store, the IDE. If one of those goes down, the graph says why the pipeline
  would fail."

---

## Part E: the evidence afterwards (3 minutes)

**E1. Verify the released image.**
* **Do:** `./deploy.sh tssc verify`
* **You see:** the digest and Rekor log index of the signature, and `components in the SBOM: N`
  from the verified attestation.

**E2. The SBOM in Trusted Profile Analyzer.**
* **Do:** Trusted Profile Analyzer (log in with Keycloak) > **SBOMs**: `coffee-menu`, labels
  `source=tekton`, `service=coffee-menu`, `commit=<sha>`. Open it: packages, licenses, advisories.
* **Say:** "When the next Log4Shell happens, this answers in seconds which of our images are affected."

**E3. The transparency log.**
* **Do:** open the Rekor URL from the **sign-image** log.
* **You see:** the log entry with the signature and the hash of what was signed.

---

## Part F: break it (3 minutes)

**F1. An unsigned commit is refused.**
* **Do:** in the Dev Spaces terminal:
  ```bash
  echo "- unsigned change" >> app/coffee-menu/RELEASES.md
  git -c commit.gpgsign=false commit -am "coffee-menu: unsigned change" && git push origin HEAD:main
  ```
* **You see:** a new pipeline run that stops at **verify-commit**:
  `STOP: the commit is not signed by admin@demo.example.com with Trusted Artifact Signer`; nothing
  is checked, built, signed or deployed — the three parallel CI tasks never even start, because
  they `runAfter: [verify-commit]`.
* **Say:** "Somebody with push rights is not enough. No trusted signature, no build."

**F2. A vulnerability gate.**
* **Do:** `./deploy.sh tssc run --gate fail` (with importers enabled and advisories present).
* **You see:** **tpa-check** stops with `STOP: N critical/high vulnerabilities`.

---

## Part G: how it is built (IntelliJ, 5 minutes)

* `stack/tssc/ci/pipeline.yaml`: the diagram in the header comment, then the twelve tasks, each
  script readable; point at `runAfter: [verify-commit]` on all three mocked tasks (parallel), the
  `podman build` / `podman push` in **build-image**, `gitsign verify --certificate-identity ...
  --certificate-oidc-issuer ...`, `cosign sign ... --rekor-url`, `syft scan`, the RHTPA upload and
  the gate.
* `stack/tssc/ci/tools-build.yaml`: every pipeline step's image, with its own header comment on
  two decisions worth pointing at in a technical walkthrough: cosign is pinned to the latest 2.x
  release (not "latest", which is a 3.x release that OpenShift's internal registry rejects — see
  "If something goes wrong"), and gitsign is **built from source**, not downloaded prebuilt,
  because every current upstream gitsign release embeds a permanently expired TUF bootstrap root
  for Rekor's public key. The build patches gitsign's vendored `sigstore/sigstore` copy with
  *this cluster's own* `root.json` (fetched live from `TUF_URL` at image-build time) before
  compiling, so the fix stays fully air-gapped — the embedded root is cryptographically scoped to
  whoever signed it, so a current *public* sigstore.dev root does not work as a substitute here.
* `stack/tssc/rhtas/securesign-v1.yaml`: one resource, Fulcio trusting the platform Keycloak.
* `stack/tssc/devspaces/sign-setup.sh` and `devfile.yaml`: how a workspace learns to sign.
* `stack/tssc/ci/triggers.yaml`: the GitLab webhook filter (main, `app/coffee-menu/`); point at the
  `backstage.io/kubernetes-id: coffee-menu-tssc` label on the generated `PipelineRun` — this is the
  only thing that makes the run show up in Developer Hub's CI tab.
* `stack/developer-hub/catalog-templates/ai-demo.yaml`: the `coffee-menu-tssc` Component — note
  `backstage.io/kubernetes-namespace: tssc-ci` (different from `coffee-menu`'s own `ai-demo`,
  because the pipeline deliberately runs outside the service mesh) and `subcomponentOf:
  component:coffee-menu`.
* `stack/developer-hub/catalog-templates/platform.yaml`: the three Resources (`trusted-artifact-
  signer`, `trusted-profile-analyzer`, `dev-spaces`) that `coffee-menu-tssc` depends on.

---

## Reset

Nothing to reset: every run creates new artifacts. To start the pipeline without a commit:
`./deploy.sh tssc run`.

## If something goes wrong

* **No pipeline run after the push:** the webhook's CEL filter (`stack/tssc/ci/triggers.yaml`)
  starts a run only when all three hold: the push is to `main`; at least one commit adds or
  modifies a file under `app/coffee-menu/` (a change anywhere else in the repo is ignored); and no
  commit message starts with `"Platform snapshot"` (so `./deploy.sh gitlab`'s bulk repo-seeding
  pushes don't each start a run of their own). The simplest reliable way to trigger a real run
  from Dev Spaces is a trivial edit under `app/coffee-menu/` — exactly what `sign-commit.sh` does
  to `RELEASES.md` (Part B2, Part F1). GitLab > the project > Settings > Webhooks > the hook >
  **Recent events** shows the delivery either way (and whether GitLab even attempted it).
  `./deploy.sh tssc run` bypasses this filter entirely and starts a run directly against any
  revision, regardless of what changed or where.
* **verify-commit fails for a commit you signed:** identity or issuer differ. The signer must be
  `admin@demo.example.com` (Keycloak realm `demo`); see the log for what the certificate contains.
  Without a signed commit: `./deploy.sh tssc run --allow-unsigned`.
* **gitsign in Dev Spaces does not show a link:** run task 1 again (it installs the wrapper that
  forces the code login), then task 2.
* **Keycloak says "Invalid parameter: redirect_uri":** rerun `./deploy.sh tssc setup` (it registers
  `urn:ietf:wg:oauth:2.0:oob` on client `trusted-artifact-signer`).
* **tpa-check says SIMULATED:** RHTPA is not installed (`helm` missing during setup).
* **No advisories in TPA:** the vulnerability importers are off by default:
  `./deploy.sh tssc setup --tpa-importers` (the first import takes hours).
* **GitLab shows the commit as "Unverified":** GitLab does not trust this cluster's Fulcio CA; the
  pipeline's `gitsign verify` against Trusted Artifact Signer is the check that counts here.
* **No CI tab, or it is empty, on `coffee-menu-tssc` in Developer Hub:** `./deploy.sh rhdh` after
  `tssc setup` (the catalog is only rendered on demand); then confirm the PipelineRun carries the
  label `backstage.io/kubernetes-id=coffee-menu-tssc`: `oc get pipelinerun -n tssc-ci --show-labels`.
* **"Open in Dev Spaces" / Resource `dev-spaces` link looks wrong:** Dev Spaces has no predictable
  hostname; the catalog is rendered with the live `cheURL` only if Dev Spaces was already installed
  when `./deploy.sh rhdh` last ran. Install Dev Spaces first (`tssc setup`), then `./deploy.sh rhdh`.
* **build-image fails with `Unable to access jarfile .../gradle-wrapper.jar`:** the repo's root
  `.gitignore` has a `!**/gradle/wrapper/gradle-wrapper.jar` exception to its blanket `*.jar` rule
  for exactly this reason — without it, every re-push of the GitLab "Platform snapshot"
  (`./deploy.sh gitlab`) silently drops the wrapper jar, even though it's tracked in this repo's
  own git history (the snapshot push does a filesystem `rsync` into a scratch directory, then a
  *fresh* `git init && git add -A` there, which re-applies whatever `.gitignore` came along with
  it — a plain `git add` in the original repo is unaffected, since .gitignore never hides files
  that are already tracked). If this ever regresses: `git check-ignore -v
  app/gradle/wrapper/gradle-wrapper.jar` should print nothing; if it prints a matching rule, fix
  `.gitignore` and `./deploy.sh gitlab` again before re-running the pipeline.
* **sign-image / sbom fail with `failed to upload manifest: ... UNKNOWN: unknown error` /
  `dockerImageManifests[0].architecture: Required value` in the registry's own logs** (`oc logs -n
  openshift-image-registry -l docker-registry=default`): the tools image picked up cosign 3.x.
  cosign v3 always stores signatures and attestations as an OCI 1.1 "referrers" image index with a
  `subject` field; OpenShift's internal registry's `ImageStreamMapping` validation unconditionally
  requires `architecture`/`os` on any image index, which a signature-only index doesn't have, so
  the push always fails this way — confirmed neither `--registry-referrers-mode=legacy` nor
  `COSIGN_DOCKER_MEDIA_TYPES=1` change it (the OCI index wrapper itself is unconditional in v3).
  `stack/tssc/ci/tools-build.yaml` pins `COSIGN_VERSION` to the latest 2.x release for this reason;
  if a rebuild ever drifts off that pin, `cosign version` in a pod from `tssc-tools:latest` will
  show a 3.x `GitVersion`. Fix: rebuild the tools image after confirming the pin
  (`oc start-build tssc-tools -n tssc-ci --wait`).
