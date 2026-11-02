#!/usr/bin/env bash
# Starts camel-ai-router with podman compose.
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example: set OPENAI_API_KEY and/or LOCAL_BASE_URL (and optionally"
  echo "ANTHROPIC_API_KEY / VLLM_BASE_URL), then run ./start.sh again."
  exit 1
fi

podman compose up --build -d
podman compose ps
echo
echo "camel-ai-router: http://localhost:8085"
echo "  curl -s localhost:8085/v1/models | jq"
echo "  curl -s localhost:8085/v1/router/status | jq"
echo "Logs:   podman compose logs -f camel-ai-router"
echo "Stop:   podman compose down"
