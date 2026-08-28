# Purpose: this component's own gate lanes, in the root gate's vocabulary.
# Assumes: it is SOURCED by check.sh, not executed. That is what lets it use
#   `run`, `$HERE`, `$PY` and the shared summary table, so one component's lanes
#   cannot report their own status differently from another's, and a child's
#   exit code cannot be lost on the way back up -- the hazard a driver that
#   EXECUTES its children has to solve and this one does not have.
# Guarantees: every path a lane runs is written literally. tests/checks/
#   evidence_runners.py models which files a lane covers by READING this text
#   and resolving $HERE/, so a path reached through a local variable is a path
#   the evidence gate cannot see.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None

# The MORK backend, which is the seam's storage consumer: named spaces whose
# atoms live in MORK's Rust trie instead of the engine's own store, reached over
# a text FFI. Until 2026-08-28 it owned no tests and no lanes at all -- what
# tested it lived in extensions/python/tests/ch19_spaces_backed_by_anything/
# test_mork_space.py and tests/prolog/suites/seams/extensions.plt, so the seat
# could be present and broken in a configuration neither of those exercised.
#
# The suites it runs are extensions/mork/tests/mork_seat.plt, which needs the
# built backend, and extensions/mork/tests/test_missing_artefacts.sh, which
# needs it ABSENT and builds its own tree of symlinks to get that. Both are
# named here rather than only inside test.sh because the evidence gate reads
# this text to learn which files a lane executes, and test.sh reaches them
# through a glob it cannot see.
#
# Nothing here builds anything: cargo is not fetched, and a tree without the
# backend runs the seat-absent half and says which half it ran.
check_mork_seat() {
    sh "$HERE/extensions/mork/test.sh"
}
run GATE mork-seat check_mork_seat

# The measurements, extensions/mork/benchmarks/bench.py over
# extensions/mork/benchmarks/workload.pl, held to
# extensions/mork/benchmarks/baseline.json. It decides on instructions:u inside
# perf's own control window and records CPU beside every row, because SWI's
# inference counter retires nothing for work done inside the Rust library: the
# flush case reads 19 inferences whether it publishes 500 atoms or 8000, and
# 12.7M instructions for the larger one.
#
# perf, setarch and the built backend are all requirements bench.sh names and
# skips on rather than failing, the same split every component script draws.
check_mork_bench() {
    sh "$HERE/extensions/mork/bench.sh"
}
run GATE mork-bench check_mork_bench

# The seat's Python, which the root ruff lane does not reach: it runs
# `ruff check metta tests bench.py` from inside extensions/python, so
# extensions/mork/benchmarks/bench.py is linted by nothing without this. The
# Python seat's configuration is used rather than a second one, because there
# is one house style and a component that argued with it would be the defect.
check_mork_lint() {
    [ -f "$HERE/extensions/python/pyproject.toml" ] || return 0
    "$PY" -m ruff check --config "$HERE/extensions/python/pyproject.toml" \
        "$HERE/extensions/mork/benchmarks/bench.py"
}
run GATE mork-lint check_mork_lint
