#!/usr/bin/env bash
# Dev Spaces: verify the last commit, exactly as the pipeline's verify-commit task does.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
set -a
# shellcheck disable=SC1090,SC1091
. stack/tssc/generated/signing.env
set +a
"$HOME/.local/bin/gitsign" verify --certificate-identity="$SIGNER_IDENTITY" --certificate-oidc-issuer="$OIDC_ISSUER" HEAD
