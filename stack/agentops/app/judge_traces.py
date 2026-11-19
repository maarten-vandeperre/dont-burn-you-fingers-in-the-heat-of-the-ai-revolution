"""
Online evaluation: let the judge model score what the agent really answered in production.
Takes the most recent traces of the live agent (tag source = 'ui' or 'load') and runs judges on
them; the results are attached to each trace as assessments (feedback), visible in the Traces tab
next to the trace, and filterable ("show me every answer the judge found irrelevant").

  python judge_traces.py [max_traces]      default 10

No expectations are needed: these judges only look at the question, the answer and the trace.
Correctness needs a known right answer, so it stays in the offline evaluation (evaluate.py).
"""

import os
import sys

os.environ.setdefault("GIT_PYTHON_REFRESH", "quiet")
import litellm  # noqa: E402,F401  (import once in the main thread, see evaluate.py)

from common import setup_mlflow

mlflow, EXPERIMENT_ID = setup_mlflow()
from mlflow.genai.scorers import RelevanceToQuery   # noqa: E402

from evaluate import JUDGE, budget_aware, cites_sources, total_tokens, used_tools   # noqa: E402

n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
# the trace search filter supports AND only: one search per source, newest n overall
import pandas as pd   # noqa: E402
found = [mlflow.search_traces(experiment_ids=[EXPERIMENT_ID], filter_string=f"tags.source = '{src}'",
                              max_results=n, order_by=["timestamp_ms DESC"]) for src in ("ui", "load")]
traces = pd.concat(found, ignore_index=True).sort_values("request_time", ascending=False).head(n)
if len(traces) == 0:
    sys.exit("no live traces yet: ask the agent something first (UI or ./deploy.sh agentops load)")
print(f"judging {len(traces)} live traces with {JUDGE}")
res = mlflow.genai.evaluate(data=traces, scorers=[RelevanceToQuery(model=JUDGE), cites_sources, budget_aware,
                                                  used_tools, total_tokens])
for k, v in sorted(res.metrics.items()):
    if k.endswith("/mean"):
        print(f"  {k:32} {v:.2f}")
print("assessments are attached to the traces: MLflow UI > experiment finops-agent > Traces")
