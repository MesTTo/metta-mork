# Changelog

## Unreleased

- Re-pin twenty-four instruction rows to the swipl the measurement names.
  Since 310b6a9a2 metta-benchmarking counts the swipl on the measurement's
  PATH, the patched build, where it counted the stock swipl that perf's own
  PATH put first. On that build batch-add, per-atom-add, mork-match-first,
  mork-match-open and native-match-open cost 3 to 6 percent fewer
  instructions and native-add, native-match-first and native-match-last about
  1 percent more, which left fifteen rows outside their bands and the native
  ones at their edge. Inference pins and every other row are unchanged; the
  ladder that places the move is in `benchmarks/baseline.json`'s
  `host_count_repin_comment`.

- `bench.sh` purges the governed .qlf set before the boot that regenerates it,
  so the workload always loads the set `engine/main.pl` builds, which is what
  the pins were taken against. The boot alone purged only a stale set, and a
  fresh one the C bench had prepared compiles two more units, which moved
  mork-native-add by +1.2% whenever c-bench ran first in the gate.

- Add a conjunction-only instruction sweep with configurable sizes and a JSON
  receipt. Compare the existing native and MORK queries with a third route that
  includes MORK enumeration, native insertion, matching and snapshot release.
  Check positive and empty answer bags before measuring. Report every observed
  winner transition without inferring a universal threshold.
- Record a 139–140 row crossover for the warmed two-hub triangle workload.
  Production routing and L069 remain open pending the engine ownership and
  language-policy decision described in `benchmarks/conjunction-routing.md`.
