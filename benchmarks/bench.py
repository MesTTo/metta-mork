"""Purpose: measure what this backend's crossings cost, against the same work
done by a native space, and hold every row to a committed baseline.

The question a storage backend has to answer is whether it is worth its
crossing at a given size, and that is a COMPARISON: the same atoms added one at
a time and in one batch, and the same query over a MORK space and over a native
one holding the same rows. Each is measured at three sizes, because one point
cannot say how the answer changes as the data grows.

Which counter decides, and why it is not the usual one. SWI's inference counter
retires nothing for work done inside the Rust library, so on every MORK row it
measures the Prolog half and is blind to the half the backend exists for; a
change measured here once read 526x faster by inferences and 1.8x SLOWER by
CPU. So instructions:u decides every row, CPU seconds are recorded beside it as
the counter it is checked against, and inferences are pinned as what they
honestly are: the exact, deterministic Prolog-side cost of the same operation.
Wall clock decides nothing.

Each row is measured inside perf's own control window, so the boot, the setup
and the teardown are outside the count. Whole-process subtraction was tried
first and is not usable at this resolution: one operation's difference read
+1,592,533 instructions under an inherited environment, +774,281 under LC_ALL=C
and -714,626 under LC_ALL=C.UTF-8, three stable modes selected by the
environment block rather than by any work [measured 2026-08-28, the flush case
at 500]. Inside the window the same operation repeats within 0.018%.
Guarantees:
  - the measured region holds the operation, because
    extensions/mork/benchmarks/workload.pl runs the setup before it opens the
    window [tested: extensions/mork/bench.sh]
  - what the window itself costs is a row, so a case near that floor is
    visible as mostly floor rather than read as a measurement
    [tested: extensions/mork/bench.sh]
  - a pinned row nothing measured fails the compare and is pruned aloud by an
    update, so a renamed case or a dropped size cannot leave a dead receipt
    reading as coverage [tested: extensions/mork/bench.sh]
  - every failing row is reported before the nonzero exit, so one regression
    never hides another [tested: extensions/mork/bench.sh]
Open Obligations:
  To Do: None
  Hacks: None
  Future Enhancements: None
"""  # noqa: D205  -- the measurement contract is one continuous narrative, not summary-and-body prose

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

SEAT = Path(__file__).resolve().parents[1]
ROOT = SEAT.parents[1]
WORKLOAD = SEAT / "benchmarks" / "workload.pl"
BASELINE = SEAT / "benchmarks" / "baseline.json"

# The harness lives in the Python seat and is imported rather than copied, as
# DEVELOPING.md requires. The path is prepended here because measure_instructions
# builds its child's environment from an allowlist that carries no PYTHONPATH,
# so a caller could not pass the seat down that way either.
sys.path.insert(0, str(ROOT / "extensions" / "python"))

from metta.testing import (  # noqa: E402  -- the sys.path line above is what makes this importable
    BenchmarkBaseline,
    measure_instructions,
)

SIZES = (500, 2000, 8000)
ROUNDS = 3

# Every case. The pairs below are the point: a row on its own says what
# something costs, and a pair says whether the backend earns its crossing.
CASES = (
    "batch-add",
    "per-atom-add",
    "native-add",
    "mork-match-first",
    "native-match-first",
    "mork-match-last",
    "native-match-last",
    "mork-match-open",
    "native-match-open",
    "flush",
)

# A selective query answers one row, which is too small to measure against the
# window's own handshake, so workload.pl asks it this many times and a row
# reports the cost of one. Everything else is measured once over `size` atoms.
QUERIES = 100
SELECTIVE = frozenset(
    {"mork-match-first", "native-match-first", "mork-match-last", "native-match-last"}
)

PAIRS = (
    ("batch-add", "per-atom-add", "one crossing against one per atom"),
    ("batch-add", "native-add", "MORK against native, writing"),
    ("mork-match-first", "native-match-first", "MORK against native, first argument bound"),
    ("mork-match-last", "native-match-last", "MORK against native, last argument bound"),
    ("mork-match-open", "native-match-open", "MORK against native, every row"),
)

COUNTERS = re.compile(r"inferences=(\d+) cputime=([0-9.]+)")


@dataclass(frozen=True)
class Row:
    """One measured case: what decides it, what checks it, and what it did.

    `instructions` are per-round differences and the pin the gate compares.
    `inferences` are the Prolog side alone, pinned because they are exact.
    `cpu` is the minimum of the same rounds, recorded and never compared.
    """

    name: str
    unit: str
    operations: int
    instructions: list[int]
    inferences: list[int] | None
    cpu: float | None

    def per_operation(self) -> float:
        """The deciding counter per atom written, row answered or atom published."""
        return min(self.instructions) / self.operations


