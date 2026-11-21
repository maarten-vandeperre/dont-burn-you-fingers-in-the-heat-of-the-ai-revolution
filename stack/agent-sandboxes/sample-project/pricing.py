"""LLM cost per team: the same domain as the FinOps agent of demo 16, small enough for a coding
agent to fix in one go. There is a bug: run `python3 -m unittest` and ask the agent to fix it."""

PRICES_PER_1K = {          # EUR per 1000 tokens: (input, output)
    "gpt-4o-mini": (0.00015, 0.0006),
    "qwen3-0-6b": (0.0, 0.0),          # in-house, on the platform's own GPUs/CPUs
}


def call_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    price_in, price_out = PRICES_PER_1K[model]
    return round(input_tokens / 1000 * price_in + output_tokens / 1000 * price_in, 6)


def team_cost(calls: list[dict]) -> float:
    return round(sum(call_cost(c["model"], c["input"], c["output"]) for c in calls), 4)
