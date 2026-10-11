#!/usr/bin/env bash
# Dev Spaces: sign commits with gitsign and this cluster's Trusted Artifact Signer (keyless).
# Devfile command "1. Set up commit signing". Settings: stack/tssc/generated/signing.env.
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
  # No RHTAS CLI server on this cluster (same gap as stack/tssc/ci/tools-build.yaml): fetch
  # gitsign/cosign straight from their upstream sigstore GitHub releases instead.
  [ -x "${bin}/gitsign" ] || curl -fsSL "https://github.com/sigstore/gitsign/releases/download/v${gitsign_version}/gitsign_${gitsign_version}_linux_${arch}" -o "${bin}/gitsign"
  [ -x "${bin}/cosign" ] || curl -fsSL "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${arch}" -o "${bin}/cosign"
  chmod +x "${bin}/gitsign" "${bin}/cosign"
  tool_source="upstream sigstore GitHub releases (no RHTAS CLI server on this cluster)"
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
