#!/usr/bin/env bash
# Starts Guarded Coffee with podman compose.
#   ./start.sh              TrustyAI guardrails image (pulled once, with retries)
#   ./start.sh --upstream   build the guardrails server from upstream NeMo Guardrails instead
# When the TrustyAI image cannot be pulled after 5 attempts (registry rate limit, ARM laptop),
# it falls back to the upstream build automatically.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example: fill in the Qwen port and/or the OpenAI key, then run ./start.sh again."
  exit 1
fi

image=$(grep -E '^GUARDRAILS_IMAGE=' .env | cut -d= -f2- || true)
image=${image:-quay.io/trustyai/nemo-guardrails-server:latest}
files=(-f compose.yaml)

if [[ "${1:-}" == "--upstream" ]]; then
  files+=(-f compose.upstream.yaml)
elif podman image exists "$image"; then
  echo "Using local image ${image}"
else
  for attempt in 1 2 3 4 5; do
    echo "Pulling ${image} (attempt ${attempt}/5)"
    if out=$(podman pull "$image" 2>&1); then
      echo "$out" | tail -1
      break
    fi
    echo "$out" | tail -3
    if grep -q "loading registries configuration" <<<"$out"; then
      conf=$(sed -n 's/.*configuration "\([^"]*\)".*/\1/p' <<<"$out" | head -1)
      echo
      echo "Your Podman registries configuration has a syntax error (this is not about the demo):"
      echo "  ${conf:-~/.config/containers/registries.conf}"
      echo "Fix the line named above, or move the file aside so Podman uses its defaults:"
      echo "  mv \"${conf:-$HOME/.config/containers/registries.conf}\" \"${conf:-$HOME/.config/containers/registries.conf}.bak\""
      exit 1
    fi
    if [[ "$attempt" -eq 5 ]]; then
      echo "Could not pull ${image}: building the guardrails server from upstream NeMo Guardrails instead"
      files+=(-f compose.upstream.yaml)
      break
    fi
    echo "Pull failed (a 'too many requests' rate limit passes after a while); retrying in $((attempt * 20)) s"
    sleep $((attempt * 20))
  done
fi

podman compose "${files[@]}" up --build -d
podman compose "${files[@]}" ps
echo
echo "Guarded Coffee: http://localhost:8080   (guardrails: :8000 Qwen, :8001 OpenAI)"
echo "Logs: podman compose logs -f guardrails-qwen"
