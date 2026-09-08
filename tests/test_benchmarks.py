"""Purpose: prove the MORK benchmark measures and gates its conjunction sweep.

Guarantees: both stores check complete answer bags, and planted changes to any
size's counter fail in either direction [tested: sh check.sh mork-bench-selftest; commit=6da518669cb9e39557d537857c0aa7190dd2e78f].
Owns resources: each test process owns its stores until exit. Temporary baseline
files stay below the repository's scratch and are removed after each test.
"""

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

SEAT = Path(__file__).resolve().parents[1]
ROOT = SEAT.parents[1]
sys.path.insert(0, str(SEAT / "benchmarks"))

import bench  # noqa: E402 -- the seat's own driver is the subject


class BenchmarkTests(unittest.TestCase):
    """The real workload and its baseline comparison, with planted defects."""

    def test_every_conjunction_size_is_measured(self):
        """A missing case or size fails even if the remaining rows compare."""
        # Operation samples exceed the separate floor.
        with (
            patch.object(bench, "windowed", side_effect=lambda case, *_: (
                [100, 101, 102] if case == "window-floor" else [1100, 1101, 1102]
            )),
            patch.object(bench, "counters", return_value=([5, 5, 5], 0.001)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            rows = bench.measure(bench.SIZES, bench.ROUNDS)
        self.assertEqual(len(rows), 39)
        for case in bench.JOIN_CASES:
            for size in bench.JOIN_SIZES:
                row = rows[bench.row_name(case, size)]
                self.assertEqual((row.unit, row.operations), ("queries", 1))

    def test_every_sweep_pin_rejects_movement_in_both_directions(self):
        """A single changed size must fail the real compare on an otherwise exact sweep."""
        rows = {
            bench.row_name(case, size): bench.Row(
                bench.row_name(case, size), "queries", 1,
                [100 * size ** power] * 3, [size] * 3, 0.001,
            )
            for case, power in zip(bench.JOIN_CASES, (1, 2), strict=True)
            for size in bench.JOIN_SIZES
        }
        (ROOT / "ai-tmp").mkdir(exist_ok=True)
        with (
            tempfile.TemporaryDirectory(prefix="ai-mork-benchmark-", dir=ROOT / "ai-tmp") as directory,
            patch.object(bench, "BASELINE", Path(directory) / "baseline.json"),
            patch.object(bench, "configuration", return_value={"seats": ["mork", "node", "python"]}),
        ):
            self.assertEqual(bench.compare(rows, update=True, whole_ladder=True), [])
            before = bench.BASELINE.read_bytes()
            self.assertEqual(bench.compare(rows, update=False, whole_ladder=True), [])
            for name, row in rows.items():
                for factor in (0.9, 1.1):
                    changed = rows | {name: replace(
                        row, instructions=[int(row.instructions[0] * factor)] * 3,
                    )}
                    failures = bench.compare(changed, update=False, whole_ladder=True)
                    self.assertEqual(len(failures), 1)
                    self.assertIn(name, failures[0])
            missing = dict(rows)
            missing.pop(next(iter(missing)))
            self.assertTrue(bench.compare(missing, update=False, whole_ladder=True))
            self.assertEqual(bench.BASELINE.read_bytes(), before)
            self.assertEqual(json.loads(before)["counter_policy"], bench.POLICIES["counter_policy"])
        exponents = bench.join_exponents(rows)
        self.assertAlmostEqual(exponents["native-conjunction"], 1.0)
        self.assertAlmostEqual(exponents["mork-conjunction"], 2.0)

    def test_partial_updates_refuse_before_measurement(self):
        """An exploratory size set must not erase the other pinned rows."""
        with (
            patch.object(bench, "measure") as measure,
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as refused,
        ):
            bench.main(["--update", "--sizes", "100"])
        self.assertEqual(refused.exception.code, 2)
        measure.assert_not_called()

    def test_both_stores_verify_the_projected_triples(self):
        """Even and odd graphs run the positive control and the empty query."""
        for case in bench.JOIN_CASES:
            for size in (2, 3, 5, 17):
                result = subprocess.run(  # noqa: S603 -- fixed cases from the seat's workload
                    bench.command(case, size, "counters"),
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(result.stdout, bench.COUNTERS)

    def test_wrong_triples_with_the_right_count_are_refused(self):
        """A changed endpoint preserves answer count but must fail the bag oracle."""
        for store in ("native", "mork"):
            space = f"&{store}:benchmark-corruption"
            goal = (
                f"bench_join_fill('{space}',8),"
                f"'add-atom'('{space}',[edge,5,2],_),"
                f"bench_join_count('{space}',3),"
                f"catch((bench_join_answers('{space}',"
                "[[0,5,1],[1,0,5],[5,1,0]]),halt(1)),"
                "error(domain_error(conjunction_answers,_),_),halt(0))"
            )
            result = subprocess.run(  # noqa: S603 -- fixed corruption fixture, no external input
                ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g", goal,  # noqa: S607 -- SWI from the gate's PATH
                 "-t", "halt", "--", "extensions"],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_always_empty_query_fails_the_positive_control(self):
        """A no-op query cannot pass a benchmark whose measured answer is empty."""
        result = subprocess.run(  # noqa: S603 -- fixed no-op mutation
            ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g",  # noqa: S607 -- gate's SWI
             "bench_join_fill('&mork:no-op',8),abolish(bench_join/2),"
             "assertz((bench_join(_,_):-fail)),"
             "catch((bench_check_join('&mork:no-op',8),halt(1)),"
             "error(domain_error(conjunction_answers,[]),_),halt(0))",
             "-t", "halt", "--", "extensions"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_wrong_count_fails_the_workload(self):
        """The measured operation refuses a planted missing result."""
        result = subprocess.run(  # noqa: S603 -- fixed count-refusal fixture
            ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g",  # noqa: S607 -- SWI from the gate's PATH
             "bench_operation(bench_nothing(Count),Count,2),halt",
             "-t", "halt", "--", "extensions"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("answered 1, expected 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
