-- AgentOps demo dataset: 30 days of LLM usage per team and model, as a FinOps team would load it
-- from the gateway's metering (demo 15's Limitador / Praxis token metrics). Deterministic (no
-- random()), relative to today, so the questions in the evaluation dataset keep the same answers:
--   * "support" switched to gpt-4o-mini three days ago: the most expensive team of the last week,
--     and over its monthly budget (budget-api)
--   * "payments" uses the most tokens overall, but on local models: cheap
CREATE TABLE IF NOT EXISTS llm_usage (
  day               date    NOT NULL,
  team              text    NOT NULL,
  model             text    NOT NULL,
  requests          integer NOT NULL,
  prompt_tokens     integer NOT NULL,
  completion_tokens integer NOT NULL,
  cost_eur          numeric(10,2) NOT NULL,
  PRIMARY KEY (day, team, model)
);

CREATE TABLE IF NOT EXISTS model_prices (
  model                 text PRIMARY KEY,
  provider              text NOT NULL,
  eur_per_million_tokens numeric(10,2) NOT NULL
);

INSERT INTO model_prices VALUES
  ('qwen3-0-6b',      'OpenShift AI (local, CPU)', 0.40),
  ('gemma-3-270m-it', 'OpenShift AI (local, CPU)', 0.20),
  ('gpt-4o-mini',     'OpenAI',                     0.55)
ON CONFLICT DO NOTHING;

WITH days AS (
  SELECT (current_date - g)::date AS day, g AS ago FROM generate_series(0, 29) g
), teams(team, t) AS (
  VALUES ('payments', 1), ('search', 2), ('support', 3), ('marketing', 4)
), mix(team, model, base) AS (
  VALUES ('payments',  'qwen3-0-6b',      420000), ('payments',  'gemma-3-270m-it', 160000),
         ('search',    'qwen3-0-6b',      150000), ('search',    'gpt-4o-mini',      60000),
         ('support',   'gemma-3-270m-it',  90000), ('support',   'gpt-4o-mini',      20000),
         ('marketing', 'gpt-4o-mini',       40000), ('marketing', 'qwen3-0-6b',       30000)
), rows AS (
  SELECT d.day, m.team, m.model,
         -- weekly rhythm (+/- 20%), plus the support spike on gpt-4o-mini in the last 3 days
         (m.base * (0.8 + 0.4 * ((extract(isodow FROM d.day)::int * 3 + t.t) % 7) / 6.0)
                 * CASE WHEN m.team = 'support' AND m.model = 'gpt-4o-mini' AND d.ago < 3 THEN 80 ELSE 1 END
         )::int AS tokens
  FROM days d JOIN mix m ON true JOIN teams t ON t.team = m.team
)
INSERT INTO llm_usage
SELECT r.day, r.team, r.model,
       greatest(1, r.tokens / 900)            AS requests,
       (r.tokens * 0.7)::int                  AS prompt_tokens,
       (r.tokens * 0.3)::int                  AS completion_tokens,
       round(r.tokens / 1000000.0 * p.eur_per_million_tokens, 2) AS cost_eur
FROM rows r JOIN model_prices p ON p.model = r.model
ON CONFLICT DO NOTHING;

-- read-only account for the MCP server: the agent can query, never change, the data
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'agent_ro') THEN
    CREATE ROLE agent_ro LOGIN PASSWORD 'agent-ro';
  END IF;
END $$;
GRANT SELECT ON llm_usage, model_prices TO agent_ro;
