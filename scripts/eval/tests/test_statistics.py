import unittest

from scripts.eval.statistics import (
    exact_mcnemar,
    mean_confidence_interval_95,
    percentile,
    sample_variance,
    wilson_interval,
)


class StatisticsTest(unittest.TestCase):
    def test_wilson_small_perfect_sample_is_not_false_certainty(self):
        low, high = wilson_interval(6, 6)
        self.assertAlmostEqual(low, 0.6097, places=3)
        self.assertAlmostEqual(high, 1.0)

    def test_exact_mcnemar_uses_paired_discordance(self):
        self.assertEqual(exact_mcnemar(0, 0), 1.0)
        self.assertAlmostEqual(exact_mcnemar(0, 10), 2 / 1024)
        self.assertEqual(exact_mcnemar(2, 2), 1.0)

    def test_percentile_interpolates(self):
        self.assertEqual(percentile([1, 2, 3, 4], 0.5), 2.5)
        self.assertEqual(percentile([], 0.95), None)

    def test_paired_mean_variance_and_ci_do_not_fake_single_sample_certainty(self):
        self.assertEqual(sample_variance([1.0, 2.0, 3.0]), 1.0)
        low, high = mean_confidence_interval_95([1.0, 2.0, 3.0])
        self.assertLess(low, 0.0)
        self.assertGreater(high, 4.0)
        self.assertEqual(mean_confidence_interval_95([1.0]), (None, None))


if __name__ == "__main__":
    unittest.main()