def configuration() -> dict[str, bool]:
    """The artifacts whose presence moves these counters.

    Both MORK objects, because without them the seat is not loaded and there is
    nothing to measure; and the engine's C reader and writer, because swrite/2
    and sread/2 sit inside every crossing measured here -- each atom is written
    to text on the way into MORK and read back from text on the way out.
    """
    return {
        "c_reader": (ROOT / "engine" / "reader.so").is_file()
        and os.environ.get("METTA_C_READER") != "off",
        "c_writer": (ROOT / "engine" / "writer.so").is_file()
        and os.environ.get("METTA_C_WRITER") != "off",
        "mork_ffi": (SEAT / "mork_ffi" / "target" / "release" / "libmork_ffi.so").is_file(),
        "morklib": (SEAT / "mork_ffi" / "morklib.so").is_file(),
    }


def command(case: str, size: int, phase: str) -> list[str]:
    """One workload process. `extensions` is what makes the engine read seats."""
    return [
        "swipl", "-q", "-g", "true", "-t", "halt", str(WORKLOAD),
        "--", "extensions", case, str(size), phase,
    ]


def counters(case: str, size: int, rounds: int) -> tuple[list[int], float]:
    """The operation's own inference and CPU deltas, read in process.

    Measured apart from the perf runs rather than inside them: the perf subject
    must print nothing and read no clock, or the reading is part of the count.
    """
    inferences: list[int] = []
    cpu: list[float] = []
    for _ in range(rounds):
        finished = subprocess.run(
            command(case, size, "counters"),
            capture_output=True,
            text=True,
            check=False,
        )
        found = COUNTERS.search(finished.stdout)
        if finished.returncode != 0 or found is None:
            detail = finished.stderr.strip() or finished.stdout.strip()
            msg = (
                f"{case} at {size} did not report its counters "
                f"(exit {finished.returncode}): {detail}"
            )
            raise RuntimeError(msg)
        inferences.append(int(found.group(1)))
        cpu.append(float(found.group(2)))
    return inferences, min(cpu)


def windowed(case: str, size: int, rounds: int, attempts: int = 3) -> list[int]:
    """The operation's retired instructions, counted inside perf's own window.

    A window that never OPENED is retried, aloud. perf can fail to arm its
    counter while another session holds the PMU, and it acknowledges nothing
    when it does, so the workload's handshake times out and this run produced
    no measurement at all. Retrying that discards nothing: a run that returned
    a number is never retried, however slow or surprising the number is.
    """
    for attempt in range(1, attempts + 1):
        try:
            return list(
                measure_instructions(
                    command(case, size, "window"), rounds=rounds, controlled=True
                )
            )
        except (RuntimeError, TimeoutError) as unopened:
            if attempt == attempts:
                raise
            print(
                f"{case} at {size}: the window did not open "
                f"(attempt {attempt} of {attempts}): {unopened}"
            )
    msg = "unreachable: the loop above either returns or raises"
    raise AssertionError(msg)


def row_name(case: str, size: int) -> str:
    """The baseline key for one case at one size."""
    return f"mork-{case}-{size}"


def measure(sizes: tuple[int, ...], rounds: int) -> dict[str, Row]:
    """Every row, measured.

    The floor is measured first, so a cold .qlf pays there, and it is taken off
    every other row: what is left is the operation, and what stays in the floor
    row is the handshake, which moves for its own reasons and says so by name.
    """
    floor_samples = windowed("window-floor", sizes[0], rounds)
    floor_inferences, floor_cpu = counters("window-floor", sizes[0], rounds)
    floor = min(floor_samples)
    rows = {
        "mork-window-floor": Row(
            "mork-window-floor", "windows", 1, floor_samples, floor_inferences, floor_cpu
        )
    }
    print(f"mork-window-floor: instructions={floor_samples}")
    for size in sizes:
        for case in CASES:
            operations = QUERIES if case in SELECTIVE else size
            raw = windowed(case, size, rounds)
            instructions = [sample - floor for sample in raw]
            if any(value <= 0 for value in instructions):
                msg = (
                    f"{case} at {size} measured {raw!r}, at or below the "
                    f"{floor} instruction window floor: this case is the "
                    f"handshake and not a workload"
                )
                raise RuntimeError(msg)
            inferences, cpu = counters(case, size, rounds)
            name = row_name(case, size)
            unit = "queries" if case in SELECTIVE else "operations"
            rows[name] = Row(name, unit, operations, instructions, inferences, cpu)
            print(
                f"{name}: instructions={instructions} raw={raw} "
                f"inferences={inferences} cpu={cpu:.6f}s"
            )
    return rows


