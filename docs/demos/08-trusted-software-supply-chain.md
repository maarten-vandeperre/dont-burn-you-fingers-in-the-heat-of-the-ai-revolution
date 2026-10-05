# Demo 8: Trusted software supply chain

**The story:** every step from a developer's commit to a running container is signed, checked and
recorded. The commit is signed with the developer's company identity, the pipeline refuses commits
it cannot trust, the image is signed and gets a bill of materials, that SBOM is checked for known
vulnerabilities, security policies are enforced, and only the verified digest is deployed.

**Duration:** 20 minutes (5 Dev Spaces, 10 pipeline, 5 proof). Parts C to F also work on their own
with `./deploy.sh tssc run`.

```
Dev Spaces: git commit (signed, Keycloak login) ─> GitLab ─> webhook ─> pipeline in tssc-ci:
  clone ─> verify-commit ─> ci-tests ─> build-image ─> sign-image ─> sbom ─> tpa-check ─> acs-checks ─> push-release ─> argocd-sync
```

Every step below has three parts: **Do** (what you click, type or open), **You see**, **Say**.

| Step | Real or simulated |
|---|---|
| Commit signing (gitsign) and verification | real: Trusted Artifact Signer on this cluster |
| CI (Gradle tests), image build, push | real |
| Image signature, SBOM, SBOM attestation | real: cosign, syft, Rekor |
| Trusted Profile Analyzer check | real when RHTPA is installed (needs `helm`), otherwise simulated |
| Advanced Cluster Security checks | simulated from real facts, unless Secret `acs-central` exists (then real `roxctl`) |
| Argo CD sync | real when the Argo CD app `ai-demo` exists (`./deploy.sh app gitops <url>`), otherwise simulated |

---

## Before you start

1. Once (about 30 minutes):
   ```bash
   ./deploy.sh tssc setup          # add --tpa-importers for vulnerability data (hours to import)
   ```
   It installs Trusted Artifact Signer, Trusted Profile Analyzer, Dev Spaces, the pipeline and the
   GitLab webhook, writes `stack/tssc/generated/signing.env` and pushes the repository to GitLab.
2. Check: `./deploy.sh validate --quick` (the `tssc` lines) and `./deploy.sh tssc urls`.
3. Optional, for a real Argo CD sync: `./deploy.sh app gitops https://<gitlab-host>/ai-platform/platform.git`.
4. Browser tabs: **Dev Spaces workspace** (URL "Dev Spaces workspace" from `tssc urls`; the first start
   takes a few minutes), **OpenShift console > Pipelines** (project `tssc-ci`), **Trusted Profile
   Analyzer**, **GitLab**.
5. In the workspace, run once: **Terminal > Run Task > devfile > 1. Set up commit signing**.
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

**B1. Sign.**
* **Do:** in the workspace: **Terminal > Run Task > devfile > 2. Sign a commit and push**.
* **You see:** `Go to the following link in a browser:` with a Keycloak URL, then
  `Enter verification code:`.
* **Do:** open the link, log in (`admin` / your demo password), copy the code Keycloak shows, paste
  it in the terminal, Enter.
* **You see:** the commit (`coffee-menu: release notes (signed in Dev Spaces)`), the start of its
  `gpgsig` signature block, and the push to GitLab.
* **Say:** "No GPG key to manage, nothing on my laptop. My company login proves who I am; Fulcio gave
  me a certificate valid for ten minutes, the signature is in the transparency log forever."

**B2. Verify it yourself.**
* **Do:** **Run Task > devfile > 3. Verify the last commit**.
* **You see:** `Validated Git signature: true`, `Validated Rekor entry: true`, the certificate identity
  `admin@demo.example.com` and issuer (the Keycloak realm).

---

## Part C: the pipeline runs (10 minutes)

* **Do:** OpenShift console > **Pipelines** > project **tssc-ci** > **PipelineRuns**: the new run
  `coffee-menu-...` (started by the GitLab webhook). Open it; the graph shows the ten tasks.

Walk through the tasks while they run; click a task to see its log.

