#!/bin/sh
# Purpose: this seat's benchmarks, standalone. `sh extensions/mork/bench.sh` is
#   what a developer runs and what extensions/mork/check.sh's mork-bench lane
#   runs, so the gate and the desk measure one thing.
#
#   Pass --update to re-pin extensions/mork/benchmarks/baseline.json after
#   reviewing the workload, and --sizes to explore off the committed ladder.
#   --conjunction-sweep compares product joins with native queries, including
#   a transferred route, and --output preserves every raw counter sample.
# Assumes: perf, setarch, swipl and a Python carrying the metta package. The
#   measurement harness is imported from that package rather than copied, which
#   is what DEVELOPING.md asks of a sibling.
# Guarantees:
#   - a missing tool or an unbuilt backend is NAMED and skipped rather than
#     failing the gate, the same split every component script here draws: a
#     toolchain that is absent exits 125 with a note, which the gate reports as
#     `skipped` and names under MEASURED NOTHING, while a measurement that runs
#     and regresses exits nonzero. The two must not share exit 0, or a lane
#     that compared nothing is indistinguishable from one that compared
#     everything.
#   - the measurement itself is extensions/mork/benchmarks/bench.py, which
#     decides on instructions:u inside perf's own control window and records
#     CPU beside it, because SWI's inference counter is blind past the FFI.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

METTA_ROOT="$HERE/../.."
TMPDIR=${TMPDIR:-"$METTA_ROOT/ai-tmp"}
mkdir -p "$TMPDIR"
export TMPDIR

# A missing prerequisite means this run says nothing about the tree, and 125 is
# the one word for that here: check.sh's run() turns it into `skipped` and
# names the lane under MEASURED NOTHING, where exiting 0 reports `ok` for a run
# that compared not one row. This lane has already answered `ok` on four of
# five whole-gate runs while another session held the PMU, and node-bench did
# the same on 2026-09-20 in a battery with no node_modules; a benchmark that
# cannot see is indistinguishable from a passing one until this word is used.
unmeasured() {
    echo "note: $*" >&2
    exit 125
}

. "$HERE/../../tools/select-python.sh"
if [ -z "$PY" ]; then
    unmeasured "no python found (set CHECK_PY), the MORK benchmarks will not run"
fi

for artefact in mork_ffi/target/release/libmork_ffi.so mork_ffi/morklib.so; do
    if [ ! -f "$HERE/$artefact" ]; then
        unmeasured "extensions/mork/$artefact is absent, so there is no backend \
to measure; run sh extensions/mork/build.sh"
    fi
done
for tool in swipl perf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        unmeasured "$tool not found, the MORK benchmarks will not run"
    fi
done
if [ ! -x /usr/bin/setarch ]; then
    unmeasured "setarch not found, so address-space layout cannot be pinned \
and the MORK benchmarks will not run"
fi

# A purge and then one boot before the measurement, so the governed .qlf set the
# workload loads is always the one engine/main.pl regenerates, which is what the
# pins were taken against. The boot alone purged only a set older than a source,
# and a FRESH set another boot path left is not that set: the C and engine
# benches prepare theirs through engine/bench.pl, which also compiles
# engine/identity.qlf and engine/source_loading.qlf where main.pl's boot consults
# those two from source, and loading them compiled moved mork-native-add-500 and
# -2000 by +1.23% and +1.22% with their inferences unchanged, so this lane failed
# whenever c-bench ran before it in the gate [measured 2026-09-24: in one battery
# on one tree, 10,411,451 after c-bench's boot preparation and 10,280,582 after a
# purge; commit=98549966e58c9455bfaf539b54641c555fc9da5e]. The lane runs alone
# in check.sh, so the purge races no other lane's boot.
#
# Both halves are load-bearing and each fails differently. Loading the purge
# inside benchmarks/workload.pl instead puts it in the MEASURED process, worth
# +25,600 instructions on mork-native-match-first-500 and -470 on
# mork-window-floor. Purging without regenerating measures a SOURCE boot, which
# moves mork-batch-add-500 by -3.6% and mork-native-add-2000 by +1.2%, both far
# outside their 1% band [measured 2026-08-29, one A/B per half].
# One spelling of the bound, implemented in bounded.sh, which every runner in
# this tree and a command typed by hand all reach.
bounded() { sh "$HERE/../../tools/bounded.sh" "$@"; }

bounded swipl -q -s "$HERE/../../engine/qlf_boot.pl" -g metta_qlf_boot:purge_all_qlf -t halt \
    </dev/null >/dev/null 2>&1 || true
bounded swipl -g halt -s "$HERE/../../engine/main.pl" -- extensions >/dev/null 2>&1 || true

exec sh "$HERE/../../tools/bounded.sh" "$PY" "$HERE/benchmarks/bench.py" "$@"
