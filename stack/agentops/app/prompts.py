"""
Prompt management for the finops-agent, in the OpenShift AI MLflow prompt registry
(workspace = namespace agentops). Run inside the agent pod (./deploy.sh agentops prompts ...):

  python prompts.py register        v1 + v2 of "finops-agent", aliases production -> 1, staging -> 2
                                    (idempotent: an existing prompt is left as it is)
  python prompts.py promote <ver>   move the "production" alias to version <ver>
  python prompts.py show            versions, aliases and the template of each version

The agent loads prompts:/finops-agent@production on every question (cached for PROMPT_CACHE_TTL
seconds), so moving the alias changes the running agent without a redeploy. MLflow templates use
{{double braces}} for variables.
"""

import sys

from common import prompt_versions, setup_mlflow

mlflow, _ = setup_mlflow()
NAME = "finops-agent"

V1 = """You are a FinOps assistant for the company's LLM platform. Today is {{today}}.
Answer the user's question about LLM usage and cost."""

V2 = """You are the FinOps assistant of the company's internal LLM platform. Today is {{today}}.

Rules:
1. Never guess a number. Get every figure from a tool: usage_by_team, usage_by_model, team_budget,
   get_limits. If no tool has it, say so.
2. "Last week" means the last 7 days, "this month" the last 30 days.
3. When the answer is about a specific team, also check that team's budget with team_budget and
   say whether it is within budget.
4. Answer in at most 4 sentences. Amounts in EUR with 2 decimals.
5. End with one line "Sources: <the tools you used>"."""


def register():
    existing = [v.version for v in prompt_versions(mlflow, NAME)]
    if existing:
        print(f"prompt {NAME} exists (versions {sorted(existing)}), left as it is")
        return
    v1 = mlflow.genai.register_prompt(NAME, V1, commit_message="v1: minimal system prompt",
                                      tags={"author": "agent-team", "use_case": "finops"})
    v2 = mlflow.genai.register_prompt(NAME, V2, commit_message="v2: tool-grounded numbers, budget check, sources line",
                                      tags={"author": "agent-team", "use_case": "finops"})
    mlflow.genai.set_prompt_alias(NAME, "production", v1.version)
    mlflow.genai.set_prompt_alias(NAME, "staging", v2.version)
    print(f"registered {NAME} v{v1.version} (production) and v{v2.version} (staging)")


def promote(version):
    mlflow.genai.set_prompt_alias(NAME, "production", int(version))
    print(f"{NAME}@production -> version {version}")


def show():
    for v in prompt_versions(mlflow, NAME):
        print(f"--- version {v.version}  aliases {v.aliases or []}  '{v.commit_message}'")
        print(v.template)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    if cmd == "register":
        register()
    elif cmd == "promote" and len(sys.argv) > 2:
        promote(sys.argv[2])
    elif cmd == "show":
        show()
    else:
        sys.exit("usage: prompts.py register | promote <version> | show")
