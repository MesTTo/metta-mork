<!--
Purpose: document the MORK extension: what it provides, what it needs, and how to build it.
Guarantees: every name here is one the extension registers or a path it ships
  [source: extensions/mork/extension.pl; extensions/mork/mork_ffi/morkspaces.pl].
-->

# MORK: spaces on a Rust trie

MORK is a storage backend. It puts the atoms of a named space in
[MORK](https://github.com/trueagi-io/MORK)'s Rust trie instead of in the
engine's own store, and it reaches it over a text FFI protocol through a
shared object this extension builds.

Nothing in the engine names it. It arrives the way every extension arrives, through
`seam:foreign_space/1`, so the engine asks the seam who owns a space name and
MORK answers for its own. A space this extension does not own leaves every ownership
hook by FAILING rather than refusing, which is what lets the next provider's
clause run.

## What it needs

`extension.pl` declares it, and the engine reads that file rather than running
it:

```prolog
title('Spaces on MORK''s Rust trie, over the FFI').
needs(artefact('mork_ffi/target/release/libmork_ffi.so')).
needs(artefact('mork_ffi/morklib.so')).
needs(predicate(open_shared_object/3)).
entry(engine, 'mork_ffi/morkspaces.pl').
```

Both shared objects are named because the backend needs both: `morkspaces.pl`
opens `libmork_ffi.so` for its global symbols and then loads `morklib.so` for
`mork/3` itself. It throws when either is missing, but SWI PRINTS a load-time
directive that throws and keeps consulting, so before the second need was
declared a tree carrying only the first reported a live backend whose every
call was `Unknown procedure: mork/3`, on every boot, quietly.

The third need is the platform itself. A WebAssembly build mounts this
checkout's files, so the `.so` is there to be SEEN while
`open_shared_object/3` does not exist to open it. The build is fine and the
platform has no dynamic linking, so the honest answer is the same as an unbuilt
tree's: the extension loads nothing and says nothing.

## Building it

The root `build.sh` provisions and validates published upstream commits:

| dependency | revision |
|---|---|
| MORK | `ed57c6716d8c510296fb5fbb8be6fbfe2df241d7` |
| PathMap | `0010dbbd52d13fad67e9a7dabfdadb1cfea71fe1` |

Both checkouts live beside this repository. `mork_ffi/Cargo.lock` pins the
remaining dependency graph. The bridge uses MORK's `ItemSink` application API
and PathMap 0.4.0. It retains the default `ProductZipper` query path; the
optional upstream `leapfrog` feature is not enabled. These revisions are the
published branch tips checked on 2026-09-08.

```sh
sh extensions/mork/build.sh
```

It needs `cargo`. Without the artefact the extension simply does not load, and a
program that needs it is told so by name rather than failing at the call:

```metta
!(require-extension! mork)
```

That is `lib/lib_mm2/lib_mm2.metta`'s first line, because every operator in that
library is a notation over `&mork`.

## What it provides

Spaces whose names begin `&mork`, plus three builtins declared through the same
seam every extension uses:

| builtin | effect class | what it does |
|---|---|---|
| `mork-add-atoms` | `writesState` | add many atoms in one crossing, rather than one call per atom |
| `mork-flush` | `writesState` | push buffered writes through the FFI |
| `mm2-exec` | `oracleIO` | run MM2 steps in MORK itself |

`lib_mm2` is the MeTTa-level surface over those: five operators over `&mork`,
loaded on demand with `!(import! &self (library lib_mm2))`.

## Testing it

```sh
sh extensions/mork/test.sh
sh extensions/mork/check.sh
```

`tests/mork_seat.plt` covers the three builtins, the claim over the namespace,
and the failure discipline that lets the next provider's clause run for a space
this extension does not own. Every test in it is conditioned on the extension being
loaded, so an unbuilt tree skips them. That is why `test.sh` says which
configuration it ran and fails a built tree that reported anything less than the
whole file.

`check.sh` delegates to the root gate and runs this seat's tests, benchmark,
lint, benchmark selftest and Rust unit tests. The selftest plants changed instruction counts
on both sides of each sweep pin, a missing size, a wrong answer count, and
wrong triples whose count is still correct. The Python MORK tests also compare
projected join bags over generated ground graphs against native storage.

`tests/test_missing_artefacts.sh` covers what a built tree cannot reach. It
builds a scratch tree of symlinks whose extension is the shipped `extension.pl` and
whose artefact is genuinely absent, so the loader's own `exists_file` check is
what runs, and then asks for the three properties an absent backend owes: the
boot writes nothing to either stream, the unmet need is recorded by name, and
`!(require-extension! mork)` refuses naming the extension, the missing file and
`extensions/mork/build.sh`. Its third configuration is a negative control: the
same tree under a control file declaring one artefact, which is what this extension
shipped until 2026-08-28, and there the suite above has to go red.

## Measuring it

```sh
sh extensions/mork/bench.sh              # compare against the committed pins
sh extensions/mork/bench.sh --update     # re-pin after reviewing the workload
```

Ten cases at three sizes, each measured inside perf's own control window so the
boot and the setup are outside the count, and each held to
`benchmarks/baseline.json`.

Eight more rows measure a skewed triangle query over 100, 400, 1600 and 3200
atoms, in a native store and a MORK store. For `H = N // 2`, both receive
`edge(I, 0)` for `1 <= I <= H` and `edge(0, J)` for `H < J <= N`. The query
`(edge X Y), (edge Y Z), (edge Z X)` answers no triangles. Setup plants one
closing edge, checks the three projected rotations, removes it and verifies
the empty answer before measuring. An always-empty query fails this control.
One complete query runs inside the window. The report fits the four instruction
minima to N raised to an exponent; each row's `measures` records the reviewed
fit. It describes the measured sizes, not a bound over all inputs.

At the published pair above, measured on 2026-09-08:

| route | N=100 | N=400 | N=1600 | N=3200 | fitted exponent |
|---|---:|---:|---:|---:|---:|
| native | 1,009,928 | 3,915,471 | 15,537,045 | 31,065,221 | 0.988795 |
| MORK | 7,997,175 | 122,623,865 | 1,567,416,445 | 7,508,864,472 | 1.951383 |

These are retired instructions for one query. Native exhibits linear growth
and MORK quadratic growth over this family. The old-pair control gives the
same classes. The pin journal at
`docs/journal/2026-09-08-the-mork-pin-advanced.md`
records both pairs, every original row's change and the controls. The simpler
two-edge path graph is linear on both pairs, so it cannot replace this skewed
fixture when assessing a join algorithm.

Every pin uses the minimum of three samples. The instruction bands are
two-sided, so an improvement beyond the band also requires a reviewed re-pin.
Load is printed before and after each row. `--sizes` explores the original
crossing cases while the conjunction sweep retains its four sizes; `--update`
requires the complete default set so it cannot erase unmeasured pins.

**instructions:u decides every row and CPU is recorded beside it.** SWI's
inference counter retires nothing for work done inside the Rust library, and
this suite shows exactly what that hides: `mork-match-first` and
`mork-match-last` both read 133 inferences per query at 8000 atoms, while CPU
reads 7.4 microseconds for one and 342.7 for the other. Wall clock decides
nothing.

What the comparison says, measured 2026-08-28 at 500, 2000 and 8000 atoms:

| | 500 | 2000 | 8000 |
|---|---|---|---|
| batch add against one add per atom | 0.34x | 0.33x | 0.33x |
| MORK against native, writing | 2.31x | 2.26x | 2.20x |
| MORK against native, first argument bound | 10.31x | 10.34x | 10.32x |
| MORK against native, last argument bound | 46.62x | 133.83x | 611.51x |
| MORK against native, every row | 10.63x | 10.79x | 10.88x |

Writing in batches is worth three of the per-atom form and stays worth it as the
load grows. Everything else is a flat multiple of a native space except the
last-argument query, and that one is the shape of the store: MORK holds an atom
as a PATH, so a bound first argument is a prefix it descends to in constant
time and a bound last argument is a constraint it can only check after walking
the whole space. Per query at 8000 that is 141,876 instructions against
8,470,666.
