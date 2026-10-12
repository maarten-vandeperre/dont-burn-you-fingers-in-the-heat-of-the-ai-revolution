#!/usr/bin/env bash
# Dev Spaces: sign commits with gitsign and this cluster's Trusted Artifact Signer (keyless).
# Devfile command "1. Set up commit signing" -- also runs automatically on every workspace start
# (devfile.yaml's postStart event), so a workspace being recreated or getting a fresh PVC (not
# just a pod restart) doesn't silently lose signing: `git commit` would otherwise fall back to a
# plain, unsigned commit with no error, because `commit.gpgsign` is a *local*, per-clone git
# config setting this script writes -- it does not come from anywhere else. Idempotent and fast
# to re-run: every step below is a no-op once already done. Settings: stack/tssc/generated/signing.env.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
env_file=stack/tssc/generated/signing.env
[ -f "$env_file" ] || { echo "missing ${env_file}: run ./deploy.sh tssc setup on your laptop (it pushes this file)"; exit 1; }
set -a
# shellcheck disable=SC1090,SC1091
. "$env_file"
set +a

bin="$HOME/.local/bin"; mkdir -p "$bin"
arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
gitsign_version=0.17.1  # same fallback version pinned in stack/tssc/ci/tools-build.yaml
if [ -n "${CLI_SERVER:-}" ]; then
  for tool in gitsign cosign; do
    if [ ! -x "${bin}/${tool}" ]; then
      curl -fsSLk "${CLI_SERVER}/clients/linux/${tool}-${arch}.gz" | gunzip > "${bin}/${tool}"
      chmod +x "${bin}/${tool}"
    fi
  done
  tool_source="${CLI_SERVER}"
else
  # No RHTAS CLI server on this cluster (same gap as stack/tssc/ci/tools-build.yaml). cosign is
  # fine straight from its upstream release; gitsign is special-cased, same reason as
  # tools-build.yaml's header comment: every current upstream prebuilt gitsign release embeds a
  # permanently expired TUF bootstrap root for Rekor's public key (a legacy sigstore/sigstore TUF
  # client gitsign's own Rekor-client construction uses unconditionally -- not the modern client
  # `gitsign initialize --mirror` configures), so a plain downloaded binary fails outright with
  # "tuf: ... expired" the moment you try to sign, with no warning until then. Build it from
  # source instead, with this cluster's own (non-expired, correctly RHTAS-keyed) root.json --
  # fetched live from TUF_URL -- patched into gitsign's vendored sigstore/sigstore copy, exactly
  # like tools-build.yaml does for the pipeline's own tools image. Only happens once per
  # workspace/PVC (skipped once ${bin}/gitsign already exists), so repeat runs of this script
  # (including the automatic postStart one on every workspace start) stay fast.
  [ -x "${bin}/cosign" ] || curl -fsSL "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${arch}" -o "${bin}/cosign"
  chmod +x "${bin}/cosign"
  if [ -x "${bin}/gitsign" ]; then
    tool_source="already installed in this workspace"
  elif command -v go >/dev/null 2>&1; then
    echo "building gitsign v${gitsign_version} from source with this cluster's own RHTAS root.json embedded (one-time, about a minute)"
    src=$(mktemp -d)
    git clone --branch "v${gitsign_version}" --depth 1 -q https://github.com/sigstore/gitsign.git "$src"
    (
      cd "$src"
      go mod download github.com/sigstore/sigstore
      sigdir=$(go list -m -f '{{.Dir}}' github.com/sigstore/sigstore)
      patched=$(mktemp -d); cp -r "${sigdir}/." "$patched" && chmod -R u+w "$patched"
      curl -fsSLk "${TUF_URL}/root.json" -o "${patched}/pkg/tuf/repository/root.json"
      go mod edit -replace "github.com/sigstore/sigstore=${patched}"
      go mod tidy
      go build -o "${bin}/gitsign" .
    ) >/tmp/gitsign-build.log 2>&1 || { echo "gitsign build failed, see /tmp/gitsign-build.log"; cat /tmp/gitsign-build.log; exit 1; }
    rm -rf "$src"
    tool_source="built from source (v${gitsign_version}, this cluster's own TUF root embedded)"
  else
    echo "no 'go' in this workspace image: falling back to the upstream prebuilt binary, which WILL" \
         "fail to sign with an 'expired' TUF error -- see stack/tssc/ci/tools-build.yaml's header comment"
    curl -fsSL "https://github.com/sigstore/gitsign/releases/download/v${gitsign_version}/gitsign_${gitsign_version}_linux_${arch}" -o "${bin}/gitsign"
    chmod +x "${bin}/gitsign"
    tool_source="upstream sigstore GitHub releases (no RHTAS CLI server, no 'go' in this image)"
  fi
fi
echo "gitsign: $("${bin}/gitsign" --version 2>&1 | head -1)  (from ${tool_source})"

# No browser in a workspace: stand-in openers that fail make gitsign use the copy-the-code login
# ("Go to the following link ... Enter verification code"), which works with every gitsign version.
nobrowser="$HOME/.local/gitsign-nobrowser"; mkdir -p "$nobrowser"
for opener in xdg-open x-www-browser www-browser; do printf '#!/bin/sh\nexit 1\n' > "${nobrowser}/${opener}"; chmod +x "${nobrowser}/${opener}"; done
printf '#!/bin/sh\nPATH="%s:$PATH" exec "%s/gitsign" "$@"\n' "$nobrowser" "$bin" > "${bin}/gitsign-devspaces"
chmod +x "${bin}/gitsign-devspaces"

git config --local commit.gpgsign true
git config --local tag.gpgsign true
git config --local gpg.format x509
git config --local gpg.x509.program "${bin}/gitsign-devspaces"
git config --local gitsign.fulcio "$FULCIO_URL"
git config --local gitsign.rekor "$REKOR_URL"
git config --local gitsign.issuer "$OIDC_ISSUER"
git config --local gitsign.clientID "$OIDC_CLIENT_ID"
git config --local user.email "$SIGNER_IDENTITY"
git config --local user.name "Platform admin"
"${bin}/gitsign" initialize --mirror "$TUF_URL" --root "${TUF_URL}/root.json" >/dev/null
echo "OK: every commit in this repository is now signed with gitsign"
echo "    identity: ${SIGNER_IDENTITY} (Keycloak ${OIDC_ISSUER}), certificates from ${FULCIO_URL}"