def compare(rows: dict[str, Row], *, update: bool, whole_ladder: bool) -> list[str]:
    """Hold every row to its pin. Answers one message per failing row."""
    baseline = BenchmarkBaseline(BASELINE, update=update)
    baseline.observe_configuration(configuration())
    failures: list[str] = []
    for row in rows.values():
        try:
            baseline.observe_counter(
                row.name,
                unit=row.unit,
                operations=row.operations,
                samples=row.inferences,
            )
        except AssertionError as outside:
            failures.append(str(outside))
        try:
            baseline.observe_instructions(row.name, row.instructions)
        except AssertionError as outside:
            failures.append(str(outside))
        if row.cpu is not None:
            baseline.observe_cpu(row.name, row.cpu / row.operations)
    # A pinned row nothing measured can never fail, so the promise "every case
    # is held to a committed count" would shrink in silence behind a renamed
    # case or a dropped size. Only the whole ladder can say a row is stale: a
    # deliberate subset run measures fewer rows on purpose.
    stale = sorted(set(baseline.cases) - set(rows))
    if stale and update:
        for name in stale:
            baseline.remove_case(name)
        print(f"pruned unmeasured baseline row(s): {', '.join(stale)}")
    elif stale and whole_ladder:
        failures.append(
            f"baseline rows nothing measured: {', '.join(stale)}; measure the "
            f"missing sizes or re-pin with --update to prune them"
        )
    baseline.finish()
    return failures


def report(rows: dict[str, Row], sizes: tuple[int, ...]) -> None:
    """The tables the comparison exists for: growth, and MORK against native."""
    print()
    print(
        "growth is the per-operation figure at the largest size over the "
        "smallest: 1.00x means the total scales linearly with the space, and "
        "below 1.00x means it scales better than linearly."
    )
    print()
    print("| case | " + " | ".join(f"{size} instr/op" for size in sizes) + " | growth |")
    print("|---" * (len(sizes) + 2) + "|")
    for case in CASES:
        cells = [rows[row_name(case, size)].per_operation() for size in sizes]
        growth = cells[-1] / cells[0] if cells[0] else 0.0
        print(
            f"| {case} | "
            + " | ".join(f"{cell:,.0f}" for cell in cells)
            + f" | {growth:.2f}x |"
        )
    print()
    print("| comparison | " + " | ".join(str(size) for size in sizes) + " |")
    print("|---" * (len(sizes) + 1) + "|")
    for left, right, label in PAIRS:
        ratios = [
            rows[row_name(left, size)].per_operation()
            / rows[row_name(right, size)].per_operation()
            for size in sizes
        ]
        print(f"| {label} | " + " | ".join(f"{ratio:.2f}x" for ratio in ratios) + " |")
    print()
    print(f"| case at {sizes[-1]} | inferences/op | CPU us/op | instructions/op |")
    print("|---|---|---|---|")
    for case in CASES:
        row = rows[row_name(case, sizes[-1])]
        if row.inferences is None or row.cpu is None:
            continue
        print(
            f"| {case} | {min(row.inferences) / row.operations:,.1f} | "
            f"{row.cpu / row.operations * 1e6:.3f} | {row.per_operation():,.0f} |"
        )


def main(argv: list[str] | None = None) -> int:
    """Measure every case at every size and update or compare its pins."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--rounds", type=int, default=ROUNDS)
    parser.add_argument(
        "--sizes",
        type=lambda text: tuple(int(part) for part in text.split(",")),
        default=SIZES,
    )
    arguments = parser.parse_args(argv)

    # What else the box was doing, recorded with every run rather than
    # remembered: instructions:u is far steadier than wall clock but the two
    # noisiest rows here are the native-space ones, and a reader comparing two
    # runs needs to know whether the machine was busy for either.
    print(f"loadavg: {Path('/proc/loadavg').read_text().strip()}")
    rows = measure(arguments.sizes, arguments.rounds)
    report(rows, arguments.sizes)
    failures = compare(
        rows,
        update=arguments.update,
        whole_ladder=tuple(arguments.sizes) == SIZES,
    )
    if failures:
        print()
        for message in failures:
            print(message, file=sys.stderr)
        print(f"{len(failures)} row(s) outside the band", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
