"""Purpose: prove the MORK benchmark's counter window and conjunction sweep.

Guarantees: both stores check complete answer bags, and planted changes to any
size's counter fail in either direction [tested: sh check.sh mork-bench-selftest; commit=6da518669cb9e39557d537857c0aa7190dd2e78f].
The control pipe preserves whole commands when the writer yields between bytes
[tested: BenchmarkTests.test_control_commands_arrive_complete; commit=WORKTREE].
Each acknowledgement consumes and validates perf's complete five-byte frame
[tested: BenchmarkTests.test_acknowledgements_consume_complete_frames,
BenchmarkTests.test_acknowledgements_refuse_wrong_or_truncated_frames; commit=WORKTREE].
Calibration modes retain minimum subtraction and cannot hide injected window
work; calibration still requires exactly five inferences and never overwrites
its historical instruction number
[tested: BenchmarkTests.test_calibration_does_not_hide_injected_window_work,
BenchmarkTests.test_calibration_keeps_exact_inferences_and_instruction_history; commit=WORKTREE].
The first count of a prepared query pays no library resolution
[tested: BenchmarkTests.test_first_count_does_not_load_a_library_inside_the_window;
commit=WORKTREE].
Owns resources: each test process owns its stores until exit. Temporary baseline
files stay below the repository's scratch and are removed after each test.
The pipe probe closes its descriptors and joins its receiver after the child exits.
"""

