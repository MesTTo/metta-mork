# Changelog

## Unreleased

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
