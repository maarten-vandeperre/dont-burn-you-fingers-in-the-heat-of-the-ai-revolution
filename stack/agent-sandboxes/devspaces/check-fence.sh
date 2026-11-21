#!/usr/bin/env bash
# What can this workspace (or sandbox) reach? Run inside a Dev Spaces workspace or an OpenShell
# sandbox. Prints one line per target: the HTTP status, or BLOCKED when no connection is possible.
#   allowed by the fence:  the company LLM API, the npm registry, github.com
#   blocked:               api.anthropic.com (no direct model access), pypi.org, example.com
probe() {  # probe <label> <url>
  local code
  code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$2" 2>/dev/null)
  [[ "$code" == 000 || -z "$code" ]] && code=BLOCKED
  printf '  %-34s %-60s %s\n' "$1" "$2" "$code"
}
echo "Egress from ${HOSTNAME:-this pod}:"
probe "company LLM API (no key: 401)" "${ANTHROPIC_BASE_URL:-https://llm-gateway.example}/v1/messages"
probe "npm registry" "https://registry.npmjs.org/express"
probe "github.com" "https://github.com"
probe "Anthropic API directly" "https://api.anthropic.com/v1/models"
probe "PyPI" "https://pypi.org/simple/"
probe "anything else" "https://example.com"
