#!/usr/bin/env bash
# Dev Spaces: change coffee-menu, sign the commit (Keycloak login with a code), push to GitLab.
# Devfile command "2. Sign a commit and push". The push starts the trusted supply chain pipeline.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
[ "$(git config --local gpg.format || true)" = x509 ] || bash stack/tssc/devspaces/sign-setup.sh
file=app/coffee-menu/RELEASES.md
[ -f "$file" ] || printf '# coffee-menu releases\n\nEvery line is a signed commit from Dev Spaces.\n\n' > "$file"
echo "- $(date -u '+%Y-%m-%d %H:%M UTC'): release from Dev Spaces, signed with Trusted Artifact Signer" >> "$file"
git add "$file"
echo
echo "Signing: open the link below in your browser, log in to Keycloak (admin / your demo password),"
echo "copy the code Keycloak shows, paste it here and press Enter."
echo
git commit -S -m "coffee-menu: release notes (signed in Dev Spaces)"
echo
git log -1 --format='commit %h by %an <%ae>%n%s'
git cat-file commit HEAD | grep -A2 '^gpgsig' | head -3
echo "..."
git push origin HEAD:main
echo
echo "OK: pushed. The pipeline starts now: OpenShift console > Pipelines > tssc-ci > trusted-supply-chain"
