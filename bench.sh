#!/bin/sh
# Purpose: this seat's benchmarks, standalone. `sh extensions/mork/bench.sh` is
#   what a developer runs and what extensions/mork/check.sh's mork-bench lane
#   runs, so the gate and the desk measure one thing.
#
#   Pass --update to re-pin extensions/mork/benchmarks/baseline.json after
#   reviewing the workload, and --sizes to explore off the committed ladder.
# Assumes: perf, setarch, swipl and a Python carrying the metta package. The
#   measurement harness is imported from that package rather than copied, which
#   is what DEVELOPING.md asks of a sibling.
# Guarantees:
#   - a missing tool or an unbuilt backend is NAMED and skipped rather than
#     failing the gate, the same split every component script here draws: a
#     toolchain that is absent exits 0 with a note, a measurement that runs and
#     regresses exits nonzero.
#   - the measurement itself is extensions/mork/benchmarks/bench.py, which
#     decides on instructions:u inside perf's own control window and records
#     CPU beside it, because SWI's inference counter is blind past the FFI.
# Open Obligations:
#   To Do: None
#   Hacks: None
#   Future Enhancements: None
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

PY=${CHECK_PY:-}
if [ -z "$PY" ]; then
    for candidate in "$HOME/Dev/.venv-pypetta/bin/python" \
                     "$HERE/../../.venv/bin/python" python3; do
        if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
    done
fi
command -v "$PY" >/dev/null 2>&1 || {
    echo "note: no python found (set CHECK_PY), the MORK benchmarks will not run" >&2
    exit 0
}

for artefact in mork_ffi/target/release/libmork_ffi.so mork_ffi/morklib.so; do
    if [ ! -f "$HERE/$artefact" ]; then
        echo "note: extensions/mork/$artefact is absent, so there is no backend \
to measure; run sh extensions/mork/build.sh" >&2
        exit 0
    fi
done
for tool in swipl perf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "note: $tool not found, the MORK benchmarks will not run" >&2
        exit 0
    fi
done
if [ ! -x /usr/bin/setarch ]; then
    echo "note: setarch not found, so address-space layout cannot be pinned \
and the MORK benchmarks will not run" >&2
    exit 0
fi

# One boot before the measurement, which is the same line check.sh runs before
# its lanes and for two reasons at once. engine/main.pl loads engine/qlf_boot.pl,
# which PURGES a .qlf set older than any source: the engine's units are
# consulted by umbrellas, so a unit edit leaves the umbrella's artifact fresh by
# mtime and the workload would otherwise measure the previous compile. And the
# boot REGENERATES the set, which is what the pins were taken against.
#
# Both halves are load-bearing and each fails differently. Loading the purge
# inside benchmarks/workload.pl instead puts it in the MEASURED process, worth
# +25,600 instructions on mork-native-match-first-500 and -470 on
# mork-window-floor. Purging without regenerating measures a SOURCE boot, which
# moves mork-batch-add-500 by -3.6% and mork-native-add-2000 by +1.2%, both far
# outside their 1% band [measured 2026-08-29, one A/B per half].
swipl -g halt -s "$HERE/../../engine/main.pl" -- extensions >/dev/null 2>&1 || true

exec "$PY" "$HERE/benchmarks/bench.py" "$@"
