import unittest

from pricing import call_cost, team_cost


class PricingTest(unittest.TestCase):
    def test_call_cost_uses_output_price_for_output_tokens(self):
        self.assertAlmostEqual(call_cost("gpt-4o-mini", 1000, 1000), 0.00075)

    def test_in_house_model_is_free(self):
        self.assertEqual(call_cost("qwen3-0-6b", 50_000, 50_000), 0.0)

    def test_team_cost(self):
        calls = [{"model": "gpt-4o-mini", "input": 2000, "output": 500}] * 4
        self.assertAlmostEqual(team_cost(calls), 0.0024)


if __name__ == "__main__":
    unittest.main()
