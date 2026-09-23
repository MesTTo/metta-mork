# Conjunction routing measurement

The warmed two-hub workload crosses from direct MORK to a copied native
snapshot at **140 rows**. At 139 rows MORK retires 13,633,989 instructions and
transfer retires 13,721,466. At 140 rows those costs are 13,933,551 and
13,775,352. This is an observed crossing between adjacent integer sizes, not
a threshold established for other distributions or queries.

## Reproduce

Run from the PeTTa root in a provisioned battery tree with the MORK artifacts:

```sh
METTA_CHILD_CEILING=0 sh extensions/mork/bench.sh --conjunction-sweep \
  --join-sizes 100,128,136,137,138,139,140,160,400,1600,3200 \
  --output extensions/mork/benchmarks/conjunction-sweep.json
```

`METTA_CHILD_CEILING=0` disables the repository runner's runtime deadline.
The command measures three rounds per route and size using `instructions:u`
inside perf's control window. Each sample subtracts the smallest measured empty
window. The table uses the smallest of the three corrected samples.
CPU seconds and Prolog inferences are retained as diagnostics. Neither chooses
the winner: Prolog inferences do not count the Rust work beyond the FFI.
The [JSON receipt](conjunction-sweep.json) retains the samples, artifact
configuration, loaded seats and source hashes for the run on 2026-09-23.

There are N distinct ground edge facts. The first floor(N/2) edges enter hub
0; the remaining edges leave it. The measured query is:

```metta
(match &space (, (edge $x $y) (edge $y $z) (edge $z $x)) ($x $y $z))
```

It returns an empty bag. Setup first adds a closing edge and requires all
three rotations of the resulting triangle, removes that edge, then requires
the empty bag. Every route performs its own positive control, so an
always-empty implementation fails before measurement.

`native-conjunction` queries a prepared native store. `mork-conjunction`
queries a prepared MORK store. `transferred-conjunction` starts with the same
MORK facts and measures creating a native space, enumerating and inserting
every row, running the native query, and releasing the snapshot. These
different starting states matter: a fast query over an already native store
does not establish that converting a MORK store is worthwhile.

Snapshot services and matching are warmed by setup, but each measured
transferred query creates and populates a fresh space. A separate cold probe
cost 29,237,626 instructions at N=100 and 44,478,729 at N=400. Its crossing was
only bracketed between those sizes; the 140 result applies to the warmed run.

## Sweep output

The following is the successful command's output table:

| skewed triangle | 100 | 128 | 136 | 137 | 138 | 139 | 140 | 160 | 400 | 1600 | 3200 | fitted exponent |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| native-conjunction | 1,236,272 | 1,570,478 | 1,665,461 | 1,673,228 | 1,689,230 | 1,696,924 | 1,712,944 | 1,950,179 | 4,806,947 | 19,089,593 | 38,165,695 | 0.9904 |
| mork-conjunction | 7,988,189 | 11,911,076 | 13,190,041 | 13,356,596 | 13,465,025 | 13,633,989 | 13,933,551 | 17,526,510 | 122,615,055 | 1,567,407,405 | 7,508,855,437 | 1.9805 |
| transferred-conjunction | 11,735,647 | 13,161,712 | 13,571,914 | 13,617,189 | 13,675,602 | 13,721,466 | 13,775,352 | 14,786,957 | 26,997,858 | 89,157,102 | 171,540,157 | 0.7779 |

```text
crossover comparison: mork-conjunction versus transferred-conjunction
crossover bracket: 139 < N <= 140; transferred-conjunction wins at N=140
native-conjunction excludes migration; transferred-conjunction includes MORK enumeration, native insertion, the query, and release.
```

The exponents fit log(instructions) against log(N) over these samples; they
are not complexity proofs. MORK's product enumerates the incoming/outgoing
pairs before finding no closing edge. Native matching can select the bound
closing conjunct earlier. The copied route also pays allocation and insertion
costs; its fitted exponent does not establish sublinear copying.

## What routing the measurement supports

For this warmed workload with facts already in MORK, select the cheaper
measured route: MORK at sampled N=100 through 139, a native snapshot at
sampled N=140 through 3200. Unsampled sizes and different query distributions
require measurements. When the same facts already reside in native storage,
native matching wins at every sampled size and there is no observed crossover.

No general atom-count threshold is installed. The existing query-planning
record, `docs/journal/2026-09-05-query-planning.md` in PeTTa, already distinguishes
skewed, uniform and clique inputs. A two-hub crossing cannot predict all of
those workloads. Startup and total cost are different quantities, as in
[PostgreSQL's cost model](https://github.com/postgres/postgres/blob/REL_18_0/src/backend/optimizer/path/costsize.c#L37-L50).
That analogy would not transfer if only full enumeration mattered and there
were no initialization or conversion costs; here both are directly measured.

Declining `seam:foreign_plan/5` is not a native-route implementation:
`engine/spaces/bounded_matching.pl` commits foreign spaces to its foreign
matching path and falls back to source-order foreign matching. The native
reordered matcher lives in `engine/spaces/native_matching.pl`. The benchmark
therefore constructs a real native snapshot instead of pricing that fallback
as though it were the native algorithm.

## Open integration

This change delivers the differential. It does not close production routing
or L069. L069's two new declaration kinds and solver consumers belong to
`engine/spaces/catalog.pl`,
`engine/spaces/native_matching.pl` and `engine/metta/effects.pl`, outside the
MORK seat. Their language vocabulary remains a product decision.
Installing a second policy mechanism only in the MORK provider
would leave the requested engine consumers unchanged.

Measured route selection needs an agreed workload declaration and its engine
consumer. Existing provider routing remains unchanged. The native-copy
benchmark is deliberately confined to ground edge facts; it does not establish
equivalence for arbitrary catalog
rows, rule definitions, variable-bearing facts or bounded demand.

## Verification and failed attempts

The full 11-size sweep exited 0 in battery 4. All 17 benchmark tests passed,
including complete answer-bag controls, an always-empty transfer mutation,
snapshot release on cut, source preservation, invalid CLI inputs and
nonmonotone crossover reporting. The complete repository release gate was not
run for this change. Ruff passed on the two changed Python files, and jscpd
found no clones across their 948 lines with a 12-line minimum.

A preceding refinement run failed after N=160 with
`RuntimeError: perf stat failed with exit 143: Events disabled`, followed by
`swipl: Terminated` and `<not counted>,,instructions:u,0,100.00,,`.
The termination cause is unconfirmed; that incomplete run is not the receipt.
An own-code warning, `Clauses of bench_case/6 are not together in the source-file`,
was fixed by moving the helper definitions below all case clauses before the
successful rerun. Existing engine warnings included `Illegal multibyte Sequence`.

An initial selftest used the wrong Python and failed with
`ImportError: deferred module publication requires CPython 3.12 or later`.
Using the venv interpreter that carries the patched host passed all 17 tests.
Battery contention also produced
`battery 3 is running as PID 73502; pick another index` and
`rm: cannot remove '<checkout>/ai-tmp/wt-battery-2/extensions/python.gitseed/tests/ch15_writing_transactions_and_worlds': Directory not empty`, the checkout's own path shortened here to `<checkout>`.
Battery 4 supplied the successful measurements.
