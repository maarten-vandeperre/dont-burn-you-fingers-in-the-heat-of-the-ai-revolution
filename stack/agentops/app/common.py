"""
Shared setup for the AgentOps demo services (agent, mcp-finops, budget-api) and scripts.

Every process traces with the MLflow SDK into ONE experiment of the OpenShift AI MLflow server:
  MLFLOW_TRACKING_URI      https://<rhoai dashboard>/mlflow
  MLFLOW_WORKSPACE         the namespace (agentops): OpenShift AI MLflow has one workspace per project
  MLFLOW_TRACKING_TOKEN    this pod's service account token (RoleBinding edit in agentops), re-read
                           from the projected file before each use because it's rotated
  MLFLOW_EXPERIMENT_NAME   finops-agent
and, with MLFLOW_TRACE_ENABLE_OTLP_DUAL_EXPORT=true + OTEL_EXPORTER_OTLP_TRACES_ENDPOINT, the
same spans also go to the platform's OpenTelemetry collector -> Tempo (console: Observe > Traces).
"""

import logging
import os
import sys

TOKEN_FILE = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SERVICE = os.environ.get("OTEL_SERVICE_NAME", "agentops")

logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                    format=f"%(asctime)s [{SERVICE}] %(levelname)s %(message)s")
log = logging.getLogger(SERVICE)
for noisy in ("httpx", "urllib3", "mlflow.tracing.export", "LiteLLM"):
    logging.getLogger(noisy).setLevel(logging.WARNING)


def refresh_token():
    """MLflow reads MLFLOW_TRACKING_TOKEN on every request: keep it equal to the rotated SA token."""
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            os.environ["MLFLOW_TRACKING_TOKEN"] = f.read().strip()


def setup_mlflow():
    refresh_token()
    import mlflow
    name = os.environ.get("MLFLOW_EXPERIMENT_NAME", "finops-agent")
    exp = mlflow.set_experiment(name)          # creates it on first use (SA has edit in the workspace)
    return mlflow, exp.experiment_id


def mlflow_ui_base():
    return os.environ.get("MLFLOW_UI_URL", os.environ.get("MLFLOW_TRACKING_URI", ""))


def prompt_versions(mlflow, name):
    """All versions of a prompt, oldest first. (search_prompt_versions only exists for Unity
    Catalog registries; in the OpenShift AI / OSS registry, versions are numbered 1..n.)"""
    client, out, n = mlflow.MlflowClient(), [], 1
    while True:
        try:
            out.append(client.get_prompt_version(name, n))
        except Exception:
            return out
        n += 1
