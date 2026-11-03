#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="$(mktemp "${TMPDIR:-/tmp}/openshift-setup.XXXXXX")"

error() {
  printf '[ERROR] %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

finish() {
  local status=$?
  trap - EXIT
  set +e

  printf '\n========== Errors and warnings ==========\n'

  awk '
    {
      # Remove ANSI color codes before matching.
      gsub(/\033\[[0-9;]*[[:alpha:]]/, "")

      if (tolower($0) ~ /(^|[^[:alnum:]_])(errors?|warn(ings?)?|fatal|fail(ed|ures?)?)([^[:alnum:]_]|$)/) {
        print
        found = 1
      }
    }
    END {
      if (!found) print "No error or warning lines detected."
    }
  ' "$LOG_FILE"

  printf '\nRun exit code: %s\nFull log: %s\n' "$status" "$LOG_FILE"
  exit "$status"
}

trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_deploy() {
  local status

  if ./deploy.sh "$@" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  else
    status=$?
    error "./deploy.sh $* failed (exit $status)."
    return "$status"
  fi
}

# Check prerequisites before starting any deployment.
if ! command -v oc >/dev/null 2>&1; then
  error 'oc is not installed or is not on PATH.'
  exit 1
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
  error 'HF_TOKEN is unset or empty. Run: export HF_TOKEN="your-token"'
  exit 1
fi

if ! oc whoami --request-timeout=15s >>"$LOG_FILE" 2>&1; then
  error 'OpenShift login check failed. Run oc login and check cluster connectivity.'
  exit 1
fi

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '##################### Infra setup #####################' \
  '#######################################################'
printf '\n\n\n\n'

run_deploy stack

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '###################### App setup ######################' \
  '#######################################################'
printf '\n\n\n\n'

run_deploy app all

printf '\n\n\n\n'
printf '%s\n' \
  '#######################################################' \
  '##################### TSSC setup ######################' \
  '#######################################################'
printf '\n\n\n\n'

run_deploy tssc setup --tpa-importers # Vulnerability data can take hours to import.