import concurrent.futures
import contextlib
import io
import json
import os
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

    def acknowledgement_probe(self, payload, goal):
        """Feed the real decoder a finite binary stream and retain its exit."""
        with tempfile.NamedTemporaryFile(prefix="ai-perf-ack-", dir=ROOT / "ai-tmp") as stream:
            stream.write(payload)
            stream.flush()
            return subprocess.run(  # noqa: S603 -- fixed decoder and local byte fixture
                ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g",  # noqa: S607 -- gate's SWI
                 "current_prolog_flag(argv,[extensions,File]),"
                 "open(File,read,In,[type(binary)])," + goal,
                 "-t", "halt", "--", "extensions", stream.name],
                capture_output=True, text=True, check=False,
            )

    def test_acknowledgements_consume_complete_frames(self):
        """Enable and disable leave no terminator in the next acknowledgement."""
        result = self.acknowledgement_probe(
            b"ack\n\0ack\n\0Z",
            "bench_acknowledge(In),bench_acknowledge(In),get_byte(In,Next),"
            "close(In),(Next=:=90->halt(0);format('remaining=~d~n',[Next]),halt(1))",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_acknowledgements_refuse_wrong_or_truncated_frames(self):
        """A newline alone does not prove that perf acknowledged the command."""
        for payload in (b"bad\n\0", b"ack\n", b"ack", b""):
            with self.subTest(payload=payload):
                result = self.acknowledgement_probe(
                    payload,
                    "catch(bench_acknowledge(In),error(io_error(read,perf_control),_),"
                    "Caught=true),close(In),(Caught==true->halt(0);halt(1))",
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_count_does_not_load_a_library_inside_the_window(self):
        """A prepared query has the same inference cost on its first two counts."""
        result = subprocess.run(  # noqa: S603 -- fixed prepared-query counter probe
            ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g",  # noqa: S607 -- gate's SWI
             "bench_join_fill('&native-bench-autoload',8),"
             "bench_check_join('&native-bench-autoload',8),"
             "findall(Cost,(between(1,2,_),statistics(inferences,I0),"
             "bench_join_count('&native-bench-autoload',0),"
             "statistics(inferences,I1),Cost is I1-I0),[First,Second]),"
             "format('counts=~d,~d~n',[First,Second]),First=:=Second,halt",
             "-t", "halt", "--", "extensions"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_control_commands_arrive_complete(self):
        """A scheduled receiver must never see part of an enable or disable tag."""
        control_read, control_write = os.pipe()
        ack_read, ack_write = os.pipe()
        commands = []

        def receive():
            while chunk := os.read(control_read, 4096):
                commands.append(chunk)
                # Acknowledge partial messages too so a broken writer can exit
                # and report its actual deliveries instead of blocking cleanup.
                with contextlib.suppress(BrokenPipeError):
                    os.write(ack_write, b"ack\n\0")

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            receiver = executor.submit(receive)
            try:
                try:
                    process = subprocess.Popen(  # noqa: S603 -- fixed delayed-writer probe
                        ["swipl", "-q", "-s", str(bench.WORKLOAD), "-g",  # noqa: S607 -- gate's SWI
                         "use_module(library(prolog_wrap)),"
                         "wrap_predicate(bench_put(Codes,Stream),wire_probe,Wrapped,"
                         "(sleep(0.02),call(Wrapped))),main,halt", "-t", "halt", "--",
                         "extensions", "window-floor", "500", "window"],
                        env=dict(os.environ, METTA_PERF_CONTROL_FD=str(control_write),
                                 METTA_PERF_ACK_FD=str(ack_read)),
                        pass_fds=(control_write, ack_read), stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True,
                    )
                finally:
                    os.close(control_write)
                    os.close(ack_read)
                with process:
                    _, stderr = process.communicate()
                receiver.result()
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(commands, [b"enable\n", b"disable\n"])
            finally:
                os.close(control_read)
                os.close(ack_write)

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

    def test_calibration_does_not_hide_injected_window_work(self):
        """Real comparison sees each injected window count after minimum subtraction."""
        modes = [14006, 16068, 16780, 18841]
        extra = {}

        def window(case, size, _rounds):
            if case == "window-floor":
                return modes
            return [14006 + 1_000_000 + extra.get((case, size), 0)] * 3

        original = bench.BASELINE.read_bytes()
        with (
            tempfile.TemporaryDirectory(prefix="ai-mork-calibration-", dir=ROOT / "ai-tmp") as directory,
            patch.object(bench, "BASELINE", Path(directory) / "baseline.json"),
            patch.object(bench, "configuration", return_value=json.loads(original)["counter_configuration"]),
            patch.object(bench, "windowed", side_effect=window),
            patch.object(bench, "counters", return_value=([5, 5, 5], 0.001)),
            contextlib.redirect_stdout(io.StringIO()) as printed,
        ):
            bench.BASELINE.write_bytes(original)
            rows = bench.measure(bench.SIZES, bench.ROUNDS)
            self.assertEqual(len(rows), 39)
            self.assertEqual(bench.compare(rows, update=True, whole_ladder=True), [])
            for row in rows.values():
                if row.unit != "windows":
                    self.assertEqual(row.instructions, [1_000_000] * 3)
            # Vary the observed modes while retaining the lower boundary.
            modes[:] = [18841, 14006, 16068]
            self.assertEqual(bench.compare(bench.measure(bench.SIZES, bench.ROUNDS),
                                          update=False, whole_ladder=True), [])
            schedule = [(case, size) for size in bench.SIZES for case in bench.CASES]
            schedule += [(case, size) for size in bench.JOIN_SIZES for case in bench.JOIN_CASES]
            self.assertEqual(len(schedule), 38)
            for target in schedule:
                for change in (-100_000, 100_000):
                    extra[target] = change
                    measured = bench.measure(bench.SIZES, bench.ROUNDS)
                    name = bench.row_name(*target)
                    self.assertEqual(measured[name].instructions, [1_000_000 + change] * 3)
                    failures = bench.compare(measured, update=False, whole_ladder=True)
                    self.assertEqual(len(failures), 1, failures)
                    self.assertIn(name, failures[0])
                extra.clear()
            report = printed.getvalue()
            self.assertIn("CALIBRATION", report)
            self.assertIn("instructions=[18841, 14006, 16068]", report)
            self.assertIn("modes=[14006, 16068, 18841]", report)
            self.assertIn("subtraction=14006", report)

    def test_calibration_keeps_exact_inferences_and_instruction_history(self):
        """Instruction calibration can vary; its empty Prolog operation cannot."""
        original = bench.BASELINE.read_bytes()
        history = json.loads(original)["benchmarks"]["mork-window-floor"]["instructions"]
        row = bench.Row("mork-window-floor", "windows", 1, [history] * 3, [5] * 3, None)
        with (
            tempfile.TemporaryDirectory(prefix="ai-mork-calibration-", dir=ROOT / "ai-tmp") as directory,
            patch.object(bench, "BASELINE", Path(directory) / "baseline.json"),
            patch.object(bench, "configuration", return_value=json.loads(original)["counter_configuration"]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            bench.BASELINE.write_bytes(original)
            self.assertEqual(bench.compare({row.name: row}, update=False, whole_ladder=False), [])
            for count in (4, 6):
                changed = replace(row, inferences=[count] * 3)
                failures = bench.compare({row.name: changed}, update=False, whole_ladder=False)
                self.assertEqual(len(failures), 1, failures)
                self.assertIn("exactly 5 inferences", failures[0])
            calibrated = replace(row, instructions=[14006, 16068, 18841])
            self.assertEqual(bench.compare({row.name: calibrated}, update=True, whole_ladder=False), [])
            recorded = json.loads(bench.BASELINE.read_text())["benchmarks"][row.name]
            self.assertEqual(recorded["instructions"], history)
            self.assertEqual(recorded["inferences"], 5)

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
