#!/usr/bin/env bash
# Starts the demo: one local Camel instance in dev mode (live reload of everything in routes/),
# developer console on http://localhost:8080/q/dev, API on http://localhost:8080/api.
#   ./run.sh                       uses the Camel version of your Camel CLI
#   CAMEL_VERSION=4.18.2 ./run.sh  pins a Camel version (4.18 is the LTS line)
set -euo pipefail
cd "$(dirname "$0")"

command -v camel >/dev/null || { echo "Camel CLI not found: jbang app install camel@apache/camel (see README)"; exit 1; }
if [[ ! -f config/llm.env ]]; then
  cp config/llm.env.example config/llm.env
  echo "Created config/llm.env from the example: add your API keys and the Qwen port, then run again."
  exit 1
fi
set -a; source config/llm.env; set +a
mkdir -p data/inbox/translate data/outbox

echo "Providers: qwen ${QWEN_BASE_URL:-} | openai ${OPENAI_API_KEY:+key set}${OPENAI_API_KEY:-no key} | anthropic ${ANTHROPIC_API_KEY:+key set}${ANTHROPIC_API_KEY:-no key}"
args=(run --source-dir=routes --dev --console)
[[ -n "${CAMEL_VERSION:-}" ]] && args+=("--camel-version=${CAMEL_VERSION}")
exec camel "${args[@]}" "$@"
