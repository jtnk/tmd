#!/usr/bin/env python3
"""Tests for the parts of the harness that decide things: `python3 perf/test_review.py`."""
import unittest

import review

FACTS = {
    "huge.resize.p99_ms": 27.4,
    "huge.resize.p99_spread_ms": 0.4,
    "huge.resize.best_fps": 0,
    "huge.scroll_by_line.p99_ms": 0.15,
    "huge.scroll_by_line.p99_spread_ms": 0.01,
    "huge.scroll_by_line.bytes_per_frame": 3119,
    "huge.scroll_by_line.best_fps": 1000,
    "binary.bytes": 405000,
}


def finding(**over):
    f = {"title": "Slow resize", "severity": "high", "scenario": "resize", "evidence": ["huge.resize.p99_ms"],
         "likely_cause": "Layout may dominate.", "next_step": "Profile md.layout."}
    f.update(over)
    return f


class Compare(unittest.TestCase):
    def test_noise_is_not_a_regression(self):
        base = dict(FACTS, **{"huge.scroll_by_line.p99_ms": 0.12})  # +25%, but only 0.03ms
        self.assertEqual(review.compare(FACTS, base), ([], []))

    def test_a_real_slowdown_is(self):
        base = dict(FACTS, **{"huge.resize.p99_ms": 20.0})
        worse, better = review.compare(FACTS, base)
        self.assertEqual([w[0] for w in worse], ["huge.resize.p99_ms"])
        self.assertEqual(better, [])

    def test_a_change_inside_the_measured_spread_is_not(self):
        facts = dict(FACTS, **{"huge.scroll_by_line.p99_spread_ms": 0.5, "huge.scroll_by_line.p99_ms": 0.4})
        base = dict(facts, **{"huge.scroll_by_line.p99_ms": 0.15})
        self.assertEqual(review.compare(facts, base)[0], [])

    def test_speedups_are_improvements(self):
        base = dict(FACTS, **{"huge.resize.p99_ms": 40.0})
        worse, better = review.compare(FACTS, base)
        self.assertEqual(worse, [])
        self.assertEqual([b[0] for b in better], ["huge.resize.p99_ms"])

    def test_a_lower_frame_rate_is_worse_despite_the_smaller_number(self):
        base = dict(FACTS, **{"huge.scroll_by_line.best_fps": 1000})
        facts = dict(FACTS, **{"huge.scroll_by_line.best_fps": 720, "huge.scroll_by_line.p99_ms": 1.2})
        self.assertIn("huge.scroll_by_line.best_fps", [w[0] for w in review.compare(facts, base)[0]])

    def test_a_p99_on_a_targets_budget_can_flip_without_a_regression(self):
        base = dict(FACTS, **{"huge.scroll_by_line.best_fps": 600, "huge.scroll_by_line.p99_ms": 1.66})
        facts = dict(FACTS, **{"huge.scroll_by_line.best_fps": 540, "huge.scroll_by_line.p99_ms": 1.68})
        self.assertEqual(review.compare(facts, base)[0], [])

    def test_binary_growth(self):
        base = dict(FACTS, **{"binary.bytes": 380000})
        self.assertEqual([w[0] for w in review.compare(FACTS, base)[0]], ["binary.bytes"])

    def test_misses(self):
        self.assertEqual(review.misses(FACTS), ["huge.resize.p99_ms"])


class Verification(unittest.TestCase):
    def test_a_grounded_finding_passes(self):
        self.assertIsNone(review.check_finding(finding(likely_cause="At 27.4 ms, layout may dominate."), FACTS))

    def test_no_evidence(self):
        self.assertIn("no facts", review.check_finding(finding(evidence=[]), FACTS))

    def test_an_invented_fact(self):
        self.assertIn("unknown", review.check_finding(finding(evidence=["huge.resize.p50_ms"]), FACTS))

    def test_an_invented_number(self):
        problem = review.check_finding(finding(next_step="This could be 3.5 ms faster."), FACTS)
        self.assertIn("3.5", problem)

    def test_a_target_is_not_an_invented_number(self):
        self.assertIsNone(review.check_finding(finding(title="Misses the 60 fps target"), FACTS))

    def test_names_with_digits_are_not_numbers(self):
        self.assertIsNone(review.check_finding(finding(likely_cause="Check the p99 of md.layout in utf8 text."), FACTS))


if __name__ == "__main__":
    unittest.main()
