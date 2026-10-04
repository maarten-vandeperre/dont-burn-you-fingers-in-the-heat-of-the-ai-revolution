#!/usr/bin/env bash
# Helpers for the demo steps (the Camel instance must be running: ./run.sh)
set -euo pipefail
cd "$(dirname "$0")"
API=${API:-http://localhost:8080/api}

pretty() { if command -v jq >/dev/null; then jq .; else cat; echo; fi; }
usage() {
  cat <<'USAGE'
./demo.sh providers                       configured providers and models
./demo.sh chat <provider> "<prompt>"      provider: qwen | openai | anthropic | auto
./demo.sh compare "<prompt>"              all providers in parallel (needs extras/compare-providers)
./demo.sh summarise <file>                copy a file into data/inbox (summary appears in data/outbox)
./demo.sh translate <file>                copy a file into data/inbox/translate (route must be enabled)
./demo.sh enable <route-id>               start a route, e.g. files-translate
./demo.sh disable <route-id>              stop a route
./demo.sh add <extra>                     load an extra route live: compare-providers | coffee-fact-timer
./demo.sh remove <extra>                  unload it again
./demo.sh routes                          routes with state and statistics
./demo.sh hawtio                          open the Hawtio web console for this instance
USAGE
}

case "${1:-}" in
  providers) curl -s "$API/providers" | pretty ;;
  chat)
    [[ $# -ge 3 ]] || { usage; exit 1; }
    body=$(printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps({"prompt": sys.stdin.read()}))')
    curl -s -X POST "$API/chat/$2" -H 'Content-Type: application/json' -d "$body" | pretty ;;
  compare)
    [[ $# -ge 2 ]] || { usage; exit 1; }
    body=$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps({"prompt": sys.stdin.read()}))')
    curl -s -X POST "$API/compare" -H 'Content-Type: application/json' -d "$body" | pretty ;;
  summarise|summarize) cp "${2:?file}" data/inbox/ && echo "dropped $(basename "$2") in data/inbox, watch data/outbox" ;;
  translate) cp "${2:?file}" data/inbox/translate/ && echo "dropped $(basename "$2") in data/inbox/translate" ;;
  enable)  camel cmd start-route --id="${2:?route id}" ;;
  disable) camel cmd stop-route --id="${2:?route id}" ;;
  add)     cp "extras/${2:?extra}.camel.yaml" routes/ && echo "routes/${2}.camel.yaml added, Camel loads it now" ;;
  remove)  rm -f "routes/${2:?extra}.camel.yaml" && echo "routes/${2}.camel.yaml removed, Camel unloads it now" ;;
  routes)  camel get route ;;
  hawtio)  camel hawtio camel-ai-demo ;;
  *) usage ;;
esac