| Task | You see in the log | Say |
|---|---|---|
| **verify-commit** | `OK: commit signed by admin@demo.example.com, certificate from Trusted Artifact Signer, recorded in Rekor` | "The pipeline trusts no commit it cannot attribute to a known person." |
| **ci-tests** | Gradle `BUILD SUCCESSFUL`, `OK: coffee-menu compiles and its tests pass` | "Plain CI, unchanged." |
| **build-image** | base images (UBI), `OK: pushed .../ai-demo/coffee-menu:<commit> = sha256:...` | "From here on we only speak in digests, never tags." |
| **sign-image** | `tlog entry created with index: N`, the verify output, a Rekor URL | "Signed and logged. Anyone can verify it, and tampering would be visible." |
| **sbom** | `SBOM (CycloneDX): N components`, the Java libraries, `SBOM attached ... as a signed attestation` | "The image carries its own signed ingredient list." |
| **tpa-check** | `SBOM stored in Trusted Profile Analyzer`, a link, `affected vulnerabilities: ...` | "Every SBOM lands in one place, where security can see which images contain a vulnerable library." |
| **acs-checks** | image, deployment and environment checks with PASS/WARN | "Policy as code: trusted base image, pinned digest, limits, no privilege, mTLS in the target namespace." |
| **push-release** | `:release now points to the signed, checked digest` | "Promotion moves a pointer; the signature stays valid because the digest does not change." |
| **argocd-sync** | `sync of ai-demo started: coffee-menu pinned to ...@sha256`, `Argo CD synced` | "GitOps deploys exactly the digest we verified." |

Simulated steps say `SIMULATED` on their first line, with what they would do; say so openly.

---

## Part D: the evidence afterwards (3 minutes)

**D1. Verify the released image.**
* **Do:** `./deploy.sh tssc verify`
* **You see:** the digest and Rekor log index of the signature, and `components in the SBOM: N`
  from the verified attestation.

**D2. The SBOM in Trusted Profile Analyzer.**
* **Do:** Trusted Profile Analyzer (log in with Keycloak) > **SBOMs**: `coffee-menu`, labels
  `source=tekton`, `service=coffee-menu`, `commit=<sha>`. Open it: packages, licenses, advisories.
* **Say:** "When the next Log4Shell happens, this answers in seconds which of our images are affected."

**D3. The transparency log.**
* **Do:** open the Rekor URL from the **sign-image** log.
* **You see:** the log entry with the signature and the hash of what was signed.

---

## Part E: break it (3 minutes)

**E1. An unsigned commit is refused.**
* **Do:** in the Dev Spaces terminal:
  ```bash
  echo "- unsigned change" >> app/coffee-menu/RELEASES.md
  git -c commit.gpgsign=false commit -am "coffee-menu: unsigned change" && git push origin HEAD:main
  ```
* **You see:** a new pipeline run that stops at **verify-commit**:
  `STOP: the commit is not signed by admin@demo.example.com with Trusted Artifact Signer`; nothing is
  built, signed or deployed.
* **Say:** "Somebody with push rights is not enough. No trusted signature, no build."

**E2. A vulnerability gate.**
* **Do:** `./deploy.sh tssc run --gate fail` (with importers enabled and advisories present).
* **You see:** **tpa-check** stops with `STOP: N critical/high vulnerabilities`.

---

## Part F: how it is built (IntelliJ, 5 minutes)

* `stack/tssc/ci/pipeline.yaml`: the ten tasks, each script readable; point at `gitsign verify
  --certificate-identity ... --certificate-oidc-issuer ...`, `cosign sign ... --rekor-url`, `syft scan`,
  the RHTPA upload and the gate.
* `stack/tssc/rhtas/securesign-v1.yaml`: one resource, Fulcio trusting the platform Keycloak.
* `stack/tssc/devspaces/sign-setup.sh` and `devfile.yaml`: how a workspace learns to sign.
* `stack/tssc/ci/triggers.yaml`: the GitLab webhook filter (main, `app/coffee-menu/`).

---

## Reset

Nothing to reset: every run creates new artifacts. To start the pipeline without a commit:
`./deploy.sh tssc run`.

## If something goes wrong

* **No pipeline run after the push:** the webhook only reacts to changes under `app/coffee-menu/` on
  `main`; GitLab > the project > Settings > Webhooks > the hook > **Recent events** shows the delivery.
  Start one by hand: `./deploy.sh tssc run`.
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
