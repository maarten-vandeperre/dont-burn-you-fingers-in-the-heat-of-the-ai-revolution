"""
Offline evaluation with a judge model: the same evaluation dataset, answered by the agent with
prompt version A and with version B, scored by LLM judges and by code. One MLflow run per version,
in experiment finops-agent: compare them under Evaluations / Runs in the MLflow UI.

  python evaluate.py 1 2            evaluate prompt versions 1 and 2 (default)
  python evaluate.py staging        any alias or version

Judge model: JUDGE_MODEL (default openai:/cloud = gpt-4o-mini through the demo 15 LLM API, as
consumer "judge"), reached with OPENAI_API_BASE / OPENAI_API_KEY: MLflow's judges call it through
LiteLLM, i.e. a plain OpenAI-compatible request with "Authorization: Bearer <key>".
"""

import os
import sys
import time

# Parallel judges: MLflow scores rows and scorers in threads. Keep it modest, so one evaluation
# stays within the demo 15 limits per consumer (5 req/s, 20 000 tokens/min, 30 MCP tool calls/min).
os.environ.setdefault("MLFLOW_GENAI_EVAL_MAX_WORKERS", "3")
os.environ.setdefault("MLFLOW_GENAI_EVAL_MAX_SCORER_WORKERS", "3")
os.environ.setdefault("GIT_PYTHON_REFRESH", "quiet")

# Import LiteLLM (the client MLflow's judges use) once, here, in the main thread: when the judge
# threads import it for the first time concurrently, they can deadlock on Python's module locks.
import litellm  # noqa: E402,F401

from common import log, setup_mlflow

mlflow, EXPERIMENT_ID = setup_mlflow()
from mlflow.genai import datasets                                         # noqa: E402
from mlflow.genai.judges import make_judge                                # noqa: E402
from mlflow.genai.scorers import Correctness, Guidelines, RelevanceToQuery, scorer   # noqa: E402

import agent                                                              # noqa: E402  (same code as the live agent)

JUDGE = os.environ.get("JUDGE_MODEL", "openai:/cloud")
AGENT_MODEL = os.environ.get("EVAL_AGENT_MODEL", "cloud")
DATASET = "finops-agent-eval"

# inputs: what the agent gets; expectations: what a correct answer contains (used by Correctness)
RECORDS = [
    {"inputs": {"question": "Which team spent the most on LLMs in the last 7 days, and is it within its budget?"},
     "expectations": {"expected_facts": ["support is the team with the highest LLM cost in the last 7 days",
                                         "support is over its monthly budget"]}},
    {"inputs": {"question": "Why did the support team's LLM cost go up?"},
     "expectations": {"expected_facts": ["support's cost comes mostly from gpt-4o-mini",
                                         "gpt-4o-mini is an OpenAI model"]}},
    {"inputs": {"question": "Is the payments team within its LLM budget?"},
     "expectations": {"expected_facts": ["payments is within its monthly budget",
                                         "payments' monthly budget is EUR 8.00"]}},
    {"inputs": {"question": "Which team used the most tokens in the last 30 days?"},
     "expectations": {"expected_facts": ["payments used the most tokens in the last 30 days"]}},
    {"inputs": {"question": "What is the request throttle on our LLM API?"},
     "expectations": {"expected_facts": ["the throttle is 5 requests per second per consumer"]}},
]


def get_or_create_dataset():
    try:
        ds = datasets.get_dataset(name=DATASET)
    except Exception:
        ds = datasets.create_dataset(name=DATASET, experiment_id=EXPERIMENT_ID,
                                     tags={"use_case": "finops", "owner": "agent-team"})
        ds.merge_records(RECORDS)
        log.info("created evaluation dataset %s with %d records", DATASET, len(RECORDS))
    return ds


# ---- scorers: three LLM judges (built in + one custom) and two code checks on the trace
cites_sources = Guidelines(name="cites_sources", model=JUDGE,
                           guidelines="The response ends with a line starting with 'Sources:' that names the tools or data used.")
# A custom judge in plain language (make_judge). Custom judges have no aggregation by default
# (scores are stored per row only), so ask for a mean, like the built-in judges have.
budget_aware = make_judge(
    name="budget_aware", model=JUDGE, feedback_value_type=float,
    instructions=("The user asked: {{ inputs }}\nThe assistant answered: {{ outputs }}\n"
                  "Score 1.0 if the answer is about a specific team's cost or budget AND says whether that team is "
                  "within or over its budget, or if no specific team is involved at all. Score 0.0 if a specific "
                  "team is discussed but its budget status is missing."))
budget_aware.aggregations = ["mean"]


@scorer
def used_tools(trace) -> int:
    """How many MCP tool calls the agent made (0 = answered from the model's imagination)."""
    return len([s for s in trace.data.spans if s.span_type == "TOOL" and s.name == "call_tool"])


@scorer
def total_tokens(trace) -> int:
    return sum(int((s.attributes or {}).get("mlflow.chat.tokenUsage", {}).get("total_tokens", 0))
               for s in trace.data.spans if s.span_type == "CHAT_MODEL")


SCORERS = [Correctness(model=JUDGE), RelevanceToQuery(model=JUDGE), cites_sources, budget_aware,
           used_tools, total_tokens]


def evaluate(prompt_ref):
    def predict(question):
        out = agent.run_agent(question, model=AGENT_MODEL, prompt=prompt_ref, source="evaluation")
        if out["status"] == "error" and "429" in out["answer"]:        # LLM API token quota: wait, retry once
            log.info("429 from the LLM API (token quota per consumer), waiting 60 s")
            time.sleep(60)
            out = agent.run_agent(question, model=AGENT_MODEL, prompt=prompt_ref, source="evaluation")
        return out["answer"]

    version = agent.load_prompt(prompt_ref).version
    with mlflow.start_run(run_name=f"prompt v{version} ({AGENT_MODEL}, judge {JUDGE})") as run:
        mlflow.set_tags({"prompt.version": str(version), "llm.model": AGENT_MODEL, "judge": JUDGE})
        mlflow.log_params({"prompt": f"{agent.PROMPT_NAME}/{version}", "agent_model": AGENT_MODEL, "judge_model": JUDGE})
        res = mlflow.genai.evaluate(data=get_or_create_dataset(), predict_fn=predict, scorers=SCORERS)
        print(f"\nprompt v{version}: run {run.info.run_id}")
        for k, v in sorted(res.metrics.items()):
            if k.endswith("/mean"):
                print(f"  {k:32} {v:.2f}")
    return res


if __name__ == "__main__":
    for ref in (sys.argv[1:] or ["1", "2"]):
        evaluate(ref)
